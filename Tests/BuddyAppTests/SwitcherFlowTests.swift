@testable import BuddyApp
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay
import Foundation
import Testing

/// Sessions a (current), c (needs you) and b (recent): the strip is [a, c, b, ＋].
@MainActor
private struct Rig {
    let clock = SwitcherTestClock()
    let timers = ManualScheduler()
    let presenter = FakeSwitcher()
    let sessions: FakeSessionsPort
    var speech: TimeInterval? = 1.0
    let flow: SwitcherFlow
    let a = SessionID(rawValue: "a"), b = SessionID(rawValue: "b"), c = SessionID(rawValue: "c")

    init(speech: TimeInterval? = 1.0, extra: [SessionSnapshot] = []) {
        let t = clock.now
        let needs = SessionStatus.needsYou(NeedsYou(kind: .soft("Which one?"), since: t.addingTimeInterval(-60)))
        sessions = FakeSessionsPort([
            .switcherSample("a", used: t.addingTimeInterval(-10)),
            .switcherSample("b", used: t.addingTimeInterval(-300)),
            .switcherSample("c", needs, used: t.addingTimeInterval(-600)),
        ] + extra, current: SessionID(rawValue: "a"))
        self.speech = speech
        let heard = speech
        let clock = clock
        flow = SwitcherFlow(presenter: presenter, sessions: sessions, heardSpeech: { heard },
                            scheduler: timers.scheduler, now: { clock.now })
    }
}

@MainActor
@Suite("Switcher · flow")
struct SwitcherFlowTests {
    @Test("hold, Tab, speak, release: the recording goes to slot 2, which becomes current")
    func holdTabSpeak() async {
        let r = Rig()
        r.flow.prepare()
        await r.flow.key(.next)
        #expect(r.flow.isOpen)
        let outcome = await r.flow.released()
        #expect(outcome == .send(.session(r.c)))
        #expect(r.presenter.calls == [.prepare([r.a, r.c, r.b]), .open(highlight: 1), .close(commit: true)])
        #expect(r.sessions.calls == [.setCurrent(r.c)])
    }

    @Test("no speech: switch only, and the answer peeks for 4 s")
    func switchOnly() async {
        let r = Rig(speech: 0.2)
        r.flow.prepare()
        await r.flow.key(.next)
        await r.flow.key(.next)
        #expect(await r.flow.released() == .switched(r.b))
        #expect(r.sessions.calls == [.setCurrent(r.b)])
        #expect(r.presenter.calls.last == .peek(r.b))
        r.timers.fire(after: SwitcherFlow.peekAfterSwitch)
        #expect(r.presenter.calls.last == .peek(nil))
    }

    @Test("65-SURFACE-RULES, rule 1: a Glance answer closes the peek, and nothing more without one")
    func aGlanceClosesThePeek() async {
        let r = Rig(speech: 0.2)
        r.flow.glanceShown()
        #expect(r.presenter.calls.isEmpty, "no peek, nothing to close")
        r.flow.prepare()
        await r.flow.key(.next)
        #expect(await r.flow.released() == .switched(r.c))
        #expect(r.presenter.calls.last == .peek(r.c))
        r.flow.glanceShown()
        #expect(r.presenter.calls.last == .peek(nil), "one answer on screen at a time")
        let count = r.presenter.calls.count
        r.timers.fire(after: SwitcherFlow.peekAfterSwitch)
        r.flow.glanceShown()
        #expect(r.presenter.calls.count == count, "closed once")
    }

    @Test("Tab moves forward, as ⌘Tab: the first lands on the session before this one, each next one is older; ⇧Tab goes back")
    func tabMovesForward() async {
        let t = SwitcherTestClock().now
        let r = Rig(extra: [.switcherSample("d", used: t.addingTimeInterval(-900)), .switcherSample("e", used: t.addingTimeInterval(-1200))])
        let d = SessionID(rawValue: "d")
        r.flow.prepare()
        // Strip, left to right: current, needs-you, then most recent first.
        #expect(r.presenter.calls.first == .prepare([r.a, r.c, r.b, d, SessionID(rawValue: "e")]))
        await r.flow.key(.next)
        #expect(r.presenter.calls.last == .open(highlight: 1))
        await r.flow.key(.next)
        await r.flow.key(.next)
        await r.flow.key(.prev)
        let moves = r.presenter.calls.compactMap { if case .move(let i) = $0 { i } else { nil } }
        #expect(moves == [2, 3, 2]) // forward, forward, back
        #expect(await r.flow.released() == .send(.session(r.b)))
    }

    @Test("the pill follows the highlight: the session, ＋ as New; Esc puts the original back")
    func pillFollowsTheHighlight() async {
        let r = Rig()
        var targets: [PillTarget] = []
        r.flow.onTarget = { targets.append($0) }
        r.flow.prepare()
        await r.flow.key(.next) // opens on c
        await r.flow.key(.next) // b
        await r.flow.key(.next) // ＋
        await r.flow.key(.cancel)
        let ids: [String] = targets.map {
            switch $0 {
            case .session(let s): s.id.rawValue
            case .new: "+"
            case .none: "-"
            }
        }
        #expect(ids == ["c", "b", "+", "a"])
    }

    @Test("a press talks to the current session while it would continue; ＋ when fresh; else the send decides")
    func pressTarget() async {
        let r = Rig()
        guard case .session(let s) = r.flow.pressTarget(fresh: false) else {
            Issue.record("expected the current session")
            return
        }
        #expect(s.id == r.a)
        #expect(r.flow.pressTarget(fresh: true) == .new)
        let stale = Rig()
        stale.clock.advance(ConversationBook.idleLimit + 60)
        #expect(stale.flow.pressTarget(fresh: false) == .none) // past the idle limit: a new session
    }

    @Test("the highlight resting 0.6 s peeks it; the next move closes that peek and waits again; Space still toggles")
    func dwellPeek() async {
        let r = Rig()
        r.flow.prepare()
        await r.flow.key(.next) // c
        r.timers.fire(after: SwitcherFlow.dwellPeek)
        #expect(r.presenter.calls.last == .peek(r.c))
        await r.flow.key(.next) // b: the dwell's peek closes
        #expect(r.presenter.calls.suffix(2) == [.move(2), .peek(nil)])
        await r.flow.key(.next) // ＋: nothing to peek
        r.timers.fire(after: SwitcherFlow.dwellPeek)
        #expect(r.presenter.calls.last == .move(3))
        await r.flow.key(.prev) // b
        await r.flow.key(.peek) // Space: peek now, and it follows the highlight
        #expect(r.presenter.calls.last == .peek(r.b))
        await r.flow.key(.prev)
        #expect(r.presenter.calls.last == .peek(r.c))
        _ = await r.flow.released()
        // Released before the dwell: no peek after the strip closed.
        r.flow.prepare()
        await r.flow.key(.next)
        _ = await r.flow.released()
        let count = r.presenter.calls.count
        r.timers.fire(after: SwitcherFlow.dwellPeek)
        #expect(r.presenter.calls.count == count)
    }

    @Test("Tab wraps through ＋; ⇧Tab goes back; 1–9 jump")
    func navigation() async {
        let r = Rig()
        r.flow.prepare()
        await r.flow.key(.next) // 1
        await r.flow.key(.next) // 2
        await r.flow.key(.next) // 3 = ＋
        await r.flow.key(.next) // wraps to 0
        await r.flow.key(.prev) // back to ＋
        await r.flow.key(.index(2))
        await r.flow.key(.index(9)) // no tile 9: ignored
        let moves = r.presenter.calls.compactMap { if case .move(let i) = $0 { i } else { nil } }
        #expect(moves == [2, 3, 0, 3, 1])
    }

    @Test("the first key can be ⇧Tab (last tile), a digit or N")
    func firstKeys() async {
        for (key, highlight) in [(SwitcherKey.prev, 2), (.index(3), 2), (.new, 3), (.peek, 1)] {
            let r = Rig()
            r.flow.prepare()
            await r.flow.key(key)
            #expect(r.presenter.calls.contains(.open(highlight: highlight)))
        }
    }

    @Test("＋: speech sends to a new session; silence leaves the next question fresh")
    func plus() async {
        let r = Rig()
        r.flow.prepare()
        await r.flow.key(.new)
        #expect(await r.flow.released() == .send(.new))
        #expect(r.sessions.calls.isEmpty)
        let quiet = Rig(speech: 0)
        quiet.flow.prepare()
        await quiet.flow.key(.new)
        #expect(await quiet.flow.released() == .fresh)
    }

    @Test("Esc restores the original; the release sends as a plain hold")
    func cancel() async {
        let r = Rig()
        r.flow.prepare()
        await r.flow.key(.next)
        await r.flow.key(.cancel)
        #expect(r.presenter.calls.last == .close(commit: false))
        #expect(await r.flow.released() == .restored(spoke: true))
        #expect(r.sessions.calls.isEmpty)
    }

    @Test("Return commits early; the release then sends without closing twice")
    func returnCommits() async {
        let r = Rig()
        r.flow.prepare()
        await r.flow.key(.next)
        await r.flow.key(.commit)
        await r.flow.key(.next) // keys after Return do nothing
        #expect(await r.flow.released() == .send(.session(r.c)))
        #expect(r.presenter.calls.filter { $0 == .close(commit: true) }.count == 1)
        #expect(!r.presenter.calls.contains(.move(2)))
    }

    @Test("no switcher key: the release is not ours; reset hides the prepared strip")
    func untouched() async {
        let r = Rig()
        #expect(await r.flow.released() == .none)
        r.flow.prepare()
        r.flow.reset()
        #expect(r.presenter.calls == [.prepare([r.a, r.c, r.b]), .close(commit: false)])
    }

    @Test("an unknown speech total counts as speech")
    func unknownSpeech() async {
        let r = Rig(speech: nil)
        r.flow.prepare()
        await r.flow.key(.next)
        #expect(await r.flow.released() == .send(.session(r.c)))
    }

    @Test("peek toggles and follows the highlight; ↑ closes it")
    func peek() async {
        let r = Rig()
        r.flow.prepare()
        await r.flow.key(.next)
        await r.flow.key(.peek)
        await r.flow.key(.next)
        await r.flow.key(.next) // ＋ has no peek
        await r.flow.key(.unpeek)
        let peeks = r.presenter.calls.compactMap { if case .peek(let id) = $0 { Optional(id) } else { nil } }
        #expect(peeks == [r.c, r.b, nil, nil])
    }

    @Test("P pins; ⌫ archives, a running session only on the second ⌫ within 1.5 s")
    func pinAndArchive() async {
        let running = SessionSnapshot.switcherSample("r", .thinking(since: .now, progress: nil), used: .now)
        let r = Rig(extra: [running])
        let rid = SessionID(rawValue: "r")
        r.flow.prepare() // [a, c, r, b]
        await r.flow.key(.next)
        await r.flow.key(.pin)
        #expect(r.sessions.calls.last == .pinned(true, r.c))
        await r.flow.key(.next) // r
        await r.flow.key(.archive)
        #expect(!r.sessions.calls.contains(.archived(true, rid)))
        r.clock.advance(1)
        await r.flow.key(.archive)
        #expect(r.sessions.calls.last == .archived(true, rid))
        await r.flow.key(.archive) // now on b (idle): one ⌫
        #expect(r.sessions.calls.last == .archived(true, r.b))
    }

    @Test("a click on a tile commits like Return")
    func click() async {
        let r = Rig()
        r.flow.prepare()
        await r.flow.key(.next)
        await r.flow.handle(.highlighted(2))
        await r.flow.handle(.tileClicked(r.a))
        #expect(await r.flow.released() == .send(.session(r.a)))
    }

    @Test("tap mode: Tab retargets, the pick commits 1.5 s after the last key")
    func tapMode() async {
        let r = Rig()
        var hints: [String?] = []
        r.flow.onHint = { hints.append($0) }
        r.flow.prepare()
        await r.flow.tapKey(.next)
        await r.flow.tapKey(.next)
        #expect(hints == ["→ C", "→ B"])
        #expect(r.sessions.calls.isEmpty)
        r.timers.fire(after: SwitcherFlow.tapCommitAfter)
        for _ in 0..<20 where r.sessions.calls.isEmpty { await Task.yield() }
        #expect(r.sessions.calls == [.setCurrent(r.b)])
        #expect(r.presenter.calls.last == .close(commit: true))
        #expect(await r.flow.takePick() == .session(r.b))
        #expect(await r.flow.takePick() == nil)
    }

    @Test("tap mode: the end of speech commits an open strip; Esc restores")
    func tapModeEnd() async {
        let r = Rig()
        await r.flow.tapKey(.new)
        #expect(await r.flow.takePick() == .new)
        let e = Rig()
        var hints: [String?] = []
        e.flow.onHint = { hints.append($0) }
        await e.flow.tapKey(.next)
        await e.flow.tapKey(.cancel)
        #expect(hints == ["→ C", nil])
        #expect(await e.flow.takePick() == nil)
        #expect(e.sessions.calls.isEmpty)
    }

    @Test("R1: a held pick with speech is handed to the send once; silence leaves none")
    func heldPick() async {
        let r = Rig()
        r.flow.prepare()
        await r.flow.key(.next)
        _ = await r.flow.released()
        #expect(await r.flow.takePick() == .session(r.c))
        #expect(await r.flow.takePick() == nil)
        let plus = Rig()
        plus.flow.prepare()
        await plus.flow.key(.new)
        _ = await plus.flow.released()
        #expect(await plus.flow.takePick() == .new)
        let quiet = Rig(speech: 0)
        quiet.flow.prepare()
        await quiet.flow.key(.next)
        _ = await quiet.flow.released()
        #expect(await quiet.flow.takePick() == nil)
    }

    @Test("R1: a tap pick committed by the timer survives the sending tap's reset")
    func tapPickSurvivesReset() async {
        let r = Rig()
        await r.flow.tapKey(.next)
        r.timers.fire(after: SwitcherFlow.tapCommitAfter)
        for _ in 0..<20 where r.sessions.calls.isEmpty { await Task.yield() }
        #expect(!r.flow.inTapMode)
        r.flow.reset() // the sending tap, tap mode already over
        #expect(await r.flow.takePick() == .session(r.c))
    }

    @Test("R1: a new listen, a cancelled gesture or Esc drops the pick")
    func pickCleared() async {
        let r = Rig()
        await r.flow.tapKey(.next)
        await r.flow.commitOpenTap()
        r.flow.clearPick()
        #expect(await r.flow.takePick() == nil)
        let e = Rig()
        await e.flow.tapKey(.next)
        await e.flow.tapKey(.commit)
        await e.flow.tapKey(.next) // opens again
        await e.flow.tapKey(.cancel)
        #expect(await e.flow.takePick() == nil)
    }

    @Test("pill hint counts background sessions waiting on the user")
    func waiting() {
        let r = Rig()
        #expect(r.flow.waitingHint() == "1 waiting · Tab")
        r.flow.nextKeyName = "`"
        #expect(r.flow.waitingHint() == "1 waiting · `")
    }
}
