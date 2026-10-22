import Synchronization

/// Runs async operations strictly one after another, in the order they were submitted.
///
/// Actors alone don't give this: while one call is suspended inside FluidAudio (for example in
/// `processWindow`, awaiting the encoder), another call on the same actor can run and reset the model
/// under it. Each operation here starts only after the previous one has finished.
final class TaskChain: Sendable {
    private let tail = Mutex<Task<Void, Never>?>(nil)

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task: Task<T, any Error> = tail.withLock { tail in
            let previous = tail
            let task = Task<T, any Error> {
                await previous?.value
                return try await operation()
            }
            tail = Task { _ = try? await task.value }
            return task
        }
        return try await task.value
    }
}
