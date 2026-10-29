import BuddyCore
import BuddyKeys
import BuddyOverlay
import Foundation
import Testing
@testable import BuddyCompanion

@Suite("Studio model")
@MainActor
struct StudioModelTests {
    typealias F = StudioFixtures

    func model(_ sessions: [SessionSnapshot]) -> (StudioModel, FakeStudioSource) {
        let source = FakeStudioSource(sessions)
        return (StudioModel(source: source, clock: { F.now }), source)
    }

    /// Lets the model's tasks (open, follow) run.
    func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// Settings › Privacy's Forget All Sessions (it replaced the v1 Conversations window's Forget).
    @Test func forgetAllForgetsEverySessionAndLeavesItsPage() async {
        let (m, source) = model([F.session("a"), F.session("b")])
        m.select(SessionID(rawValue: "b"))
        await settle()
        #expect(await m.forgetAll() == 0)
        #expect(source.calls.filter { if case .forget = $0 { true } else { false } }
            == [.forget(SessionID(rawValue: "a")), .forget(SessionID(rawValue: "b"))])
        #expect(source.snapshots.isEmpty)
        #expect(m.selection == .home, "the forgotten session's page closes")
        #expect(PrivacyPane.forgetAllLine(failed: 0) == "Forgotten.")
        #expect(PrivacyPane.forgetAllLine(failed: 2) == "2 sessions couldn't be forgotten.")
        #expect(!PrivacyPane.forgetAllMessage.contains("Claude"), "no plumbing in the confirmation")
    }

    /// Owner, Oct 29: the sidebar lists Dictation once a dictation key is set up; its page never
    /// takes dictated words (no composer there).
    @Test func dictationPageIsListedOnlyWhenAvailable() {
        let history = DictationHistory(file: nil)
        let m = StudioModel(source: FakeStudioSource([]), dictationHistory: history, clock: { F.now })
        #expect(!m.showsDictation)
        history.available = true
        #expect(m.showsDictation)
        m.windowVisible = true
        m.windowKey = true
        m.homeComposerFocused = true
        m.selection = .dictation
        #expect(!m.composerIsKey)
        #expect(!m.showsSettingsList)
        #expect(!StudioModel(source: FakeStudioSource([]), clock: { F.now }).showsDictation)
        #expect(PrivacyPane.forgetAllMessage.contains("dictation history"))
    }

    /// QA U46: with the `sessions` kill switch off there's no store. Forget All is hidden (it would
    /// say "Forgotten." with the history still on disk), and Home's composer says why it can't start.
    @Test func withSessionsOffForgetAllIsHiddenAndHomeSaysSo() async {
        let (m, source) = model([])
        source.hasSessions = false
        #expect(!m.hasSessions)
        let action = ForgetAllAction(available: { m.hasSessions }, run: { await m.forgetAll() })
        #expect(action.runnable == nil, "no Forget All row")
        #expect(ForgetAllAction(available: { true }, run: { 0 }).runnable != nil)
        #expect(ForgetAllAction().runnable == nil, "no action: no row")
        #expect(await m.ask("hello") == false)
        #expect(m.notice == "Sessions are turned off.")
        #expect(!source.calls.contains(.start("hello")), "nothing tries to start")
    }

    @Test func opensOnHomeAndSelectingASessionMakesItCurrent() async {
        let (m, source) = model([F.session("a")])
        #expect(m.selection == .home)
        #expect(!m.showsSettingsList)
        m.select(SessionID(rawValue: "a"))
        await settle()
        #expect(source.calls == [.open(SessionID(rawValue: "a"))])
        #expect(m.selectedSession?.title == "a")
    }

    @Test func settingsSwapTheSidebarAndRememberTheLastPage() {
        let (m, _) = model([])
        m.showSettings()
        #expect(m.selection == .settings(.general))
        #expect(m.showsSettingsList)
        m.showSettings(.teammates)
        m.leaveSettings()
        #expect(m.selection == .home)
        #expect(!m.showsSettingsList)
        m.showSettings()
        #expect(m.selection == .settings(.teammates))
    }

    @Test func oldDeepLinksOpenTheMappedPage() {
        let (m, _) = model([])
        m.showSettings(SettingsPage(.privacy))
        #expect(m.selection == .settings(.permissions))
    }

    @Test func followsChangesAndLeavesAForgottenSession() async {
        let (m, source) = model([F.session("a"), F.session("b")])
        m.start()
        await settle()
        m.select(SessionID(rawValue: "a"))
        source.set([F.session("b")])
        await settle()
        #expect(m.snapshots.map(\.id.rawValue) == ["b"])
        #expect(m.selection == .home)
        m.stop()
    }

    @Test func forgetGoesHomeAndAFailureSaysSo() async {
        let (m, source) = model([F.session("a")])
        m.select(SessionID(rawValue: "a"))
        await m.forget(SessionID(rawValue: "a"))
        #expect(m.selection == .home)
        #expect(source.calls.contains(.forget(SessionID(rawValue: "a"))))

        let failing = StudioModel(source: FailingForget(), clock: { F.now })
        await failing.forget(SessionID(rawValue: "x"))
        #expect(failing.notice == "Couldn't forget that session.")
    }

    @Test func renameTrimsAndIgnoresEmptyOrUnchanged() async {
        let (m, source) = model([F.session("a", "Old")])
        m.start()
        await settle()
        await m.rename(SessionID(rawValue: "a"), to: "   ")
        await m.rename(SessionID(rawValue: "a"), to: "Old")
        await m.rename(SessionID(rawValue: "a"), to: "  New title ")
        #expect(source.calls == [.rename(SessionID(rawValue: "a"), "New title")])
        m.stop()
    }

    @Test func archiveAndBringBackFromTheArchivedGroup() async {
        // QA S-15: archiving the open session goes Home; one opened from Archived stays open.
        let (m, source) = model([F.session("a"), F.session("b", archived: true)])
        m.start()
        await settle()
        m.select(SessionID(rawValue: "a"))
        await m.setArchived(true, for: SessionID(rawValue: "a"))
        await settle()
        #expect(source.calls.contains(.archive(SessionID(rawValue: "a"), true)))
        #expect(m.selection == .home)
        m.select(SessionID(rawValue: "b"))
        source.set(source.snapshots)   // any later change
        await settle()
        #expect(m.selection == .session(SessionID(rawValue: "b")))
        await m.setArchived(false, for: SessionID(rawValue: "b"))
        await settle()
        #expect(m.selection == .session(SessionID(rawValue: "b")))
        #expect(m.sidebar().rows(.archived).map(\.id.rawValue) == ["a"])
        m.stop()
    }

    @Test func theSessionMenuRenamesAndStopsOnlyWithASessionOpen() async {
        let (m, _) = model([F.session("a")])
        m.requestRename()
        #expect(m.renameRequests == 0)
        m.select(SessionID(rawValue: "a"))
        m.requestRename()
        #expect(m.renameRequests == 1)
        #expect(!m.canStop)
        let page = ConversationPageModel(snapshot: F.session("a"))
        m.register(page)
        #expect(!m.canStop)
        page.record(question: "Why?", kind: .typed, context: nil)
        page.apply(.turnStarted(userUUID: "u", kind: .typed))
        #expect(m.canStop)
        m.stopSelected()
        #expect(!page.page.isRunning)
    }

    @Test func togglePinFlipsIt() async {
        let (m, source) = model([F.session("a", pinned: true)])
        await m.togglePin(SessionID(rawValue: "a"))
        #expect(source.calls == [.pin(SessionID(rawValue: "a"), false)])
    }

    @Test func askStartsASessionAndOpensIt() async {
        let (m, source) = model([])
        #expect(await m.ask("  ") == false)
        #expect(await m.ask("Why did March jump?"))
        await settle()
        #expect(source.calls.first == .start("Why did March jump?"))
        #expect(m.selection == .session(SessionID(rawValue: "s_new")))

        source.nextSessionID = nil
        #expect(await m.ask("again") == false)
        #expect(m.notice != nil)
    }

    @Test func homesQuestionShowsInTheNewSessionsPageOnce() async throws {
        // Round 3 S-02: the session isn't running yet when its page opens, so the page showed an
        // answer with no question.
        let (m, source) = model([])
        #expect(await m.ask("Why did March jump?"))
        let id = SessionID(rawValue: "s_new")
        let page = await m.makePage(for: F.session("s_new"))
        let turn = try #require(page.page.turns.last)
        #expect(page.page.turns.count == 1 && turn.question == "Why did March jump?" && !turn.finished)
        // Only that first page: opened again later, the transcript has it.
        #expect(await m.makePage(for: F.session("s_new")).page.turns.isEmpty)
        // Already in the transcript (it finished before the page came up): not added twice.
        #expect(await m.ask("Again?"))
        source.turns[id] = [TranscriptTurn(id: "u-1", question: "Again?", block: BuddyBlock(say: "Yes", shape: .rich),
                                           mode: .deep, model: ModelID(rawValue: "x"), kind: .typed, markdown: "Yes")]
        #expect(await m.makePage(for: F.session("s_new")).page.turns.count == 1)
    }

    @Test func aSessionsUnsentDraftComesBackWhenItsPageReopens() async {
        // Round 3 S-04: switching sessions dropped what was typed.
        let (m, _) = model([F.session("a"), F.session("b")])
        let a = await m.makePage(for: F.session("a"))
        m.register(a)
        a.draft = "Half a thought " + a.composer.collapse("row 1\nrow 2")
        a.attach([URL(fileURLWithPath: "/tmp/march.csv")])
        m.register(await m.makePage(for: F.session("b")))
        let again = await m.makePage(for: F.session("a"))
        #expect(again.draft == "Half a thought [Pasted text #1 +2 lines]" && again.attachments.map(\.name) == ["march.csv"])
        #expect(again.composer.expandedText == "Half a thought row 1\nrow 2", "the paste chip still expands")
        // Sent (or cleared) drafts aren't kept.
        m.register(again)
        again.draft = "  "
        again.attachments = []
        m.register(nil)
        #expect(await m.makePage(for: F.session("a")).draft.isEmpty)
    }

    @Test func homeFilesGoWithTheFirstMessageThenClear() async {
        // QA U23: Home's ＋ attaches files to the new session's first message.
        let (m, source) = model([])
        let file = URL(fileURLWithPath: "/tmp/march.csv")
        m.homeAttachments = [file]
        #expect(await m.ask("Why did March jump?"))
        #expect(source.calls.first == .startWith("Why did March jump?", [file]))
        #expect(m.homeAttachments.isEmpty)
    }

    @Test func homeCardsRunningFirstThenRecent() {
        let (m, _) = model([
            F.session("r1", status: F.thinking(for: 3)),
            F.session("r2", status: F.needsYou(since: 5)),
            F.session("r3", status: F.thinking(for: 4)),
            F.session("r4", status: F.thinking(for: 9), ago: 200),
            F.session("old", ago: 3 * F.day),
            F.session("new", ago: 10),
            F.session("mid", ago: F.hour),
            F.session("last", ago: 2 * F.day),
            F.session("hidden", archived: true, ago: 1),
        ])
        #expect(m.running.map(\.id.rawValue) == ["r2", "r1", "r3"])
        #expect(m.recent.map(\.id.rawValue) == ["new", "mid", "last"])
        #expect(!m.isEmpty)
        #expect(model([F.session("x", archived: true)]).0.isEmpty)
    }

    @Test func homeOrbOnlyWhileHomeIsOnScreen() {
        let (m, _) = model([F.session("a")])
        #expect(!m.homeOrbVisible)
        m.windowVisible = true
        #expect(m.homeOrbVisible)
        m.select(SessionID(rawValue: "a"))
        #expect(!m.homeOrbVisible)
    }

    @Test func arrowsMoveThroughSidebarRowsAndWrap() {
        let (m, _) = model([F.session("now", status: F.thinking(for: 1)), F.session("t1", ago: 10), F.session("t2", ago: 20)])
        m.move(by: 1)
        #expect(m.selection == .session(SessionID(rawValue: "now")))
        m.move(by: -1)
        #expect(m.selection == .session(SessionID(rawValue: "t2")))
        m.move(by: 1)
        #expect(m.selection == .session(SessionID(rawValue: "now")))
    }

    @Test func newSessionGoesHomeAndAsksForTheComposer() {
        let (m, _) = model([F.session("a")])
        m.select(SessionID(rawValue: "a"))
        m.newSession()
        #expect(m.selection == .home)
        #expect(m.composerFocusRequests == 1)
        m.newSession()
        #expect(m.composerFocusRequests == 2, "pressed again on Home still focuses")
    }

    @Test func runningCardProgress() {
        #expect(StudioModel.progress(F.thinking(for: 1, progress: StepProgress(done: 4, total: 9))) == 4.0 / 9.0)
        #expect(StudioModel.progress(F.thinking(for: 1, progress: StepProgress(done: 12, total: 9))) == 1)
        #expect(StudioModel.progress(F.thinking(for: 1, progress: StepProgress(done: 0, total: 0))) == nil)
        #expect(StudioModel.progress(F.thinking(for: 1)) == nil)
        #expect(StudioModel.progress(F.needsYou(since: 1)) == nil)
    }

    @Test func aSessionCountsAsShownOnlyWithItsPageUpInAnOpenWindowOnThisSpace() {
        let (m, _) = model([F.session("a"), F.session("b")])
        let a = SessionID(rawValue: "a")
        let page = ConversationPageModel(snapshot: F.session("a"))
        m.select(a)
        m.register(page)
        #expect(m.shownSession == nil, "window not open")
        m.windowVisible = true
        #expect(m.shownSession?.id == a)
        #expect(m.shownSession?.isKey == false)
        #expect(page.isVisible)
        m.windowKey = true
        #expect(m.shownSession?.isKey == true)
        m.windowOnScreen = false
        #expect(m.shownSession == nil, "another Space")
        #expect(!page.isVisible)
        m.windowOnScreen = true
        m.select(SessionID(rawValue: "b"))
        #expect(m.shownSession == nil, "b's page isn't up yet")
        #expect(!page.isVisible)
        m.register(nil)
        m.showHome()
        #expect(m.shownSession == nil)
    }

    @Test func recordGoesOnlyToTheShownPage() {
        let (m, _) = model([F.session("a")])
        let page = ConversationPageModel(snapshot: F.session("a"))
        m.select(SessionID(rawValue: "a"))
        m.register(page)
        let before = page.page.turns.count
        m.record(question: "And for April?", kind: .voiceInPage, context: nil, to: SessionID(rawValue: "other"))
        #expect(page.page.turns.count == before)
        m.record(question: "And for April?", kind: .voiceInPage, context: nil, to: SessionID(rawValue: "a"))
        #expect(page.page.turns.count == before + 1)
    }

    @Test func dictationTypesIntoTheFocusedComposerOnlyInTheKeyWindow() {
        let (m, _) = model([F.session("a")])
        m.homeDraft = "Why did"
        m.homeComposerFocused = true
        m.windowVisible = true
        #expect(!m.composerIsKey, "window not key")
        m.insertIntoComposer("March jump")
        #expect(m.homeDraft == "Why did")
        m.windowKey = true
        #expect(m.composerIsKey)
        m.insertIntoComposer("March jump")
        #expect(m.homeDraft == "Why did March jump")

        let page = ConversationPageModel(snapshot: F.session("a"))
        m.select(SessionID(rawValue: "a"))
        m.register(page)
        #expect(!m.composerIsKey, "the page's composer isn't focused")
        m.pageComposerFocused = true
        m.insertIntoComposer("for April")
        #expect(page.draft == "for April")
        m.insertIntoComposer("too")
        #expect(page.draft == "for April too")
        m.showSettings()
        #expect(!m.composerIsKey)
    }

    @Test func aTeammateRowOpensItsSessionThenTheLane() {
        let (m, _) = model([F.session("a"), F.session("b")])
        let a = SessionID(rawValue: "a")
        m.openTeammate("task-1", in: a)
        #expect(m.selection == .session(a))
        let page = ConversationPageModel(snapshot: F.session("a"))
        m.register(page)
        #expect(page.openLane == "task-1", "applied when the page comes up")
        m.openTeammate("task-2", in: a)
        #expect(page.openLane == "task-2", "page already up: at once")
        let other = ConversationPageModel(snapshot: F.session("b"))
        m.openTeammate("task-3", in: SessionID(rawValue: "b"))
        m.register(other)
        #expect(other.openLane == "task-3")
    }

    @Test func shownSessionChangesAreReportedOnce() {
        let (m, source) = model([F.session("a"), F.session("b")])
        let a = SessionID(rawValue: "a")
        m.windowVisible = true
        m.select(a)
        m.register(ConversationPageModel(snapshot: F.session("a")))
        m.windowKey = true
        m.windowOnScreen = false
        m.windowOnScreen = true
        m.showHome()
        let shown = source.calls.compactMap { if case .shown(let id) = $0 { id?.rawValue ?? "none" } else { nil } }
        #expect(shown == ["a", "none", "a", "none"])
    }

    @Test func continueOnlyForAnInterruptedSession() async {
        let (m, source) = model([F.session("cut", status: .interrupted(at: F.now)), F.session("idle")])
        await m.continueInterrupted(SessionID(rawValue: "idle"))
        #expect(source.calls.isEmpty)
        await m.continueInterrupted(SessionID(rawValue: "cut"))
        #expect(source.calls == [.handle(.action(SessionID(rawValue: "cut"), .continueInterrupted))])
    }

    /// QA U30: a page opened on a session whose teammates already exist (running, or reopened)
    /// had an empty roster, and Open lane opened nothing.
    @Test func aPageOpenedOnExistingTeammatesHasTheirRosterAndLanes() async {
        let mates = [TeammateSnapshot(id: "task0", toolUseID: "tool0", name: "Researcher", state: .done),
                     TeammateSnapshot(id: "task1", toolUseID: "tool1", name: "Writer", state: .working, liveLine: "Drafting")]
        let session = F.session("a", status: F.thinking(for: 5), teammates: mates)
        let (m, source) = model([session])
        source.lanes[session.id] = ["tool0": LaneHistory(texts: ["Found three sources.", "March is two invoices."]),
                                    "tool1": LaneHistory(texts: ["Drafting the note"])]
        let page = await m.makePage(for: session)
        #expect(page.page.teammates.map(\.name) == ["Researcher", "Writer"])
        let researcher = page.page.teammates[0]
        #expect(researcher.laneText.text.contains("March is two invoices."))
        #expect(researcher.laneText.isFinished)
        #expect(!page.page.teammates[1].laneText.isFinished, "a working teammate's lane keeps streaming")

        m.select(session.id)
        m.register(page)
        m.openTeammate("task0", in: session.id)
        #expect(page.openLane == "task0")
        #expect(page.page.teammates.contains { $0.id == page.openLane })
    }

    /// QA U7: a session opened mid-turn showed a running turn with no question, timed from 0:00.
    @Test func aPageOpenedMidTurnShowsTheQuestionAndTheRealClock() async throws {
        var session = F.session("a", status: F.thinking(for: 180))
        session.liveLine = "Reading Q3.numbers"
        let (m, source) = model([session])
        source.sent[session.id] = SentTurn(uuid: "u-2", shown: "Why did March jump?", kind: .typed, at: F.now.addingTimeInterval(-181))
        source.turns[session.id] = [TranscriptTurn(id: "u-1", question: "Hi", block: BuddyBlock(say: "Hello", shape: .rich),
                                                    mode: .deep, model: ModelID(rawValue: "x"), kind: .typed, markdown: "Hello")]
        let page = await m.makePage(for: session)
        let turn = try #require(page.page.turns.last)
        #expect(page.page.turns.count == 2)
        #expect(turn.question == "Why did March jump?" && turn.started && !turn.finished)
        #expect(abs(turn.trail.elapsed(at: F.now) - 180) < 1)
        #expect(page.page.liveLine(at: F.now) == "Reading Q3.numbers · 3:00")

        // Already in the transcript (it finished meanwhile), or not running: nothing is added.
        source.sent[session.id] = SentTurn(uuid: "u-1", shown: "Hi", kind: .typed, at: F.now)
        #expect(await m.makePage(for: session).page.turns.count == 1)
        session.status = .done(at: F.now, unread: false)
        source.sent[session.id] = SentTurn(uuid: "u-3", shown: "x", kind: .typed, at: F.now)
        #expect(await m.makePage(for: session).page.turns.count == 1)
    }

    @Test func aNewTeammateInAnUpdateGetsItsLaneSoFar() async {
        var session = F.session("a", status: F.thinking(for: 5))
        let (m, source) = model([session])
        let page = await m.makePage(for: session)
        #expect(page.page.teammates.isEmpty)
        source.lanes[session.id] = ["tool9": LaneHistory(texts: ["Checked the PO numbers."])]
        session.teammates = [TeammateSnapshot(id: "task9", toolUseID: "tool9", name: "Analyst", state: .done)]
        await m.update(page, with: session)
        #expect(page.page.teammates.first?.laneText.text == "Checked the PO numbers.")
    }

    @Test func homeHintNamesTheKeyWithoutPickerTags() {
        #expect(BuddyKey.rightOption.shortName == "Right ⌥")
        #expect(BuddyKey.leftCommand.shortName == "Left ⌘")
        #expect(BuddyKey.function.shortName == "Fn")
        #expect(BuddyKey.allCases.allSatisfy { !$0.shortName.contains("(") })
    }

    @Test func theInspectorHasNoEmptyTabs() {
        // QA S-05: Files and Context show only once the session has some.
        #expect(StudioInspector.tabs(SessionDetails()) == [.team, .details])
        let full = SessionDetails(files: [URL(fileURLWithPath: "/tmp/a.md")], contexts: [.init(id: "c", appName: "Numbers")])
        #expect(StudioInspector.tabs(full) == StudioModel.InspectorTab.allCases)
    }

    @Test func resumeCommandQuotesTheFolder() {
        #expect(SessionDetails().resumeCommand == nil)
        #expect(SessionDetails(claudeSessionID: "abc").resumeCommand == "claude --resume abc")
        #expect(SessionDetails(claudeSessionID: "abc", workingDirectory: "/Users/me/It's here").resumeCommand
            == "cd '/Users/me/It'\\''s here' && claude --resume abc")
    }
}

@MainActor
private final class FailingForget: StudioDataSource {
    struct Failure: Error {}
    var snapshots: [SessionSnapshot] { [] }
    func changes() -> AsyncStream<[SessionSnapshot]> { AsyncStream { $0.finish() } }
    func open(_ id: SessionID) async {}
    func setPinned(_ pinned: Bool, for id: SessionID) async {}
    func setArchived(_ archived: Bool, for id: SessionID) async {}
    func rename(_ id: SessionID, to title: String) async {}
    func forget(_ id: SessionID) async throws { throw Failure() }
    func startSession(text: String) async -> SessionID? { nil }
    func transcript(for id: SessionID) async -> [TranscriptTurn] { [] }
    func events(for id: SessionID) -> AsyncStream<SessionEvent> { AsyncStream { $0.finish() } }
    func handle(_ event: PanelEvent) async {}
    func details(for id: SessionID) async -> SessionDetails { SessionDetails() }
    func openPanel(_ id: SessionID) async {}
    func teammateLanes(for id: SessionID) async -> [String: LaneHistory] { [:] }
    func shownSessionChanged(from old: SessionID?, to new: SessionID?) {}
}
