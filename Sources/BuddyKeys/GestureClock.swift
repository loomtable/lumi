import Darwin

/// Monotonic time for gestures, in the same base as event times (`CLOCK_UPTIME_RAW`, which does
/// not advance while the Mac sleeps). Real: `UptimeClock`. Fake: `ManualClock`.
public protocol GestureClock: Sendable {
    func now() -> Nanos
    /// Returns at or after `deadline`, or throws `CancellationError` when the task is cancelled.
    func sleep(until deadline: Nanos) async throws
}

public struct UptimeClock: GestureClock {
    public init() {}

    public func now() -> Nanos { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    public func sleep(until deadline: Nanos) async throws {
        let current = now()
        guard deadline > current else { return }
        try await Task.sleep(nanoseconds: deadline - current)
    }
}
