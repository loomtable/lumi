import BuddyCore
import Foundation

/// Minutes and hours before `t0`.
func ago(_ minutes: Double) -> Date { t0.addingTimeInterval(-minutes * 60) }
func hoursAgo(_ hours: Double) -> Date { ago(hours * 60) }

func sid(_ raw: String) -> SessionID { SessionID(rawValue: raw) }

/// A session for attention tests: `status` and `lastUsed` matter, the rest is filler.
func session(
    _ id: String, _ status: SessionStatus = .idle, used: Date = t0, finished: Date? = nil, pinned: Bool = false,
    archived: Bool = false, ranFor: TimeInterval? = nil, title: String? = nil
) -> SessionSnapshot {
    SessionSnapshot(
        id: sid(id), title: title ?? "Session \(id)", color: .ember, harness: .open, status: status, pinned: pinned,
        archived: archived, lastUsed: used, finishedAt: finished, ranFor: ranFor)
}

func running(since: Date = t0) -> SessionStatus { .thinking(since: since, progress: nil) }
func needs(since: Date = t0) -> SessionStatus { .needsYou(NeedsYou(kind: .soft("Which one?"), since: since)) }
func unread(at: Date = t0) -> SessionStatus { .done(at: at, unread: true) }
func seen(at: Date = t0) -> SessionStatus { .done(at: at, unread: false) }
let failedStatus = SessionStatus.failed(SessionFailure(reason: .crashed, retryable: true))
