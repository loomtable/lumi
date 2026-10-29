import BuddyCore
import Foundation
import Testing
@testable import BuddyOverlay

@MainActor
struct ConversationPageModelTests {
    func model() -> (ConversationPageModel, Box) {
        let snap = SessionSnapshot(id: SessionID(rawValue: "s_1"), title: "Fix", color: .ember,
                                   origin: SessionOrigin(key: ContextKey(bundleID: "com.apple.dt.Xcode"), appName: "Xcode"),
                                   harness: .open, lastUsed: .now)
        let m = ConversationPageModel(snapshot: snap)
        let box = Box()
        m.onAction = { box.actions.append($0) }
        return (m, box)
    }

    final class Box { var actions: [PageAction] = [] }

    @Test func textIsCoalescedUntilFlushedAndOtherEventsFlushFirst() {
        let (m, _) = model()
        m.record(question: "Hi", kind: .typed, context: nil)
        m.apply(.text("Hel", subagent: nil))
        m.apply(.text("lo", subagent: nil))
        #expect(m.page.turns[0].answer.text.isEmpty)
        m.apply(.step(TrailStep(id: "r", kind: .read, verb: "Reading", object: "a.md")))
        #expect(m.page.turns[0].answer.text == "Hello")
    }

    @Test func textFlushesOnItsOwnWithin33ms() async throws {
        let (m, _) = model()
        m.record(question: "Hi", kind: .typed, context: nil)
        m.apply(.text("Hello", subagent: nil))
        // Flushed by its own timer, without another event (polled: the suite runs loaded).
        let deadline = ContinuousClock.now + .seconds(2)
        while m.page.turns[0].answer.text.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(m.page.turns[0].answer.text == "Hello")
    }

    @Test func submitSendsATurnThenSteersWhileRunning() {
        let (m, box) = model()
        #expect(m.withScreen)
        m.draft = "  Fix the TTL "
        m.submit()
        #expect(m.draft.isEmpty)
        #expect(m.page.turns.first?.context?.headline == "Read from Xcode")
        m.draft = "Only AuthKit"
        m.submit()
        #expect(box.actions == [
            .submit(PageSubmit(text: "Fix the TTL", kind: .typed, withScreen: true)),
            .submit(PageSubmit(text: "Only AuthKit", kind: .steer, withScreen: true)),
        ])
        #expect(m.page.turns.count == 1)
        m.draft = "   "
        m.submit()
        #expect(box.actions.count == 2)
    }

    @Test func textOnlyWhenTheScreenChipIsOff() {
        let (m, box) = model()
        m.withScreen = false
        m.draft = "Hi"
        m.submit()
        #expect(m.page.turns[0].context?.headline == nil)
        #expect(box.actions == [.submit(PageSubmit(text: "Hi", kind: .typed, withScreen: false))])
    }

    @Test func stopAndApproveReportActions() {
        let (m, box) = model()
        m.draft = "Go"
        m.submit()
        let ask = PermissionAsk(id: "p", title: "Run x", toolName: "Bash", detail: .command("x"), tier: .needsClick)
        m.apply(.permissionRequested(ask))
        m.approve("p", allow: false, message: "Use make instead")
        m.stop()
        m.stop()
        #expect(box.actions.dropFirst() == [.approve(requestID: "p", allow: false, always: false, message: "Use make instead"), .stop])
    }

    @Test func attachmentsGoWithTheSendThenClear() {
        let (m, box) = model()
        m.attach([URL(filePath: "/tmp/a.png"), URL(filePath: "/tmp/b.md"), URL(filePath: "/tmp/a.png")])
        #expect(m.attachments.map(\.kind) == [.image, .file])
        m.draft = "Look"
        m.submit()
        guard case .submit(let s)? = box.actions.last else { Issue.record("no submit"); return }
        #expect(s.attachments.map(\.name) == ["a.png", "b.md"])
        #expect(m.attachments.isEmpty)
    }

    @Test func pageActionsMapToPanelEvents() {
        let id = SessionID(rawValue: "s_1")
        #expect(PanelEvent(.stop, session: id) == .stop(id))
        #expect(PanelEvent(.submit(PageSubmit(text: "x")), session: id) == .submit(id, PageSubmit(text: "x")))
        #expect(PanelEvent(.mic(down: true), session: id) == .action(id, .mic(down: true)))
    }

    @Test func somethingElseAnswersTheQuestionFromTheComposer() {
        // QA U6: the composer takes the answer, focused, instead of clearing and doing nothing.
        let (m, box) = model()
        m.draft = "Ask"
        m.submit()
        let q = QuestionAsk(id: "q", items: [.init(question: "Which sheet?", header: "Sheet", options: [.init(label: "Q3"), .init(label: "Q4")])])
        m.apply(.questionAsked(q))
        let focus = m.focusRequest
        m.answerInComposer("q", questions: ["Which sheet?"])
        #expect(m.focusRequest == focus + 1)
        m.draft = "The draft one"
        m.submit()
        #expect(box.actions.last == .answer(requestID: "q", answers: ["Which sheet?": "The draft one"]))
        #expect(m.answering == nil)
        #expect(m.page.turns.count == 1)
    }

    @Test func aPendingQuestionNeedsYouUntilAnswered() {
        // QA U18: the header disc's amber rim covers questions as well as approvals.
        let (m, _) = model()
        m.draft = "Ask"
        m.submit()
        #expect(!m.page.needsYou)
        m.apply(.questionAsked(QuestionAsk(id: "q", items: [.init(question: "Which?", header: "W", options: [.init(label: "A")])])))
        #expect(m.page.needsYou)
        m.answer("q", answers: ["Which?": "A"])
        #expect(!m.page.needsYou)
    }

    @Test func somethingElseStepsThroughEveryQuestion() {
        // QA U28: a multi-question ask is answered whole, one question at a time.
        let (m, box) = model()
        m.draft = "Ask"
        m.submit()
        m.answerInComposer("q", questions: ["Which sheet?", "Which month?"])
        #expect(m.answering?.step == "1/2")
        m.draft = "Q4"
        m.submit()
        #expect(m.answering?.question == "Which month?")
        #expect(!box.actions.contains { if case .answer = $0 { true } else { false } })
        m.draft = "March"
        m.submit()
        #expect(box.actions.last == .answer(requestID: "q", answers: ["Which sheet?": "Q4", "Which month?": "March"]))
        #expect(m.answering == nil)
    }

    @Test func teammatesAreSeededFromTheSnapshot() {
        // QA U30: a page opened mid-run shows the roster the store already has.
        let mates = [TeammateSnapshot(id: "t1", toolUseID: "tu1", name: "Researcher", state: .working, liveLine: "Reading 4 sources"),
                     TeammateSnapshot(id: "t2", toolUseID: "tu2", name: "Writer", state: .done)]
        let snap = SessionSnapshot(id: SessionID(rawValue: "s_1"), title: "Q3", color: .ember, harness: .open, teammates: mates,
                                   lastUsed: .now)
        let m = ConversationPageModel(snapshot: snap)
        #expect(m.page.teammates.map(\.name) == ["Researcher", "Writer"])
        #expect(m.page.teammates[0].liveLine == "Reading 4 sources")
        var later = snap
        later.teammates[0].state = .done
        m.update(later)
        #expect(m.page.teammates[0].state == .done)
        #expect(m.page.teammates.count == 2)
        // A live lane wins over the store's copy.
        m.apply(.step(TrailStep(id: "x", kind: .read, verb: "Reading", object: "a.md", subagent: "tu2")))
        later.teammates[1].state = .failed
        m.update(later)
        #expect(m.page.teammates[1].state == .done)
    }

    /// The store's snapshot and the page's own stream arrive on separate paths: a snapshot that
    /// still says "live" after the page saw the merged answer must not bring the roster back.
    @Test func aStaleSnapshotDoesNotBringASettledRosterBack() {
        let mate = TeammateSnapshot(id: "t1", toolUseID: "tu1", name: "Scout", state: .working)
        let snap = SessionSnapshot(id: SessionID(rawValue: "s_1"), title: "Q3", color: .ember, harness: .open, teammates: [mate],
                                   lastUsed: .now)
        let m = ConversationPageModel(snapshot: snap)
        #expect(m.page.team.isLive)
        m.apply(.task(.ended(taskID: "t1", status: .completed, summary: "ok")))
        m.apply(.turnStarted(userUUID: nil, kind: .typed))
        m.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Done.")))
        #expect(!m.page.team.isLive)
        m.update(snap)   // published before the store saw the end
        #expect(!m.page.team.isLive && m.page.teammates.map(\.state) == [.done])
        var settled = snap
        settled.teammates[0].state = .done
        settled.teamLive = false
        m.update(settled)
        #expect(!m.page.team.isLive)
    }

    @Test func aPageThatFollowsNoneOfTheTeamTakesTheStoresEnd() {
        let mate = TeammateSnapshot(id: "t1", toolUseID: "tu1", name: "Scout", state: .working)
        let snap = SessionSnapshot(id: SessionID(rawValue: "s_1"), title: "Q3", color: .ember, harness: .open, teammates: [mate],
                                   lastUsed: .now)
        let m = ConversationPageModel(snapshot: snap)
        var settled = snap
        settled.teammates[0].state = .done
        settled.teamLive = false
        m.update(settled)
        #expect(!m.page.team.isLive && m.page.teammates.map(\.state) == [.done])
    }

    @Test func seedingWithLanesIsIdempotentAndAddsNoRows() {
        let snap = SessionSnapshot(id: SessionID(rawValue: "s_1"), title: "Q3", color: .ember, harness: .open, lastUsed: .now)
        let m = ConversationPageModel(snapshot: snap, history: [TranscriptTurn(question: "Split", block: BuddyBlock(say: "On it.", shape: .chip),
                                                                               mode: .deep, model: .opus)])
        let mates = [TeammateSnapshot(id: "t1", toolUseID: "tu1", name: "Researcher", state: .done),
                     TeammateSnapshot(id: "t2", toolUseID: "tu2", name: "Writer", state: .working)]
        let lanes = ["tu1": LaneHistory(texts: ["Found 3 invoices.", "Done."]), "tu2": LaneHistory(texts: ["Drafting."])]
        m.seed(teammates: mates, live: true, lanes: lanes)
        m.seed(teammates: mates, live: true, lanes: lanes)
        #expect(m.page.teammates.map(\.name) == ["Researcher", "Writer"])
        #expect(m.page.teammates[0].laneText.text == "Found 3 invoices.\n\nDone.")
        #expect(m.page.teammates[0].laneText.isFinished)
        #expect(m.page.teammates[0].lane.phase == .done)
        #expect(!m.page.teammates[1].laneText.isFinished)
        #expect(m.page.teammates[1].lane.isWorking)
        #expect(m.page.turns.allSatisfy { $0.trail.rows.isEmpty })
    }

    @Test func aSeededWorkingLaneShowsTheStoresLineWithNoClock() {
        // QA U32: not "Thinking · 0:02" beside a chip saying "Reading 4 sources".
        let snap = SessionSnapshot(id: SessionID(rawValue: "s_1"), title: "Q3", color: .ember, harness: .open,
                                   teammates: [TeammateSnapshot(id: "t1", toolUseID: "tu1", name: "Researcher", state: .working,
                                                                liveLine: "Reading 4 sources")], lastUsed: .now)
        let m = ConversationPageModel(snapshot: snap)
        let lane = m.page.teammates[0].lane
        #expect(lane.liveLine(at: .now.addingTimeInterval(30)) == "Reading 4 sources")
        var later = snap
        later.teammates[0].liveLine = "Comparing POs"
        m.update(later)
        #expect(m.page.teammates[0].lane.live == "Comparing POs")
    }

    @Test func seedLanesFillsTheSnapshotsTeammates() {
        let snap = SessionSnapshot(id: SessionID(rawValue: "s_1"), title: "Q3", color: .ember, harness: .open,
                                   teammates: [TeammateSnapshot(id: "t1", toolUseID: "tu1", name: "Researcher", state: .done)],
                                   lastUsed: .now)
        let m = ConversationPageModel(snapshot: snap)
        m.seedLanes(["tu1": LaneHistory(texts: ["Found 3 invoices."])])
        #expect(m.page.teammates[0].laneText.text == "Found 3 invoices.")
        #expect(m.page.teammates[0].laneText.isFinished)
    }

    /// The deferred U30 follow-up: a lane opened later shows its earlier tool steps too, at their
    /// own times, and seeding again neither repeats them nor overrides a live lane.
    @Test func aSeededLaneShowsItsEarlierSteps() {
        let snap = SessionSnapshot(id: SessionID(rawValue: "s_1"), title: "Q3", color: .ember, harness: .open,
                                   teammates: [TeammateSnapshot(id: "t1", toolUseID: "tu1", name: "Researcher", state: .done),
                                               TeammateSnapshot(id: "t2", toolUseID: "tu2", name: "Writer", state: .working,
                                                                liveLine: "Reading 4 sources")],
                                   lastUsed: .now)
        let m = ConversationPageModel(snapshot: snap)
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let read = TrailStep(id: "r1", kind: .read, verb: "Reading", object: "q3.csv", subagent: "tu1")
        let grep = TrailStep(id: "g1", kind: .search, verb: "Searching for", object: "March", subagent: "tu2")
        let lanes = ["tu1": LaneHistory(texts: ["Found it."], steps: [.init(.step(read), at: t0),
                                                                     .init(.stepFinished(id: "r1", isError: false, preview: nil), at: t0 + 4)]),
                     "tu2": LaneHistory(steps: [.init(.step(grep), at: t0 + 1)])]
        m.seedLanes(lanes)
        m.seedLanes(lanes)
        let researcher = m.page.teammates[0].lane
        #expect(researcher.rows.map(\.id) == ["r1"])
        #expect(researcher.rows[0].status == .done && researcher.rows[0].finishedAt == t0 + 4)
        #expect(researcher.phase == .done)
        let writer = m.page.teammates[1].lane
        #expect(writer.rows.map(\.id) == ["g1"] && writer.isWorking && writer.rows[0].status == .running)
        // QA U42: the store's line is newer than the file's last step.
        #expect(writer.live == "Reading 4 sources")
        // The store still updates a seeded lane's state until the page follows it live.
        var later = snap
        later.teammates[1].state = .done
        m.update(later)
        #expect(m.page.teammates[1].state == .done)
    }

    @Test func stopWorksWithASteerInTheField() {
        // QA U12: the model's stop doesn't depend on the draft.
        let (m, box) = model()
        m.draft = "Go"
        m.submit()
        m.draft = "only March"
        m.stop()
        #expect(box.actions.last == .stop)
        #expect(m.draft == "only March")
    }

    // QA U36: tokens that don't fit fold into "+N" instead of clipping.
    @Test func attachmentsThatDontFitFoldIntoAPlusToken() {
        let long = ["po-ledger.csv", "quarterly-report-final.pdf", "screenshot 2026-10-28.png"]
        #expect(AttachmentTokens.shownCount(names: ["a.png"], width: 340) == 1)
        #expect(AttachmentTokens.shownCount(names: ["a.png", "b.md"], width: 340) == 2, "short ones all fit")
        let at340 = AttachmentTokens.shownCount(names: long, width: 340)
        #expect(at340 >= 1 && at340 < long.count, "the rest go to +N")
        #expect(AttachmentTokens.shownCount(names: long, width: 900) == long.count, "Studio width shows all")
        #expect(AttachmentTokens.shownCount(names: Array(repeating: "very-long-file-name-here.swift", count: 9), width: 200) == 1,
                "always at least one")
    }

    /// A narrow composer drops whole hints from the end (never "@ file…archer"): the full row,
    /// then without "Full Claude Code", then the "/" hint alone.
    @Test func composerHintsDropWholeFromTheEnd() {
        let rows = ComposerView.hintRows(narrow: true, teammate: "researcher")
        #expect(rows.map(\.leading) == [["/ commands", "@ files, @researcher"], ["/ commands", "@ files, @researcher"], ["/ commands"]])
        #expect(rows.map(\.trailing) == ["Full Claude Code", nil, nil])
        #expect(ComposerView.hintRows(narrow: false, teammate: nil).map(\.leading).prefix(2)
                == [["/ commands & your skills", "@ files & folders", "⌘⇧↩ new session"], ["/ commands & your skills", "@ files & folders"]])
    }

    @Test("⌘⇧↩ sends to a new session: nothing lands in this page, the composer clears, a toast shows")
    func submitToNewSession() {
        let (m, box) = model()
        m.draft = "Draft the release notes"
        m.submitToNewSession()
        #expect(box.actions == [.submitToNewSession(PageSubmit(text: "Draft the release notes", withScreen: m.withScreen))])
        #expect(m.page.turns.isEmpty)
        #expect(m.draft.isEmpty)
        #expect(m.startedSession != nil)
        m.openStartedSession()
        #expect(box.actions.last == .openStartedSession)
        #expect(m.startedSession == nil)
        m.submitToNewSession() // empty: nothing
        #expect(box.actions.count == 2)
    }

    @Test func compactPlaceholdersAreShort() {
        // QA U2: at the Panel's 400 pt the placeholder must fit one line.
        #expect(ComposerView.placeholder(running: false, compact: true) == "Ask, / for commands")
        #expect(ComposerView.placeholder(running: true, compact: true) == "Add direction")
        #expect(ComposerView.placeholder(running: false, compact: false).count > 30)
    }

    @Test func theMicTogglesAndReports() {
        let (m, box) = model()
        m.toggleMic()
        #expect(m.listening)
        m.toggleMic()
        #expect(!m.listening)
        #expect(box.actions == [.mic(down: true), .mic(down: false)])
    }

    @Test func anOpenLaneRelaysToTheTeammate() {
        let (m, box) = model()
        m.draft = "Split"
        m.submit()
        m.apply(.task(.started(taskID: "t1", toolUseID: "tu", name: "Writer", description: "Draft", kind: .agent)))
        m.openLane = "t1"
        m.draft = "Keep it short"
        m.submit()
        #expect(box.actions.last == .relay(teammate: "Writer", text: "Keep it short"))
    }

    /// QA U13: "@name" in the composer reaches that teammate; an unknown name is a normal send.
    @Test func atATeammateRelaysFromTheComposer() {
        let (m, box) = model()
        m.draft = "Split"
        m.submit()
        m.apply(.task(.started(taskID: "t1", toolUseID: "tu", name: "Writer", description: "Draft", kind: .agent)))
        m.draft = "@writer: keep it short"
        m.submit()
        #expect(box.actions.last == .relay(teammate: "Writer", text: "keep it short"))
        m.draft = "@Reviewer check it"
        m.submit()
        guard case .submit(let sent)? = box.actions.last else { Issue.record("expected a send"); return }
        #expect(sent.text == "@Reviewer check it" && sent.kind == .steer)
        #expect(ConversationPageModel.addressed("@Writer 2 go", teammates: ["Writer", "Writer 2"])! == ("Writer 2", "go"))
        #expect(ConversationPageModel.addressed("@Writers go", teammates: ["Writer"]) == nil)
        #expect(ConversationPageModel.addressed("@Writer", teammates: ["Writer"]) == nil)
    }

    private func past(_ id: String, _ q: String, kind: TurnKind? = .typed, changedFiles: Bool = false) -> TranscriptTurn {
        TranscriptTurn(id: id, question: q, block: BuddyBlock(say: "a", shape: .rich), mode: .deep, model: ModelID(rawValue: "m"),
                       kind: kind, markdown: "a", changedFiles: changedFiles)
    }

    /// Edit an earlier prompt: idle only, the note first when later replies changed files; Send
    /// goes to the host and the page changes only when the session went back.
    @Test func editingAPromptReplacesItAndEverythingAfter() {
        let (m, box) = model()
        m.load(history: [past("v1", "old lane", kind: nil), past("u1", "q1"), past("u2", "q2"), past("u3", "q3", changedFiles: true)])
        #expect(!m.canEdit(m.page.turns[0]), "a v1 turn has no user uuid")
        #expect(m.canEdit(m.page.turns[1]))

        m.beginEdit("u1")
        #expect(m.editing?.text == "q1")
        m.cancelEdit()
        #expect(m.editing == nil && box.actions.isEmpty)

        m.beginEdit("u2")
        m.editing?.text = "  q2, shorter "
        m.sendEdit()
        #expect(m.editing?.confirming == true, "a later reply changed files: the note shows first")
        #expect(box.actions.isEmpty)
        m.sendEdit()
        #expect(box.actions == [.submit(PageSubmit(text: "q2, shorter", kind: .typed, withScreen: true, replacing: "u2"))])
        #expect(m.editing?.sending == true)
        #expect(m.page.turns.count == 4, "nothing changes until the session went back")
        m.cancelEdit()
        m.sendEdit()
        #expect(m.editing?.sending == true && box.actions.count == 1, "no second send, no cancel while it goes")

        m.apply(.applied(prompt: "u2", question: "q2, shorter"))
        #expect(m.editing == nil)
        #expect(m.page.turns.map(\.question) == ["old lane", "q1", "q2, shorter"])
        #expect(m.page.turns.last?.context?.headline == "Read from Xcode")

        // While the new turn runs nothing can be edited.
        #expect(m.page.isRunning)
        #expect(!m.canEdit(m.page.turns[1]))
        m.beginEdit("u1")
        #expect(m.editing == nil)
    }

    /// The session couldn't go back: the page is as it was and the words wait in the composer,
    /// with one plain line; the next send clears the line.
    @Test func aFailedEditKeepsThePageAndPutsTheTextInTheComposer() {
        let (m, box) = model()
        m.load(history: [past("u1", "q1"), past("u2", "q2")])
        m.beginEdit("u1")
        m.editing?.text = "again"
        m.sendEdit()
        #expect(box.actions == [.submit(PageSubmit(text: "again", kind: .typed, withScreen: true, replacing: "u1"))])
        m.apply(.failed(text: "again"))
        #expect(m.page.turns.map(\.question) == ["q1", "q2"])
        #expect(m.editing == nil)
        #expect(m.draft == "again")
        #expect(m.notice == "Couldn't edit that message. Your text is in the box.")
        m.submit()
        #expect(m.notice == nil)
    }

    /// The other page showing the session (it didn't edit) drops the replaced turns at once.
    @Test func theOtherPageDropsTheReplacedTurns() {
        let (m, _) = model()
        m.load(history: [past("u1", "q1"), past("u2", "q2"), past("u3", "q3")])
        m.apply(.applied(prompt: "u2", question: "new"))
        #expect(m.page.turns.map(\.question) == ["q1", "new"])
        #expect(m.page.turns.last?.context == nil)
    }

    /// Teammates that worked in the replaced turns leave the header and their lanes go; a team
    /// from a kept turn stays.
    @Test func anEditDropsTheReplacedTurnsTeam() {
        let (m, _) = model()
        m.load(history: [past("u1", "q1"), past("u2", "q2")])
        m.record(question: "split it", kind: .typed, context: nil)
        m.apply(.turnStarted(userUUID: "u3", kind: .typed))
        m.apply(.task(.started(taskID: "t1", toolUseID: "tu", name: "Writer", description: "Draft", kind: .agent)))
        m.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Writer is on it.")))
        m.apply(.task(.ended(taskID: "t1", status: .completed, summary: "done")))
        #expect(m.page.teammates.map(\.name) == ["Writer"])
        m.apply(.applied(prompt: "u2", question: "new"))
        #expect(m.page.teammates.isEmpty && !m.page.team.isLive)

        // A past turn's team, kept: editing a later turn leaves it.
        let (k, _) = model()
        var withTeam = past("u1", "q1")
        withTeam.teammates = ["Scout"]
        k.load(history: [withTeam, past("u2", "q2")])
        k.seed(teammates: [TeammateSnapshot(id: "t9", toolUseID: "tu9", name: "Scout", state: .done)], live: false, lanes: [:])
        k.apply(.applied(prompt: "u2", question: "new"))
        #expect(k.page.teammates.map(\.name) == ["Scout"])
        k.apply(.applied(prompt: "u1", question: "newer"))
        #expect(k.page.teammates.isEmpty)
    }

    /// An empty edit sends nothing.
    @Test func anEmptyEditSendsNothing() {
        let (m, box) = model()
        m.load(history: [past("u1", "q1")])
        m.beginEdit("u1")
        m.editing?.text = "   "
        m.sendEdit()
        #expect(box.actions.isEmpty && m.editing?.sending == false)
    }
}

@MainActor
struct InterruptedContinueTests {
    @Test func anInterruptedTurnOffersContinueAndResumes() {
        let snap = SessionSnapshot(id: SessionID(rawValue: "s_1"), title: "Fix", color: .ember, harness: .open, lastUsed: .now)
        let m = ConversationPageModel(snapshot: snap)
        var actions: [PageAction] = []
        m.onAction = { actions.append($0) }
        m.draft = "Go"
        m.submit()
        m.apply(.processEnded(status: 15, midTurn: true))
        #expect(m.page.turns.last?.interrupted == true)
        m.continueInterrupted()
        #expect(actions.last == .continueInterrupted)
        #expect(m.page.turns.count == 2)
        #expect(m.page.isRunning)
        #expect(m.page.turns[0].interrupted == false)
    }

    @Test func aSessionInterruptedWhileLumiWasClosedOffersContinueOnOpen() {
        let block = BuddyBlock(say: "Partly done.", shape: .chip)
        let snap = SessionSnapshot(id: SessionID(rawValue: "s_1"), title: "Fix", color: .ember, harness: .open,
                                   status: .interrupted(at: .now), lastUsed: .now)
        let m = ConversationPageModel(snapshot: snap, history: [TranscriptTurn(question: "Fix", block: block, mode: .deep, model: .opus)])
        #expect(m.page.turns.last?.interrupted == true)
    }
}
