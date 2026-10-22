import Foundation
import Synchronization

/// The result of work raced against a deadline.
enum Raced<T: Sendable>: Sendable {
    case done(Result<T, any Error>)
    /// The deadline passed first. The work isn't stopped (a Core ML call can't be): its result is dropped.
    case timedOut
}

/// Waits for `work` or `deadline`, whichever comes first. For model calls that can hang (a saturated
/// Neural Engine): the caller moves on, and the late result goes nowhere. A cancelled caller gets
/// `CancellationError` at once.
func race<T: Sendable>(_ work: Task<T, any Error>, within deadline: Duration) async -> Raced<T> {
    let state = Mutex<(settled: Bool, continuation: CheckedContinuation<Raced<T>, Never>?, timer: Task<Void, Never>?)>(
        (false, nil, nil))
    @Sendable func settle(_ outcome: Raced<T>) {
        let (continuation, timer) = state.withLock { s -> (CheckedContinuation<Raced<T>, Never>?, Task<Void, Never>?) in
            guard !s.settled else { return (nil, nil) }
            s.settled = true
            defer { s.continuation = nil; s.timer = nil }
            return (s.continuation, s.timer)
        }
        timer?.cancel()
        continuation?.resume(returning: outcome)
    }
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Raced<T>, Never>) in
            let timer = Task {
                try? await Task.sleep(for: deadline)
                if !Task.isCancelled { settle(.timedOut) }
            }
            let alreadySettled = state.withLock { s -> Bool in
                if s.settled { return true }
                s.continuation = continuation
                s.timer = timer
                return false
            }
            if alreadySettled {
                timer.cancel()
                continuation.resume(returning: .done(.failure(CancellationError())))
                return
            }
            Task { settle(.done(await work.result)) }
        }
    } onCancel: {
        settle(.done(.failure(CancellationError())))
    }
}
