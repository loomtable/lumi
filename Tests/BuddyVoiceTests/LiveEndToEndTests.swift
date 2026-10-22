import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import BuddyVoice

/// The whole voice path on the real Mac with real models: a question rendered by `say` into a file is
/// fed through `FileMic` (file-injected audio), then Parakeet transcribes it and Kokoro speaks a reply
/// through the speakers.
///
/// Why not speak through the speakers: with voice processing on, its echo canceller removes whatever
/// the Mac itself plays, so `say` out loud transcribes as nothing (measured). The live mic path is
/// covered by EngineMic's own live checks and a human-voice check in the manual test batch.
///
///   BUDDYVOICE_LIVE_E2E=1 [BUDDYVOICE_MODELS_DIR=…] Scripts/test.sh --filter LiveEndToEnd
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUDDYVOICE_LIVE_E2E"] == "1"), .serialized)
struct LiveEndToEndTests {
    private func ms(since t: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    @Test(arguments: SpeechModel.allCases)
    func askThenHearTheReply(model: SpeechModel) async throws {
        var settings = VoiceSettings(speechModel: model)
        if let dir = ProcessInfo.processInfo.environment["BUDDYVOICE_MODELS_DIR"] {
            settings.modelsDirectory = URL(filePath: dir, directoryHint: .isDirectory)
        }
        let question = FileManager.default.temporaryDirectory.appending(path: "buddyvoice-e2e-question.aiff")
        let say = try Process.run(URL(filePath: "/usr/bin/say"),
                                  arguments: ["-o", question.path, "Why is this list empty? I added a date filter yesterday."])
        say.waitUntilExit()
        let mic = try FileMic(file: question)

        let voice = VoiceController.live(settings: settings, mic: mic)
        let events = EventLog()
        let stream = voice.events, levelStream = voice.levels
        Task { for await e in stream { events.log.withLock { $0.append((.now, e)) } } }
        Task { for await l in levelStream { events.levels.withLock { $0.append((.now, l)) } } }

        var t = ContinuousClock.now
        try await voice.prepare()
        print("[\(model)] prepare: \(Int(ms(since: t))) ms")

        try await voice.startListening()
        try await Task.sleep(for: .seconds(mic.duration + 0.3))
        t = .now
        let text = try await voice.finishListening()
        print("[\(model)] gesture → transcript: \(Int(ms(since: t))) ms: \(text)")
        #expect(text.lowercased().contains("date filter"))
        let micLevels = events.levels.withLock { $0.compactMap { if case .mic(let l) = $0.1 { l } else { nil } } }
        #expect((micLevels.max() ?? 0) > 0.3)

        let start = ContinuousClock.now
        try await voice.speak("Your new date filter drops last week's test data. Want me to loosen it?")
        print("[\(model)] speak() returned (synthesis + playback scheduled): \(Int(ms(since: start))) ms")
        let firstGlow = try await waitForLevel(events, after: start) { if case .reply(let l) = $0 { l > 0.05 } else { false } }
        print("[\(model)] speak → first audible glow: \(Int(firstGlow)) ms")
        _ = try await waitFor(events, after: start, timeout: .seconds(20)) { $0 == .speakingFinished }

        try await voice.speak("This sentence gets cut off after half a second so we can time the stop.")
        try await Task.sleep(for: .milliseconds(500))
        t = .now
        await voice.stopSpeaking()
        let stopped = ms(since: t)
        print("[\(model)] stopSpeaking: \(String(format: "%.1f", stopped)) ms")
        #expect(stopped < 150)
    }

    final class EventLog: Sendable {
        let log = Mutex<[(ContinuousClock.Instant, VoiceController.Event)]>([])
        let levels = Mutex<[(ContinuousClock.Instant, VoiceController.Level)]>([])
    }

    /// Milliseconds from `after` to the first level matching `match`.
    private func waitForLevel(
        _ events: EventLog,
        after: ContinuousClock.Instant,
        timeout: Duration = .seconds(5),
        _ match: (VoiceController.Level) -> Bool
    ) async throws -> Double {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let hit = events.levels.withLock({ $0.first { $0.0 >= after && match($0.1) } }) {
                let d = hit.0 - after
                return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("level not seen within \(timeout)")
        return .nan
    }

    /// Milliseconds from `after` to the first event matching `match`.
    private func waitFor(
        _ events: EventLog,
        after: ContinuousClock.Instant,
        timeout: Duration = .seconds(5),
        _ match: (VoiceController.Event) -> Bool = { _ in false }
    ) async throws -> Double {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let hit = events.log.withLock({ $0.first { $0.0 >= after && match($0.1) } }) {
                let d = hit.0 - after
                return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("event not seen within \(timeout)")
        return .nan
    }
}

/// Records what EngineMic hears while `say` speaks, with voice processing on and off, as 16 kHz WAVs.
///   BUDDYVOICE_LIVE_E2E=1 BUDDYVOICE_DUMP_DIR=/tmp/x Scripts/test.sh --filter LiveMicDump
/// It plays `say` through the speakers, so it only runs when both are set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUDDYVOICE_LIVE_E2E"] == "1"
                && ProcessInfo.processInfo.environment["BUDDYVOICE_DUMP_DIR"] != nil), .serialized)
struct LiveMicDumpTests {
    @Test(arguments: [true, false])
    func recordSay(voiceProcessing: Bool) async throws {
        let dir = URL(filePath: ProcessInfo.processInfo.environment["BUDDYVOICE_DUMP_DIR"]!, directoryHint: .isDirectory)
        let mic = EngineMic(voiceProcessing: voiceProcessing)
        try await mic.prepare()
        let stream = try await mic.start()
        let collector = Task {
            var samples: [Float] = []
            for await e in stream { if case .audio(let c) = e { samples += c.samples } }
            return samples
        }
        let say = try Process.run(URL(filePath: "/usr/bin/say"),
                                  arguments: ["Why is this list empty? I added a date filter yesterday."])
        say.waitUntilExit()
        try await Task.sleep(for: .milliseconds(300))
        await mic.stop()
        let samples = await collector.value
        let rms = LevelMeter.rms(samples[...])
        print("vp=\(voiceProcessing): \(samples.count) samples, rms \(20 * log10(max(rms, 1e-9))) dBFS")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: dir.appending(path: "say-vp-\(voiceProcessing).wav"), settings: format.settings)
        try file.write(from: buffer)
    }
}
