@testable import BuddyApp
import BuddyBridge
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay
import Foundation
import Synchronization
import Testing

/// QA R1, R2, R4: explicit targets reach the router, a new-conversation request starts a new
/// session, and typed asks stay on the v1 path without the Panel.
@MainActor
struct RoutingFixTests {
    let overlay = FakeOverlay()

    private func packet(_ utterance: String) -> ContextPacket {
        var p = ContextPacket(askedAt: .now, utterance: utterance)
        p.app = .init(name: "Safari", bundle: "com.apple.Safari", kind: .browser)
        return p
    }

    private func typed(_ h: LiveSessionsTests.Harness, _ text: String, at now: Date = .now) async -> SessionID {
        await h.sessions.plan(SummonInput(source: .textBox, kind: .typed, command: .newSession, now: now), packet: packet(text)).id
    }

    private func routing(_ h: LiveSessionsTests.Harness) -> SessionRouting {
        SessionRouting(sessions: h.sessions, conversations: MemoryConversations(), trust: { FolderTrust(trustedPaths: []) })
    }

    // R1
    @Test func aPickedSessionWinsOverTheVisiblePageAndTheIdleLimit() async throws {
        let h = try LiveSessionsTests.Harness()
        let old = await typed(h, "old budget", at: Date().addingTimeInterval(-3 * 3600))
        let page = await typed(h, "trip to lisbon")
        let r = routing(h)
        let picked = await r.route(RouteRequest(packet: packet("and march?"), kind: .voice, visiblePage: (page, .panel),
                                                source: .switcherPick(old)))
        #expect(picked.sessionID == old && picked.kind == .voice)
        // Without a source the page wins (owner rule), and an idle current doesn't continue.
        let plain = await r.route(RouteRequest(packet: packet("and march?"), kind: .voice, visiblePage: (page, .panel)))
        #expect(plain.sessionID == page && plain.kind == .voiceInPage)
    }

    // R2
    @Test func newConversationMakesTheNextQuestionANewSession() async throws {
        let h = try LiveSessionsTests.Harness()
        let current = await typed(h, "trip to lisbon")
        let engine = FakeSessionEngine(session: [.turnEnded(TurnEnd(kind: .typed, markdown: "Ok."))])
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(settings: settings, voice: FakeVoice(), context: FakeContext.packet(), turns: engine,
                                 overlay: overlay, pointer: FixedPointer())
        c.routing = routing(h)
        c.start()
        await c.startNewConversation()
        // The press below starts a new listen, which clears picks but not this request.
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.doubleTap))
        overlay.send(.submitted(text: "something unrelated", source: .textBox))
        let deadline = ContinuousClock.now + waitCeiling
        while engine.sent.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        let sent = try #require(engine.sent.first)
        #expect(sent.session != nil && sent.session != current, "a new session, not the current one")
        #expect(h.sessions.current != current)
    }

    // The pick expires (lead): a pick, then an empty recording, then a question an hour later
    // goes by the normal rules.
    @Test func aPickFollowedByAnEmptyRecordingDoesntSteerALaterQuestion() async throws {
        let h = try LiveSessionsTests.Harness()
        let picked = await typed(h, "old budget")
        let other = await typed(h, "trip to lisbon")
        let now = Mutex(Date())
        let voice = FakeVoice()
        voice.setTranscript("")
        let engine = FakeSessionEngine(session: [.turnEnded(TurnEnd(kind: .typed, markdown: "Ok."))])
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(settings: settings, voice: voice, context: FakeContext.packet(), turns: engine,
                                 overlay: overlay, pointer: FixedPointer(), clock: { now.withLock { $0 } })
        c.routing = routing(h)
        c.start()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        c.nextRouteSource = .switcherPick(picked)        // the switcher's pick during the hold
        await c.handle(.gesture(.holdEnded))             // nothing was said
        let deadline = ContinuousClock.now + waitCeiling
        while c.phase != .idle, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(engine.sent.isEmpty && c.nextRouteSource == nil, "discarded, and the pick with it")
        #expect(c.phase == .idle, "\(c.phase)")

        // An hour later, the next ask routes with whatever the coordinator hands it: no pick.
        now.withLock { $0 = $0.addingTimeInterval(3600) }
        let source = c.takeRouteSource()
        #expect(source == nil)
        let routed = await routing(h).route(RouteRequest(packet: packet("what's the weather"), kind: .typed, source: source))
        #expect(routed.sessionID != picked, "the normal rules, not the stale pick")
        _ = other
    }

    @Test func aPickExpiresAfterAMinute() async throws {
        let now = Mutex(Date())
        let c = BuddyCoordinator(voice: FakeVoice(), context: FakeContext.packet(), turns: FakeSessionEngine(),
                                 overlay: overlay, pointer: FixedPointer(), clock: { now.withLock { $0 } })
        let id = SessionID.new()
        c.nextRouteSource = .switcherPick(id)
        #expect(c.takeRouteSource() == .switcherPick(id))
        #expect(c.takeRouteSource() == nil, "one-shot")
        c.nextRouteSource = .switcherPick(id)
        now.withLock { $0 = $0.addingTimeInterval(BuddyCoordinator.routeSourceLifetime + 1) }
        #expect(c.takeRouteSource() == nil, "stale")
        c.nextRouteSource = .switcherPick(id)
        await c.escapePressed()
        #expect(c.nextRouteSource == nil, "Esc clears it")
    }

    // R6: pages tell LiveSessions what they show, so rule 3 and the pool's on-screen rule work.
    @Test func aSessionThePanelJustShowedIsContinuedAndKeptOnScreen() async throws {
        let h = try LiveSessionsTests.Harness()
        let shown = await typed(h, "trip to lisbon")
        let current = await typed(h, "budget for march")
        h.sessions.pageShown(shown, kind: .panel)
        h.sessions.pageShown(shown, kind: .studio)
        #expect(h.sessions.onScreen == [shown] && h.sessions.panelShownAt[shown] != nil)
        h.sessions.pageHidden(shown, kind: .panel)
        #expect(h.sessions.onScreen == [shown], "Studio still shows it")
        h.sessions.pageHidden(shown, kind: .studio)
        #expect(h.sessions.onScreen.isEmpty)
        #expect(h.sessions.current == current)
        let routed = await routing(h).route(RouteRequest(packet: packet("and hotels?"), kind: .voice))
        #expect(routed.sessionID == shown, "the Panel showed it under 2 min ago (rule 3)")
    }

    // R11: Quick's hand-off resolves to the conversation's open session, not the Deep lane.
    @Test func aQuickHandOffResolvesToTheSessionsOpenClaudeSession() async throws {
        let h = try LiveSessionsTests.Harness()
        let quick = await h.sessions.plan(SummonInput(source: .talkKey, kind: .voice, now: .now), packet: packet("what is this"))
        #expect(quick.harness == .quick)
        let (id, launch) = try #require(await h.sessions.handoffLaunch(conversation: quick.id.rawValue))
        #expect(id == quick.id && !launch.exists)
        #expect(await h.sessions.handoffLaunch(conversation: quick.id.rawValue)?.1.claudeSession == launch.claudeSession,
                "the same mint until Claude Code starts it")
        _ = try await h.index.create(id: "c_v1", title: "Old", at: .now, projectFolder: nil)
        try await h.index.recordTurn(id: "c_v1", at: .now, quickSessionID: nil, deepSessionID: "22222222-2222-4222-8222-222222222222",
                                     lastLane: .deep, projectFolder: nil)
        #expect(await h.sessions.handoffLaunch(conversation: "c_v1") == nil, "a v1 Deep conversation keeps the Deep lane")
        #expect(await h.sessions.handoffLaunch(conversation: "c_unknown") == nil)
    }

    // R4
    @Test func withoutThePanelTypedAsksStayOnTheV1Path() async throws {
        let h = try LiveSessionsTests.Harness()
        h.sessions.typedOpensSessions = false
        let fresh = await h.sessions.plan(SummonInput(source: .textBox, kind: .typed, now: .now), packet: packet("list files"))
        #expect(fresh.harness == .quick && fresh.launch == nil, "a new typed session starts on Quick")
        #expect(try await h.index.record(id: fresh.id.rawValue)?.harness == .quick)
        // An open session (made while the Panel was on) also answers typed asks on the v1 path.
        h.sessions.typedOpensSessions = true
        let open = await typed(h, "plan a trip")
        h.sessions.typedOpensSessions = false
        let again = await h.sessions.plan(SummonInput(source: .composer(open), kind: .typed, now: .now), packet: packet("and hotels"))
        #expect(again.id == open && again.launch == nil, "no open-session Markdown reaches the Glance")
        // Voice in an open session still goes open (the envelope gives it a buddy block).
        let voice = await h.sessions.plan(SummonInput(source: .composer(open), kind: .voice, now: .now), packet: packet("why"))
        #expect(voice.launch != nil)
    }

    @Test func theRuntimeTiesTypedSessionsToThePanelFlag() async throws {
        let h = try LiveSessionsTests.Harness()
        #expect(LiveSessions(store: SessionStore(index: h.index), manager: h.manager, trust: { FolderTrust(trustedPaths: []) })
            .typedOpensSessions == false, "off unless the shell turns it on with the Panel")
    }
}
