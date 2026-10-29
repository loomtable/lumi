import BuddyCore
import Foundation

/// The Studio sidebar's sessions (04 §6.1), worked out from the snapshots alone.
///
/// - **Now**: running and blocked sessions only, those that need you first (longest waiting first),
///   then working ones (most recent first). A session whose teammates still work counts as working,
///   between the lead's interim answers too, so it never drops out mid-run. Its teammates nest
///   under it until the lead answers after the last one.
/// - **Pinned**: pinned sessions that aren't in Now.
/// - **Today / Yesterday / Previous 7 days / Older**: everything else, by when it was last used.
/// - **Archived**: archived sessions, last; the sidebar folds it (QA S-15).
///
/// A search keeps the sessions whose title or last answer contains the text.
nonisolated public struct SidebarGrouping: Sendable, Equatable {
    public enum Group: String, Sendable, CaseIterable {
        case now, pinned, today, yesterday, previous7Days, older, archived

        public var title: String {
            switch self {
            case .now: "Now"
            case .pinned: "Pinned"
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .previous7Days: "Previous 7 Days"
            case .older: "Older"
            case .archived: "Archived"
            }
        }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var session: SessionSnapshot
        /// Only in Now.
        public var teammates: [TeammateSnapshot]
        public var trailing: Trailing
        public var id: SessionID { session.id }
    }

    /// What sits at a row's end. Colour is never the only signal: each has words or a glyph.
    public enum Trailing: Sendable, Equatable {
        case needsYou
        /// Steps done of the plan, e.g. "4/9".
        case progress(done: Int, total: Int)
        /// Working for this long.
        case elapsed(TimeInterval)
        case unread
        case failed
        case interrupted
        /// Last used at this time.
        case time(Date)
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public var group: Group
        public var rows: [Row]
        public var id: Group { group }
    }

    public var sections: [Section]

    public init(_ snapshots: [SessionSnapshot], now: Date, calendar: Calendar = .current, search: String = "") {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = snapshots.filter { query.isEmpty || Self.matches($0, query) }
        let visible = matching.filter { !$0.archived }

        // An ask the user has seen still waits, but with the running ones: no more amber.
        let blocked = visible.compactMap { s -> (SessionSnapshot, Date)? in
            if s.needsAttention, case .needsYou(let ask) = s.status { (s, ask.since) } else { nil }
        }.sorted { $0.1 < $1.1 }.map(\.0)
        let blockedIDs = Set(blocked.map(\.id))
        let working = visible.filter { $0.isRunning && !blockedIDs.contains($0.id) }
            .sorted { $0.lastUsed > $1.lastUsed }
        let live = Set((blocked + working).map(\.id))
        let rest = visible.filter { !live.contains($0.id) }.sorted { $0.lastUsed > $1.lastUsed }

        var byGroup: [Group: [Row]] = [:]
        byGroup[.now] = (blocked + working).map { Row(session: $0, teammates: $0.liveTeam, trailing: Self.trailing($0, now: now)) }
        for s in rest {
            let group = s.pinned ? .pinned : Self.dateGroup(s.lastUsed, now: now, calendar: calendar)
            byGroup[group, default: []].append(Row(session: s, teammates: [], trailing: Self.trailing(s, now: now)))
        }
        byGroup[.archived] = matching.filter(\.archived).sorted { $0.lastUsed > $1.lastUsed }
            .map { Row(session: $0, teammates: [], trailing: .time($0.lastUsed)) }
        sections = Group.allCases.compactMap { group in
            guard let rows = byGroup[group], !rows.isEmpty else { return nil }
            return Section(group: group, rows: rows)
        }
    }

    /// The title, or the last answer's line (QA S-16: titles alone miss what was said).
    static func matches(_ s: SessionSnapshot, _ query: String) -> Bool {
        s.title.localizedCaseInsensitiveContains(query) || s.lastSay?.localizedCaseInsensitiveContains(query) == true
    }

    public func rows(_ group: Group) -> [Row] { sections.first { $0.group == group }?.rows ?? [] }

    /// Every session row in display order, archived ones left out (for ↑/↓ and the first selection).
    public var allRows: [Row] { sections.filter { $0.group != .archived }.flatMap(\.rows) }

    static func dateGroup(_ date: Date, now: Date, calendar: Calendar) -> Group {
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday { return .yesterday }
        if let week = calendar.date(byAdding: .day, value: -7, to: today), date >= week { return .previous7Days }
        return .older
    }

    static func trailing(_ s: SessionSnapshot, now: Date) -> Trailing {
        // The lead answered and its team still works: how far the team is ("1/3").
        switch s.status {
        case .thinking, .needsYou: break
        default:
            if s.teamLive { return .progress(done: s.teammates.count { !$0.state.isRunning }, total: s.teammates.count) }
        }
        return switch s.status {
        case .needsYou(let ask) where ask.seen: .elapsed(max(0, now.timeIntervalSince(ask.since)))
        case .needsYou: .needsYou
        case .thinking(let since, let progress):
            if let progress, progress.total > 0 { .progress(done: progress.done, total: progress.total) } else {
                .elapsed(max(0, now.timeIntervalSince(since)))
            }
        case .done(_, unread: true): .unread
        case .failed: .failed
        case .interrupted: .interrupted
        case .idle, .done: .time(s.lastUsed)
        }
    }

    /// "1:52", or "1:02:05" past an hour.
    public static func clock(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.down))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
