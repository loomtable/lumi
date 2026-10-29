import BuddyCore
import Foundation

/// What a session is doing, as the switcher strip ranks it (03 §3.5).
public enum AttentionState: Sendable, Equatable {
    /// A turn is in flight.
    case running(since: Date, progress: StepProgress?)
    /// A permission, a question or the answer's `asks_user` is waiting, unseen.
    case needsYou(since: Date)
    /// Finished while its answer wasn't on screen, under 4 h ago.
    case readyUnread(finishedAt: Date)
    /// The turn failed.
    case failed
    /// Nothing waiting: finished and seen, idle, or interrupted when Lumi quit. Fades by age.
    case resting(Decay.Band)

    /// Running, needs-you and unseen results never fade out of the strip.
    public var isLive: Bool {
        switch self {
        case .running, .needsYou, .readyUnread: true
        case .failed, .resting: false
        }
    }
}

/// How sessions age (03 §5.4). Running, needs-you, unseen and pinned sessions never decay; the
/// rest rank and fade by the time since they were last used or finished. The strip still shows
/// the newest of them however old (owner, Oct 29), so a band orders, it never hides.
public enum Decay {
    public enum Band: Int, Sendable, Equatable, Comparable, CaseIterable {
        /// Under 15 min.
        case fresh
        /// 15 min – 2 h.
        case recent
        /// 2 – 6 h.
        case idle
        /// 6 – 8 h.
        case stale
        /// Over 8 h (the Live Activity life).
        case expired

        public static func < (a: Band, b: Band) -> Bool { a.rawValue < b.rawValue }
    }

    public static let freshFor: TimeInterval = 15 * 60
    public static let recentFor: TimeInterval = 2 * 3600
    public static let idleFor: TimeInterval = 6 * 3600
    public static let staleFor: TimeInterval = 8 * 3600
    /// An unseen result turns into a plain finished one after this long (HIG: 4 h after end).
    public static let unseenFor: TimeInterval = 4 * 3600

    public static func band(age: TimeInterval) -> Band {
        switch age {
        case ..<freshFor: .fresh
        case ..<recentFor: .recent
        case ..<idleFor: .idle
        case ..<staleFor: .stale
        default: .expired
        }
    }

    /// The later of last use and finish: a long turn that just finished is fresh.
    public static func lastTouched(_ s: SessionSnapshot) -> Date {
        max(s.lastUsed, s.finishedAt ?? s.lastUsed)
    }

    public static func state(of s: SessionSnapshot, now: Date) -> AttentionState {
        switch s.status {
        case .thinking(let since, let progress):
            return .running(since: since, progress: progress)
        case .needsYou(let needs) where needs.seen:
            // Seen: it still waits on its card, without asking for attention (no reminder).
            return .running(since: needs.since, progress: nil)
        case .needsYou(let needs):
            return .needsYou(since: needs.since)
        case .done(let at, unread: true) where now.timeIntervalSince(at) < unseenFor:
            return .readyUnread(finishedAt: at)
        case .failed:
            return .failed
        case .idle, .done, .interrupted:
            return .resting(band(age: now.timeIntervalSince(lastTouched(s))))
        }
    }
}
