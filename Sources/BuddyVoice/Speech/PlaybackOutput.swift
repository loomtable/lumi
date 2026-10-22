import AVFAudio
import Foundation
import Synchronization

/// The two players `AudioPlayback` uses: replies, and interface sounds (so a tick never cuts a reply).
enum PlaybackChannel: Sendable, Hashable {
    case voice
    case effects
}

/// The audio output under `AudioPlayback`: the real engine in the app, a timed fake in tests, so
/// playback logic is tested without the shared output device (other apps and other test runs on the
/// same Mac reconfigure it, which dropped replies mid-test).
protocol PlaybackOutput: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// Connects `channel` with `format` and prepares output without starting it.
    func prepare(_ channel: PlaybackChannel, format: AVAudioFormat)
    /// Connects `channel` with `format` (reconnecting if it changed) and starts output if stopped.
    func start(_ channel: PlaybackChannel, format: AVAudioFormat) throws
    /// Queues `buffer` after what's already queued on `channel`. `playedBack` runs, on any thread, once
    /// it has been heard; it doesn't run if the channel is stopped first.
    func schedule(_ buffer: AVAudioPCMBuffer, on channel: PlaybackChannel, playedBack: (@Sendable () -> Void)?)
    /// Silences `channel` now, dropping what's queued.
    func stop(_ channel: PlaybackChannel)
    /// Stops output and goes back to prepared (idle).
    func stopOutput()
    /// After a configuration change: reconnect each channel on its next start.
    func forgetFormats()
    /// Calls `handler` (on any thread) when the device or its format changes. Idempotent.
    func observeConfiguration(_ handler: @escaping @Sendable () -> Void)
}

/// The real output: one AVAudioEngine with a player node per channel, voice processing off.
/// `@unchecked Sendable`: it's only ever used by the `AudioPlayback` actor that owns it.
final class EngineOutput: PlaybackOutput, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let voice = AVAudioPlayerNode()
    private let effects = AVAudioPlayerNode()
    private var formats: [PlaybackChannel: AVAudioFormat] = [:]
    private var observer: (any NSObjectProtocol)?

    var isRunning: Bool { engine.isRunning }

    private func node(_ channel: PlaybackChannel) -> AVAudioPlayerNode {
        channel == .voice ? voice : effects
    }

    private func connect(_ channel: PlaybackChannel, format: AVAudioFormat) {
        let node = node(channel)
        if node.engine == nil { engine.attach(node) }
        if formats[channel] != format {
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            formats[channel] = format
        }
    }

    func prepare(_ channel: PlaybackChannel, format: AVAudioFormat) {
        connect(channel, format: format)
        engine.prepare()
    }

    func start(_ channel: PlaybackChannel, format: AVAudioFormat) throws {
        connect(channel, format: format)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    func schedule(_ buffer: AVAudioPCMBuffer, on channel: PlaybackChannel, playedBack: (@Sendable () -> Void)?) {
        let node = node(channel)
        if let playedBack {
            node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack,
                                completionHandler: Self.completion(playedBack))
        } else {
            node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        }
        if !node.isPlaying { node.play() }
    }

    func stop(_ channel: PlaybackChannel) { node(channel).stop() }

    func stopOutput() {
        voice.stop()
        effects.stop()
        engine.stop()
        engine.prepare()
    }

    func forgetFormats() { formats.removeAll() }

    func observeConfiguration(_ handler: @escaping @Sendable () -> Void) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: Self.notification(handler))
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // AVFAudio calls these on its own threads; built here, outside any actor (isolation trap).
    private static func completion(_ f: @escaping @Sendable () -> Void) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in f() }
    }

    private static func notification(_ f: @escaping @Sendable () -> Void) -> @Sendable (Notification) -> Void {
        { _ in f() }
    }
}

/// Plays nothing: each buffer counts as heard once its duration has passed after what was queued
/// before it, and `stop` drops what's pending. For tests, without the shared output device.
final class FakePlaybackOutput: PlaybackOutput {
    private struct State {
        var running = false
        var dropped: [PlaybackChannel: Int] = [:]
        var playheadEnd: [PlaybackChannel: ContinuousClock.Instant] = [:]
        var handler: (@Sendable () -> Void)?
        var scheduled = 0
    }
    private let state = Mutex(State())

    var isRunning: Bool { state.withLock { $0.running } }
    var scheduledCount: Int { state.withLock { $0.scheduled } }

    func prepare(_ channel: PlaybackChannel, format: AVAudioFormat) {}

    func start(_ channel: PlaybackChannel, format: AVAudioFormat) throws {
        state.withLock { $0.running = true }
    }

    func schedule(_ buffer: AVAudioPCMBuffer, on channel: PlaybackChannel, playedBack: (@Sendable () -> Void)?) {
        let duration = Duration.seconds(Double(buffer.frameLength) / buffer.format.sampleRate)
        let (generation, end) = state.withLock { s -> (Int, ContinuousClock.Instant) in
            s.scheduled += 1
            let start = max(ContinuousClock.now, s.playheadEnd[channel] ?? .now)
            s.playheadEnd[channel] = start + duration
            return (s.dropped[channel, default: 0], start + duration)
        }
        guard let playedBack else { return }
        Task {
            try? await Task.sleep(until: end, clock: .continuous)
            let current = self.state.withLock { $0.dropped[channel, default: 0] == generation }
            if current { playedBack() }
        }
    }

    func stop(_ channel: PlaybackChannel) {
        state.withLock {
            $0.dropped[channel, default: 0] += 1
            $0.playheadEnd[channel] = nil
        }
    }

    func stopOutput() {
        stop(.voice)
        stop(.effects)
        state.withLock { $0.running = false }
    }

    func forgetFormats() {}

    func observeConfiguration(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { if $0.handler == nil { $0.handler = handler } }
    }

    /// The device changed: the engine stops itself, as AVAudioEngine does, then the handler runs.
    func simulateConfigurationChange() {
        let handler = state.withLock { s -> (@Sendable () -> Void)? in
            s.running = false
            return s.handler
        }
        stop(.voice)
        stop(.effects)
        handler?()
    }
}
