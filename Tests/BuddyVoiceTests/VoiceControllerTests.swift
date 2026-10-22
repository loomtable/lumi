import BuddyCore
import Synchronization
import Testing
@testable import BuddyVoice

/// Builds a controller on fakes with a manual clock and records its events.
private struct Rig {
    let mic = FakeMic()
    let transcriber = FakeTranscriber(result: "  why is this list empty?  ")
    let detector = FakeSpeechDetector()
    let speaker = FakeSpeaker()
    let sounds = FakeSoundPlayer()
    let clock = FakeClock(1000)
    let controller: VoiceController
    let recorded = Recorded()

    final class Recorded: Sendable {
        let events = Mutex<[VoiceController.Event]>([])
        let levels = Mutex<[VoiceController.Level]>([])
        var all: [VoiceController.Event] { events.withLock { $0 } }
    }

    init(finishDeadline: Duration? = .seconds(30),
         slowFinishNotice: Duration? = .milliseconds(1500), longFinishNotice: Duration? = .seconds(10),
         setupChosen: Bool = true) {
        controller = VoiceController(
            mic: mic, transcriber: transcriber, detector: detector, speaker: speaker,
            sounds: sounds, clock: clock, tickInterval: nil, levelBuffer: 10_000, setupChosen: setupChosen,
            finishDeadline: finishDeadline,
            slowFinishNotice: slowFinishNotice, longFinishNotice: longFinishNotice
        )
        let stream = controller.events, levelStream = controller.levels
        let recorded = recorded
        Task { for await e in stream { recorded.events.withLock { $0.append(e) } } }
        Task { for await l in levelStream { recorded.levels.withLock { $0.append(l) } } }
    }

    var events: [VoiceController.Event] { recorded.all }
    var levels: [VoiceController.Level] { recorded.levels.withLock { $0 } }

    /// Moves the clock to the end of a chunk of `seconds` of audio, sends it, and waits until the
    /// controller has fully handled it (STT, VAD, meters, safeguards).
    func feed(seconds: Double, amplitude: Float) async {
        let before = await controller.processedChunks
        clock.advance(seconds)
        let n = Int(seconds * AudioChunk.sampleRate)
        guard mic.send(.audio(AudioChunk(samples: [Float](repeating: amplitude, count: n), capturedAt: 0))) else { return }
        _ = await eventually { await controller.processedChunks > before || !mic.isRunning }
    }
}

private func eventually(_ timeout: Duration = .seconds(2), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

struct VoiceControllerTests {
    @Test func gestureFinishReturnsTrimmedTranscriptAfterDrainingAudio() async throws {
        let rig = Rig()
        try await rig.controller.prepare()
        #expect(rig.mic.prepareCount == 1 && rig.transcriber.loadCount == 1 && rig.speaker.warmUpCount == 1)

        try await rig.controller.startListening()
        #expect(rig.mic.startCount == 1 && rig.transcriber.beginCount == 1 && rig.detector.resetCount == 1)
        rig.mic.sendAudio(seconds: 1, amplitude: 0.1)   // 50 chunks, not awaited one by one
        let text = try await rig.controller.finishListening()

        #expect(text == "why is this list empty?")
        #expect(rig.transcriber.sampleCount == 16_000, "every buffered chunk reaches STT before finish")
        #expect(rig.mic.stopCount == 1)
        #expect(await rig.controller.state == .idle)
    }

    @Test func micLevelsArriveEveryTwentyMillisecondsAndEndAtZero() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        rig.mic.sendAudio(seconds: 1, amplitude: 0.1)
        // Levels are only drawn while listening, so let the chunks land before the gesture.
        _ = await eventually { await rig.controller.processedChunks == 50 }
        _ = try await rig.controller.finishListening()
        _ = await eventually { rig.levels.last == .mic(0) }

        // The rig keeps every level frame (levelBuffer 10,000) so they can be counted.
        let levels = rig.levels.compactMap { if case .mic(let l) = $0 { l } else { nil } }
        #expect(levels.count == 51)              // 50 frames + the closing 0
        #expect(levels[levels.count - 2] > 0.6)  // -20 dBFS settles near the top
        #expect(levels.last == 0)
    }

    @Test func tenSecondsOfSilenceStopsAndHoldsWithoutSending() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        await rig.feed(seconds: 1, amplitude: 0.2)      // speech
        for _ in 0 ..< 10 { await rig.feed(seconds: 1, amplitude: 0) }  // silence starts with the first chunk
        #expect(await rig.controller.state == .listening, "9 s of silence so far")
        await rig.feed(seconds: 1, amplitude: 0)        // 10 s

        #expect(await eventually { await rig.controller.state == .held })
        #expect(await eventually { rig.events.contains(.autoStopped(.silence, held: true)) })
        #expect(rig.mic.stopCount == 1)
        #expect(try await rig.controller.sendHeld() == "why is this list empty?")
        #expect(try await rig.controller.sendHeld() == nil)
        #expect(await rig.controller.state == .idle)
    }

    @Test func warnsAtOneFortyFiveAndStopsAtTwoMinutes() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        for _ in 0 ..< 105 { await rig.feed(seconds: 1, amplitude: 0.2) }
        await rig.feed(seconds: 0.02, amplitude: 0.2)
        #expect(await eventually { rig.events.contains(.nearLimit) })
        #expect(await rig.controller.state == .listening)
        for _ in 0 ..< 15 { await rig.feed(seconds: 1, amplitude: 0.2) }
        await rig.feed(seconds: 0.02, amplitude: 0.2)
        #expect(await eventually { rig.events.contains(.autoStopped(.maxLength, held: true)) })
        #expect(rig.events.filter { $0 == .nearLimit }.count == 1)
    }

    @Test func heldRecordingMustBeSentOrDiscardedBeforeListeningAgain() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        await rig.controller.interrupt(.typing)
        #expect(await eventually { rig.events.contains(.autoStopped(.typing, held: true)) })
        await #expect(throws: VoiceController.VoiceError.recordingHeld) { try await rig.controller.startListening() }
        #expect(try await rig.controller.finishListening() == "why is this list empty?", "the gesture sends a held recording")
        try await rig.controller.startListening()
        #expect(rig.mic.startCount == 2)
    }

    @Test func discardingOverThirtySecondsOfSpeechAsksFirst() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        for _ in 0 ..< 32 { await rig.feed(seconds: 1, amplitude: 0.2) }   // speech from the first chunk's end: 31 s

        let first = await rig.controller.discard()
        guard case .needsConfirmation(let seconds) = first else { Issue.record("got \(first)"); return }
        #expect(seconds > 30)
        #expect(await rig.controller.state == .listening, "nothing is lost while asking")

        #expect(await rig.controller.discard(confirmed: true) == .discarded)
        #expect(rig.transcriber.cancelCount == 1 && rig.transcriber.finishCount == 0)
        #expect(rig.sounds.sounds == [.discard])
        #expect(await rig.controller.state == .idle)
    }

    @Test func shortDiscardNeedsNoConfirmation() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        await rig.feed(seconds: 2, amplitude: 0.2)
        #expect(await rig.controller.discard() == .discarded)
        #expect(await rig.controller.discard() == .nothingToDiscard)
    }

    @Test func buddyKeyWhileSpeakingStopsTheReplyAndListens() async throws {
        let rig = Rig()
        #expect(try await rig.controller.speak("Your date filter drops last week's data."))
        #expect(await rig.controller.state == .speaking)
        rig.speaker.emit(level: 0.3)
        #expect(await eventually { rig.levels.contains { if case .reply(let l) = $0 { l > 0 } else { false } } })

        try await rig.controller.startListening()
        #expect(rig.speaker.stopCount == 1)
        #expect(await eventually { rig.events.contains(.speakingFinished) })
        #expect(await rig.controller.state == .listening)
        #expect(try await rig.controller.speak("ignored while the user talks") == false)
        #expect(rig.speaker.spoken.count == 1)
    }

    @Test func continuingQueuesBehindTheReplyInsteadOfCuttingIt() async throws {
        let rig = Rig()
        #expect(try await rig.controller.speak("Let me check."))
        #expect(try await rig.controller.speak("One moment.", continuing: true))
        #expect(rig.speaker.stopCount == 0)
        #expect(rig.speaker.spoken == ["Let me check."])
        #expect(rig.speaker.continued == ["One moment."])
        #expect(await rig.controller.state == .speaking)
        rig.speaker.finishSpeaking()
        #expect(await eventually { await rig.controller.state == .idle })
        #expect(await eventually { rig.events.last == .speakingFinished })
        #expect(rig.events.filter { $0 == .speakingFinished }.count == 1, "one reply, one end")
    }

    @Test func continuingWhileTheReplyIsPreparingWaitsAndQueuesBehindIt() async throws {
        let rig = Rig()
        rig.speaker.speakGate.close()
        let first = Task { try await rig.controller.speak("Let me check.") }
        #expect(await eventually { await rig.controller.state == .preparingReply })
        let second = Task { try await rig.controller.speak("One moment.", continuing: true) }
        try await Task.sleep(for: .milliseconds(50))
        rig.speaker.speakGate.open()
        #expect(try await first.value)
        #expect(try await second.value)
        #expect(rig.speaker.stopCount == 0)
        #expect(rig.speaker.spoken == ["Let me check."])
        #expect(rig.speaker.continued == ["One moment."])
    }

    @Test func continuingAReplyStoppedWhilePreparingSaysNothing() async throws {
        let rig = Rig()
        rig.speaker.speakGate.close()
        let first = Task { try await rig.controller.speak("Let me check.") }
        #expect(await eventually { await rig.controller.state == .preparingReply })
        let second = Task { try await rig.controller.speak("One moment.", continuing: true) }
        try await Task.sleep(for: .milliseconds(50))
        await rig.controller.stopSpeaking()
        rig.speaker.speakGate.open()
        #expect(try await first.value == false)
        #expect(try await second.value == false)
        #expect(rig.speaker.spoken.isEmpty)
        #expect(rig.speaker.continued.isEmpty)
    }

    @Test func continuingWithNothingInFlightStartsANewReply() async throws {
        let rig = Rig()
        #expect(try await rig.controller.speak("Done.", continuing: true))
        #expect(rig.speaker.spoken == ["Done."])
        rig.speaker.finishSpeaking()
        #expect(await eventually { await rig.controller.state == .idle })
        // After a stop, a continuing line starts fresh too: there's nothing left to continue.
        #expect(try await rig.controller.speak("Your filter drops last week."))
        await rig.controller.stopSpeaking()
        #expect(try await rig.controller.speak("Want me to loosen it?", continuing: true))
        #expect(rig.speaker.spoken == ["Done.", "Your filter drops last week.", "Want me to loosen it?"])
        #expect(rig.speaker.continued.isEmpty)
    }

    @Test func replyFinishingOnItsOwnReportsOnce() async throws {
        let rig = Rig()
        try await rig.controller.speak("Done.")
        rig.speaker.finishSpeaking()
        #expect(await eventually { await rig.controller.state == .idle })
        #expect(await eventually { rig.events.last == .speakingFinished })
        #expect(rig.events.filter { $0 == .speakingFinished }.count == 1)
    }

    @Test func revokedMicEndsListeningAndReportsIt() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        rig.mic.send(.problem(.permissionDenied))
        #expect(await eventually { await rig.controller.state == .idle })
        #expect(await eventually { rig.events.contains(.micProblem(.permissionDenied)) })
        #expect(rig.transcriber.cancelCount == 1)
        #expect(rig.mic.stopCount == 1)
    }

    @Test func rebuildIsReportedAndListeningContinues() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        rig.mic.send(.rebuilt)
        await rig.feed(seconds: 0.5, amplitude: 0.1)
        #expect(await eventually { rig.events.contains(.micRebuilt) })
        #expect(try await rig.controller.finishListening() == "why is this list empty?")
    }

    @Test func soundsAreSkippedWhileTheUserSpeaks() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        await rig.controller.play(.summon)               // before speech: plays
        await rig.feed(seconds: 0.5, amplitude: 0.2)     // speech starts
        await rig.controller.play(.ready)
        #expect(rig.sounds.sounds == [.summon])
    }

    @Test func failedStartLeavesNothingRunning() async throws {
        struct Boom: Error {}
        let rig = Rig()
        rig.mic.failNextStart(with: Boom())
        await #expect(throws: Boom.self) { try await rig.controller.startListening() }
        #expect(rig.transcriber.cancelCount == 1)
        #expect(await rig.controller.state == .idle)
    }

    @Test func sttFailureSurfacesFromFinish() async throws {
        struct STTDown: Error {}
        let rig = Rig()
        try await rig.controller.startListening()
        rig.transcriber.failNextFinish(with: STTDown())
        await #expect(throws: STTDown.self) { _ = try await rig.controller.finishListening() }
        #expect(await rig.controller.state == .idle)
    }

    /// A Core ML call on a saturated Neural Engine can hang: the listen ends with a true line instead.
    @Test func aHungTranscriptEndsTheListenAtTheDeadline() async throws {
        let rig = Rig(finishDeadline: .milliseconds(150))
        try await rig.controller.startListening()
        rig.transcriber.delayFinish(.seconds(5))
        let start = ContinuousClock.now
        await #expect(throws: VoiceController.VoiceError.transcriptionTimedOut) { _ = try await rig.controller.finishListening() }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await rig.controller.state == .idle)
    }

    /// Review: an auto-stop (silence, the time limit, a screen lock) finalises too, under the actor's lock.
    @Test func aHungTranscriptAtAnAutoStopIsHeldAsTheError() async throws {
        let rig = Rig(finishDeadline: .milliseconds(150))
        try await rig.controller.startListening()
        rig.transcriber.delayFinish(.seconds(5))
        let start = ContinuousClock.now
        await rig.controller.interrupt(.screenLocked)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await rig.controller.state == .held)
        await #expect(throws: VoiceController.VoiceError.transcriptionTimedOut) { _ = try await rig.controller.sendHeld() }
    }

    /// Review: the next listen's begin() queues behind a hung model call; it's bounded too.
    @Test func aHungBeginEndsTheStartAtTheDeadline() async throws {
        let rig = Rig(finishDeadline: .milliseconds(150))
        rig.transcriber.delayBegin(.seconds(5))
        let start = ContinuousClock.now
        await #expect(throws: VoiceController.VoiceError.transcriptionTimedOut) { try await rig.controller.startListening() }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await rig.controller.state == .idle)
    }

    /// The listen-length cap end to end: warned at 1:45, stopped and held at 2:00, and the held
    /// recording's transcript comes through whole.
    @Test func aDictationThatHitsTheCapIsHeldAndSentWhole() async throws {
        let rig = Rig(finishDeadline: .seconds(30))
        try await rig.controller.startListening()
        rig.transcriber.delayFinish(.milliseconds(500))
        for _ in 0..<13 { await rig.feed(seconds: 10, amplitude: 0.2) }
        #expect(await eventually { await rig.controller.state == .held })
        #expect(rig.events.contains(.nearLimit))
        #expect(try await rig.controller.sendHeld() == "why is this list empty?")
    }

    /// Review: a listen while the model loads says "Still setting up voice" at once, and doesn't queue a
    /// cancel behind the load.
    @Test func aListenBeforeTheModelLoadedIsStillSettingUpWithoutACancel() async throws {
        let rig = Rig()
        rig.transcriber.failNextBegin(with: VoiceModelError.notLoaded)
        await #expect(throws: VoiceController.VoiceError.stillSettingUp) { try await rig.controller.startListening() }
        #expect(rig.transcriber.cancelCount == 0)
    }

    /// A long finish says so, then says it's still working; each once, so the wait doesn't look frozen.
    @Test func aSlowFinishAnnouncesTranscribingThenStillWorking() async throws {
        let rig = Rig(slowFinishNotice: .milliseconds(50), longFinishNotice: .milliseconds(150))
        try await rig.controller.startListening()
        rig.transcriber.delayFinish(.seconds(1))
        _ = try await rig.controller.finishListening()
        let notices: @Sendable () -> [VoiceController.Event] = { rig.events.filter { if case .transcribing = $0 { true } else { false } } }
        #expect(await eventually { notices().count == 2 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(notices() == [.transcribing(long: false), .transcribing(long: true)])
    }

    @Test func aQuickFinishSaysNothing() async throws {
        let rig = Rig(slowFinishNotice: .milliseconds(300))
        try await rig.controller.startListening()
        _ = try await rig.controller.finishListening()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!rig.events.contains { if case .transcribing = $0 { true } else { false } }, "cancelled once the transcript was in")
    }

    @Test func aTranscriptWithinTheDeadlineIsReturned() async throws {
        let rig = Rig(finishDeadline: .seconds(2))
        try await rig.controller.startListening()
        rig.transcriber.delayFinish(.milliseconds(50))
        #expect(try await rig.controller.finishListening() == "why is this list empty?")
    }

    @Test func voiceIsolationSettingReachesTheMic() async throws {
        let rig = Rig()
        try await rig.controller.setVoiceProcessing(false)
        #expect(rig.mic.voiceProcessing == false)
    }

    // MARK: Races found in review

    @Test func gestureDuringStartIsAppliedOnceStarted() async throws {
        let rig = Rig()
        rig.mic.startGate.close()
        let start = Task { try await rig.controller.startListening() }
        _ = await eventually { rig.mic.startGate.arrivals == 1 }
        #expect(await rig.controller.state == .starting)

        let finish = Task { try await rig.controller.finishListening() }
        try await Task.sleep(for: .milliseconds(20))
        rig.mic.startGate.open()
        try await start.value
        #expect(try await finish.value == "why is this list empty?")
        #expect(rig.mic.stopCount == 1, "the mic isn't left on")
        #expect(await rig.controller.state == .idle)
    }

    // Waiting for the mic to go live (about 450 ms with VP) must not hold the lock.
    @Test func waitingForMicLiveNeverBlocksDiscardOrSend() async throws {
        let rig = Rig()
        rig.mic.holdLiveSignal(true)
        let clock = ContinuousClock()
        let start = Task { try await rig.controller.startListening() }
        _ = await eventually { rig.mic.isRunning }
        try await Task.sleep(for: .milliseconds(20))
        let began = clock.now
        #expect(await rig.controller.discard(playSound: false) == .discarded)
        #expect(clock.now - began < .milliseconds(50))
        try await start.value                                // returns once the capture stopped
        #expect(clock.now - began < .milliseconds(100))
        #expect(await rig.controller.state == .idle)

        let second = Task { try await rig.controller.startListening() }
        _ = await eventually { rig.mic.isRunning }
        #expect(try await rig.controller.finishListening() == "why is this list empty?")
        try await second.value
    }

    @Test func escDuringStartDiscardsOnceStarted() async throws {
        let rig = Rig()
        rig.mic.startGate.close()
        let start = Task { try await rig.controller.startListening() }
        _ = await eventually { rig.mic.startGate.arrivals == 1 }
        let discard = Task { await rig.controller.discard() }
        try await Task.sleep(for: .milliseconds(20))
        rig.mic.startGate.open()
        try await start.value
        #expect(await discard.value == .discarded)
        #expect(rig.mic.stopCount == 1)
        #expect(await rig.controller.state == .idle)
    }

    @Test func concurrentStartsStartOnce() async throws {
        let rig = Rig()
        async let a: Void = rig.controller.startListening()
        async let b: Void = rig.controller.startListening()
        _ = try await (a, b)
        #expect(rig.mic.startCount == 1 && rig.transcriber.beginCount == 1)
    }

    @Test func listeningDuringSynthesisCancelsTheReply() async throws {
        let rig = Rig()
        rig.speaker.speakGate.close()
        let speak = Task { try await rig.controller.speak("A reply still being synthesised.") }
        _ = await eventually { rig.speaker.speakGate.arrivals == 1 }
        #expect(await rig.controller.state == .preparingReply)

        try await rig.controller.startListening()
        rig.speaker.speakGate.open()
        #expect(try await speak.value == false)
        #expect(await rig.controller.state == .listening, "the late reply doesn't take over")
        #expect(rig.speaker.spoken.isEmpty, "a reply stopped mid-synthesis never plays")
        await rig.feed(seconds: 0.2, amplitude: 0.1)
        #expect(try await rig.controller.finishListening() == "why is this list empty?")
    }

    @Test func stopDuringSynthesisSilencesTheReply() async throws {
        let rig = Rig()
        rig.speaker.speakGate.close()
        let speak = Task { try await rig.controller.speak("Stop me before I start.") }
        _ = await eventually { rig.speaker.speakGate.arrivals == 1 }
        await rig.controller.stopSpeaking()
        rig.speaker.speakGate.open()
        #expect(try await speak.value == false)
        #expect(rig.speaker.spoken.isEmpty)
        #expect(await rig.controller.state == .idle)
    }

    @Test func discardedSpeechNeverReachesTheNextListen() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        for _ in 0 ..< 3 { rig.mic.sendAudio(seconds: 0.2, amplitude: 0.2) }  // backlog, not awaited
        #expect(await rig.controller.discard() == .discarded)
        try await rig.controller.startListening()
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.transcriber.sampleCount == 0, "old audio must not be appended after begin()")
        await rig.feed(seconds: 0.1, amplitude: 0.1)
        #expect(rig.transcriber.sampleCount == 1_600)
    }

    @Test func gestureDuringAutoStopReturnsTheHeldRecording() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        async let interrupted: Void = rig.controller.interrupt(.screenLocked)
        async let text = rig.controller.finishListening()
        _ = await interrupted
        #expect(try await text == "why is this list empty?")
        #expect(await rig.controller.state == .idle)
    }

    @Test func interruptKeepsTheTail() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        rig.mic.sendAudio(seconds: 0.4, amplitude: 0.2)   // 20 chunks still queued
        await rig.controller.interrupt(.typing)
        #expect(rig.transcriber.sampleCount == 6_400, "audio captured before the stop is transcribed")
    }

    @Test func failedMicKeepsWhatWasHeard() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        await rig.feed(seconds: 1, amplitude: 0.2)
        rig.mic.send(.problem(.engineFailed("no audio")))
        #expect(await eventually { await rig.controller.state == .held })
        #expect(await eventually { rig.events.contains(.autoStopped(.micFailed, held: true)) })
        #expect(try await rig.controller.sendHeld() == "why is this list empty?")
    }

    @Test func failedFinishDuringAutoStopIsNotSentAsEmpty() async throws {
        struct STTDown: Error {}
        let rig = Rig()
        try await rig.controller.startListening()
        await rig.feed(seconds: 1, amplitude: 0.2)
        rig.transcriber.failNextFinish(with: STTDown())
        await rig.controller.interrupt(.systemSleep)
        #expect(await rig.controller.state == .held)
        await #expect(throws: STTDown.self) { _ = try await rig.controller.finishListening() }
        #expect(await rig.controller.state == .idle)
    }

    @Test func tapThenSilenceKeepsNothingAndDoesntBlockTheNextTap() async throws {
        let rig = Rig()
        rig.transcriber.setResult("")
        try await rig.controller.startListening()
        for _ in 0 ..< 11 { await rig.feed(seconds: 1, amplitude: 0) }
        #expect(await eventually { rig.events.contains(.autoStopped(.silence, held: false)) })
        #expect(await rig.controller.state == .idle)
        #expect(try await rig.controller.sendHeld() == nil)
        try await rig.controller.startListening()
        #expect(rig.mic.startCount == 2)
    }

    @Test func stateEventsSurviveAFloodOfLevels() async throws {
        // Its own controller: an AsyncStream has one consumer, and Rig already reads `events`.
        let mic = FakeMic()
        let transcriber = FakeTranscriber(result: "hi")
        let controller = VoiceController(
            mic: mic, transcriber: transcriber, detector: FakeSpeechDetector(), speaker: FakeSpeaker(),
            sounds: FakeSoundPlayer(), clock: FakeClock(), tickInterval: nil
        )
        try await controller.startListening()
        mic.sendAudio(seconds: 20, amplitude: 0.1)   // 1,000 level frames that nobody reads
        await controller.interrupt(.typing)
        var seen: [VoiceController.Event] = []
        for await e in controller.events {
            seen.append(e)
            if e == .autoStopped(.typing, held: true) { break }
        }
        #expect(seen.contains(.autoStopped(.typing, held: true)))
        #expect(transcriber.sampleCount == 320_000)
    }

    // MARK: Lead review of #25

    @Test func listeningBeforeTheModelLoadsSaysStillSettingUp() async throws {
        let rig = Rig()
        rig.transcriber.failNextBegin(with: VoiceModelError.notLoaded)
        await #expect(throws: VoiceController.VoiceError.stillSettingUp) { try await rig.controller.startListening() }
        #expect(rig.mic.startCount == 0, "the mic never starts without a model")
        #expect(await rig.controller.state == .idle)
        try await rig.controller.startListening()
        #expect(rig.mic.startCount == 1)
    }

    @Test func aBrokenVADNeverCutsTheUserOffForSilence() async throws {
        let rig = Rig()
        rig.detector.setFailing(true)
        try await rig.controller.startListening()
        for _ in 0 ..< 15 { await rig.feed(seconds: 1, amplitude: 0.2) }
        #expect(await rig.controller.state == .listening)
        #expect(!rig.events.contains { if case .autoStopped(.silence, _) = $0 { true } else { false } })
        #expect(try await rig.controller.finishListening() == "why is this list empty?")
    }

    @Test func aFailedFinaliseWithNoSpeechIsHeldNotDiscarded() async throws {
        struct STTDown: Error {}
        let rig = Rig()
        try await rig.controller.startListening()
        rig.transcriber.failNextFinish(with: STTDown())
        await rig.controller.interrupt(.screenLocked)
        #expect(await rig.controller.state == .held)
        await #expect(throws: STTDown.self) { _ = try await rig.controller.sendHeld() }
        #expect(await rig.controller.state == .idle)
    }

    @Test func aReplyIsNotDroppedBecauseANoOpTransitionHeldTheLock() async throws {
        let rig = Rig()
        async let discarded = rig.controller.discard()   // a no-op transition while idle
        async let spoken = rig.controller.speak("Still spoken.")
        #expect(await discarded == .nothingToDiscard)
        #expect(try await spoken == true)
        #expect(rig.speaker.spoken == ["Still spoken."])
    }

    // MARK: Shell integration API

    @Test func soundsOffSilencesEverySound() async throws {
        let rig = Rig()
        await rig.controller.setSoundsEnabled(false)
        await rig.controller.play(.summon)
        try await rig.controller.startListening()
        await rig.feed(seconds: 1, amplitude: 0.2)
        #expect(await rig.controller.discard() == .discarded)
        #expect(rig.sounds.sounds.isEmpty)
    }

    @Test func aDiscardTheUserDidntAskForIsSilent() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        #expect(await rig.controller.discard(playSound: false) == .discarded)
        #expect(rig.sounds.sounds.isEmpty)
        try await rig.controller.startListening()
        #expect(await rig.controller.discard() == .discarded)
        #expect(rig.sounds.sounds == [.discard])
    }

    @Test func escOnALongRecordingHoldsItWhileAsking() async throws {
        let rig = Rig()
        try await rig.controller.startListening()
        for _ in 0 ..< 32 { await rig.feed(seconds: 1, amplitude: 0.2) }
        guard case .needsConfirmation = await rig.controller.discard() else { Issue.record("expected a confirmation"); return }
        await rig.controller.interrupt(.confirmingDiscard)
        #expect(await rig.controller.state == .held)
        #expect(rig.mic.stopCount == 1, "the mic stops while asking")
        #expect(await eventually { rig.events.contains(.autoStopped(.confirmingDiscard, held: true)) })
        #expect(rig.sounds.sounds.isEmpty)
        guard case .needsConfirmation = await rig.controller.discard() else { Issue.record("still asks"); return }
        #expect(await rig.controller.discard(confirmed: true) == .discarded)
        #expect(await rig.controller.state == .idle)
    }

    @Test func confirmingDiscardHoldsEvenWithNoSpeechHeard() async throws {
        let rig = Rig()
        rig.transcriber.setResult("")
        try await rig.controller.startListening()
        await rig.controller.interrupt(.confirmingDiscard)
        #expect(await rig.controller.state == .held)
        #expect(await eventually { rig.events.contains(.autoStopped(.confirmingDiscard, held: true)) })
    }

    @Test func prepareReportsEachStepWithRealProgressInOrder() async throws {
        let rig = Rig()
        let p1 = ModelLoadProgress(fraction: 0.4, phase: .downloading(completedFiles: 2, totalFiles: 5))
        let p2 = ModelLoadProgress(fraction: 0.9, phase: .compiling)
        rig.transcriber.reportOnLoad([p1, p2])
        rig.transcriber.loadGate.close()
        #expect(await rig.controller.prepareState == .notStarted)

        let prepare = Task { try await rig.controller.prepare() }
        // The download is still running: the first report is visible before load finishes.
        #expect(await eventually { await rig.controller.prepareState == .preparing(.speechModel(p1)) })
        rig.transcriber.loadGate.open()
        try await prepare.value

        #expect(await rig.controller.prepareState == .ready)
        #expect(await eventually { rig.events.contains(.prepare(.ready)) })
        let states = rig.events.compactMap { if case .prepare(let p) = $0 { p } else { nil } }
        #expect(states == [
            .preparing(.speechModel(nil)),
            .preparing(.speechModel(p1)),
            .preparing(.speechModel(p2)),
            .preparing(.voiceActivity),
            .preparing(.voice(nil)),
            .preparing(.microphone),
            .ready,
        ])
    }

    @Test func manyProgressReportsArriveInOrder() async throws {
        let rig = Rig()
        let reports = (1 ... 200).map { ModelLoadProgress(fraction: Double($0) / 200, phase: .downloading(completedFiles: $0, totalFiles: 200)) }
        rig.transcriber.reportOnLoad(reports)
        try await rig.controller.prepare()
        _ = await eventually { rig.events.contains(.prepare(.ready)) }
        let seen = rig.events.compactMap { if case .prepare(.preparing(.speechModel(let p?))) = $0 { p.fraction } else { nil } }
        #expect(seen.count == 200)
        #expect(seen == seen.sorted())
    }

    @Test func aFailedPrepareCanBeRetried() async throws {
        struct Offline: Error {}
        let rig = Rig()
        rig.transcriber.failNextLoad(with: Offline())
        await #expect(throws: Offline.self) { try await rig.controller.prepare() }
        guard case .failed = await rig.controller.prepareState else { Issue.record("expected failed"); return }
        try await rig.controller.prepare()
        #expect(await rig.controller.prepareState == .ready)
        #expect(rig.mic.prepareCount == 1)
    }

    @Test func concurrentPreparesRunOnce() async throws {
        let rig = Rig()
        async let a: Void = rig.controller.prepare()
        async let b: Void = rig.controller.prepare()
        _ = try await (a, b)
        #expect(rig.transcriber.loadCount == 1 && rig.mic.prepareCount == 1)
        try await rig.controller.prepare()
        #expect(rig.transcriber.loadCount == 1, "ready is final")
    }

    @Test func beforeASetupIsChosenOnlyTheMicIsPreparedAndListeningSaysSo() async throws {
        let rig = Rig(setupChosen: false)
        try await rig.controller.prepare()
        #expect(rig.transcriber.loadCount == 0 && rig.speaker.warmUpCount == 0, "nothing is downloaded")
        #expect(rig.mic.prepareCount == 1)
        #expect(await rig.controller.prepareState == .ready)
        await #expect(throws: VoiceController.VoiceError.notSetUp) { try await rig.controller.startListening() }
        #expect(await rig.controller.state == .idle)

        await rig.controller.setSetupChosen(true)
        #expect(await rig.controller.prepareState == .notStarted, "the choice needs downloads: prepare again")
        try await rig.controller.prepare()
        #expect(rig.transcriber.loadCount == 1 && rig.speaker.warmUpCount == 1)
        #expect(await rig.controller.prepareState == .ready)
        try await rig.controller.startListening()
        #expect(await rig.controller.state == .listening)
    }

    @Test func aSetupChosenWhilePreparingIsLoadedBeforePrepareReturns() async throws {
        let rig = Rig(setupChosen: false)
        rig.mic.prepareGate.close()
        let first = Task { try await rig.controller.prepare() }
        #expect(await eventually { await rig.controller.prepareState == .preparing(.microphone) })
        await rig.controller.setSetupChosen(true)
        rig.mic.prepareGate.open()
        try await first.value
        #expect(rig.transcriber.loadCount == 1, "the same prepare goes on to load what the choice needs")
        #expect(await rig.controller.prepareState == .ready)
        let states = rig.events.compactMap { if case .prepare(let p) = $0 { p } else { nil } }
        #expect(states.firstIndex(of: .notStarted) ?? 0 < states.firstIndex(of: .preparing(.speechModel(nil))) ?? 0,
                "never ready for settings it didn't load")
        #expect(states.filter { $0 == .ready }.count == 1)
    }

    @Test func choosingTheLumiVoiceLaterAsksForAPrepareOnce() async throws {
        let onDevice = FakeSpeaker(), mac = FakeSpeaker()
        let router = ReplyVoiceSpeaker(onDevice: onDevice, system: mac, choice: .system) { _ in fatalError("no ElevenLabs here") }
        let controller = VoiceController(mic: FakeMic(), transcriber: FakeTranscriber(result: ""), detector: FakeSpeechDetector(),
                                         speaker: router, sounds: FakeSoundPlayer(), clock: FakeClock(0), tickInterval: nil)
        try await controller.prepare()
        #expect(onDevice.warmUpCount == 0, "the Mac voice never loads Kokoro")
        await controller.setReplyVoice(.onDevice)
        #expect(await controller.prepareState == .notStarted)
        try await controller.prepare()
        #expect(onDevice.warmUpCount == 1)
        #expect(await controller.prepareState == .ready)
        await controller.setReplyVoice(.system)
        await controller.setReplyVoice(.onDevice)
        #expect(await controller.prepareState == .ready, "already loaded: nothing to prepare")
    }

    @Test func liveWiringPassesTheSoundsSettingThrough() async {
        // Builds the real stack without preparing it: nothing loads and the mic doesn't run.
        let off = VoiceController.live(settings: VoiceSettings(soundsEnabled: false))
        #expect(await off.soundsEnabled == false)
        let on = VoiceController.live(settings: VoiceSettings())
        #expect(await on.soundsEnabled == true)
    }
}
