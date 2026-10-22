import AVFoundation
import BuddyCore
import Foundation
import os
import Synchronization

/// The fallback voice: AVSpeechSynthesizer, preferring a Premium or Enhanced English voice. Speech is
/// rendered to buffers and played through `AudioPlayback`, so the glow gets the same levels as Kokoro.
public actor SystemSpeaker: SpeechSpeaker {
    private let synthesizer = AVSpeechSynthesizer()
    private let playback: AudioPlayback
    private let voice: AVSpeechSynthesisVoice?
    private var generation = 0
    /// One collector per render, so concurrent renders (warm-up and a reply) don't share state.
    private var collectors: [Int: SpeechCollector] = [:]
    private var renders = 0
    /// The reply in flight, by generation, for `continueReply`.
    private var reply: (generation: Int, handle: AudioPlayback.ReplyHandle)?
    /// The last queued continuation; the next one runs after it, so lines keep their order.
    private var tail: Task<Void, Never>?
    private let log = Logger(subsystem: BuddyCore.bundleIdentifier, category: "voice")

    public init(playback: AudioPlayback, language: String = "en-US") {
        self.playback = playback
        voice = Self.bestVoice(language: language)
    }

    public func warmUp() async {
        // The first render loads the voice (a Premium voice is slow cold), so it gets a longer limit.
        _ = try? await render("Ready.", minimumTimeout: Self.coldRenderTimeout)
        await playback.prewarm()
    }

    public func speak(_ text: String) async throws -> AsyncStream<Float> {
        generation += 1
        let id = generation
        tail?.cancel()
        tail = nil
        reply = nil
        let ticket = await playback.reserveReply()   // refused by playback if a stop lands first
        let (samples, sampleRate) = try await render(text)
        guard id == generation else { return AsyncStream { $0.finish() } }
        let handle = try await playback.beginReply(sampleRate: sampleRate, ticket: ticket)
        do {
            try await handle.append(samples)
        } catch {
            await handle.finish()
            throw error
        }
        // Released at once: a continuation holds the reply again while it is still playing.
        await handle.finish()
        guard id == generation else { return AsyncStream { $0.finish() } }
        reply = (id, handle)
        return handle.levels
    }

    /// Renders `text` and queues it behind the reply still playing, so a follow-on line doesn't cut it.
    public func continueReply(_ text: String) async -> Bool {
        guard let (id, handle) = reply, id == generation else { return false }
        // Held before anything else awaits, so the reply can't end before its line is queued.
        let attach = Task { await handle.hold() }
        let previous = tail
        tail = Task {
            await previous?.value
            guard await attach.value else { return }
            if id == self.generation, let (samples, _) = try? await self.render(text), id == self.generation {
                _ = try? await handle.append(samples)
            }
            await handle.finish()
        }
        return await attach.value
    }

    public func stop() async {
        generation += 1
        tail?.cancel()
        tail = nil
        reply = nil
        synthesizer.stopSpeaking(at: .immediate)
        // The synthesizer may not send its closing empty buffer after a stop; release the waiters.
        for collector in collectors.values { collector.finish() }
        await playback.stopVoice()
    }

    /// Renders speech to samples. Empty text renders nothing. A render that never sends its closing
    /// buffer fails after `renderTimeout(for:)` instead of hanging the reply (or `prepare()`).
    private func render(_ text: String, minimumTimeout: Double = 2) async throws -> ([Float], Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], 22_050) }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        let collector = SpeechCollector()
        renders += 1
        let key = renders
        collectors[key] = collector
        defer { collectors[key] = nil }
        let timeout = Self.renderTimeout(for: trimmed, minimum: minimumTimeout)
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { self.renderTimedOut(collector, after: timeout) }
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            collector.onFinish(done)
            synthesizer.write(utterance, toBufferCallback: Self.bufferCallback(collector))
        }
        return collector.result
    }

    /// The first render after launch loads the voice; a Premium voice can take seconds.
    static let coldRenderTimeout: Double = 5

    /// Rendering runs faster than real time; allow generously more than the spoken length.
    static func renderTimeout(for text: String, minimum: Double = 2) -> Double {
        max(minimum, Double(text.count) * 0.08)
    }

    /// A render that never sent its closing buffer. Stop the synthesizer too, or the next `write`
    /// queues behind the stuck utterance and times out as well.
    private func renderTimedOut(_ collector: SpeechCollector, after seconds: Double) {
        guard !collector.isFinished else { return }
        log.error("System voice render timed out after \(seconds, privacy: .public) s; stopping the synthesizer")
        synthesizer.stopSpeaking(at: .immediate)
        collector.finish(error: VoiceUnavailable.synthesisFailed("system voice timed out"))
    }

    // Called by AVSpeechSynthesizer on its own queue; built outside the actor (isolation trap).
    nonisolated static func bufferCallback(_ collector: SpeechCollector) -> AVSpeechSynthesizer.BufferCallback {
        { buffer in collector.receive(buffer) }
    }

    static func bestVoice(language: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }
}

/// Accumulates synthesized buffers as mono Float32. An empty buffer marks the end.
final class SpeechCollector: Sendable {
    private struct State {
        var samples: [Float] = []
        var sampleRate: Double = 22_050
        var done: CheckedContinuation<Void, any Error>?
        var finished = false
        var error: (any Error)?
    }

    private let state = Mutex(State())

    func onFinish(_ continuation: CheckedContinuation<Void, any Error>) {
        let finished: (Bool, (any Error)?) = state.withLock { s in
            if !s.finished { s.done = continuation }
            return (s.finished, s.error)
        }
        guard finished.0 else { return }
        if let error = finished.1 { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    var result: ([Float], Double) { state.withLock { ($0.samples, $0.sampleRate) } }
    var isFinished: Bool { state.withLock { $0.finished } }

    func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
            finish()
            return
        }
        let samples = Self.monoFloats(pcm)
        state.withLock {
            $0.sampleRate = pcm.format.sampleRate
            $0.samples.append(contentsOf: samples)
        }
    }

    /// Ends the render, successfully or with `error`. Only the first call counts.
    func finish(error: (any Error)? = nil) {
        let done: CheckedContinuation<Void, any Error>? = state.withLock { s in
            guard !s.finished else { return nil }
            s.finished = true
            s.error = error
            let done = s.done
            s.done = nil
            return done
        }
        guard let done else { return }
        if let error { done.resume(throwing: error) } else { done.resume() }
    }

    /// Channel 0 as Float32, from either of the formats the synthesizer produces.
    static func monoFloats(_ pcm: AVAudioPCMBuffer) -> [Float] {
        let n = Int(pcm.frameLength)
        if let data = pcm.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: data, count: n))
        }
        if let data = pcm.int16ChannelData?[0] {
            return (0..<n).map { Float(data[$0]) / Float(Int16.max) }
        }
        return []
    }
}
