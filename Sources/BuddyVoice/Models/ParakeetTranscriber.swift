import AVFoundation
import FluidAudio
import Foundation

public enum VoiceModelError: Error, Equatable, Sendable {
    case notLoaded
    case badAudioFormat
}

/// Speech-to-text through FluidAudio Parakeet. The model is a config value (`SpeechModel`):
/// - `.parakeetUnified` streams: audio is decoded while the user speaks, so `finish()` only flushes
///   the tail (about 30 ms, S5). Partials stay inside FluidAudio; no callback is set.
/// - `.parakeetTDTv2` buffers the utterance and transcribes it on `finish()` (about 50 ms for 5 s).
///
/// Every call runs through a `TaskChain`, so a `cancel()`/`begin()` can never reset FluidAudio while an
/// `append` is suspended inside it (which would mix the old session's tokens into the new one, or throw
/// "Streaming window out of range"). `begin()` and `cancel()` also bump a session number at once, so
/// appends still queued from the old session are dropped instead of decoded.
public actor ParakeetTranscriber: SpeechTranscriber {
    private let model: SpeechModel
    private let store: ModelStore
    private let chain = TaskChain()
    private var unified: StreamingUnifiedAsrManager?
    private var tdt: AsrManager?
    private var buffered: [Float] = []
    private var session = 0

    /// `.appleOnDevice` never reaches here (`VoiceController.live` builds `AppleSpeechTranscriber`
    /// for it); it would read as TDT v2.
    public init(model: SpeechModel = .default, store: ModelStore = ModelStore()) {
        self.model = model
        self.store = store
    }

    public func load(progress: @escaping @Sendable (ModelLoadProgress) -> Void) async throws {
        try await chain.run { try await self.loadNow(progress: progress) }
    }

    /// Throws `VoiceModelError.notLoaded` until `load()` has finished, so a listen can't start on a
    /// model that isn't there yet ("Still setting up voice").
    public func begin() async throws {
        session += 1
        // Answered now, not after the load in progress: queued behind it, the listen would wait it out.
        guard isLoaded else { throw VoiceModelError.notLoaded }
        try await chain.run {
            guard await self.isLoaded else { throw VoiceModelError.notLoaded }
            try await self.resetNow()
        }
    }

    private var isLoaded: Bool {
        switch model {
        case .parakeetUnified: unified != nil
        case .parakeetTDTv2, .appleOnDevice: tdt != nil
        }
    }

    public func append(_ samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        let session = session
        try await chain.run { try await self.appendNow(samples, session: session) }
    }

    public func finish() async throws -> String {
        let session = session
        return try await chain.run { try await self.finishNow(session: session) }
    }

    public func cancel() async {
        session += 1
        _ = try? await chain.run { try await self.resetNow() }
    }

    // MARK: Operations (run one at a time by the chain)

    private func loadNow(progress: @escaping @Sendable (ModelLoadProgress) -> Void) async throws {
        let report = Self.progressHandler(progress)
        try store.ensureDirectories()
        switch model {
        case .parakeetUnified:
            guard unified == nil else { return }
            // Default context 70_13_13, int8 encoder (the tier S5 measured).
            let manager = StreamingUnifiedAsrManager()
            try await manager.loadModels(to: store.asrBase, progressHandler: report)
            unified = manager
        case .parakeetTDTv2, .appleOnDevice:
            guard tdt == nil else { return }
            // Already on this Mac in FluidAudio's own folder (another app): copied in, not downloaded.
            VoiceStorage.adoptParakeetTDTv2(into: store)
            let models = try await AsrModels.downloadAndLoad(to: store.parakeetTDTv2, version: .v2, progressHandler: report)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            tdt = manager
        }
    }

    private func resetNow() async throws {
        buffered.removeAll(keepingCapacity: true)
        try await unified?.reset()
    }

    private func appendNow(_ samples: [Float], session: Int) async throws {
        guard session == self.session else { return }   // queued before a cancel or a new begin
        switch model {
        case .parakeetUnified:
            guard let unified else { throw VoiceModelError.notLoaded }
            try await unified.appendAudio(try Self.buffer(samples))
            try await unified.processBufferedAudio()
        case .parakeetTDTv2, .appleOnDevice:
            guard tdt != nil else { throw VoiceModelError.notLoaded }
            buffered.append(contentsOf: samples)
        }
    }

    private func finishNow(session: Int) async throws -> String {
        guard session == self.session else { return "" }
        switch model {
        case .parakeetUnified:
            guard let unified else { throw VoiceModelError.notLoaded }
            let text = try await unified.finish()
            try await unified.reset()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .parakeetTDTv2, .appleOnDevice:
            guard let tdt else { throw VoiceModelError.notLoaded }
            defer { buffered.removeAll(keepingCapacity: true) }
            guard !buffered.isEmpty else { return "" }
            var state = TdtDecoderState.make(decoderLayers: await tdt.decoderLayerCount)
            let result = try await tdt.transcribe(buffered, decoderState: &state)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 16 kHz mono Float32 buffer, the format FluidAudio's streaming API takes.
    static func buffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw VoiceModelError.badAudioFormat }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    /// FluidAudio calls this on its download queue; built outside the actor (isolation trap).
    nonisolated static func progressHandler(_ forward: @escaping @Sendable (ModelLoadProgress) -> Void) -> ProgressHandler {
        { p in
            let phase: ModelLoadProgress.Phase = switch p.phase {
            case .listing: .listing
            case .downloading(let done, let total): .downloading(completedFiles: done, totalFiles: total)
            case .compiling: .compiling
            }
            forward(ModelLoadProgress(fraction: p.fractionCompleted, phase: phase))
        }
    }
}
