import Foundation
import Synchronization

/// A clock tests move by hand.
public final class ManualConversationClock: ConversationClock {
    private let current: Mutex<Date>

    public init(_ start: Date = Date(timeIntervalSince1970: 1_760_000_000)) {
        current = Mutex(start)
    }

    public func now() -> Date { current.withLock { $0 } }

    public func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Records which sessions Forget asked to delete; deletes nothing.
public final class FakeSessionFiles: SessionFileStore {
    private let requests = Mutex<[[String]]>([])

    public init() {}

    public var deletedSessions: [[String]] { requests.withLock { $0 } }

    public func deleteSessions(_ ids: [String]) -> SessionDeletion {
        requests.withLock { $0.append(ids) }
        return SessionDeletion(deleted: ids)
    }
}
