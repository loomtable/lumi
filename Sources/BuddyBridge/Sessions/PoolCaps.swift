import Foundation

/// How many open-session processes stay warm, and for how long (02 §D3).
public struct PoolCaps: Sendable, Equatable {
    /// Live processes kept: a soft cap. Sessions that are working run anyway; only idle ones are
    /// suspended to get back under it.
    public var live: Int
    /// An idle, unattended session's process is suspended after this long.
    public var idleSuspend: Duration

    public init(live: Int, idleSuspend: Duration = .seconds(600)) {
        self.live = max(1, live)
        self.idleSuspend = idleSuspend
    }

    /// 8 GB: 2 · 16 GB: 4 · 24 GB: 6 · 32 GB and up: 8. Idle `claude` processes measured 80–340 MB.
    public static func forMemory(_ bytes: UInt64) -> PoolCaps {
        let gb = Double(bytes) / 1_073_741_824
        let live = switch gb {
        case ..<12: 2
        case ..<20: 4
        case ..<28: 6
        default: 8
        }
        return PoolCaps(live: live)
    }
}

/// The system's memory-pressure warnings, one value each (`DispatchSource` warning and critical).
public enum MemoryPressure {
    public static func events() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { continuation.yield() }
        continuation.onTermination = { _ in source.cancel() }
        source.resume()
        return stream
    }
}
