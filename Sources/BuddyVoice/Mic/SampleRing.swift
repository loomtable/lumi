import Darwin
import Synchronization

/// Lock-free single-producer, single-consumer ring of Float samples.
///
/// The producer is the real-time IO thread (the sink block): it never locks or allocates. The consumer is
/// the capture pipeline's serial queue. Indices only grow; the slot is `index & mask`.
final class SampleRing: Sendable {
    let capacity: Int
    private let mask: Int
    // Written only by the producer between `writeIndex` loads and stores, read only by the consumer below
    // `writeIndex`; the acquire/release pair on the indices orders those accesses, so the shared pointer is
    // safe to send. Allocated once and freed in deinit.
    nonisolated(unsafe) private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    /// Host time (mach units) of the newest frame written.
    private let newestHostTime = Atomic<UInt64>(0)
    /// Buffers stamped before this host time belong to an earlier start and are dropped.
    private let acceptFromHostTime = Atomic<UInt64>(0)
    /// Frames dropped because the consumer fell behind (or the buffer was stale).
    let droppedFrames = Atomic<Int>(0)

    /// `capacity` is rounded up to a power of two. The default holds about 1.3 s at 96 kHz.
    init(capacity: Int = 1 << 17) {
        var size = 1
        while size < capacity { size <<= 1 }
        self.capacity = size
        mask = size - 1
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit { storage.deallocate() }

    // MARK: Producer (real-time thread)

    /// Copies `frames` samples taken every `stride` floats from `source` (channel 0 of an interleaved or
    /// non-interleaved buffer). `hostTime` 0 means the timestamp was not valid.
    func write(_ source: UnsafePointer<Float>, frames: Int, stride: Int, hostTime: UInt64) {
        if hostTime != 0, hostTime < acceptFromHostTime.load(ordering: .relaxed) {
            droppedFrames.add(frames, ordering: .relaxed)
            return
        }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let n = min(frames, capacity - (w - r))
        if n < frames { droppedFrames.add(frames - n, ordering: .relaxed) }
        for i in 0..<n {
            storage[(w + i) & mask] = source[i * stride]
        }
        if hostTime != 0 { newestHostTime.store(hostTime, ordering: .relaxed) }
        writeIndex.store(w + n, ordering: .releasing)
    }

    // MARK: Consumer (pipeline queue)

    /// Appends everything available to `out` and returns the host time of the newest frame (mach units).
    @discardableResult
    func read(into out: inout [Float]) -> UInt64 {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = w - r
        if n > 0 {
            out.reserveCapacity(out.count + n)
            for i in 0..<n { out.append(storage[(r + i) & mask]) }
            readIndex.store(w, ordering: .releasing)
        }
        return newestHostTime.load(ordering: .relaxed)
    }

    /// Starts a new capture: drops anything unread and any late buffer stamped before `hostTime`.
    /// Call from the consumer side.
    func beginCapture(at hostTime: UInt64) {
        acceptFromHostTime.store(hostTime, ordering: .relaxed)
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }
}

enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func now() -> UInt64 { mach_absolute_time() }

    /// Mach host time to nanoseconds on the CLOCK_UPTIME_RAW scale that `AudioChunk.capturedAt` uses.
    static func nanoseconds(_ hostTime: UInt64) -> UInt64 {
        hostTime * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}
