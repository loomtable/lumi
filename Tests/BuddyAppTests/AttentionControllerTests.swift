@testable import BuddyApp
import BuddyConversations
import BuddyCore
import BuddyOverlay
import CoreGraphics
import Foundation
import Testing

@MainActor
private struct AttentionRig {
    let clock = SwitcherTestClock()
    let timers = ManualScheduler()
    let presenter = FakeSwitcher()
    let notifier = FakeNotifier()
    let presence = FakePresence()
    let sessions: FakeSessionsPort
    let controller: AttentionController

    init(settings: SessionSettings = SessionSettings()) {
        sessions = FakeSessionsPort([], current: SessionID(rawValue: "cur"))
        let clock = clock
        controller = AttentionController(
            presenter: presenter, sessions: sessions, notifier: notifier, presence: presence,
            settings: { settings }, scheduler: timers.scheduler, now: { clock.now })
    }

    func snap(_ id: String, _ status: SessionStatus = .idle, ranFor: TimeInterval? = nil) -> SessionSnapshot {
        var s = SessionSnapshot.switcherSample(id, status, used: clock.now, title: "Session \(id)")
        s.ranFor = ranFor
        return s
    }

    var running: SessionStatus { .thinking(since: clock.now.addingTimeInterval(-60), progress: nil) }
    var ready: SessionStatus { .done(at: clock.now, unread: true) }
    var needs: SessionStatus { .needsYou(NeedsYou(kind: .soft("Which?"), since: clock.now)) }
}

@MainActor
@Suite("Switcher · attention")
struct AttentionControllerTests {
    private let x = SessionID(rawValue: "x"), y = SessionID(rawValue: "y"), cur = SessionID(rawValue: "cur")

    @Test("every list refreshes the strip's tiles in place")
    func refreshesTiles() async {
        let r = AttentionRig()
        await r.controller.update([r.snap("cur", r.running), r.snap("x", r.running), r.snap("y")])
        #expect(r.presenter.calls.first == .refresh([cur, x, y]))
    }

    @Test("away and ran ≥ 30 s: one banner; seen withdraws it; at the Mac: none")
    func banners() async {
        let r = AttentionRig()
        r.presence.presence = .away
        await r.controller.update([r.snap("x", r.running)])
        await r.controller.update([r.snap("x", r.ready)])
        #expect(r.notifier.calls == [.post(Banner(session: x, body: "Session x is ready", level: .passive))])
        r.presence.presence = .present
        await r.controller.update([r.snap("x", .done(at: r.clock.now, unread: false))])
        #expect(r.notifier.calls.last == .withdraw(x))

        let p = AttentionRig()
        await p.controller.update([p.snap("x", p.running)])
        await p.controller.update([p.snap("x", p.ready)])
        #expect(p.notifier.calls.isEmpty)
    }

    @Test("a needs-you unanswered for 30 min reminds once")
    func reminder() async {
        let r = AttentionRig()
        await r.controller.update([r.snap("x", r.running)])
        await r.controller.update([r.snap("x", r.needs)])
        r.presence.presence = .away
        r.clock.advance(1800)
        await r.controller.remind()
        #expect(r.notifier.calls == [.post(Banner(session: x, body: "Session x still needs your OK", level: .active, isReminder: true))])
    }

    /// Owner, Oct 29: once the user has seen the ask (its card), it asks for nothing more.
    @Test("a seen needs-you cancels its reminder")
    func seenAsk() async {
        let r = AttentionRig()
        let ask = NeedsYou(kind: .soft("Which?"), since: r.clock.now)
        var seen = ask
        seen.seen = true
        await r.controller.update([r.snap("x", r.running)])
        await r.controller.update([r.snap("x", .needsYou(ask))])
        await r.controller.update([r.snap("x", .needsYou(seen))])
        r.presence.presence = .away
        r.clock.advance(1800)
        await r.controller.remind()
        #expect(r.notifier.calls.isEmpty)
    }
}
