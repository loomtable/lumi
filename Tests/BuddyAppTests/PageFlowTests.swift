import CoreGraphics
import Foundation
import Testing
@testable import BuddyApp
import BuddyBridge
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

@MainActor
struct PageFlowTests {
    let s = SessionID(rawValue: "s_1")
    let panel = FakePanel()
    let answering = FakeAnswering()

    func flow(_ port: SessionScriptPort = SessionScriptPort([])) -> PageFlow {
        let f = PageFlow(panel: panel, turns: port, permissions: LivePermissionHost(answering: answering))
        f.makeRequest = { id, submit in
            TurnRequest(question: Question(packet: ContextPacket(askedAt: .now, utterance: submit.text)), state: ConversationState(id: id.rawValue),
                        kind: submit.kind, target: .session(id, SessionLaunch(claudeSession: UUID(), exists: true, cwd: URL(filePath: "/tmp"))))
        }
        return f
    }

    func snapshot() -> SessionSnapshot { SessionSnapshot(id: s, title: "Fix", color: .ember, harness: .open, lastUsed: .now) }

    @Test func beginOpensThePageWithTheQuestionAndIsTheVisiblePage() {
        let f = flow()
        f.begin(snapshot(), question: "Why?", kind: .typed, context: nil)
        #expect(panel.calls == [.show(s, turns: 0), .record("Why?", .typed, s)])
        #expect(f.visiblePage?.id == s)
        #expect(f.visiblePage?.kind == .panel)
    }

    @Test func aFinishedTurnInTheVisiblePageAppendsThereSilently() {
        let f = flow()
        var delivered: [Delivery] = []
        f.onDelivered = { _, d in delivered.append(d) }
        f.begin(snapshot(), question: "Why?", kind: .typed, context: nil)
        #expect(f.receive(.text("Hi", subagent: nil), session: s, kind: .typed) == nil)
        #expect(f.receive(.turnEnded(TurnEnd(kind: .typed, markdown: "Hi")), session: s, kind: .typed) == .appendInPage(.panel, speak: false))
        #expect(delivered == [.appendInPage(.panel, speak: false)])
        #expect(panel.calls.contains(.append(.text("Hi", subagent: nil), s)))
    }

    @Test func minimisedDuringTheTurnStaysAmbient() async {
        let f = flow()
        f.begin(snapshot(), question: "Why?", kind: .typed, context: nil)
        panel.minimise()
        await f.handle(.minimised(s))
        #expect(f.receive(.turnEnded(TurnEnd(kind: .typed, markdown: "Hi")), session: s, kind: .typed) == .ambient(notify: nil))
    }

    @Test func composerSendsStreamIntoThePage() async {
        let port = SessionScriptPort([.turnStarted(userUUID: "u", kind: .typed), .turnEnded(TurnEnd(kind: .typed, markdown: "Done"))])
        let f = flow(port)
        await f.handle(.submit(s, PageSubmit(text: "Fix it", kind: .typed, withScreen: true)))
        #expect(port.sent.map(\.kind) == [.typed])
        #expect(port.sent.first?.question.packet.utterance == "Fix it")
        #expect(panel.calls.contains(.append(.turnEnded(TurnEnd(kind: .typed, markdown: "Done")), s)))
    }

    @Test("⌘⇧↩ starts a new session in the background; the toast opens it")
    func submitToNewSessionRunsInTheBackground() async {
        let port = SessionScriptPort([.turnStarted(userUUID: "u", kind: .typed), .turnEnded(TurnEnd(kind: .typed, markdown: "Done"))])
        let f = flow(port)
        let new = SessionID(rawValue: "s_new")
        f.newSession = { new }
        var expanded: [SessionID] = []
        f.onExpand = { expanded.append($0) }
        f.begin(snapshot(), question: "Why?", kind: .typed, context: nil)
        let before = panel.calls
        await f.handle(.action(s, .submitToNewSession(PageSubmit(text: "Draft the notes"))), from: .studio)
        #expect(port.sent.map(\.question.packet.utterance) == ["Draft the notes"])
        if case .session(let id, _)? = port.sent.first?.target { #expect(id == new) } else { Issue.record("not sent to a session") }
        #expect(panel.calls.filter { if case .show = $0 { true } else { false } } == before.filter { if case .show = $0 { true } else { false } },
                "no page opens for it")
        // It ended in the background: an ambient finish, not a page.
        #expect(f.visiblePage?.id == s)
        await f.handle(.action(s, .openStartedSession), from: .studio)
        #expect(expanded == [new])
    }

    @Test func steerAndRelayGoToTheSameSession() async {
        let port = SessionScriptPort([])
        let f = flow(port)
        await f.handle(.submit(s, PageSubmit(text: "Only March", kind: .steer)))
        await f.handle(.action(s, .relay(teammate: "Writer", text: "keep it short")))
        #expect(port.sent.map(\.kind) == [.steer, .relay])
        #expect(port.sent.last?.question.packet.utterance == "The user says to @Writer: keep it short")
    }

    @Test func stopCancelsTheSessionsTurn() async {
        let port = SessionScriptPort([])
        let f = flow(port)
        await f.handle(.stop(s))
        #expect(port.cancelled == ["s_1"])
    }

    @Test func approvalsAndAnswersReachTheEngine() async {
        let f = flow()
        f.receive(.permissionRequested(PermissionAsk(id: "p", title: "Run x", toolName: "Bash", detail: .command("x"), tier: .needsClick)),
                  session: s, kind: .typed)
        await f.handle(.action(s, .approve(requestID: "p", allow: true, always: true, message: nil)))
        await f.handle(.action(s, .answer(requestID: "q", answers: ["Which?": "A"])))
        #expect(answering.recorded.first == .decide("p", s, .allowForSession))
    }

    @Test func anUnsentApprovalBringsTheCardBack() async {
        let f = PageFlow(panel: panel, turns: SessionScriptPort([]), permissions: LivePermissionHost(answering: NoPermissionAnswering()))
        let ask = PermissionAsk(id: "p", title: "Run x", toolName: "Bash", detail: .command("x"), tier: .needsClick)
        f.receive(.permissionRequested(ask), session: s, kind: .typed)
        await f.handle(.action(s, .approve(requestID: "p", allow: true, always: false, message: nil)))
        #expect(panel.calls.filter { $0 == .append(.permissionRequested(ask), s) }.count == 2)
        #expect(f.permissions.pending.count == 1)
    }

    @Test func pageEventsNeverWriteTheStore() async {
        // QA R19: the pool's feed is the one writer to LiveSessions; PageFlow only renders.
        let store = FakeSessionsPort([SessionSnapshot.sample("s_1")])
        let f = PageFlow(panel: panel, turns: SessionScriptPort([]), permissions: LivePermissionHost(answering: answering), sessions: store)
        f.begin(SessionSnapshot.sample("s_1"), question: "Hi", kind: .typed, context: nil)
        f.receive(.turnStarted(userUUID: "u", kind: .typed), session: s, kind: .typed)
        f.receive(.turnEnded(TurnEnd(kind: .typed, markdown: "Done")), session: s, kind: .typed)
        #expect(!store.calls.contains { if case .apply = $0 { true } else { false } })
    }

    @Test func withoutTheEngineASendFailsInThePage() async {
        let f = PageFlow(panel: panel, turns: SessionScriptPort([]), permissions: LivePermissionHost(answering: answering))
        await f.handle(.submit(s, PageSubmit(text: "Hi")))
        guard case .append(.turnEnded(let end), _)? = panel.calls.last else { Issue.record("no failure"); return }
        #expect(end.isError)
    }
}

/// The coordinator with the Panel on: typed session turns render in the page (never the Glance
/// card or `proseBlock`), voice session turns get the Glance.
@MainActor
struct SessionTurnPresentingTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()
    let panel = FakePanel()

    func make(_ port: SessionScriptPort) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(settings: settings, voice: voice, context: FakeContext.packet(), turns: port,
                                 overlay: overlay, pointer: FixedPointer(point: CGPoint(x: 400, y: 300)))
        let flow = PageFlow(panel: panel, turns: port, permissions: LivePermissionHost(answering: FakeAnswering()))
        c.pageFlow = flow
        c.pages = flow
        c.start()
        return c
    }

    func settle(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        for _ in 0..<50 { await Task.yield() }
    }

    var answers: [BuddyBlock] { overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a.block } else { nil } } }

    @Test func aTypedSessionTurnWithACodeFenceRendersInThePage() async {
        let md = "Here:\n\n```swift\nlet ttl = 3600\n```"
        let port = SessionScriptPort([.turnStarted(userUUID: "u", kind: .typed), .text(md, subagent: nil),
                                      .turnEnded(TurnEnd(kind: .typed, markdown: md))])
        let c = make(port)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.doubleTap))
        overlay.send(.submitted(text: "fix the ttl", source: .textBox))
        await settle(until: { panel.calls.contains(.append(.turnEnded(TurnEnd(kind: .typed, markdown: md)), SessionID(rawValue: port.sent.first?.state.id ?? ""))) })
        #expect(panel.calls.first.map { if case .show = $0 { true } else { false } } == true)
        #expect(panel.calls.contains { if case .record("fix the ttl", .typed, _) = $0 { true } else { false } })
        #expect(answers.isEmpty)
        #expect(c.phase == .idle)
    }

    @Test func aVoiceSessionTurnGetsVoiceAndGlance() async {
        let block = BuddyBlock(say: "It's the totals row.", shape: .card)
        let port = SessionScriptPort([.turnStarted(userUUID: "u", kind: .voice),
                                      .step(TrailStep(id: "r", kind: .read, verb: "Reading", object: "q3.numbers")),
                                      .turnEnded(TurnEnd(kind: .voice, markdown: "", block: block))])
        let c = make(port)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        await settle(until: { c.phase == .showing })
        #expect(answers == [block])
        // The pill shows the Trail's live verb.
        #expect(overlay.calls.contains {
            switch $0 {
            case .thinking(_, status: "Reading q3.numbers"?), .status("Reading q3.numbers"?): true
            default: false
            }
        })
        #expect(!panel.calls.contains { if case .show = $0 { true } else { false } })
    }

    @Test func pageKindsAreTheTypedOnes() {
        #expect([TurnKind.typed, .voiceInPage, .steer, .relay].allSatisfy(BuddyCoordinator.rendersInPage))
        #expect(![TurnKind.voice, .action].contains(where: BuddyCoordinator.rendersInPage))
    }
}

/// Composer sends: the store's launch and recap seed, a fresh screen read only with ▣ on.
@MainActor
struct PageRequestTests {
    let s = SessionID(rawValue: "s_1")
    let launch = SessionLaunch(claudeSession: UUID(), exists: true, cwd: URL(filePath: "/tmp"))

    func make() -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        return BuddyCoordinator(settings: settings, voice: FakeVoice(), context: FakeContext.packet(), turns: SessionScriptPort([]),
                                overlay: FakeOverlay(), pointer: FixedPointer(point: .zero))
    }

    @Test func usesThePlansLaunchAndSeed() async {
        let c = make()
        let plan = SessionTurnPlan(id: s, harness: .open, kind: .typed, launch: launch, seed: "<quick-note>recap</quick-note>")
        let r = await c.pageRequest(s, PageSubmit(text: "And April?", kind: .typed, withScreen: false), plan: plan)
        #expect(r?.seed == "<quick-note>recap</quick-note>")
        #expect(r?.kind == .typed)
        #expect(r?.question.packet.utterance == "And April?")
        #expect(r?.question.packet.app == nil)
        #expect(r?.question.screenshot == nil)
        guard case .session(let id, let l)? = r?.target else { Issue.record("not a session turn"); return }
        #expect(id == s)
        #expect(l == launch)
    }

    @Test func theScreenChipReadsTheFrontAppAgain() async {
        let c = make()
        let plan = SessionTurnPlan(id: s, harness: .open, kind: .typed, launch: launch, seed: nil)
        let r = await c.pageRequest(s, PageSubmit(text: "What about this?", kind: .typed, withScreen: true), plan: plan)
        #expect(r?.question.packet.app != nil)
        #expect(r?.question.packet.utterance == "What about this?")
    }

    @Test func noLaunchNoRequest() async {
        let c = make()
        #expect(await c.pageRequest(s, PageSubmit(text: "x"), plan: SessionTurnPlan(id: s, harness: .quick, kind: .typed)) == nil)
    }
}

@MainActor
struct PageFlowEventsTests {
    let s = SessionID(rawValue: "s_1")

    @Test func subscribersGetTheSessionsEventsOnly() async {
        let f = PageFlow(panel: FakePanel(), turns: SessionScriptPort([]), permissions: LivePermissionHost(answering: FakeAnswering()))
        let stream = f.events(for: s)
        f.receive(.text("Hi", subagent: nil), session: s, kind: .typed)
        f.receive(.text("Other", subagent: nil), session: SessionID(rawValue: "s_2"), kind: .typed)
        f.publish(.compacted, session: s)
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == .text("Hi", subagent: nil))
        #expect(await it.next() == .compacted)
    }
}

final class FakeStudioHost: StudioPageHost {
    var shownSession: (id: SessionID, isKey: Bool)?
    private(set) var recorded: [(String, TurnKind, SessionID)] = []
    private(set) var edits: [PageEdit] = []

    init(_ shown: (id: SessionID, isKey: Bool)?) { shownSession = shown }

    func record(question: String, kind: TurnKind, context: ContextStrip?, to session: SessionID) {
        recorded.append((question, kind, session))
    }

    func applyEdit(_ edit: PageEdit, to session: SessionID) { edits.append(edit) }
}

/// QA R3: the Studio counts as a visible page for routing (owner rule 2) and delivery.
@MainActor
struct StudioVisiblePageTests {
    let s = SessionID(rawValue: "s_1")
    let other = SessionID(rawValue: "s_2")
    let panel = FakePanel()

    func flow(_ host: FakeStudioHost?) -> PageFlow {
        let f = PageFlow(panel: panel, turns: SessionScriptPort([]), permissions: LivePermissionHost(answering: FakeAnswering()))
        f.studio = host
        return f
    }

    @Test func aTalkKeyTurnWhileTheStudioShowsASessionContinuesItInPage() {
        let host = FakeStudioHost((s, true))
        let f = flow(host)
        let page = f.visiblePage
        #expect(page?.id == s)
        #expect(page?.kind == .studio)
        let input = SummonInput(source: .talkKey, kind: .voice, visiblePage: page, now: .now)
        guard case .continueSession(let id, let kind) = SummonRouter.route(input, candidates: [], policy: RoutingPolicy()) else {
            Issue.record("not continued")
            return
        }
        #expect(id == s)
        #expect(kind == .voiceInPage)
    }

    @Test func itsAnswerIsAppendedInTheStudioWithNoPanelOrCard() {
        let host = FakeStudioHost((s, false))
        let f = flow(host)
        f.begin(SessionSnapshot(id: s, title: "Fix", color: .ember, harness: .open, lastUsed: .now),
                question: "And April?", kind: .voiceInPage, context: nil)
        #expect(host.recorded.map(\.0) == ["And April?"])
        #expect(panel.calls.isEmpty)
        #expect(f.receive(.turnEnded(TurnEnd(kind: .voiceInPage, markdown: "April too.")), session: s, kind: .voiceInPage)
            == .appendInPage(.studio, speak: false))
        let delivery = RoutedDelivery(visiblePages: { f.focusedPages })
        let answer = Answer(block: BuddyBlock(say: "Hi", shape: .chip), lane: Lane(mode: .quick, model: .haiku), conversation: .ember,
                            turn: 1, replyHint: "")
        // V-01: a Studio window that isn't key is behind the app the user is in: the Glance answers.
        #expect(delivery.surface(for: answer, conversationID: "s_1", kind: .voice) == .glance)
        host.shownSession = (s, true)
        #expect(delivery.surface(for: answer, conversationID: "s_1", kind: .voice) == .page(.studio))
    }

    /// V-01: a Studio window partly visible behind another app isn't where the talk key goes.
    @Test func anUnfocusedStudioAloneTakesNoTalkKeyTurn() {
        let host = FakeStudioHost((s, false))
        let f = flow(host)
        #expect(f.visiblePage == nil)
        #expect(f.focusedPages.isEmpty)
        let input = SummonInput(source: .talkKey, kind: .voice, visiblePage: f.visiblePage, current: other, now: .now)
        #expect(SummonRouter.route(input, candidates: [], policy: RoutingPolicy()).kind == .voice)
    }

    @Test func aQuestionTypedInOnePageShowsInTheOtherOnTheSameSession() async {
        // QA S-26: the Panel and Studio both show s; each records only the other's sends.
        let host = FakeStudioHost((s, false))
        let f = flow(host)
        f.makeRequest = { id, submit in
            TurnRequest(question: Question(packet: ContextPacket(askedAt: .now, utterance: submit.text)), state: ConversationState(id: id.rawValue),
                        kind: submit.kind, target: .session(id, SessionLaunch(claudeSession: UUID(), exists: true, cwd: URL(filePath: "/tmp"))))
        }
        panel.show(session: SessionSnapshot(id: s, title: "Fix", color: .ember, harness: .open, lastUsed: .now), page: [])
        await f.handle(.submit(s, PageSubmit(text: "From the Panel")), from: .panel)
        #expect(host.recorded.map(\.0) == ["From the Panel"])
        #expect(!panel.calls.contains(.record("From the Panel", .typed, s)))
        await f.handle(.submit(s, PageSubmit(text: "From Studio")), from: .studio)
        #expect(panel.calls.contains(.record("From Studio", .typed, s)))
        #expect(host.recorded.map(\.0) == ["From the Panel"])
        // A steer folds into the running turn: never a new turn in the other page.
        await f.handle(.submit(s, PageSubmit(text: "shorter", kind: .steer)), from: .panel)
        #expect(host.recorded.count == 1)
    }

    /// An edited prompt: once the session went back, both pages showing it replace the turns at
    /// once; if it couldn't, only the page that edited hears, and gets the words back.
    @Test func anEditedPromptReachesBothPagesAndAFailureOnlyTheEditingOne() async {
        let host = FakeStudioHost((s, false))
        let f = flow(host)
        f.makeRequest = { id, submit in
            TurnRequest(question: Question(packet: ContextPacket(askedAt: .now, utterance: submit.text)), state: ConversationState(id: id.rawValue),
                        kind: submit.kind, target: .session(id, SessionLaunch(claudeSession: UUID(), exists: true, cwd: URL(filePath: "/tmp"))))
        }
        panel.show(session: SessionSnapshot(id: s, title: "Fix", color: .ember, harness: .open, lastUsed: .now), page: [])
        await f.handle(.submit(s, PageSubmit(text: "Shorter", replacing: "u2")), from: .panel)
        let applied = PageEdit.applied(prompt: "u2", question: "Shorter")
        #expect(panel.calls.contains(.edit(applied, s)))
        #expect(host.edits == [applied])
        #expect(host.recorded.isEmpty, "an edit isn't mirrored as a new question")

        f.makeRequest = { _, _ in nil }
        await f.handle(.submit(s, PageSubmit(text: "Again", replacing: "u3")), from: .studio)
        #expect(host.edits.last == .failed(text: "Again"))
        #expect(!panel.calls.contains(.edit(.failed(text: "Again"), s)))
        #expect(!panel.calls.contains { if case .append(.turnEnded, _) = $0 { true } else { false } }, "no failed turn in the page")
    }

    @Test func aKeyStudioWinsOverThePanelAndAnUnfocusedOneDoesNot() {
        panel.show(session: SessionSnapshot(id: other, title: "P", color: .ember, harness: .open, lastUsed: .now), page: [])
        let host = FakeStudioHost((s, false))
        let f = flow(host)
        #expect(f.visiblePage?.id == other)
        #expect(f.visiblePages == [other: .panel, s: .studio])
        host.shownSession = (s, true)
        #expect(f.visiblePage?.kind == .studio)
        host.shownSession = nil
        #expect(f.visiblePage?.kind == .panel)
        host.shownSession = (s, false)
        #expect(f.focusedPages == [other: .panel], "an unfocused Studio isn't where the user looks")
    }
}

/// QA R11: "Speak answers", the composer mic and ⌘⇧E are wired.
@MainActor
struct PageFlowHooksTests {
    let s = SessionID(rawValue: "s_1")
    let panel = FakePanel()

    func flow(speak: Bool) -> (PageFlow, Box) {
        let f = PageFlow(panel: panel, turns: SessionScriptPort([]), permissions: LivePermissionHost(answering: FakeAnswering()))
        let box = Box()
        f.settings = { DeliverySettings(speakTypedAnswers: speak) }
        f.onSpeak = { text, continuing in box.spoken.append((text, continuing)) }
        f.onExpand = { box.expanded.append($0) }
        f.onMic = { _, down in box.mic.append(down) }
        return (f, box)
    }

    final class Box {
        var spoken: [(String, Bool)] = []
        var expanded: [SessionID] = []
        var mic: [Bool] = []
    }

    @Test func voiceInPageSpeaksItsLinesOnlyWithSpeakAnswersOn() {
        let (on, box) = flow(speak: true)
        on.receive(.turnStarted(userUUID: "u", kind: .voiceInPage), session: s, kind: .voiceInPage)
        on.receive(.sayFirstSentence("It's the TTL."), session: s, kind: .voiceInPage)
        on.receive(.say("It's the TTL. I set it to an hour."), session: s, kind: .voiceInPage)
        on.receive(.turnEnded(TurnEnd(kind: .voiceInPage, markdown: "It's the TTL. I set it to an hour.")), session: s, kind: .voiceInPage)
        #expect(box.spoken.map(\.0) == ["It's the TTL.", "I set it to an hour."])
        #expect(box.spoken.map(\.1) == [false, true])

        let (off, quiet) = flow(speak: false)
        off.receive(.sayFirstSentence("It's the TTL."), session: s, kind: .voiceInPage)
        off.receive(.turnEnded(TurnEnd(kind: .voiceInPage, markdown: "x")), session: s, kind: .voiceInPage)
        #expect(quiet.spoken.isEmpty)
    }

    @Test func aTypedAnswerSpeaksItsFirstSentence() {
        let (f, box) = flow(speak: true)
        f.receive(.turnEnded(TurnEnd(kind: .typed, markdown: "The **token** lived 60 s. I fixed it.\n\n```swift\nx\n```")), session: s, kind: .typed)
        #expect(box.spoken.map(\.0) == ["The token lived 60 s."])
        #expect(PageFlow.firstSpokenSentence("```\ncode\n```") == nil)
    }

    @Test func expandOpensTheStudioAndTucksThePanel() async {
        let (f, box) = flow(speak: false)
        panel.show(session: SessionSnapshot(id: s, title: "F", color: .ember, harness: .open, lastUsed: .now), page: [])
        await f.handle(.expand(s))
        #expect(box.expanded == [s])
        #expect(panel.calls.last == .minimise)
        await f.handle(.action(s, .mic(down: true)))
        #expect(box.mic == [true])
    }
}

/// Voice "yes" on a pending approval in the visible page: reversible asks only.
@MainActor
struct VoiceApprovalTests {
    let s = SessionID(rawValue: "s_1")
    let voice = FakeVoice()
    let panel = FakePanel()
    let answering = FakeAnswering()

    func make() -> (BuddyCoordinator, PageFlow) {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(settings: settings, voice: voice, context: FakeContext.packet(), turns: SessionScriptPort([]),
                                 overlay: FakeOverlay(), pointer: FixedPointer(point: .zero))
        let f = PageFlow(panel: panel, turns: SessionScriptPort([]), permissions: LivePermissionHost(answering: answering))
        c.pageFlow = f
        panel.show(session: SessionSnapshot(id: s, title: "F", color: .ember, harness: .open, lastUsed: .now), page: [])
        return (c, f)
    }

    func ask(_ tier: ApprovalTier) -> PermissionAsk {
        PermissionAsk(id: "p", title: "Edit a.md", toolName: "Edit", detail: .plain(""), tier: tier)
    }

    @Test func aBareYesAllowsAReversibleAsk() async {
        let (c, f) = make()
        f.receive(.permissionRequested(ask(.reversible)), session: s, kind: .typed)
        #expect(await c.approvesByVoice("Yes."))
        #expect(answering.recorded == [.decide("p", s, .allow(updatedInput: nil))])
    }

    @Test func aNeedsClickAskIsNeverApprovedByVoice() async {
        let (c, f) = make()
        f.receive(.permissionRequested(ask(.needsClick)), session: s, kind: .typed)
        #expect(await c.approvesByVoice("go ahead"))
        #expect(answering.recorded.isEmpty)
        #expect(voice.calls.contains(.speak("This one needs a click.")))
        #expect(f.permissions.pending.count == 1)
    }

    @Test func anythingElseIsAnOrdinaryTurn() async {
        let (c, f) = make()
        f.receive(.permissionRequested(ask(.reversible)), session: s, kind: .typed)
        #expect(await c.approvesByVoice("yes but only the March sheet") == false)
        #expect(answering.recorded.isEmpty)
        let (idle, _) = make()
        #expect(await idle.approvesByVoice("yes") == false)
    }

    @Test func aSpokenYesApprovesInsteadOfSendingATurn() async {
        let port = SessionScriptPort([])
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(settings: settings, voice: voice, context: FakeContext.packet(), turns: port,
                                 overlay: FakeOverlay(), pointer: FixedPointer(point: .zero))
        let f = PageFlow(panel: panel, turns: port, permissions: LivePermissionHost(answering: answering))
        c.pageFlow = f
        c.pages = f
        c.start()
        panel.show(session: SessionSnapshot(id: s, title: "F", color: .ember, harness: .open, lastUsed: .now), page: [])
        f.receive(.permissionRequested(ask(.reversible)), session: s, kind: .typed)
        voice.setTranscript("Go ahead.")
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + waitCeiling
        while answering.recorded.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(answering.recorded == [.decide("p", s, .allow(updatedInput: nil))])
        #expect(port.sent.isEmpty)
        #expect(c.phase == .idle)
    }

    @Test(arguments: ["Yes", "yes please!", "Go ahead.", "allow it", "Do it", "OK, go ahead"])
    func affirmatives(_ t: String) { #expect(BuddyCoordinator.isBareAffirmative(t)) }

    @Test(arguments: ["no", "yes and also", "do it later", ""])
    func notAffirmatives(_ t: String) { #expect(!BuddyCoordinator.isBareAffirmative(t)) }
}

@MainActor
struct PageFlowContinueTests {
    let s = SessionID(rawValue: "s_1")

    @Test func continueStreamsTheResumedTurnIntoThePage() async {
        let panel = FakePanel()
        let f = PageFlow(panel: panel, turns: SessionScriptPort([]), permissions: LivePermissionHost(answering: FakeAnswering()))
        f.onContinue = { _ in AsyncStream { c in
            c.yield(.session(.turnEnded(TurnEnd(kind: .typed, markdown: "Done."))))
            c.finish()
        } }
        await f.handle(.action(s, .continueInterrupted))
        #expect(panel.calls.contains(.append(.turnEnded(TurnEnd(kind: .typed, markdown: "Done.")), s)))
    }

    @Test func withoutTheEngineItStaysInterrupted() async {
        let panel = FakePanel()
        let f = PageFlow(panel: panel, turns: SessionScriptPort([]), permissions: LivePermissionHost(answering: FakeAnswering()))
        await f.handle(.action(s, .continueInterrupted))
        #expect(panel.calls.last == .append(.processEnded(status: 0, midTurn: true), s))
    }
}

/// QA R6: the Panel reports the session it shows to the store.
@MainActor
struct PanelPageReportingTests {
    @Test func showSwitchAndMinimiseAreReported() async {
        let store = PageRecordingSessions()
        let f = PageFlow(panel: FakePanel(), turns: SessionScriptPort([]), permissions: LivePermissionHost(answering: FakeAnswering()),
                         sessions: store)
        let a = SessionSnapshot.sample("s_a"), b = SessionSnapshot.sample("s_b")
        f.show(a, history: [])
        f.show(a, history: [])
        f.begin(b, question: "Hi", kind: .typed, context: nil)
        await f.handle(.minimised(b.id))
        #expect(store.pages == [.shown(a.id, .panel), .hidden(a.id, .panel), .shown(b.id, .panel), .hidden(b.id, .panel)])
    }
}

/// R20: a turn the CLI starts on its own (a teammate handed back) reaches the Panel through the
/// pool's feed; page turns don't render twice.
@MainActor
struct PanelBackgroundTurnTests {
    let s = SessionID(rawValue: "s_1")

    @Test func cliStartedTurnsComeFromTheFeedOnly() {
        let panel = FakePanel()
        let f = PageFlow(panel: panel, turns: SessionScriptPort([]), permissions: LivePermissionHost(answering: FakeAnswering()))
        f.fed(.text("ignored: a page turn's own stream renders it", subagent: nil), session: s)
        f.fed(.turnStarted(userUUID: nil, kind: .typed), session: s)
        f.fed(.text("Researcher is done.", subagent: nil), session: s)
        f.fed(.turnEnded(TurnEnd(kind: .typed, markdown: "Researcher is done.")), session: s)
        f.fed(.text("after", subagent: nil), session: s)
        #expect(panel.calls == [
            .append(.turnStarted(userUUID: nil, kind: .typed), s),
            .append(.text("Researcher is done.", subagent: nil), s),
            .append(.turnEnded(TurnEnd(kind: .typed, markdown: "Researcher is done.")), s),
        ])
    }

    @Test func notWhileAPageTurnRuns() {
        let panel = FakePanel()
        let f = PageFlow(panel: panel, turns: SessionScriptPort([]), permissions: LivePermissionHost(answering: FakeAnswering()))
        f.begin(SessionSnapshot.sample("s_1"), question: "Go", kind: .typed, context: nil)
        let before = panel.calls.count
        f.fed(.turnStarted(userUUID: nil, kind: .typed), session: s)
        f.fed(.text("x", subagent: nil), session: s)
        #expect(panel.calls.count == before)
    }
}

/// QA S-05: the inspector's model, mode and cost come from what Claude Code reported.
struct SessionFactsTests {
    func ended(_ cost: Double?) -> SessionEvent { .turnEnded(TurnEnd(kind: .typed, markdown: "ok", costUSD: cost)) }

    @Test func modelModeAndCostAcrossTurnsAndAResume() {
        var facts = SessionFacts()
        facts.note(.initialized(InitSummary(sessionID: "c", model: "claude-opus-5-5", cwd: nil, permissionMode: "auto",
                                            version: nil, capabilities: [], mcpServers: [])))
        facts.note(ended(0.04))
        facts.note(ended(0.10))   // the process's running total
        #expect(facts.model == "claude-opus-5-5" && facts.permissionMode == "auto")
        #expect(abs((facts.costUSD ?? 0) - 0.10) < 1e-9)
        // Suspended and resumed: the new process counts from zero again.
        facts.note(.processEnded(status: 0, midTurn: false))
        facts.note(ended(0.03))
        #expect(abs((facts.costUSD ?? 0) - 0.13) < 1e-9)
        // A turn without a cost changes nothing; an init without a model keeps the last one.
        facts.note(ended(nil))
        facts.note(.initialized(InitSummary(sessionID: "c", model: nil, cwd: nil, permissionMode: nil,
                                            version: nil, capabilities: [], mcpServers: [])))
        #expect(facts.model == "claude-opus-5-5" && abs((facts.costUSD ?? 0) - 0.13) < 1e-9)
    }
}
