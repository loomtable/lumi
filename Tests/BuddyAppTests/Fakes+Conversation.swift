@testable import BuddyApp
import BuddyBridge
import BuddyCore
import Foundation
import Synchronization

/// A `TurnPort` that answers every request, whatever its target, with a session script: the
/// coordinator's ask still targets the cascade until foundation routes typed asks to open sessions.
final class SessionScriptPort: TurnPort {
    private let state: Mutex<(script: [SessionEvent], sent: [TurnRequest], cancelled: [String])>

    init(_ script: [SessionEvent]) { state = Mutex((script, [], [])) }

    var sent: [TurnRequest] { state.withLock { $0.sent } }
    var cancelled: [String] { state.withLock { $0.cancelled } }

    func send(_ request: TurnRequest) async -> AsyncStream<TurnStreamEvent> {
        let script = state.withLock {
            $0.sent.append(request)
            return $0.script
        }
        return AsyncStream { c in
            for e in script { c.yield(.session(e)) }
            c.finish()
        }
    }

    func cancel(conversation: String) async { state.withLock { $0.cancelled.append(conversation) } }
}

/// Records the permission host's answers.
final class FakeAnswering: PermissionAnswering {
    enum Call: Sendable, Equatable {
        case decide(String, SessionID, PermissionDecision)
        case answer(String, SessionID, [String: String])
    }

    private let calls = Mutex<[Call]>([])
    var recorded: [Call] { calls.withLock { $0 } }

    /// What every reply returns: false acts like a pool with no live session.
    private let result: Bool
    init(writes: Bool = true) { result = writes }

    func decide(_ requestID: String, in session: SessionID, _ decision: PermissionDecision) async -> Bool {
        calls.withLock { $0.append(.decide(requestID, session, decision)) }
        return result
    }

    func answer(_ requestID: String, in session: SessionID, answers: [String: String]) async -> Bool {
        calls.withLock { $0.append(.answer(requestID, session, answers)) }
        return result
    }
}

/// Records which sessions the pages report as shown and hidden (QA R6).
@MainActor final class PageRecordingSessions: SessionsPort {
    enum Page: Equatable {
        case shown(SessionID, PageKind)
        case hidden(SessionID, PageKind)
    }

    private(set) var pages: [Page] = []
    var snapshots: [SessionSnapshot] = []
    var current: SessionID?
    func changes() -> AsyncStream<[SessionSnapshot]> { AsyncStream { $0.finish() } }
    func setCurrent(_ id: SessionID) async {}
    func setPinned(_ pinned: Bool, for id: SessionID) async {}
    func setArchived(_ archived: Bool, for id: SessionID) async {}
    func rename(_ id: SessionID, to title: String) async {}
    func forget(_ id: SessionID) async throws {}
    func apply(_ event: SessionEvent, to id: SessionID) {}
    func pageShown(_ id: SessionID, kind: PageKind) { pages.append(.shown(id, kind)) }
    func pageHidden(_ id: SessionID, kind: PageKind) { pages.append(.hidden(id, kind)) }
}
