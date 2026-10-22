import AVFoundation
import Foundation

/// RMS of consecutive windows of samples; the speaking glow follows these (~20 ms).
enum LevelWindows {
    static func rms(_ samples: [Float], sampleRate: Double, window: Double = 0.02) -> [Float] {
        let size = max(1, Int(sampleRate * window))
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / size + 1)
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + size)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            levels.append((sum / Float(end - start)).squareRoot())
            start = end
        }
        return levels
    }

    /// Below this a 20 ms window is inaudible (about -57.6 dBFS, where the glow's metered level is 0.05).
    static let quiet: Float = 0.0013

    /// Drops the near-silent lead-in voices render before the first word (about 300 ms for Kokoro),
    /// keeping one window of pre-roll so the onset isn't clipped.
    static func trimLeadingQuiet(_ samples: [Float], sampleRate: Double, window: Double = 0.02) -> [Float] {
        let size = max(1, Int(sampleRate * window))
        let levels = rms(samples, sampleRate: sampleRate, window: window)
        guard let first = levels.firstIndex(where: { $0 > quiet }) else { return samples }
        let start = max(0, first - 1) * size
        return start == 0 ? samples : Array(samples[start...])
    }

    /// Keeps at most `maximum` seconds of near-silence before the first word. Used between sentences,
    /// where some pause is natural but Kokoro's ~300 ms lead-in plus the previous tail is too long.
    static func capLeadingQuiet(_ samples: [Float], sampleRate: Double, maximum: Double = 0.12, window: Double = 0.02) -> [Float] {
        let size = max(1, Int(sampleRate * window))
        let levels = rms(samples, sampleRate: sampleRate, window: window)
        guard let first = levels.firstIndex(where: { $0 > quiet }) else { return samples }
        let keep = Int((maximum * sampleRate).rounded())
        let drop = first * size - keep
        return drop <= 0 ? samples : Array(samples[drop...])
    }
}

/// One output engine for spoken replies and interface sounds, with voice processing off.
/// Replies go to one player node and sounds to another, so a tick never cuts off a reply.
public actor AudioPlayback {
    private let output: any PlaybackOutput
    /// The reply being played. It stays open while the voice is still synthesizing later sentences, so
    /// the idle stop can't fire between them.
    private struct Reply {
        let id: Int
        let sampleRate: Double
        let levels: AsyncStream<Float>.Continuation
        /// Each scheduled segment's playhead start and its 20 ms RMS windows, for the meter.
        let segments: AsyncStream<(ContinuousClock.Instant, [Float])>.Continuation
        let meter: Task<Void, Never>
        /// Callers still appending: `beginReply` takes one, `hold` adds one, `finish` releases one.
        /// The reply ends once none are left and everything scheduled has played back.
        var holds = 1
        var outstanding = 0
        var appended = 0
        /// When the audio scheduled so far ends. A segment appended after the node ran dry starts now.
        var playheadEnd: ContinuousClock.Instant
    }

    /// Where each segment of the last reply sat on the playhead, for tests and live measurements.
    struct SegmentTiming: Sendable {
        var appendedAt: ContinuousClock.Instant
        var startsAt: ContinuousClock.Instant
        var endsAt: ContinuousClock.Instant
        var playedBackAt: ContinuousClock.Instant?
    }

    private var reply: Reply?
    private(set) var timeline: [SegmentTiming] = []
    private var generation = 0
    /// Bumped by `stopVoice()`. A reply ticket from before a stop is stale and never starts.
    private var stops = 0
    /// A running output engine costs idle CPU and keeps Bluetooth output awake, so it stops
    /// this long after the last reply or sound and goes back to prepared.
    private let idleStopDelay: Duration
    private var idleStop: Task<Void, Never>?
    private var effectsPlayUntil = ContinuousClock.now

    public init(idleStopDelay: Duration = .seconds(2)) {
        self.init(idleStopDelay: idleStopDelay, output: EngineOutput())
    }

    init(idleStopDelay: Duration = .seconds(2), output: any PlaybackOutput) {
        self.idleStopDelay = idleStopDelay
        self.output = output
    }

    /// Whether output is running right now (it's stopped while idle).
    public var isOutputRunning: Bool { output.isRunning }

    /// Identifies a reply from before its synthesis starts, so a `stopVoice()` that arrives while the
    /// voice is still synthesizing cancels it: its later `playVoice` finishes without playing.
    public struct ReplyTicket: Sendable, Equatable {
        let stops: Int
    }

    /// Take a ticket before synthesizing; pass it to `playVoice`.
    public func reserveReply() -> ReplyTicket { ReplyTicket(stops: stops) }

    func isCurrent(_ ticket: ReplyTicket) -> Bool { ticket.stops == stops }

    /// A reply being played segment by segment, for example sentence by sentence while the voice is
    /// still synthesizing the rest. `levels` is one stream across all segments.
    public struct ReplyHandle: Sendable {
        public let levels: AsyncStream<Float>
        let id: Int
        let playback: AudioPlayback

        /// Queues the next segment right after the previous one (or now, if playback ran dry). Returns
        /// false once the reply was stopped or replaced, so the caller can stop synthesizing.
        @discardableResult
        public func append(_ samples: [Float]) async throws -> Bool {
            try await playback.append(samples, to: id, keepLeadIn: false)
        }

        /// Like `append`, but plays the samples exactly as given: for the middle of a sentence that
        /// arrives in pieces (a streamed voice), where trimming each piece's quiet start would cut it.
        @discardableResult
        public func appendContinuing(_ samples: [Float]) async throws -> Bool {
            try await playback.append(samples, to: id, keepLeadIn: true)
        }

        /// No more segments from this caller. The levels stream ends when every hold is released and the
        /// last segment has played back.
        public func finish() async {
            await playback.finish(id)
        }

        /// Keeps the reply open for more segments, for example a follow-on line that continues it.
        /// Returns false once the reply has ended (played out, stopped or replaced); pair a true with
        /// one `finish()`.
        public func hold() async -> Bool {
            await playback.hold(id)
        }
    }

    /// Starts a segmented reply, interrupting any current one. With a `ticket` from before a
    /// `stopVoice()`, the reply is refused: `levels` is already finished and appends return false.
    public func beginReply(sampleRate: Double, ticket: ReplyTicket? = nil) throws -> ReplyHandle {
        if let ticket, !isCurrent(ticket) { return ReplyHandle(levels: AsyncStream { $0.finish() }, id: 0, playback: self) }
        cutReply()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false) else { throw VoiceModelError.badAudioFormat }
        try ensureRunning(.voice, format: format)
        generation += 1
        let id = generation
        let (levels, levelsContinuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(8))
        let (segments, segmentsContinuation) = AsyncStream.makeStream(of: (ContinuousClock.Instant, [Float]).self)
        // Yields each window when the playhead reaches it, across segments and any gaps between them.
        let meter = Task {
            for await (start, windows) in segments {
                for (index, level) in windows.enumerated() {
                    try? await Task.sleep(until: start + .milliseconds(20 * index), clock: .continuous)
                    if Task.isCancelled { return }
                    levelsContinuation.yield(level)
                }
            }
        }
        reply = Reply(id: id, sampleRate: sampleRate, levels: levelsContinuation, segments: segmentsContinuation,
                      meter: meter, playheadEnd: .now)
        timeline = []
        return ReplyHandle(levels: levels, id: id, playback: self)
    }

    /// Plays a whole reply. The stream yields its RMS every 20 ms in step with playback and finishes when
    /// the last sample has played or `stopVoice()` is called. A new reply interrupts the previous one.
    /// With a `ticket` from before a `stopVoice()`, nothing plays and the stream finishes at once.
    public func playVoice(_ samples: [Float], sampleRate: Double, ticket: ReplyTicket? = nil) throws -> AsyncStream<Float> {
        if let ticket, !isCurrent(ticket) { return AsyncStream { $0.finish() } }
        // Nothing to say (empty text, or a render stopped early) isn't a voice failure.
        guard !LevelWindows.trimLeadingQuiet(samples, sampleRate: sampleRate).isEmpty else {
            cutReply()
            return AsyncStream { $0.finish() }
        }
        let handle = try beginReply(sampleRate: sampleRate)
        _ = try append(samples, to: handle.id, keepLeadIn: false)
        finish(handle.id)
        return handle.levels
    }

    private func append(_ samples: [Float], to id: Int, keepLeadIn: Bool) throws -> Bool {
        guard var current = reply, current.id == id, current.holds > 0 else { return false }
        // The first segment loses its whole quiet lead-in; later ones keep a natural pause.
        let trimmed = keepLeadIn ? samples : current.appended == 0
            ? LevelWindows.trimLeadingQuiet(samples, sampleRate: current.sampleRate)
            : LevelWindows.capLeadingQuiet(samples, sampleRate: current.sampleRate)
        guard !trimmed.isEmpty else { return true }
        let buffer = try Self.buffer(trimmed, sampleRate: current.sampleRate)
        try ensureRunning(.voice, format: buffer.format)   // a device change may have stopped the engine
        let index = timeline.count
        output.schedule(buffer, on: .voice, playedBack: Self.completion(self, generation: id, segment: index))
        let now = ContinuousClock.now
        let start = max(now, current.playheadEnd)
        current.playheadEnd = start + .microseconds(Int64(Double(trimmed.count) / current.sampleRate * 1e6))
        current.outstanding += 1
        current.appended += 1
        reply = current
        timeline.append(SegmentTiming(appendedAt: now, startsAt: start, endsAt: current.playheadEnd))
        current.segments.yield((start, LevelWindows.rms(trimmed, sampleRate: current.sampleRate)))
        return true
    }

    private func finish(_ id: Int) {
        guard var current = reply, current.id == id, current.holds > 0 else { return }
        current.holds -= 1
        reply = current
        if current.holds == 0, current.outstanding == 0 { finishReply() }
    }

    private func hold(_ id: Int) -> Bool {
        guard var current = reply, current.id == id else { return false }
        current.holds += 1
        reply = current
        return true
    }

    /// Connects the reply node and prepares the engine ahead of the first reply, without starting
    /// output (a running engine keeps the audio hardware awake). Called from the voices' warm-up.
    public func prewarm(sampleRate: Double = 24_000) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false) else { return }
        output.prepare(.voice, format: format)
    }

    /// Silences the reply now (`AVAudioPlayerNode.stop()` drops scheduled audio immediately) and
    /// invalidates every outstanding ticket, so a reply still synthesizing never starts.
    public func stopVoice() {
        stops += 1
        cutReply()
    }

    /// Ends the current reply without touching tickets: a newer reply replacing it.
    private func cutReply() {
        output.stop(.voice)
        finishReply()
    }

    var isPlayingVoice: Bool { reply != nil }

    /// Plays a short sound alongside anything else.
    public func playEffect(_ samples: [Float], sampleRate: Double) throws {
        guard !samples.isEmpty else { return }
        let buffer = try Self.buffer(samples, sampleRate: sampleRate)
        try ensureRunning(.effects, format: buffer.format)
        output.schedule(buffer, on: .effects, playedBack: nil)
        let duration = Double(samples.count) / sampleRate
        effectsPlayUntil = max(effectsPlayUntil, .now + .milliseconds(Int(duration * 1000) + 50))
        scheduleIdleStop()
    }

    private func finishReply() {
        guard let reply else { return }
        reply.meter.cancel()
        reply.segments.finish()
        reply.levels.finish()
        self.reply = nil
        scheduleIdleStop()
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        let delay = idleStopDelay
        idleStop = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.stopIfIdle()
        }
    }

    /// Back to prepared (not running) once nothing is playing; the next play restarts it in ~20 ms.
    private func stopIfIdle() {
        guard reply == nil, ContinuousClock.now >= effectsPlayUntil, output.isRunning else { return }
        output.stopOutput()
    }

    private func played(generation id: Int, segment: Int) {
        guard var current = reply, current.id == id else { return }
        if timeline.indices.contains(segment) { timeline[segment].playedBackAt = .now }
        current.outstanding -= 1
        reply = current
        if current.holds == 0, current.outstanding == 0 { finishReply() }
    }

    /// The output device or its format changed: the engine has stopped itself. Drop a reply that was
    /// playing and reconnect on the next play. A reply with nothing queued yet (its first sentence
    /// still synthesizing, or between sentences) stays open: nothing was cut, and the mic stopping
    /// voice processing right after a send changes the output format exactly then.
    func configurationChanged() {
        output.stop(.voice)
        output.stop(.effects)
        output.forgetFormats()
        if var current = reply, current.holds > 0, current.outstanding == 0 {
            current.playheadEnd = .now
            reply = current
        } else {
            finishReply()
        }
    }

    private func ensureRunning(_ channel: PlaybackChannel, format: AVAudioFormat) throws {
        output.observeConfiguration(Self.configurationHandler(self))
        idleStop?.cancel()
        idleStop = nil
        try output.start(channel, format: format)
    }

    // AVFAudio calls these on its own threads. They're built here, outside any actor, so they don't
    // inherit isolation (runtime isolation trap), and hop back onto the actor.
    nonisolated static func completion(_ playback: AudioPlayback, generation: Int, segment: Int) -> @Sendable () -> Void {
        { Task { await playback.played(generation: generation, segment: segment) } }
    }

    nonisolated static func configurationHandler(_ playback: AudioPlayback) -> @Sendable () -> Void {
        { Task { await playback.configurationChanged() } }
    }

    static func buffer(_ samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw VoiceModelError.badAudioFormat }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}
