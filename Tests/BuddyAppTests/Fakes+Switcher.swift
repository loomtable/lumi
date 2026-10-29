@testable import BuddyApp
import BuddyConversations
import BuddyCore
import Foundation

/// Timers the test fires by hand: `fire(after:)` runs every live one with that delay.
@MainActor final class ManualScheduler {
    private var pending: [(delay: Duration, task: Task<Void, Never>, work: @MainActor () -> Void)] = []

    var scheduler: SwitcherScheduler {
        SwitcherScheduler { [self] delay, work in
            let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(3600)) }
            pending.append((delay, task, work))
            return task
        }
    }

    var delays: [Duration] { pending.filter { !$0.task.isCancelled }.map(\.delay) }

    func fire(after delay: Duration) {
        let due = pending.filter { $0.delay == delay && !$0.task.isCancelled }
        pending.removeAll { $0.delay == delay }
        for p in due {
            p.task.cancel()
            p.work()
        }
    }
}

@MainActor final class FakeNotifier: NotificationPosting {
    enum Call: Equatable {
        case post(Banner)
        case withdraw(SessionID)
    }

    private(set) var calls: [Call] = []
    func post(_ banner: Banner) async { calls.append(.post(banner)) }
    func withdraw(_ session: SessionID) async { calls.append(.withdraw(session)) }
}

@MainActor final class FakePresence: PresenceSource {
    var presence: Presence = .present
}

/// A clock tests move by hand.
@MainActor final class SwitcherTestClock {
    var now = Date(timeIntervalSince1970: 1_760_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

extension SessionSnapshot {
    static func switcherSample(_ id: String, _ status: SessionStatus = .idle, used: Date, title: String? = nil) -> SessionSnapshot {
        SessionSnapshot(id: SessionID(rawValue: id), title: title ?? id.uppercased(), color: .ember, harness: .open,
                        status: status, lastUsed: used)
    }
}

/// Records every route request, then routes as the wrapped router does.
@MainActor final class SpyRouting: TurnRouting {
    private let inner: any TurnRouting
    private(set) var requests: [RouteRequest] = []
    private(set) var newSessions = 0

    init(_ inner: any TurnRouting) { self.inner = inner }

    func route(_ request: RouteRequest) async -> RoutedTurn {
        requests.append(request)
        return await inner.route(request)
    }

    func startNewSession() {
        newSessions += 1
        inner.startNewSession()
    }
}
