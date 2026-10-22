import Foundation
import Synchronization
import Testing
@testable import BuddyVoice

/// Plays back scripted HTTP responses and records the requests. No network.
final class ScriptedStreamer: HTTPStreamer {
    struct Response: Sendable {
        var status = 200
        var chunks: [Data] = []
        /// Delay before each chunk, to stand in for a stream that's still arriving.
        var chunkDelay: Duration = .zero
        var failAfterChunks: (any Error & Sendable)?
        var sendError: (any Error & Sendable)?
        /// Time to connect; cancelling meanwhile throws URLError(.cancelled), as URLSession does.
        var connectDelay: Duration = .zero
        /// Holds every chunk after the first until opened: "still streaming" without timing.
        var holdAfterFirst: FakeGate?
    }
    private let state = Mutex<(responses: [Response], requests: [URLRequest], terminated: Int)>(([], [], 0))

    init(_ responses: [Response]) { state.withLock { $0.responses = responses } }

    var requests: [URLRequest] { state.withLock { $0.requests } }
    var terminated: Int { state.withLock { $0.terminated } }

    func send(_ request: URLRequest) async throws -> (status: Int, body: AsyncThrowingStream<Data, any Error>) {
        let response = state.withLock { s -> Response in
            s.requests.append(request)
            return s.responses.isEmpty ? Response(status: 500) : s.responses.removeFirst()
        }
        if response.connectDelay > .zero {
            try? await Task.sleep(for: response.connectDelay)
            if Task.isCancelled { throw URLError(.cancelled) }
        }
        if let error = response.sendError { throw error }
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                for (i, chunk) in response.chunks.enumerated() {
                    if i > 0, let gate = response.holdAfterFirst { await gate.pass() }
                    if response.chunkDelay > .zero { try? await Task.sleep(for: response.chunkDelay) }
                    if Task.isCancelled { return }
                    continuation.yield(chunk)
                }
                if let error = response.failAfterChunks { continuation.finish(throwing: error) } else { continuation.finish() }
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.state.withLock { $0.terminated += 1 }
            }
        }
        return (response.status, stream)
    }
}

/// `seconds` of 24 kHz 16-bit PCM at a faint but audible level (just above LevelWindows.quiet).
private func pcm(_ seconds: Double, amplitude: Int16 = 70) -> Data {
    var data = Data()
    for i in 0 ..< Int(24_000 * seconds) {
        let v = i % 2 == 0 ? amplitude : -amplitude
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

private func errorBody(_ status: String, _ message: String) -> Data {
    Data(#"{"detail":{"status":"\#(status)","message":"\#(message)"}}"#.utf8)
}

struct ElevenLabsClientTests {
    @Test func decodesLittleEndianPCMAcrossOddChunkBoundaries() {
        var carry = Data()
        // 0x0001 = 1, 0x8000 = -32768, split so the second sample straddles two chunks.
        let a = ElevenLabsClient.decode(Data([0x01, 0x00, 0x00]), carry: &carry)
        let b = ElevenLabsClient.decode(Data([0x80]), carry: &carry)
        #expect(a == [Float(1) / 32_768])
        #expect(b == [-1])
        #expect(carry.isEmpty)
    }

    @Test(arguments: [
        (401, "invalid_api_key", "Invalid API key", ElevenLabsFailure.invalidKey),
        (401, "quota_exceeded", "This request exceeds your quota", .quotaExceeded),
        (400, "invalid_model", "Model eleven_v4_turbo is not supported here", .modelRejected("invalid_model")),
        (429, "too_many_concurrent_requests", "Busy", .unreachable("busy")),
        (503, "", "", .unreachable("server error 503")),
        (400, "max_character_limit_exceeded", "Too long", .badResponse(status: 400)),
    ])
    func mapsErrorResponses(status: Int, code: String, message: String, expected: ElevenLabsFailure) {
        #expect(ElevenLabsClient.failure(status: status, body: errorBody(code, message)) == expected)
    }

    @Test func requestCarriesTheKeyInTheHeaderAndAsksForRawPCM() async throws {
        let http = ScriptedStreamer([.init(chunks: [pcm(0.05)])])
        let client = ElevenLabsClient(http: http, keys: FakeSecretStore("sk-test"))
        for try await _ in try await client.speech("Hello there.", voiceID: "voice1") {}
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/text-to-speech/voice1/stream")
        #expect(request.url?.query == "output_format=pcm_24000")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "sk-test")
        #expect(request.url?.absoluteString.contains("sk-test") == false, "the key is never in the URL")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
        #expect(body == ["text": "Hello there.", "model_id": "eleven_v4_turbo"])
    }

    @Test func aRejectedModelFallsBackToFlashOnceAndRemembers() async throws {
        let http = ScriptedStreamer([
            .init(status: 400, chunks: [errorBody("invalid_model", "model not available on this endpoint")]),
            .init(chunks: [pcm(0.05)]),
            .init(chunks: [pcm(0.05)]),
        ])
        let client = ElevenLabsClient(http: http, keys: FakeSecretStore("k"))
        for try await _ in try await client.speech("One.", voiceID: "v") {}
        for try await _ in try await client.speech("Two.", voiceID: "v") {}
        let models = http.requests.compactMap { $0.httpBody }.compactMap { try? JSONDecoder().decode([String: String].self, from: $0)["model_id"] }
        #expect(models == ["eleven_v4_turbo", "eleven_flash_v2_5", "eleven_flash_v2_5"])
    }

    @Test func noKeyOrOfflineAreTypedFailures() async {
        let none = ElevenLabsClient(http: ScriptedStreamer([]), keys: FakeSecretStore())
        await #expect(throws: ElevenLabsFailure.noKey) { _ = try await none.speech("Hi.", voiceID: "v") }
        let offline = ElevenLabsClient(http: ScriptedStreamer([.init(sendError: URLError(.notConnectedToInternet))]),
                                       keys: FakeSecretStore("k"))
        await #expect(throws: ElevenLabsFailure.unreachable("offline or unreachable")) { _ = try await offline.speech("Hi.", voiceID: "v") }
    }

    @Test func aLargeVoiceListStillValidates() async throws {
        let one = #"{"voice_id":"v%d","name":"Voice %d","category":"premade","fine_tuning":{"x":"%@"}}"#
        let padding = String(repeating: "p", count: 2_000)
        let items = (0 ..< 100).map { String(format: one, $0, $0, padding) }.joined(separator: ",")
        let body = Data(#"{"voices":[\#(items)]}"#.utf8)
        #expect(body.count > 150_000)
        let http = ScriptedStreamer([.init(chunks: stride(from: 0, to: body.count, by: 4_800).map { body.subdata(in: $0 ..< min($0 + 4_800, body.count)) })])
        let account = ElevenLabsAccount(keys: FakeSecretStore("k"), http: http)
        #expect(await account.validate() == .ok)
    }

    @Test func modelErrorsInOtherShapesStillTriggerTheFallback() {
        let list = Data(#"{"detail":[{"loc":["body","model_id"],"msg":"model not supported"}]}"#.utf8)
        let text = Data(#"{"detail":"Model eleven_v4_turbo is unavailable"}"#.utf8)
        #expect(ElevenLabsClient.failure(status: 422, body: list) == .modelRejected("status 422"))
        #expect(ElevenLabsClient.failure(status: 400, body: text) == .modelRejected("status 400"))
    }

    @Test func aKeyThatCantListVoicesStillValidates() async throws {
        let denied = ScriptedStreamer.Response(status: 401, chunks: [errorBody("missing_permissions", "This key lacks voices_read")])
        let account = ElevenLabsAccount(keys: FakeSecretStore("k"), http: ScriptedStreamer([denied, denied]))
        #expect(await account.validate() == .ok)
        #expect(try await account.voices().isEmpty, "the picker falls back to the default voice")
    }

    @Test func theCachedStoreReadsTheKeychainOnce() throws {
        final class CountingStore: SecretStore {
            let reads = Mutex(0)
            func contains() -> Bool { true }
            func read() throws -> String? { reads.withLock { $0 += 1 }; return "k" }
            func write(_ secret: String) throws {}
            func delete() throws {}
        }
        let base = CountingStore()
        let cached = CachedSecretStore(base)
        for _ in 0 ..< 5 { _ = try cached.read() }
        #expect(base.reads.withLock { $0 } == 1)
        try cached.write("new")
        #expect(try cached.read() == "new")
        try cached.delete()
        #expect(try cached.read() == nil)
        #expect(!cached.contains())
    }

    @Test func anUnreadableKeyIsNotReportedAsMissing() async {
        struct Locked: SecretStore {
            func contains() -> Bool { true }
            func read() throws -> String? { throw KeychainError(status: -25293) }
            func write(_ secret: String) throws {}
            func delete() throws {}
        }
        let client = ElevenLabsClient(http: ScriptedStreamer([]), keys: Locked())
        await #expect(throws: ElevenLabsFailure.keyUnreadable) { _ = try await client.speech("Hi.", voiceID: "v") }
    }

    @Test func accountValidatesAGivenKeyBeforeSavingIt() async throws {
        let voices = Data(#"{"voices":[{"voice_id":"a1","name":"Ava","category":"premade"}]}"#.utf8)
        let http = ScriptedStreamer([.init(chunks: [voices]), .init(status: 401, chunks: [errorBody("invalid_api_key", "Invalid API key")])])
        let keys = FakeSecretStore()
        let account = ElevenLabsAccount(keys: keys, http: http)
        #expect(await account.validate(key: "  new-key  ") == .ok)
        #expect(http.requests.first?.value(forHTTPHeaderField: "xi-api-key") == "new-key")
        #expect(!account.hasKey, "checking doesn't save")
        try account.saveKey(" saved ")
        #expect(try keys.read() == "saved")
        #expect(await account.validate() == .invalidKey)
    }
}

@Suite(.serialized)
struct ElevenLabsSpeakerTests {
    @Test func speakReturnsAtTheFirstAudioWhileTheSentenceIsStillStreaming() async throws {
        let rest = FakeGate()
        rest.close()
        let http = ScriptedStreamer([.init(chunks: Array(repeating: pcm(0.1), count: 6), holdAfterFirst: rest)])
        let playback = AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput())
        let speaker = ElevenLabsSpeaker(voiceID: "v", client: ElevenLabsClient(http: http, keys: FakeSecretStore("k")), playback: playback)
        // Pieces 2–6 can't arrive until the gate opens, so returning at all proves speak didn't wait for them.
        let levels = try await speaker.speak("A sentence that streams in six pieces.")
        #expect(await playback.timeline.count == 1, "only the first piece was queued when speak returned")
        rest.open()
        for await _ in levels {}
        let timeline = await playback.timeline
        #expect(timeline.count >= 3, "pieces queued as they arrived")
        #expect(timeline.allSatisfy { $0.playedBackAt != nil })
    }

    @Test func sentencesAndAContinuationAreRequestedInOrder() async throws {
        let http = ScriptedStreamer(Array(repeating: .init(chunks: [pcm(0.05)]), count: 3))
        let speaker = ElevenLabsSpeaker(voiceID: "v", client: ElevenLabsClient(http: http, keys: FakeSecretStore("k")),
                                        playback: AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput()))
        let levels = try await speaker.speak("Your date filter drops last week. Want me to loosen it now?")
        #expect(await speaker.continueReply("One moment while I check the repo."))
        for await _ in levels {}
        let texts = http.requests.compactMap { $0.httpBody }.compactMap { try? JSONDecoder().decode([String: String].self, from: $0)["text"] }
        #expect(texts == ["Your date filter drops last week.", "Want me to loosen it now?", "One moment while I check the repo."])
    }

    @Test func accountProblemsKeepTheFallbackAndNetworkProblemsOnlyThisReply() async {
        let invalid = ScriptedStreamer([.init(status: 401, chunks: [errorBody("invalid_api_key", "Invalid API key")])])
        let a = ElevenLabsSpeaker(voiceID: "v", client: ElevenLabsClient(http: invalid, keys: FakeSecretStore("bad")),
                                  playback: AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput()))
        await #expect(throws: VoiceUnavailable.loadFailed("ElevenLabs: invalidKey")) { _ = try await a.speak("Hello there friend.") }
        #expect(await a.lastFailure == .invalidKey)

        let offline = ScriptedStreamer([.init(sendError: URLError(.timedOut))])
        let b = ElevenLabsSpeaker(voiceID: "v", client: ElevenLabsClient(http: offline, keys: FakeSecretStore("k")),
                                  playback: AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput()))
        await #expect(throws: VoiceUnavailable.synthesisFailed("ElevenLabs: unreachable(\"timed out\")")) { _ = try await b.speak("Hello there friend.") }

        let none = ElevenLabsSpeaker(voiceID: "v", client: ElevenLabsClient(http: ScriptedStreamer([]), keys: FakeSecretStore()),
                                     playback: AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput()))
        await #expect(throws: VoiceUnavailable.loadFailed("no ElevenLabs key")) { _ = try await none.speak("Hello there friend.") }
    }

    @Test func aFailureBeforeAudioFallsBackToTheOnDeviceVoiceForThatReply() async throws {
        let http = ScriptedStreamer([.init(chunks: [], failAfterChunks: URLError(.networkConnectionLost))])
        let primary = ElevenLabsSpeaker(voiceID: "v", client: ElevenLabsClient(http: http, keys: FakeSecretStore("k")),
                                        playback: AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput()))
        let onDevice = FakeSpeaker()
        let speaker = FallbackSpeaker(primary: primary, fallback: onDevice)
        _ = try await speaker.speak("Hello there friend.")
        #expect(onDevice.spoken == ["Hello there friend."])
        #expect(await speaker.active == .primary, "a network failure doesn't switch voices for good")
    }

    @Test func stoppingBeforeTheFirstAudioIsNotAFailure() async throws {
        let http = ScriptedStreamer([.init(chunks: [pcm(0.1)], connectDelay: .milliseconds(400))])
        let speaker = ElevenLabsSpeaker(voiceID: "v", client: ElevenLabsClient(http: http, keys: FakeSecretStore("k")),
                                        playback: AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput()))
        let speaking = Task { try await speaker.speak("Hello there friend.") }
        try await Task.sleep(for: .milliseconds(100))
        await speaker.stop()
        let levels = try await speaking.value
        for await _ in levels {}
        #expect(await speaker.lastFailure == nil, "a stop isn't reported as ElevenLabs failing")
    }

    @Test func stopMidStreamCancelsTheRequest() async throws {
        let http = ScriptedStreamer([.init(chunks: Array(repeating: pcm(0.1), count: 30), chunkDelay: .milliseconds(30))])
        let speaker = ElevenLabsSpeaker(voiceID: "v", client: ElevenLabsClient(http: http, keys: FakeSecretStore("k")),
                                        playback: AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput()))
        let levels = try await speaker.speak("A long sentence that keeps on streaming for a while.")
        await speaker.stop()
        for await _ in levels {}
        try await Task.sleep(for: .milliseconds(150))
        #expect(http.terminated == 1, "the HTTP stream was dropped, which cancels the request")
    }
}
