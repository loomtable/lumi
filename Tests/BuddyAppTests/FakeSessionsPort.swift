@testable import BuddyApp
import BuddyCore
import Foundation

/// A `SessionsPort` over an in-memory list, recording every call. `apply` keeps only what the
/// fake can derive simply: thinking on `turnStarted`, done (unread) on `turnEnded`.
@MainActor final class FakeSessionsPort: SessionsPort {
    enum Call: Equatable {
        case setCurrent(SessionID)
        case pinned(Bool, SessionID)
        case archived(Bool, SessionID)
        case rename(SessionID, String)
        case forget(SessionID)
        case apply(SessionEvent, SessionID)
    }

    private(set) var snapshots: [SessionSnapshot] { didSet { publish() } }
    private(set) var current: SessionID?
    /// What a page or the Glance shows; the test sets it.
    var onScreen: Set<SessionID> = []
    private(set) var calls: [Call] = []
    var forgetError: (any Error)?
    var now: @MainActor () -> Date = Date.init
    private var subscribers: [AsyncStream<[SessionSnapshot]>.Continuation] = []

    init(_ snapshots: [SessionSnapshot] = [], current: SessionID? = nil) {
        self.snapshots = snapshots
        self.current = current
    }

    func changes() -> AsyncStream<[SessionSnapshot]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [SessionSnapshot].self)
        continuation.yield(snapshots)
        subscribers.append(continuation)
        return stream
    }

    /// Adds or replaces a session.
    func put(_ snapshot: SessionSnapshot) {
        if let i = snapshots.firstIndex(where: { $0.id == snapshot.id }) { snapshots[i] = snapshot } else { snapshots.insert(snapshot, at: 0) }
    }

    func setCurrent(_ id: SessionID) async {
        calls.append(.setCurrent(id))
        current = id
    }

    func setPinned(_ pinned: Bool, for id: SessionID) async {
        calls.append(.pinned(pinned, id))
        update(id) { $0.pinned = pinned }
    }

    func setArchived(_ archived: Bool, for id: SessionID) async {
        calls.append(.archived(archived, id))
        update(id) { $0.archived = archived }
    }

    func rename(_ id: SessionID, to title: String) async {
        calls.append(.rename(id, title))
        update(id) { $0.title = title }
    }

    func forget(_ id: SessionID) async throws {
        calls.append(.forget(id))
        if let forgetError { throw forgetError }
        snapshots.removeAll { $0.id == id }
        if current == id { current = nil }
    }

    func apply(_ event: SessionEvent, to id: SessionID) {
        calls.append(.apply(event, id))
        let at = now()
        switch event {
        case .turnStarted: update(id) { $0.status = .thinking(since: at, progress: nil) }
        case .turnEnded: update(id) {
            $0.status = .done(at: at, unread: true)
            $0.finishedAt = at
            $0.turns += 1
        }
        default: break
        }
    }

    private func update(_ id: SessionID, _ change: (inout SessionSnapshot) -> Void) {
        guard let i = snapshots.firstIndex(where: { $0.id == id }) else { return }
        change(&snapshots[i])
    }

    private func publish() {
        for subscriber in subscribers { subscriber.yield(snapshots) }
    }
}

extension SessionSnapshot {
    /// A plain idle open session for tests.
    static func sample(_ id: String = SessionID.new().rawValue, title: String = "Trip to Lisbon", lastUsed: Date = .now) -> SessionSnapshot {
        SessionSnapshot(id: SessionID(rawValue: id), title: title, color: .ember, harness: .open, lastUsed: lastUsed)
    }
}
