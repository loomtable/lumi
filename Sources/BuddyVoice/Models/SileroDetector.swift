import FluidAudio
import Foundation

/// Regroups an arbitrary stream of samples into fixed-size chunks (Silero takes exactly 4096).
struct SampleChunker: Sendable {
    let size: Int
    private var pending: [Float] = []

    init(size: Int) {
        self.size = size
        pending.reserveCapacity(size * 2)
    }

    /// Appends samples and returns every complete chunk, keeping the remainder.
    mutating func push(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var chunks: [[Float]] = []
        var start = 0
        while pending.count - start >= size {
            chunks.append(Array(pending[start..<(start + size)]))
            start += size
        }
        pending.removeFirst(start)
        return chunks
    }

    mutating func reset() { pending.removeAll(keepingCapacity: true) }
    var buffered: Int { pending.count }
}

/// Silero VAD through FluidAudio, used only for the 30 s silence safeguard (S5: its 256 ms chunks put
/// end of speech 0.7–1.2 s late, too slow to decide when to send).
///
/// Calls run one at a time through a `TaskChain`: `process` suspends inside `VadManager` between chunks,
/// and a `reset()` landing there would otherwise be overwritten by the old stream state.
public actor SileroDetector: SpeechActivityDetector {
    private let store: ModelStore
    private let segmentation: VadSegmentationConfig
    private let chain = TaskChain()
    private var manager: VadManager?
    private var state: VadStreamState?
    private var chunker = SampleChunker(size: VadManager.chunkSize)

    public init(store: ModelStore = ModelStore(), minSilenceDuration: TimeInterval = 0.3) {
        self.store = store
        var config = VadSegmentationConfig.default
        config.minSilenceDuration = minSilenceDuration
        segmentation = config
    }

    public func load() async throws {
        try await chain.run { try await self.loadNow() }
    }

    public func reset() async {
        _ = try? await chain.run { await self.resetNow() }
    }

    public func process(_ samples: [Float]) async throws -> SpeechActivity? {
        try await chain.run { try await self.processNow(samples) }
    }

    private func loadNow() async throws {
        guard manager == nil else { return }
        try store.ensureDirectories()
        let vad = try await VadManager(modelDirectory: store.vadBase)
        manager = vad
        state = await vad.makeStreamState()
    }

    private func resetNow() async {
        chunker.reset()
        state = await manager?.makeStreamState()
    }

    private func processNow(_ samples: [Float]) async throws -> SpeechActivity? {
        guard let manager, var current = state else { throw VoiceModelError.notLoaded }
        var transition: SpeechActivity?
        for chunk in chunker.push(samples) {
            let result = try await manager.processStreamingChunk(chunk, state: current, config: segmentation)
            current = result.state
            if let event = result.event {
                // Several chunks in one call can start and end; the last transition wins.
                transition = event.kind == .speechStart ? .started : .ended
            }
        }
        state = current
        return transition
    }
}
