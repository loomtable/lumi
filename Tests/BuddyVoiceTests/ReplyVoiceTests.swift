import Foundation
import Synchronization
import Testing
@testable import BuddyVoice

private func pcm(_ seconds: Double, amplitude: Int16 = 70) -> Data {
    var data = Data()
    for i in 0 ..< Int(24_000 * seconds) {
        let v = i % 2 == 0 ? amplitude : -amplitude
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

private let invalidKey = ScriptedStreamer.Response(status: 401, chunks: [Data(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#.utf8)])

struct ReplyVoiceCodingTests {
    @Test(arguments: [
        (#"{"kind":"elevenLabs","voiceID":"abc"}"#, ReplyVoice.elevenLabs(voiceID: "abc")),
        (#"{"kind":"onDevice"}"#, .onDevice),
        (#"{"kind":"system"}"#, .system),
        (#"{"kind":"elevenLabs"}"#, .onDevice),
        (#"{"kind":"elevenLabs","voiceID":"  "}"#, .onDevice),
        (#"{"kind":"somethingNew","voiceID":"x"}"#, .onDevice),
        (#"{}"#, .onDevice),
        (#""elevenLabs""#, .onDevice),
    ])
    func decodesLeniently(json: String, expected: ReplyVoice) throws {
        #expect(try JSONDecoder().decode(ReplyVoice.self, from: Data(json.utf8)) == expected)
    }

    @Test func roundTrips() throws {
        for voice in [ReplyVoice.onDevice, .system, .elevenLabs(voiceID: "v1")] {
            #expect(try JSONDecoder().decode(ReplyVoice.self, from: JSONEncoder().encode(voice)) == voice)
        }
    }
}

@Suite(.serialized)
struct ReplyVoiceSpeakerTests {
    private func router(_ http: ScriptedStreamer, system: FakeSpeaker, onDevice: FakeSpeaker = FakeSpeaker(),
                        choice: ReplyVoice = .elevenLabs(voiceID: "v"), key: String? = "k") -> ReplyVoiceSpeaker {
        let playback = AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput())
        let keys = FakeSecretStore(key)
        return ReplyVoiceSpeaker(onDevice: onDevice, system: system, choice: choice) {
            ElevenLabsSpeaker(voiceID: $0, client: ElevenLabsClient(http: http, keys: keys), playback: playback)
        }
    }

    private func collect(_ stream: AsyncStream<ReplyVoiceSpeaker.Status>, count: Int) async -> [String] {
        var out: [String] = []
        for await change in stream {
            switch change {
            case .problem(let line): out.append(line)
            case .recovered: out.append("<recovered>")
            }
            if out.count == count { break }
        }
        return out
    }

    @Test func onDeviceChoiceNeverCallsElevenLabs() async throws {
        let http = ScriptedStreamer([])
        let onDevice = FakeSpeaker(), mac = FakeSpeaker()
        let speaker = router(http, system: mac, onDevice: onDevice, choice: .onDevice)
        await speaker.warmUp()
        _ = try await speaker.speak("Hello there friend.")
        #expect(onDevice.spoken == ["Hello there friend."] && mac.spoken.isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test func theMacVoiceSpeaksWithoutLoadingTheOnDeviceOne() async throws {
        let http = ScriptedStreamer([])
        let onDevice = FakeSpeaker(), mac = FakeSpeaker()
        let speaker = router(http, system: mac, onDevice: onDevice, choice: .system)
        await speaker.warmUp()
        _ = try await speaker.speak("Hello there friend.")
        #expect(mac.spoken == ["Hello there friend."] && onDevice.spoken.isEmpty)
        #expect(onDevice.warmUpCount == 0 && http.requests.isEmpty)
    }

    @Test func beforeItsWarmUpTheOnDeviceChoiceSpeaksWithTheMacVoice() async throws {
        // A reply before any setup (typed during onboarding) must not download Kokoro.
        let onDevice = FakeSpeaker(), mac = FakeSpeaker()
        let speaker = router(ScriptedStreamer([]), system: mac, onDevice: onDevice, choice: .onDevice)
        _ = try await speaker.speak("Hello there friend.")
        #expect(mac.spoken == ["Hello there friend."] && onDevice.spoken.isEmpty && onDevice.warmUpCount == 0)
    }

    @Test func onlyTheOnDeviceChoiceWarmsTheOnDeviceVoice() async throws {
        let onDevice = FakeSpeaker(), mac = FakeSpeaker()
        let speaker = router(ScriptedStreamer([]), system: mac, onDevice: onDevice, key: nil)
        await speaker.warmUp()
        #expect(onDevice.warmUpCount == 0, "ElevenLabs falls back to the Mac voice, so Kokoro isn't downloaded")
        #expect(await speaker.setChoice(.onDevice), "the on-device voice needs a warm-up first")
        await speaker.warmUp()
        #expect(onDevice.warmUpCount == 1)
        #expect(await speaker.setChoice(.onDevice) == false)
    }

    @Test func elevenLabsSpeaksAndAContinuationFollowsIt() async throws {
        let http = ScriptedStreamer(Array(repeating: .init(chunks: [pcm(0.05)]), count: 2))
        let mac = FakeSpeaker()
        let speaker = router(http, system: mac)
        let levels = try await speaker.speak("Your date filter drops last week.")
        #expect(await speaker.continueReply("Want me to loosen it now?"))
        for await _ in levels {}
        #expect(mac.spoken.isEmpty && mac.continued.isEmpty)
        #expect(http.requests.count == 2)
    }

    @Test func aRejectedKeyFallsBackReportsOnceAndStaysOnTheMacVoiceUntilTheChoiceIsSetAgain() async throws {
        let http = ScriptedStreamer([invalidKey, .init(chunks: [pcm(0.05)])])
        let mac = FakeSpeaker()
        let speaker = router(http, system: mac)
        _ = try await speaker.speak("First reply here.")
        _ = try await speaker.speak("Second reply here.")
        #expect(mac.spoken == ["First reply here.", "Second reply here."])
        #expect(http.requests.count == 1, "the rejected key isn't retried every reply")
        let lines = await collect(speaker.status, count: 1)
        #expect(lines == ["ElevenLabs rejected the API key, so the Mac voice is speaking."])

        await speaker.setChoice(.elevenLabs(voiceID: "v"))   // e.g. after a new key is saved
        let levels = try await speaker.speak("Third reply here.")
        for await _ in levels {}
        #expect(http.requests.count == 2, "ElevenLabs is tried again")
        #expect(mac.spoken.count == 2)
    }

    @Test func aNetworkProblemOnlyAffectsThatReply() async throws {
        let http = ScriptedStreamer([.init(sendError: URLError(.notConnectedToInternet)), .init(chunks: [pcm(0.05)])])
        let mac = FakeSpeaker()
        let speaker = router(http, system: mac)
        _ = try await speaker.speak("First reply here.")
        let levels = try await speaker.speak("Second reply here.")
        for await _ in levels {}
        #expect(mac.spoken == ["First reply here."])
        #expect(http.requests.count == 2)
        #expect(await collect(speaker.status, count: 2) == ["ElevenLabs couldn't be reached, so the Mac voice said this reply.", "<recovered>"],
                "the line can be cleared once ElevenLabs speaks again")
    }

    @Test func aStopWhileElevenLabsFailsDoesntSpeakTheFallback() async throws {
        let http = ScriptedStreamer([.init(sendError: URLError(.timedOut), connectDelay: .milliseconds(200))])
        let mac = FakeSpeaker()
        let speaker = router(http, system: mac)
        let speaking = Task { try await speaker.speak("Hello there friend.") }
        try await Task.sleep(for: .milliseconds(50))
        await speaker.stop()
        _ = try await speaking.value
        #expect(mac.spoken.isEmpty)
    }

    @Test func noKeyMeansTheMacVoiceWithoutARequest() async throws {
        let http = ScriptedStreamer([])
        let mac = FakeSpeaker()
        let speaker = router(http, system: mac, key: nil)
        _ = try await speaker.speak("Hello there friend.")
        #expect(mac.spoken == ["Hello there friend."])
        #expect(http.requests.isEmpty)
        #expect(await collect(speaker.status, count: 1) == ["ElevenLabs has no API key, so the Mac voice is speaking."])
    }

    @Test func aFailureFromBeforeTheChoiceChangedNeitherBlocksNorReports() async throws {
        // The first reply waits on ElevenLabs while a new key is saved; then it fails with the old key.
        let late = ScriptedStreamer.Response(status: 401, chunks: invalidKey.chunks, connectDelay: .milliseconds(200))
        let http = ScriptedStreamer([late, .init(chunks: [pcm(0.05)])])
        let mac = FakeSpeaker()
        let speaker = router(http, system: mac)
        let first = Task { try await speaker.speak("First reply here.") }
        try await Task.sleep(for: .milliseconds(50))
        await speaker.setChoice(.elevenLabs(voiceID: "v"))
        _ = try await first.value
        #expect(mac.spoken == ["First reply here."], "the reply itself is still said, by the Mac voice")
        let levels = try await speaker.speak("Second reply here.")
        for await _ in levels {}
        #expect(http.requests.count == 2, "the new choice isn't blocked by the old key's failure")
        await speaker.stop()
        await speaker.setChoice(.onDevice)
        // Nothing was reported, so the stream stays empty: a status arriving within 100 ms would be a stale line.
        let early = Task { await collect(speaker.status, count: 1) }
        try await Task.sleep(for: .milliseconds(100))
        early.cancel()
        #expect(await early.value.isEmpty)
    }

    @Test func settingTheChoiceAgainClearsAReportedLineInOrder() async throws {
        let http = ScriptedStreamer([invalidKey])
        let speaker = router(http, system: FakeSpeaker())
        _ = try await speaker.speak("First reply here.")
        await speaker.setChoice(.elevenLabs(voiceID: "v"))
        #expect(await collect(speaker.status, count: 2) == ["ElevenLabs rejected the API key, so the Mac voice is speaking.", "<recovered>"])
    }

    @Test func theControllerReportsTheProblemAsAnEvent() async throws {
        let speaker = router(ScriptedStreamer([invalidKey]), system: FakeSpeaker())
        let controller = VoiceController(mic: FakeMic(), transcriber: FakeTranscriber(result: ""), detector: FakeSpeechDetector(),
                                         speaker: speaker, sounds: FakeSoundPlayer(), clock: FakeClock(0), tickInterval: nil)
        let events = controller.events
        _ = try await controller.speak("Hello there friend.")
        var seen: VoiceController.Event?
        for await event in events {
            if case .replyVoiceProblem = event { seen = event; break }
        }
        #expect(seen == .replyVoiceProblem("ElevenLabs rejected the API key, so the Mac voice is speaking."))
    }
}
