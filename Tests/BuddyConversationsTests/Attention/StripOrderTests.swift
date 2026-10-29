import BuddyCore
import Foundation
import Testing
@testable import BuddyConversations

@Suite("Attention · strip order")
struct StripOrderTests {
    private func ids(_ list: [SessionSnapshot]) -> [String] { list.map(\.id.rawValue) }

    @Test("current, needs-you oldest, running newest, unread newest, recent MRU, pinned, idle")
    func fullOrder() {
        let sessions = [
            session("idle", used: hoursAgo(3)),
            session("recent2", seen(at: ago(50)), used: ago(50), finished: ago(50)),
            session("cur", seen(at: ago(1)), used: ago(1)),
            session("run-old", running(since: ago(9))),
            session("needs-new", needs(since: ago(1))),
            session("unread-old", unread(at: ago(40)), finished: ago(40)),
            session("pinned", used: hoursAgo(12), pinned: true),
            session("run-new", running(since: ago(2))),
            session("needs-old", needs(since: ago(20))),
            session("unread-new", unread(at: ago(3)), finished: ago(3)),
            session("recent1", used: ago(20)),
        ]
        let order = StripOrder.order(sessions, current: sid("cur"), now: t0)
        #expect(ids(order) == [
            "cur", "needs-old", "needs-new", "run-new", "run-old", "unread-new", "unread-old", "recent1",
        ]) // 8 reachable: recent2, pinned and idle are cut
    }

    @Test("pinned sessions come before idle ones and never expire")
    func pinned() {
        let sessions = [
            session("idle", used: hoursAgo(3)),
            session("pin-old", used: hoursAgo(30), pinned: true),
            session("pin-new", used: hoursAgo(10), pinned: true),
            session("pin-recent", used: ago(5), pinned: true),
            session("gone", used: hoursAgo(9)),
        ]
        // An expired session still tops the strip up to its visible count.
        #expect(ids(StripOrder.order(sessions, current: nil, now: t0)) == ["pin-recent", "pin-new", "pin-old", "idle", "gone"])
    }

    @Test("older sessions fill the rest of the strip, newest first, up to 8")
    func older() {
        let fresh = (0..<5).map { session("f\($0)", used: ago(Double($0))) }
        let idle = (0..<5).map { session("i\($0)", used: hoursAgo(3 + Double($0) * 0.1)) }
        let stale = [session("s0", used: hoursAgo(7))]
        #expect(ids(StripOrder.order(fresh + idle + stale, current: nil, now: t0)) ==
            ["f0", "f1", "f2", "f3", "f4", "i0", "i1", "i2"])
        let few = Array(fresh.prefix(3)) + stale + [idle[0]]
        #expect(ids(StripOrder.order(few, current: nil, now: t0)) == ["f0", "f1", "f2", "i0", "s0"])
    }

    @Test("the last few sessions always show, however old, finished or failed, newest first")
    func recentAlwaysShow() {
        // The owner's strip: one session from today, the rest finished ~10 h ago.
        let sessions = [
            session("today", seen(at: ago(5)), used: ago(5)),
            session("weather", seen(at: hoursAgo(10.1)), used: hoursAgo(10.1), finished: hoursAgo(10.1)),
            session("german2", seen(at: hoursAgo(10.15)), used: hoursAgo(10.15), finished: hoursAgo(10.15)),
            session("german1", used: hoursAgo(10.2)),
            session("cooking", failedStatus, used: hoursAgo(10.3)),
            session("week", used: hoursAgo(24 * 7)),
            session("older", used: hoursAgo(24 * 8)),
            session("arch", used: hoursAgo(10.12), archived: true),
        ]
        #expect(ids(StripOrder.order(sessions, current: sid("today"), now: t0)) ==
            ["today", "weather", "german2", "german1", "cooking", "week", "older"])
        // Live ones still lead; the old ones fill the rest of the strip.
        let live = [session("run", running(since: ago(1))), session("run2", running(since: ago(2)))] + sessions
        #expect(ids(StripOrder.order(live, current: nil, now: t0)) ==
            ["run", "run2", "today", "weather", "german2", "german1", "cooking", "week"])
    }

    @Test("archived, expired and missing current")
    func exclusions() {
        let sessions = [
            session("arch", running(), archived: true),
            session("old", used: hoursAgo(9)),
            session("a", used: ago(1)),
        ]
        // Expired ones only fill free slots; archived ones never show.
        #expect(ids(StripOrder.order(sessions, current: sid("missing"), now: t0)) == ["a", "old"])
        let full = (0..<8).map { session("f\($0)", used: ago(Double($0))) } + sessions
        #expect(ids(StripOrder.order(full, current: nil, now: t0)).contains("old") == false)
        #expect(StripOrder.order([], current: nil, now: t0).isEmpty)
    }

    @Test("an old current session still takes slot 1")
    func oldCurrent() {
        let sessions = [session("a", used: ago(1)), session("cur", used: hoursAgo(30))]
        #expect(ids(StripOrder.order(sessions, current: sid("cur"), now: t0)) == ["cur", "a"])
    }

    @Test("failed sessions sit with recent ones while under 2 h")
    func failed() {
        let sessions = [session("ok", used: ago(10)), session("bad", failedStatus, used: ago(5))]
        #expect(ids(StripOrder.order(sessions, current: nil, now: t0)) == ["bad", "ok"])
    }

    @Test("refresh keeps the frozen order, updates state, drops archived and forgotten")
    func freeze() {
        let frozen = [session("a"), session("b"), session("c"), session("d")]
        let latest = [
            session("d", needs()), session("new", needs()), session("a", running()),
            session("b", archived: true),
        ]
        let refreshed = StripOrder.refresh(frozen, with: latest)
        #expect(ids(refreshed) == ["a", "d"])
        #expect(refreshed[0].status == running())
    }

    @Test("first Tab: slot 2 after the current session, else slot 1; ＋ alone is 0")
    func firstHighlight() {
        let tiles = [session("cur"), session("b")]
        #expect(StripOrder.firstHighlight(tiles, current: sid("cur")) == 1)
        #expect(StripOrder.firstHighlight(tiles, current: nil) == 0)
        #expect(StripOrder.firstHighlight([session("cur")], current: sid("cur")) == 1) // → ＋
        #expect(StripOrder.firstHighlight([], current: nil) == 0)
    }

    @Test("50 sessions order in well under a millisecond each")
    func speed() {
        let many = (0..<50).map { session("s\($0)", $0 % 7 == 0 ? running(since: ago(Double($0))) : .idle, used: ago(Double($0) * 7)) }
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<100 { _ = StripOrder.order(many, current: sid("s3"), now: t0) } }
        #expect(elapsed < .milliseconds(100))
    }
}
