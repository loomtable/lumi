import AVFAudio
import Foundation

/// The slice of AVAudioEngine that `EngineMic` drives. A seam so the recovery logic can be tested
/// without audio hardware.
protocol MicEngine: AnyObject {
    /// The ring the engine's sink node writes channel 0 into.
    var ring: SampleRing { get }
    /// Current hardware input format. A voice-processing unit reports 0 Hz / 0 ch while it settles (S5).
    var hardwareFormat: MicFormat { get }
    var isRunning: Bool { get }
    /// Whether voice processing is on right now. While it is, other apps' audio is ducked.
    var voiceProcessingEnabled: Bool { get }
    /// Turns voice processing on or off and reconnects the sink with the new hardware format. Only on a
    /// stopped engine that isn't prepared: enabling on a prepared engine fails with -10849.
    func setVoiceProcessing(_ enabled: Bool) throws
    /// Reconnects the sink with the current hardware format, on a stopped engine. How the engine's own
    /// settle-time configuration change is handled without building a new engine.
    func reconnect() throws
    func prepare()
    func start() throws
    func stop()
    /// Stops and removes the configuration-change observer. The engine is not used again.
    func invalidate()
}

struct MicFormat: Equatable, Sendable {
    var sampleRate: Double
    var channels: UInt32

    var isValid: Bool { sampleRate > 0 && channels > 0 }
}

/// Builds an engine with voice processing on or off. `onConfigurationChange` must be called (from any
/// thread) for every AVAudioEngineConfigurationChange the engine posts.
typealias MicEngineFactory = @Sendable (
    _ voiceProcessing: Bool,
    _ onConfigurationChange: @escaping @Sendable () -> Void
) throws -> any MicEngine

/// The real engine: AVAudioSinkNode on the input node, connected with the hardware format (S5: the node's
/// output format can be stale after a change and connecting with it throws an uncatchable NSException).
final class AVMicEngine: MicEngine {
    let ring = SampleRing()
    private let engine = AVAudioEngine()
    private var sink: AVAudioSinkNode?
    private var observer: (any NSObjectProtocol)?

    /// Least ducking of other apps while listening: −8 dB measured, against −30 dB for the default.
    /// No level turns it off, and `enableAdvancedDucking` measured −30 dB.
    static let ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)

    static let factory: MicEngineFactory = { voiceProcessing, onChange in
        try AVMicEngine(voiceProcessing: voiceProcessing, onConfigurationChange: onChange)
    }

    init(voiceProcessing: Bool, onConfigurationChange: @escaping @Sendable () -> Void) throws {
        if voiceProcessing { try enableVoiceProcessing(true) }
        try connectSink()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
            using: AVMicEngine.notificationBlock(onConfigurationChange)
        )
    }

    var hardwareFormat: MicFormat {
        let f = engine.inputNode.inputFormat(forBus: 0)
        return MicFormat(sampleRate: f.sampleRate, channels: f.channelCount)
    }

    var isRunning: Bool { engine.isRunning }
    var voiceProcessingEnabled: Bool { engine.inputNode.isVoiceProcessingEnabled }

    func setVoiceProcessing(_ enabled: Bool) throws {
        guard enabled != voiceProcessingEnabled else { return }
        try enableVoiceProcessing(enabled)
        try connectSink()
    }

    func reconnect() throws { try connectSink() }

    private func enableVoiceProcessing(_ enabled: Bool) throws {
        try engine.inputNode.setVoiceProcessingEnabled(enabled)
        if enabled { engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = Self.ducking }
    }

    /// A fresh sink connected with the current hardware format (the channel count changes with voice
    /// processing: 1 → 9 on a MacBook Pro mic).
    private func connectSink() throws {
        if let sink { engine.detach(sink) }
        sink = nil
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicError.invalidFormat(sampleRate: format.sampleRate, channels: format.channelCount)
        }
        let sink = AVAudioSinkNode(receiverBlock: EngineMic.sinkBlock(ring: ring))
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: format)
        self.sink = sink
    }

    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }

    func invalidate() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
    }

    /// NotificationCenter calls this on the posting thread; built outside any actor.
    static func notificationBlock(_ onChange: @escaping @Sendable () -> Void) -> @Sendable (Notification) -> Void {
        { _ in onChange() }
    }
}
