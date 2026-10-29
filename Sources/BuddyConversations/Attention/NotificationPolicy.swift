import BuddyCore
import Foundation

/// One macOS notification. Innocuous text only, never answer content; no sound.
public struct Banner: Sendable, Equatable {
    public enum Level: Sendable, Equatable {
        /// Needs-you and its reminder (`UNNotificationInterruptionLevel.active`).
        case active
        /// Ready (`.passive`). Never time-sensitive or critical: Focus is the user's call.
        case passive
    }

    /// Also the notification's identifier: a new banner replaces the session's old one.
    public var session: SessionID
    /// "Trip to Lisbon is ready", "Fix login bug needs your OK".
    public var body: String
    public var level: Level
    public var isReminder: Bool

    public init(session: SessionID, body: String, level: Level, isReminder: Bool = false) {
        self.session = session
        self.body = body
        self.level = level
        self.isReminder = isReminder
    }
}

public enum NotificationAction: Sendable, Equatable {
    case post(Banner)
    /// Remove the session's banner from Notification Center (it was seen).
    case withdraw(SessionID)
}

/// When Lumi may post a notification (lead, Oct 28):
/// - at the Mac: never; the capsules, switcher and sidebar show it;
/// - away, and the turn ran at least 30 s: one banner when a session becomes ready or needs
///   the user (shorter turns: the user saw them start and end);
/// - a needs-you unanswered for 30 min: one reminder banner if away (at the Mac, its amber
///   capsule and tile already show it).
/// A seen session's banner is withdrawn at once.
public struct NotificationPolicy: Sendable, Equatable {
    public static let minimumRun: TimeInterval = 30
    public static let remindAfter: TimeInterval = 30 * 60

    struct Waiting: Sendable, Equatable {
        var since: Date
        var title: String
        var reminded: Bool
    }

    private var waiting: [SessionID: Waiting] = [:]
    private var posted: Set<SessionID> = []

    public init() {}

    /// `enabled`: Settings › "Notify me when I'm away".
    public mutating func handle(_ t: AttentionTransition, presence: Presence, enabled: Bool, now: Date) -> [NotificationAction] {
        switch t {
        case .settled(let id):
            waiting[id] = nil
            return posted.remove(id) == nil ? [] : [.withdraw(id)]
        case .needsYou(let s, let ran):
            waiting[s.id] = Waiting(since: now, title: s.title, reminded: false)
            return post(s, body: "\(s.title) needs your OK", level: .active, ran: ran, presence: presence, enabled: enabled)
        case .ready(let s, let ran):
            waiting[s.id] = nil
            return post(s, body: "\(s.title) is ready", level: .passive, ran: ran, presence: presence, enabled: enabled)
        case .failed(let s):
            waiting[s.id] = nil
            return posted.remove(s.id) == nil ? [] : [.withdraw(s.id)]
        }
    }

    /// Reminders that are due. Call at `nextReminder`.
    public mutating func tick(now: Date, presence: Presence, enabled: Bool) -> [NotificationAction] {
        var out: [NotificationAction] = []
        for (id, w) in waiting.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where !w.reminded && now.timeIntervalSince(w.since) >= Self.remindAfter {
            waiting[id]?.reminded = true
            guard presence == .away, enabled else { continue }
            posted.insert(id)
            out.append(.post(Banner(session: id, body: "\(w.title) still needs your OK", level: .active, isReminder: true)))
        }
        return out
    }

    /// When the next reminder is due; nil with nothing waiting.
    public var nextReminder: Date? {
        waiting.values.filter { !$0.reminded }.map { $0.since.addingTimeInterval(Self.remindAfter) }.min()
    }

    private mutating func post(
        _ s: SessionSnapshot, body: String, level: Banner.Level, ran: TimeInterval?, presence: Presence, enabled: Bool
    ) -> [NotificationAction] {
        guard enabled, presence == .away, (ran ?? 0) >= Self.minimumRun else {
            // An older banner for this session (needs-you, now ready) is out of date.
            return posted.remove(s.id) == nil ? [] : [.withdraw(s.id)]
        }
        posted.insert(s.id)
        return [.post(Banner(session: s.id, body: body, level: level))]
    }
}
