import AVFoundation
import Foundation
import Testing
@testable import BuddyVoice

/// Loads the real models and runs them once. Opt-in, because it needs the ~1.6 GB of models (or a
/// network to fetch them) and plays a short reply through the speakers:
///   BUDDYVOICE_LIVE_MODELS=1 [BUDDYVOICE_MODELS_DIR=…] BUDDYVOICE_CLIP=speech.wav Scripts/test.sh --filter LiveModels
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUDDYVOICE_LIVE_MODELS"] == "1"), .serialized)
struct LiveModelsTests {
    let env = ProcessInfo.processInfo.environment
    var store: ModelStore {
        env["BUDDYVOICE_MODELS_DIR"].map { ModelStore(root: URL(filePath: $0, directoryHint: .isDirectory)) } ?? ModelStore()
    }

    func clip() throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(filePath: try #require(env["BUDDYVOICE_CLIP"])))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        #expect(file.processingFormat.sampleRate == 16_000, "the clip must already be 16 kHz mono")
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    func ms(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    @Test func parakeetUnifiedStreamsAndFinalizes() async throws {
        let samples = try clip()
        let stt = ParakeetTranscriber(model: .parakeetUnified, store: store)
        var t = ContinuousClock.now
        try await stt.load()
        print("LIVE unified load \(Int(ms(since: t))) ms")
        try await stt.begin()
        for start in stride(from: 0, to: samples.count, by: 1600) {
            try await stt.append(Array(samples[start..<min(samples.count, start + 1600)]))
        }
        t = ContinuousClock.now
        let text = try await stt.finish()
        print("LIVE unified finish \(String(format: "%.1f", ms(since: t))) ms: \(text)")
        #expect(text.lowercased().contains("list"))
        // A second utterance on the same transcriber starts clean.
        try await stt.begin()
        #expect(try await stt.finish().isEmpty)
    }

    /// A discard while appends are still queued (the capture loop hands over chunks faster than the
    /// encoder decodes them), then an immediate re-listen. Nothing may throw ("Streaming window out of
    /// range"), and the queued audio must not reach the next session. Stopping the old feeder itself is
    /// the caller's job: an append made after `begin()` belongs to the new session by definition.
    @Test func cancelWithQueuedAppendsLeavesTheNextSessionClean() async throws {
        let samples = try clip()
        let stt = ParakeetTranscriber(model: .parakeetUnified, store: store)
        try await stt.load()
        for round in 0 ..< 5 {
            try await stt.begin()
            let queued = stride(from: 0, to: samples.count, by: 1600).map { start in
                Task { try await stt.append(Array(samples[start..<min(samples.count, start + 1600)])) }
            }
            try await Task.sleep(for: .milliseconds(10 + 30 * round))
            await stt.cancel()
            try await stt.begin()
            for task in queued { try await task.value }
            let leaked = try await stt.finish()
            #expect(leaked.isEmpty, "round \(round) leaked: \(leaked)")
        }
        try await stt.begin()
        for start in stride(from: 0, to: samples.count, by: 1600) {
            try await stt.append(Array(samples[start..<min(samples.count, start + 1600)]))
        }
        let text = try await stt.finish()
        print("LIVE after 5 cancel races: \(text)")
        #expect(text.lowercased().contains("list"))
    }

    @Test func sileroSeesSpeech() async throws {
        let samples = try clip()
        let vad = SileroDetector(store: store)
        let t = ContinuousClock.now
        try await vad.load()
        print("LIVE vad load \(Int(ms(since: t))) ms")
        var events: [SpeechActivity] = []
        for start in stride(from: 0, to: samples.count, by: 1600) {
            if let e = try await vad.process(Array(samples[start..<min(samples.count, start + 1600)])) { events.append(e) }
        }
        print("LIVE vad events \(events)")
        #expect(events.first == .started)
    }

    @Test func kokoroSpeaksAndStopsFast() async throws {
        let playback = AudioPlayback()
        let kokoro = KokoroSpeaker(store: store, playback: playback)
        var t = ContinuousClock.now
        try await kokoro.load()
        print("LIVE kokoro load + warm-up \(Int(ms(since: t))) ms")
        t = ContinuousClock.now
        let levels = try await kokoro.speak("Your new date filter drops last week's test data, so the list is empty. Want me to loosen it?")
        print("LIVE kokoro time to audio \(Int(ms(since: t))) ms")
        try await Task.sleep(for: .milliseconds(400))
        t = ContinuousClock.now
        await kokoro.stop()
        var after = 0
        for await _ in levels { after += 1 }
        let stopMs = ms(since: t)
        print("LIVE kokoro stop → levels finished \(String(format: "%.1f", stopMs)) ms")
        #expect(stopMs < 150)
    }

    /// Where the time goes between `speak()` and the first audible glow, for unseen 14-word replies.
    @Test func kokoroLatencyBreakdown() async throws {
        let kokoro = KokoroSpeaker(store: store, playback: AudioPlayback())
        try await kokoro.load()
        let replies = [
            "Your new date filter drops last week's test data. Want me to loosen it for now?",
            "The build failed because the signing identity expired yesterday. Should I renew it?",
            "That chart counts signups twice when users switch teams. I can fix the query.",
        ]
        // The glow lights at a metered level of 0.05, about -57.6 dBFS raw.
        let audible: Float = 0.0013
        for (i, text) in replies.enumerated() {
            var t = ContinuousClock.now
            let (samples, rate) = try await kokoro.synthesize(text)
            let synth = ms(since: t)
            let windows = LevelWindows.rms(samples, sampleRate: rate)
            let lead = Double(windows.firstIndex { $0 > audible } ?? windows.count) * 20

            let playback = AudioPlayback()
            if i > 0 { await playback.prewarm(sampleRate: rate) }   // run 0 measures a cold engine
            t = ContinuousClock.now
            let levels = try await playback.playVoice(samples, sampleRate: rate)
            let start = ms(since: t)
            var firstAudible = Double.nan
            for await level in levels where level > audible {
                firstAudible = ms(since: t)
                break
            }
            await playback.stopVoice()
            print(String(format: "LIVE breakdown %d (%@ engine): synth %.0f ms, raw lead-in %.0f ms, playVoice %.1f ms, play → first audible level %.0f ms → glow at ~%.0f ms",
                         i, i > 0 ? "prewarmed" : "cold", synth, lead, start, firstAudible, synth + firstAudible))
            #expect(firstAudible < start + 60, "the quiet lead-in is trimmed")
        }
    }

    /// Time to first audio for one-, two- and three-sentence replies (warm voice), sentence by sentence
    /// against the whole line synthesized at once (the path before sentence splitting), on the same text.
    @Test func kokoroSentenceLatency() async throws {
        let playback = AudioPlayback()
        let kokoro = KokoroSpeaker(store: store, playback: playback)
        await kokoro.warmUp()
        let replies = [
            ("1 sentence", "Your new date filter drops last week's test data."),
            ("2 sentences", "Your new date filter drops last week's test data. Want me to loosen it?"),
            ("3 sentences", "The build failed on the signing step. The identity expired yesterday. Should I renew it now?"),
            ("4 sentences", "Your list is empty because the new date filter drops last week's test data. The seed script only writes rows dated last Monday. Loosening the filter to thirty days brings them back. Want me to change it?"),
        ]
        for (label, text) in replies {
            for run in 0 ..< 3 {
                for split in [true, false] {
                    let t = ContinuousClock.now
                    let levels: AsyncStream<Float>
                    if split {
                        levels = try await kokoro.speak(text)
                    } else {
                        let (samples, rate) = try await kokoro.synthesize(text)
                        levels = try await playback.playVoice(samples, sampleRate: rate)
                    }
                    var firstAudible = Double.nan
                    for await level in levels where level > LevelWindows.quiet {
                        if firstAudible.isNaN { firstAudible = ms(since: t) }
                    }
                    let total = ms(since: t)
                    // How long the node sat idle waiting for the next sentence (0 when it was queued in time).
                    let timeline = await playback.timeline
                    let idle = zip(timeline, timeline.dropFirst()).map { a, b in max(0, milliseconds(b.startsAt - a.endsAt)) }
                    print(String(format: "LIVE sentences %@ run %d %@: first audible %.0f ms, done %.0f ms, segments %d, idle gaps %@ ms",
                                 label, run, split ? "split" : "whole", firstAudible, total, timeline.count,
                                 idle.map { String(format: "%.0f", $0) }.joined(separator: ",")))
                }
            }
        }
    }

    /// A follow-on line queued with `continueReply` plays after the first, on one level stream.
    @Test func kokoroContinuesAReplyWithoutCuttingIt() async throws {
        let playback = AudioPlayback()
        let kokoro = KokoroSpeaker(store: store, playback: playback)
        await kokoro.warmUp()
        let t = ContinuousClock.now
        let levels = try await kokoro.speak("Let me check the repo.")
        #expect(await kokoro.continueReply("One moment. I'm reading the date filter now."))
        var audible = 0
        for await level in levels where level > LevelWindows.quiet { audible += 1 }
        let timeline = await playback.timeline
        print(String(format: "LIVE continue: done %.0f ms, segments %d, audible windows %d", ms(since: t), timeline.count, audible))
        #expect(timeline.count == 2, "\"One moment.\" merges into the next sentence")
        #expect(timeline.allSatisfy { $0.playedBackAt != nil }, "nothing was cut")
        #expect(await kokoro.continueReply("Too late.") == false, "the reply has played out")
    }

    func milliseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Kokoro synthesis cost by text: whole replies against their sentences, each run 4 times.
    @Test func kokoroSynthesisBySentence() async throws {
        let kokoro = KokoroSpeaker(store: store, playback: AudioPlayback())
        try await kokoro.load()
        let texts = [
            "Your new date filter drops last week's test data. Want me to loosen it?",
            "Your new date filter drops last week's test data.",
            "Want me to loosen it?",
            "The build failed on the signing step. The identity expired yesterday. Should I renew it now?",
            "The build failed on the signing step.",
            "The identity expired yesterday.",
            "Should I renew it now?",
        ]
        for text in texts {
            var times: [Double] = []
            var seconds = 0.0
            for _ in 0 ..< 4 {
                let t = ContinuousClock.now
                let (samples, rate) = try await kokoro.synthesize(text)
                times.append(ms(since: t))
                seconds = Double(samples.count) / rate
            }
            print(String(format: "LIVE synth %.0f/%.0f/%.0f/%.0f ms for %.1f s audio: %@", times[0], times[1], times[2], times[3], seconds, text))
        }
    }

    /// The fallback voice continues a reply too, rather than cutting it.
    @Test func systemVoiceContinuesAReply() async throws {
        let playback = AudioPlayback()
        let speaker = SystemSpeaker(playback: playback)
        await speaker.warmUp()
        let levels = try await speaker.speak("Let me check the repo.")
        #expect(await speaker.continueReply("One moment."))
        for await _ in levels {}
        let timeline = await playback.timeline
        print("LIVE system continue: segments \(timeline.count)")
        #expect(timeline.count == 2)
        #expect(timeline.allSatisfy { $0.playedBackAt != nil }, "nothing was cut")
    }

    @Test func systemVoiceRendersAndStops() async throws {
        let speaker = SystemSpeaker(playback: AudioPlayback())
        let t = ContinuousClock.now
        let levels = try await speaker.speak("Using the system voice.")
        print("LIVE system voice time to audio \(Int(ms(since: t))) ms")
        await speaker.stop()
        for await _ in levels {}
    }
}

/// Review: a listen while Parakeet loads is told "not loaded" at once instead of waiting out the load.
///   BUDDYVOICE_LIVE_BEGIN=1 BUDDYVOICE_MODELS_DIR=… Scripts/test.sh --filter LiveBeginDuringLoad
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUDDYVOICE_LIVE_BEGIN"] == "1"))
struct LiveBeginDuringLoadTests {
    @Test func beginDuringALoadAnswersAtOnce() async throws {
        let env = ProcessInfo.processInfo.environment
        let store = env["BUDDYVOICE_MODELS_DIR"].map { ModelStore(root: URL(filePath: $0, directoryHint: .isDirectory)) } ?? ModelStore()
        let transcriber = ParakeetTranscriber(model: .parakeetTDTv2, store: store)
        let loading = Task { try await transcriber.load { _ in } }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        await #expect(throws: VoiceModelError.notLoaded) { try await transcriber.begin() }
        let waited = ContinuousClock.now - start
        try await loading.value
        let loadTook = ContinuousClock.now - start
        print("begin answered in \(waited); load finished after \(loadTook)")
        #expect(waited < .milliseconds(100))
        try await transcriber.begin()   // and once loaded, it begins
    }
}
