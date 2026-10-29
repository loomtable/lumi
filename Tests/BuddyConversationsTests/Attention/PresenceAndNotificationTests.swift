import BuddyCore
import Foundation
import Testing
@testable import BuddyConversations

@Suite("Attention · presence")
struct PresenceTests {
    @Test("present needs recent input, unlocked and awake", arguments: [
        (0.0, false, false, Presence.present), (119.9, false, false, .present), (120, false, false, .away),
        (5, true, false, .away), (5, false, true, .away),
    ])
    func presence(idle: TimeInterval, locked: Bool, asleep: Bool, expected: Presence) {
        #expect(Presence.of(secondsSinceInput: idle, locked: locked, displayAsleep: asleep) == expected)
    }

    @Test("tracker reports going away and coming back once")
    func tracker() {
        var t = PresenceTracker()
        #expect(t.update(.present) == nil)
        #expect(t.update(.away) == .wentAway)
        #expect(t.update(.away) == nil)
        #expect(t.update(.present) == .cameBack)
    }
}

@Suite("Attention · transitions")
struct TransitionTests {
    @Test("the first list is the baseline")
    func baseline() {
        var t = TransitionTracker()
        #expect(t.update([session("a", unread()), session("b", needs())], now: t0).isEmpty)
    }

    @Test("running → ready carries the run time; seen settles")
    func ready() {
        var t = TransitionTracker()
        _ = t.update([session("a", running(since: ago(2)))], now: ago(1))
        let done = session("a", unread(at: t0))
        #expect(t.update([done], now: t0) == [.ready(done, ran: 120)])
        #expect(t.update([session("a", seen())], now: t0 + 1) == [.settled(sid("a"))])
        #expect(t.update([session("a", seen())], now: t0 + 2).isEmpty)
    }

    @Test("needs-you, then answered and running again, then ready")
    func needsThenReady() {
        var t = TransitionTracker()
        _ = t.update([session("a", running(since: ago(1)))], now: ago(1))
        let asking = session("a", needs())
        #expect(t.update([asking], now: t0) == [.needsYou(asking, ran: 60)])
        #expect(t.update([session("a", running(since: t0 + 5))], now: t0 + 5) == [.settled(sid("a"))])
        let done = session("a", unread(at: t0 + 65))
        #expect(t.update([done], now: t0 + 65) == [.ready(done, ran: 60)])
    }

    @Test("forgotten and archived settle; a new session arriving unread counts")
    func membership() {
        var t = TransitionTracker()
        _ = t.update([session("a", needs()), session("b", unread())], now: t0)
        let fresh = session("c", unread())
        let out = t.update([session("b", unread(), archived: true), fresh], now: t0 + 1)
        #expect(out == [.settled(sid("a")), .settled(sid("b")), .ready(fresh, ran: nil)])
    }

    @Test("no run start seen: the snapshot's ranFor")
    func ranFor() {
        var t = TransitionTracker()
        _ = t.update([], now: t0)
        let done = session("a", unread(), ranFor: 45)
        #expect(t.update([done], now: t0) == [.ready(done, ran: 45)])
    }
}

@Suite("Attention · notification policy")
struct NotificationPolicyTests {
    private let s = session("a", title: "Trip to Lisbon")

    @Test("banners only when away, enabled and the turn ran ≥ 30 s", arguments: [
        (Presence.away, true, TimeInterval?(30), true), (.away, true, 29.9, false), (.away, true, nil, false),
        (.present, true, 600, false), (.away, false, 600, false),
    ])
    func gate(presence: Presence, enabled: Bool, ran: TimeInterval?, posts: Bool) {
        var p = NotificationPolicy()
        let out = p.handle(.ready(s, ran: ran), presence: presence, enabled: enabled, now: t0)
        #expect(out == (posts ? [.post(Banner(session: sid("a"), body: "Trip to Lisbon is ready", level: .passive))] : []))
    }

    @Test("needs-you is active; seen withdraws only what was posted")
    func withdraw() {
        var p = NotificationPolicy()
        #expect(p.handle(.needsYou(s, ran: 60), presence: .away, enabled: true, now: t0) ==
            [.post(Banner(session: sid("a"), body: "Trip to Lisbon needs your OK", level: .active))])
        #expect(p.handle(.settled(sid("a")), presence: .present, enabled: true, now: t0) == [.withdraw(sid("a"))])
        #expect(p.handle(.settled(sid("a")), presence: .present, enabled: true, now: t0).isEmpty)
    }

    @Test("a needs-you banner gives way when the session turns ready at the Mac")
    func supersede() {
        var p = NotificationPolicy()
        _ = p.handle(.needsYou(s, ran: 60), presence: .away, enabled: true, now: t0)
        #expect(p.handle(.ready(s, ran: 90), presence: .present, enabled: true, now: t0 + 9) == [.withdraw(sid("a"))])
    }

    @Test("one reminder after 30 min: a banner when away, nothing at the Mac")
    func reminder() {
        var p = NotificationPolicy()
        _ = p.handle(.needsYou(s, ran: 5), presence: .present, enabled: true, now: t0)
        #expect(p.nextReminder == t0 + 1800)
        #expect(p.tick(now: t0 + 1799, presence: .away, enabled: true).isEmpty)
        #expect(p.tick(now: t0 + 1800, presence: .away, enabled: true) ==
            [.post(Banner(session: sid("a"), body: "Trip to Lisbon still needs your OK", level: .active, isReminder: true))])
        #expect(p.tick(now: t0 + 9000, presence: .away, enabled: true).isEmpty)
        #expect(p.nextReminder == nil)

        var q = NotificationPolicy()
        _ = q.handle(.needsYou(s, ran: 5), presence: .present, enabled: true, now: t0)
        #expect(q.tick(now: t0 + 1800, presence: .present, enabled: true).isEmpty, "its amber capsule and tile show it")
        #expect(q.nextReminder == nil)
    }

    @Test("answered in time: no reminder")
    func answered() {
        var p = NotificationPolicy()
        _ = p.handle(.needsYou(s, ran: 5), presence: .present, enabled: true, now: t0)
        _ = p.handle(.settled(sid("a")), presence: .present, enabled: true, now: t0 + 60)
        #expect(p.tick(now: t0 + 4000, presence: .away, enabled: true).isEmpty)
    }
}
