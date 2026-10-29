import Foundation
import Synchronization

/// A sleep the test releases by hand: it records every requested duration and returns only on
/// `release()`, so timing tests don't depend on how loaded the machine is.
final class ManualSleeper: Sendable {
    private let state = Mutex<(requested: [Duration], waiting: [CheckedContinuation<Void, Never>])>(([], []))

    var requested: [Duration] { state.withLock { $0.requested } }
    var waitingCount: Int { state.withLock { $0.waiting.count } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            await withCheckedContinuation { continuation in
                state.withLock {
                    $0.requested.append(duration)
                    $0.waiting.append(continuation)
                }
            }
        }
    }

    /// Ends every sleep under way.
    func release() {
        for continuation in state.withLock({ s in defer { s.waiting = [] }; return s.waiting }) { continuation.resume() }
    }
}
