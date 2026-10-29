import Foundation
import Testing
@testable import BuddyApp
import BuddyBridge
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay

/// Code review (30-QA R1–R4): the coordinator, SessionRouting and LiveSessions together, as
/// the app wires them with `LumiFeatures.sessions` on.
@MainActor
struct ReviewRoutingTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()
    let presenter = FakeSwitcher()

    final class Rig {
        let live: LiveSessionsTests.Harness
        let engine: FakeSessionEngine
        let coordinator: BuddyCoordinator

        @MainActor init(voice: FakeVoice, overlay: FakeOverlay, engine: FakeSessionEngine) throws {
            live = try LiveSessionsTests.Harness()
            self.engine = engine
            var settings = BuddyCoordinator.Settings()
            settings.sounds = false
            coordinator = BuddyCoordinator(
                settings: settings, voice: voice, context: FakeContext.packet(), turns: engine,
                overlay: overlay, pointer: FixedPointer())
            coordinator.routing = SessionRouting(sessions: live.sessions, conversations: MemoryConversations(),
                                                 trust: { FolderTrust(trustedPaths: []) })
        }
    }

    static let ok = TurnEnd(kind: .typed, markdown: "Ok.", block: BuddyBlock(say: "Ok.", shape: .chip))

    func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// Two open sessions, `a` current; returns (a, b).
    func twoSessions(_ rig: Rig) async -> (SessionID, SessionID) {
        let now = Date()
        func typed(_ current: SessionID?) -> SummonInput {
            SummonInput(source: .textBox, kind: .typed, command: .newSession, current: current, now: now)
        }
        let b = await rig.live.sessions.plan(typed(nil), packet: ContextPacket(askedAt: now, utterance: "budget for march"))
        let a = await rig.live.sessions.plan(typed(b.id), packet: ContextPacket(askedAt: now, utterance: "trip to lisbon"))
        return (a.id, b.id)
    }

    // R1: hold + Tab, pick another session, speak: the recording must go to the pick. SessionRouting
    // only ever sends `.talkKey`, so the visible page (rule 2) wins over the pick.
    @Test func aSwitcherPickWithSpeechGoesToThePickedSessionEvenWithAPageOnScreen() async throws {
        let rig = try Rig(voice: voice, overlay: overlay, engine: FakeSessionEngine(session: [.turnEnded(Self.ok)]))
        let (a, b) = await twoSessions(rig)
        rig.coordinator.pages = FakePageSurfaces(showing: a) // the Panel shows a
        rig.coordinator.switcherFlow = SwitcherFlow(presenter: presenter, sessions: rig.live.sessions, heardSpeech: { 1 })
        rig.coordinator.start()
        let index = try #require(StripOrder.order(rig.live.sessions.snapshots, current: a, now: Date()).firstIndex { $0.id == b })

        await rig.coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await rig.coordinator.handle(.gesture(.switcher(.index(index + 1))))
        await rig.coordinator.handle(.gesture(.switcherReleased))
        await waitFor { !rig.engine.sent.isEmpty }

        #expect(presenter.calls.contains(.open(highlight: index)), "the strip opened on b")
        // Spoken turns start on Quick (V-06), so the pick shows in the conversation the turn is sent in.
        #expect(rig.engine.sent.first?.request.state.id == b.rawValue, "the spoken turn went to the picked session, not the page's \(a)")
    }

    // R1, without a page: the picked session was last used over the idle limit ago, so rule 5
    // skips it and the turn starts a new session instead.
    @Test func aSwitcherPickOfAnOlderSessionIsNotDroppedForANewOne() async throws {
        let rig = try Rig(voice: voice, overlay: overlay, engine: FakeSessionEngine(session: [.turnEnded(Self.ok)]))
        let old = Date().addingTimeInterval(-3 * 3600)
        let b = await rig.live.sessions.plan(
            SummonInput(source: .textBox, kind: .typed, now: old), packet: ContextPacket(askedAt: old, utterance: "old budget"))
        rig.coordinator.switcherFlow = SwitcherFlow(presenter: presenter, sessions: rig.live.sessions, heardSpeech: { 1 })
        rig.coordinator.start()

        await rig.coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await rig.coordinator.handle(.gesture(.switcher(.index(1))))
        await rig.coordinator.handle(.gesture(.switcherReleased))
        await waitFor { !rig.engine.sent.isEmpty }

        #expect(rig.engine.sent.first?.request.state.id == b.id.rawValue, "the spoken turn went to the picked session")
    }

    // R2: ⌘N / "new topic" / the switcher's ＋ call `conversations.startNew()`, which SessionRouting
    // never reads: LiveSessions.current stays, so the next question continues the old session.
    @Test func newTopicStartsANewSessionWithSessionsOn() async throws {
        let rig = try Rig(voice: voice, overlay: overlay, engine: FakeSessionEngine(session: [.turnEnded(Self.ok)]))
        let (a, _) = await twoSessions(rig)
        rig.coordinator.start()
        #expect(rig.live.sessions.current == a)

        await rig.coordinator.startNewConversation()
        await rig.coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await rig.coordinator.handle(.gesture(.doubleTap))
        overlay.send(.submitted(text: "something unrelated", source: .textBox))
        await waitFor { !rig.engine.sent.isEmpty }

        let sent = try #require(rig.engine.sent.first)
        #expect(sent.request.state.id != a.rawValue, "a new topic must not continue the current session")
    }

    // R4: sessions on, Panel off (step 2 of the flip order). An open session's Markdown answer would
    // come back through `proseBlock`, which returns nil on a code fence. Lead's decision: typed asks
    // reach open sessions only with the Panel on, so here the ask stays on the cascade (v1's path).
    @Test func aTypedAskWithoutThePanelStaysOnTheCascade() async throws {
        let fenced = "Run this:\n\n```sh\nls -la\n```\n\nThat lists the files."
        let rig = try Rig(voice: voice, overlay: overlay, engine: FakeSessionEngine(
            cascade: [BuddyCoordinatorTests.done(BuddyBlock(say: "Run ls -la.", shape: .chip))],
            session: [.turnEnded(TurnEnd(kind: .typed, markdown: fenced))]))
        rig.live.sessions.typedOpensSessions = false // the Panel is off
        rig.coordinator.start()

        await rig.coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await rig.coordinator.handle(.gesture(.doubleTap))
        overlay.send(.submitted(text: "how do I list files", source: .textBox))
        await waitFor { rig.coordinator.phase == .showing }

        guard case .cascade = rig.engine.sent.first?.request.target else { Issue.record("a cascade turn"); return }
        let id = try #require(rig.live.sessions.current)
        #expect(try await rig.live.index.record(id: id.rawValue)?.harness == .quick, "no open session without the Panel")
        let shown = overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a.block.say } else { nil } }
        #expect(!shown.contains(TurnFailureLine.noAnswer.text), "the answer, not the no-answer failure")
    }
}

extension ReviewRoutingTests {
    // R7: the open Claude session is recorded (and the harness flipped to open) when the turn is
    // planned, before anything is sent. If that first turn never reaches Claude Code (Esc while
    // routing, a launch failure, the empty stream before engine-core), the next plan resumes a
    // session that doesn't exist (`exists: true`) and the Quick recap seed is gone for good.
    @Test func aContinuedQuickSessionKeepsItsSeedUntilTheOpenSessionReallyStarted() async throws {
        let h = try LiveSessionsTests.Harness()
        let t0 = LiveSessionsTests.t0Date
        let voice = await h.sessions.plan(SummonInput(source: .talkKey, kind: .voice, now: t0),
                                          packet: ContextPacket(askedAt: t0, utterance: "what is this chart"))
        try await h.index.setRecap(["Q: what is this chart\nA: Revenue by month."], id: voice.id.rawValue)

        let first = try #require(await h.sessions.composerPlan(voice.id))
        #expect(first.launch?.exists == false && first.seed != nil)
        // The turn is cancelled before it is sent: no user turn, no Claude Code session file.
        let retry = try #require(await h.sessions.composerPlan(voice.id))
        #expect(retry.launch?.exists == false, "nothing was ever sent to that Claude session")
        #expect(retry.seed == first.seed, "the recap still seeds the first real turn")
    }
}

extension ReviewRoutingTests {
    // R9: a background teammate keeps running past the lead's `result` (probe 5), and its
    // can_use_tool waits there with no timeout. The main turn's `.turnEnded` clears every pending
    // ask of the session, so the card and the needs-you status vanish while Claude Code still waits.
    @Test func aTeammatesPendingApprovalSurvivesTheLeadTurnEnding() async {
        let host = LivePermissionHost(answering: NoPermissionAnswering())
        let session = SessionID.new()
        let ask = PermissionAsk(id: "r1", title: "Run npm test", toolName: "Bash", detail: .plain("npm test"),
                                tier: .needsClick, asker: "scout")
        host.observe(.permissionRequested(ask), in: session)
        host.observe(.turnEnded(Self.ok), in: session)
        #expect(host.pending(in: session).map(\.ask.id) == ["r1"], "still waiting on the user")

        var activity = SessionActivity()
        _ = activity.apply(.turnStarted(userUUID: "u1", kind: .typed), at: .now, onScreen: false)
        _ = activity.apply(.permissionRequested(ask), at: .now, onScreen: false)
        _ = activity.apply(.turnEnded(Self.ok), at: .now, onScreen: false)
        guard case .needsYou = activity.status else { Issue.record("needs-you, not \(activity.status)"); return }
    }
}

extension ReviewRoutingTests {
    // R6: the pool feed (AppRuntime.connectSessionEngine: every `pool.allEvents()` event goes to
    // `LiveSessions.apply`, and `onSent` to `recordSent`) keeps the row current. The Panel showing
    // the session must also set `panelShownAt` (router rule 3) and `onScreen` (a finished answer in
    // front is already seen); nothing writes either today.
    @Test func thePoolFeedAndThePanelKeepTheSessionStoreCurrent() async throws {
        let h = try LiveSessionsTests.Harness()
        let t0 = Date()
        let plan = await h.sessions.plan(SummonInput(source: .textBox, kind: .typed, now: t0),
                                         packet: ContextPacket(askedAt: t0, utterance: "plan a trip"))
        let id = plan.id
        let panel = FakePanel()
        let flow = PageFlow(panel: panel, turns: FakeSessionEngine(), permissions: LivePermissionHost(answering: NoPermissionAnswering()),
                            sessions: h.sessions)
        let snapshot = try #require(flow.snapshot(for: id))
        flow.begin(snapshot, question: "plan a trip", kind: .typed, context: nil)
        #expect(panel.visibleSession == id)
        #expect(h.sessions.panelShownAt[id] != nil, "the Panel showed it: rule 3 continues it for 2 min")
        #expect(h.sessions.onScreen.contains(id), "its page is in front")

        // What the pool feed delivers for the turn, once each.
        let launch = try #require(plan.launch)
        await h.sessions.recordSent(userUUID: "u1", kind: .typed, shown: "plan a trip", claudeSession: launch.claudeSession, in: id)
        h.sessions.apply(.turnStarted(userUUID: "u1", kind: .typed), to: id)
        h.sessions.apply(.turnEnded(Self.ok), to: id)
        guard case .done(_, let unread) = h.sessions.snapshots.first(where: { $0.id == id })?.status else {
            Issue.record("done"); return
        }
        #expect(!unread, "the answer landed in the page in front: already seen")

        let deadline = ContinuousClock.now + waitCeiling
        while (try await h.index.record(id: id.rawValue))?.turns != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let record = try #require(try await h.index.record(id: id.rawValue))
        #expect(record.turns == 1 && record.recap == ["Q: plan a trip\nA: Ok."])
        #expect(try await h.index.userTurns(of: id.rawValue).map(\.uuid) == ["u1"])
    }
}
