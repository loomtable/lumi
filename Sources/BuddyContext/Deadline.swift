import Dispatch
import Synchronization

/// Runs blocking sensor work (synchronous AX and CG calls) off the Swift concurrency pool and
/// gives up waiting at a deadline. A sensor stuck on a hung app keeps its GCD thread until the
/// AX messaging timeout (0.25 s), but never holds a cooperative thread or delays the packet.
enum Deadline {
    static let queue = DispatchQueue(label: "BuddyContext.sensors", qos: .userInitiated, attributes: .concurrent)
    /// Deadlines fire here, never behind blocked sensor work.
    private static let timers = DispatchQueue(label: "BuddyContext.deadlines", qos: .userInteractive)

    /// Returns the work's result and its duration in ms, or nil if it missed `deadline`.
    static func run<T: Sendable>(
        within deadline: Duration, _ work: @escaping @Sendable () -> T
    ) async -> (value: T, ms: Double)? {
        let once = Once<(value: T, ms: Double)?>()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            let start = ContinuousClock.now
            queue.async {
                let value = work()
                once.resume((value, (ContinuousClock.now - start).milliseconds))
            }
            timers.asyncAfter(deadline: .now() + deadline.timeInterval) {
                once.resume(nil)
            }
        }
    }

    /// `task`'s value, or nil if it isn't ready by `deadline`. The task keeps running; cancel it
    /// if its result is no longer wanted.
    static func value<T: Sendable>(of task: Task<T, Never>, within deadline: Duration) async -> T? {
        let once = Once<T?>()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            Task { once.resume(await task.value) }
            timers.asyncAfter(deadline: .now() + deadline.timeInterval) {
                once.resume(nil)
            }
        }
    }

    /// Resumes a continuation exactly once, whichever side gets there first.
    final class Once<T: Sendable>: Sendable {
        private let slot = Mutex<CheckedContinuation<T, Never>?>(nil)

        func set(_ c: CheckedContinuation<T, Never>) { slot.withLock { $0 = c } }

        func resume(_ value: T) {
            let c = slot.withLock { s in
                defer { s = nil }
                return s
            }
            c?.resume(returning: value)
        }
    }
}

extension Duration {
    var milliseconds: Double {
        let (s, attos) = components
        return Double(s) * 1_000 + Double(attos) / 1e15
    }

    var timeInterval: Double { milliseconds / 1_000 }
}
