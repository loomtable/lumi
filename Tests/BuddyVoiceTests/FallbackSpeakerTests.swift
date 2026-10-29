import Testing
@testable import BuddyVoice

private struct PlaybackBroke: Error {}

/// A speaker that records calls and fails on demand.
private actor StubSpeaker: LoadableSpeaker {
    var loadError: (any Error)?
    var speakError: (any Error)?
    /// Speak waits this long before failing or answering, so a stop can land in between.
    var speakDelay: Duration = .zero
    private(set) var spoken: [String] = []
    /// Speak calls started, answered or not.
    private(set) var speakCalls = 0
    private(set) var continued: [String] = []
    private(set) var stops = 0
    private(set) var warmUps = 0
    private(set) var loads = 0

    init(loadError: (any Error)? = nil, speakError: (any Error)? = nil, speakDelay: Duration = .zero) {
        self.loadError = loadError
        self.speakError = speakError
        self.speakDelay = speakDelay
    }

    func setLoadError(_ e: (any Error)?) { loadError = e }

    /// Load takes this long (a launch still loading models and warming up).
    var loadDelay: Duration = .zero
    func setLoadDelay(_ d: Duration) { loadDelay = d }
    private var loaded = false
    func load() async throws {
        if loaded { return }
        loads += 1
        if loadDelay > .zero { try await Task.sleep(for: loadDelay) }
        if let loadError { throw loadError }
        loaded = true
    }
    func warmUp() async { warmUps += 1 }
    /// Per-call delays, used before `speakDelay`.
    var speakDelays: [Duration] = []
    func setSpeakDelays(_ delays: [Duration]) { speakDelays = delays }
    func speak(_ text: String) async throws -> AsyncStream<Float> {
        speakCalls += 1
        if loadDelay > .zero, !loaded { try await load() }   // like KokoroSpeaker.speak
        let delay = speakDelays.isEmpty ? speakDelay : speakDelays.removeFirst()
        if delay > .zero { try await Task.sleep(for: delay) }
        if let speakError { throw speakError }
        spoken.append(text)
        return AsyncStream { $0.yield(0.5); $0.finish() }
    }
    func continueReply(_ text: String) async -> Bool {
        continued.append(text)
        return true
    }
    func stop() async { stops += 1 }
}

struct FallbackSpeakerTests {
    /// Live (Oct 29): a re-summon that stops the reply while the primary is still on its first
    /// sentence makes it throw. That's the stop, not a failure: the system voice says nothing, and
    /// a load error thrown then doesn't switch voices for good.
    @Test func aStopWhileThePrimaryStartsIsNeverAFailure() async throws {
        for error in [VoiceUnavailable.synthesisFailed("cancelled"), .loadFailed("cancelled")] {
            let primary = StubSpeaker(speakError: error, speakDelay: .milliseconds(200))
            let fallback = StubSpeaker()
            let speaker = FallbackSpeaker(primary: primary, fallback: fallback)
            let reply = Task { try await speaker.speak("an answer") }
            while await primary.speakCalls == 0 { await Task.yield() }
            await speaker.stop()
            let levels = try await reply.value
            var heard = 0
            for await _ in levels { heard += 1 }
            #expect(heard == 0)
            #expect(await fallback.spoken.isEmpty, "the system voice never says a stopped reply")
            #expect(await speaker.active == .primary, "a stop never switches voices")
        }
    }

    @Test func aContinuationGoesToTheVoiceThatSaidTheReply() async throws {
        let primary = StubSpeaker(speakError: VoiceUnavailable.synthesisFailed("too many phonemes"))
        let fallback = StubSpeaker()
        let speaker = FallbackSpeaker(primary: primary, fallback: fallback)
        #expect(await speaker.continueReply("nothing to continue") == false)
        _ = try await speaker.speak("first")
        #expect(await speaker.continueReply("second"))
        #expect(await fallback.continued == ["second"], "the system voice said this reply")
        #expect(await primary.continued.isEmpty)
        await speaker.stop()
        #expect(await speaker.continueReply("after a stop") == false)
    }

    /// A Core ML call on a saturated Neural Engine can hang without failing: past the deadline the
    /// primary is stopped (its late reply never plays) and the system voice says this reply.
    @Test func aPrimaryThatHangsIsStoppedAndTheSystemVoiceSpeaks() async throws {
        let primary = StubSpeaker(speakDelay: .seconds(5)), fallback = StubSpeaker()
        let speaker = FallbackSpeaker(primary: primary, fallback: fallback, primaryDeadline: .milliseconds(150))
        let start = ContinuousClock.now
        _ = try await speaker.speak("the build failed")
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await fallback.spoken == ["the build failed"])
        #expect(await primary.stops == 1)
        #expect(await speaker.active == .primary, "one slow reply doesn't switch voices for good")
        #expect(await speaker.continueReply("more"))
        #expect(await fallback.continued == ["more"])
    }

    /// Review: a reply that times out after a stop and a newer reply must not stop the newer one.
    /// The old reply's primary never starts within the deadline, and the newer one starts at once:
    /// the deadline is long enough that a loaded machine can't make the newer reply miss it too
    /// (QA R18b: 200 ms did, at load average 60+). Waiting for `first` waits out the deadline.
    @Test func aTimedOutReplyOvertakenByANewerOneLeavesItAlone() async throws {
        let primary = StubSpeaker(), fallback = StubSpeaker()
        await primary.setSpeakDelays([.seconds(60), .zero])
        let speaker = FallbackSpeaker(primary: primary, fallback: fallback, primaryDeadline: .seconds(2))
        let first = Task { try await speaker.speak("old") }
        while await primary.speakCalls < 1 { try await Task.sleep(for: .milliseconds(1)) } // the old reply is waiting
        await speaker.stop()
        _ = try await speaker.speak("new")
        _ = try await first.value
        #expect(await primary.stops == 1, "only the user's stop; the timeout didn't stop the new reply")
        #expect(await fallback.spoken.isEmpty, "the stale reply isn't spoken by the system voice")
        #expect(await primary.spoken.contains("new"))
    }

    @Test func aPrimaryWithinTheDeadlineSpeaks() async throws {
        let primary = StubSpeaker(speakDelay: .milliseconds(50)), fallback = StubSpeaker()
        let speaker = FallbackSpeaker(primary: primary, fallback: fallback, primaryDeadline: .seconds(2))
        _ = try await speaker.speak("hi")
        #expect(await primary.spoken == ["hi"])
        #expect(await fallback.spoken.isEmpty)
        #expect(await primary.stops == 0)
    }

    /// Check: loading at launch isn't a hang. A reply during a 400 ms load still gets the
    /// primary, though the synthesis floor is shorter than that.
    @Test func loadingTimeDoesNotCountAgainstTheFirstAudioLimit() async throws {
        let primary = StubSpeaker(), fallback = StubSpeaker()
        await primary.setLoadDelay(.milliseconds(400))
        let speaker = FallbackSpeaker(primary: primary, fallback: fallback, primaryDeadline: .milliseconds(150),
                                      primaryLoadGrace: .seconds(5))
        _ = try await speaker.speak("still loading")
        #expect(await primary.spoken == ["still loading"])
        #expect(await fallback.spoken.isEmpty)
    }

    @Test func aLoadThatHangsGivesThisReplyToTheSystemVoice() async throws {
        let primary = StubSpeaker(), fallback = StubSpeaker()
        await primary.setLoadDelay(.seconds(5))
        let speaker = FallbackSpeaker(primary: primary, fallback: fallback, primaryLoadGrace: .milliseconds(150))
        let start = ContinuousClock.now
        _ = try await speaker.speak("hello")
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await fallback.spoken == ["hello"])
        #expect(await speaker.active == .primary, "a slow load isn't a failed one")
    }

    @Test func usesPrimaryWhenHealthy() async throws {
        let primary = StubSpeaker(), fallback = StubSpeaker()
        let speaker = FallbackSpeaker(primary: primary, fallback: fallback)
        await speaker.warmUp()
        _ = try await speaker.speak("hi")
        #expect(await primary.spoken == ["hi"])
        #expect(await fallback.spoken.isEmpty)
        #expect(await speaker.active == .primary)
        #expect(await fallback.warmUps == 0, "the fallback warms only when it's in use")
    }

    @Test func loadFailureSwitchesUntilAWarmUpLoadsThePrimaryAgain() async throws {
        let primary = StubSpeaker(loadError: VoiceUnavailable.loadFailed("no models"))
        let fallback = StubSpeaker()
        let speaker = FallbackSpeaker(primary: primary, fallback: fallback)
        await speaker.warmUp()
        #expect(await speaker.active == .fallback)
        #expect(await fallback.warmUps == 1)
        _ = try await speaker.speak("hi")
        #expect(await fallback.spoken == ["hi"])

        await primary.setLoadError(nil)
        await speaker.warmUp()
        #expect(await speaker.active == .primary)
    }

    @Test func loadFailureDuringSpeakSwitchesAndStillAnswers() async throws {
        let primary = StubSpeaker(speakError: VoiceUnavailable.loadFailed("compile failed"))
        let fallback = StubSpeaker()
        let speaker = FallbackSpeaker(primary: primary, fallback: fallback)
        var got: [Float] = []
        for await l in try await speaker.speak("hello") { got.append(l) }
        #expect(got == [0.5])
        #expect(await fallback.spoken == ["hello"])
        #expect(await speaker.active == .fallback)
    }

    @Test func synthesisFailureUsesTheFallbackForThatReplyOnly() async throws {
        let primary = StubSpeaker(speakError: VoiceUnavailable.synthesisFailed("too many phonemes"))
        let fallback = StubSpeaker()
        let speaker = FallbackSpeaker(primary: primary, fallback: fallback)
        _ = try await speaker.speak("odd text")
        #expect(await fallback.spoken == ["odd text"])
        #expect(await speaker.active == .primary)
    }

    @Test func playbackErrorsAreThrownWithoutSwitching() async throws {
        let primary = StubSpeaker(speakError: PlaybackBroke()), fallback = StubSpeaker()
        let speaker = FallbackSpeaker(primary: primary, fallback: fallback)
        await #expect(throws: PlaybackBroke.self) { _ = try await speaker.speak("hi") }
        #expect(await fallback.spoken.isEmpty)
        #expect(await speaker.active == .primary)
    }

    @Test func stopWhileThePrimaryFailsKeepsTheFallbackQuiet() async throws {
        let primary = StubSpeaker(speakError: VoiceUnavailable.synthesisFailed("x"), speakDelay: .milliseconds(50))
        let fallback = StubSpeaker()
        let speaker = FallbackSpeaker(primary: primary, fallback: fallback)
        let reply = Task { try await speaker.speak("stopped reply") }
        try await Task.sleep(for: .milliseconds(10))
        await speaker.stop()
        var levels = 0
        for await _ in try await reply.value { levels += 1 }
        #expect(levels == 0)
        #expect(await fallback.spoken.isEmpty)
    }

    @Test func stopReachesBothVoices() async {
        let primary = StubSpeaker(), fallback = StubSpeaker()
        await FallbackSpeaker(primary: primary, fallback: fallback).stop()
        #expect(await primary.stops == 1)
        #expect(await fallback.stops == 1)
    }
}
