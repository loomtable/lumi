import Synchronization

/// Fake key source for tests and previews: `send` delivers events, `flags` is the hardware state.
public final class FakeKeySource: KeyEventSource {
    private struct State {
        var continuation: AsyncStream<KeySourceEvent>.Continuation?
        var flags: UInt64 = 0
        var startError: KeySourceError?
    }

    private let state = Mutex(State())

    public init(startError: KeySourceError? = nil) {
        state.withLock { $0.startError = startError }
    }

    public func start() throws(KeySourceError) -> AsyncStream<KeySourceEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: KeySourceEvent.self)
        let error: KeySourceError? = state.withLock { s in
            if let e = s.startError { return e }
            if s.continuation != nil { return .alreadyStarted }
            s.continuation = continuation
            return nil
        }
        if let error { throw error }
        return stream
    }

    public func stop() {
        state.withLock { s in
            s.continuation?.finish()
            s.continuation = nil
        }
    }

    public func currentFlags() -> UInt64 { state.withLock { $0.flags } }

    public var isStarted: Bool { state.withLock { $0.continuation != nil } }

    public func setFlags(_ flags: UInt64) { state.withLock { $0.flags = flags } }

    public func send(_ event: KeySourceEvent) {
        _ = state.withLock { $0.continuation?.yield(event) }
    }
}

/// A clock that only moves when told to. Sleepers wake when `advance(to:)` passes their deadline.
public final class ManualClock: GestureClock {
    private struct Sleeper {
        let id: Int
        let deadline: Nanos
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Nanos
        var nextID = 0
        var sleepers: [Sleeper] = []
    }

    private let state: Mutex<State>

    public init(now: Nanos = 0) {
        state = Mutex(State(now: now))
    }

    public func now() -> Nanos { state.withLock { $0.now } }

    /// How many tasks are currently sleeping; lets tests wait until a timer is armed.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(until deadline: Nanos) async throws {
        let id = state.withLock { s -> Int in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let resumeNow: Result<Void, any Error>? = state.withLock { s in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= s.now { return .success(()) }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: c))
                    return nil
                }
                if let resumeNow { c.resume(with: resumeNow) }
            }
        } onCancel: {
            let sleeper = state.withLock { s -> Sleeper? in
                guard let i = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: i)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    public func advance(to time: Nanos) {
        let due = state.withLock { s -> [Sleeper] in
            s.now = max(s.now, time)
            let now = s.now
            let due = s.sleepers.filter { $0.deadline <= now }
            s.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
