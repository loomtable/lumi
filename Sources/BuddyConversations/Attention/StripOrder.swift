import BuddyCore
import Foundation

/// The switcher strip's tile order (03 §3.3), a pure function of the sessions and the time.
/// The strip computes it once when it opens and freezes it: state changes while it is open
/// update tiles in place (`refresh`) but never reorder them.
///
/// ```
/// slot 1  the current session
/// then    needs-you       oldest wait first
/// then    running         most recently started first
/// then    ready-unread    most recently finished first
/// then    recent          MRU (fresh, recent, or failed under 2 h)
/// then    pinned          MRU, however old
/// then    the rest        MRU, until the strip is full (owner, Oct 29: the last few
///                         sessions always show, however old)
/// ```
/// Archived sessions never show. At most `maxReachable` sessions, all of them on the strip.
public enum StripOrder {
    /// Sessions the strip shows and Tab reaches (8 chips and New fill its three rows); the rest
    /// are in the Studio.
    public static let maxReachable = 8

    public static func order(_ sessions: [SessionSnapshot], current: SessionID?, now: Date) -> [SessionSnapshot] {
        let shown = sessions.filter { !$0.archived }
        var head: [SessionSnapshot] = []
        if let current, let c = shown.first(where: { $0.id == current }) { head.append(c) }
        let rest = shown.filter { $0.id != current }

        var needs: [(SessionSnapshot, Date)] = []
        var running: [(SessionSnapshot, Date)] = []
        var unread: [(SessionSnapshot, Date)] = []
        var recent: [SessionSnapshot] = []
        var pinned: [SessionSnapshot] = []
        var older: [SessionSnapshot] = []
        for s in rest {
            let band = Decay.band(age: now.timeIntervalSince(Decay.lastTouched(s)))
            switch Decay.state(of: s, now: now) {
            case .needsYou(let since): needs.append((s, since))
            case .running(let since, _): running.append((s, since))
            case .readyUnread(let at): unread.append((s, at))
            case .failed, .resting:
                if band <= .recent {
                    recent.append(s)
                } else if s.pinned {
                    pinned.append(s)
                } else {
                    older.append(s)
                }
            }
        }

        var out = head
        out += by(needs, oldestFirst: true)
        out += by(running, oldestFirst: false)
        out += by(unread, oldestFirst: false)
        out += mru(recent)
        out += mru(pinned)
        out += mru(older)
        return Array(out.prefix(maxReachable))
    }

    /// The frozen order with each tile's latest state. Sessions that were archived or
    /// forgotten while the strip was open drop out (their tile collapses); new ones don't
    /// appear until the next open.
    public static func refresh(_ frozen: [SessionSnapshot], with latest: [SessionSnapshot]) -> [SessionSnapshot] {
        let byID = Dictionary(latest.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return frozen.compactMap { old in
            guard let new = byID[old.id], !new.archived else { return nil }
            return new
        }
    }

    /// The tile the first Tab highlights: slot 2 when slot 1 is the current session, so one
    /// hold-Tab-release toggles between the last two (as ⌘Tab); else slot 1.
    public static func firstHighlight(_ tiles: [SessionSnapshot], current: SessionID?) -> Int {
        guard let first = tiles.first else { return 0 } // only ＋
        return first.id == current ? min(1, tiles.count) : 0
    }

    // MARK: -

    private static func mru(_ list: [SessionSnapshot]) -> [SessionSnapshot] { list.sorted(by: mruFirst) }

    private static func mruFirst(_ a: SessionSnapshot, _ b: SessionSnapshot) -> Bool {
        if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed }
        return a.id.rawValue < b.id.rawValue
    }

    /// Sorted by the paired date, ties broken MRU then by id, so the order is total.
    private static func by(_ list: [(SessionSnapshot, Date)], oldestFirst: Bool) -> [SessionSnapshot] {
        list.sorted { a, b in
            if a.1 != b.1 { return oldestFirst ? a.1 < b.1 : a.1 > b.1 }
            return mruFirst(a.0, b.0)
        }.map(\.0)
    }
}
