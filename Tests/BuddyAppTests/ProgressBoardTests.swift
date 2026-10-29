import Foundation
import Synchronization
import Testing
@testable import BuddyApp
import BuddyBridge
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay

/// A `TurnPort` whose streams stay open until the test ends them.
private final class HeldTurns: TurnPort {
    private let open = Mutex<[AsyncStream<TurnStreamEvent>.Continuation]>([])
    private let cancelledIDs = Mutex<[String]>([])
    var count: Int { open.withLock { $0.count } }
    var cancelled: [String] { cancelledIDs.withLock { $0 } }

    func send(_ request: TurnRequest) async -> AsyncStream<TurnStreamEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TurnStreamEvent.self)
        open.withLock { $0.append(continuation) }
        return stream
    }

    func cancel(conversation: String) async { cancelledIDs.withLock { $0.append(conversation) } }

    func emit(_ event: TurnStreamEvent, turn: Int = 0) { open.withLock { $0[turn] }.yield(event) }
    func finish(turn: Int = 0) { open.withLock { $0[turn] }.finish() }
}

@MainActor
struct ProgressBoardTests {
    let overlay = FakeOverlay()
    let a = SessionID(rawValue: "s_a")
    let b = SessionID(rawValue: "s_b")

    func step(_ verb: String, _ object: String? = nil, subagent: String? = nil) -> TurnStreamEvent {
        .session(.step(TrailStep(id: UUID().uuidString, kind: .web, verb: verb, object: object, subagent: subagent)))
    }

    func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    // MARK: The board

    @Test func theQuestionOnThePillHasNoCapsuleUntilAnotherTakesThePill() {
        let board = ProgressBoard(overlay: overlay)
        var pill: Int? = 1
        board.pillEpoch = { pill }
        board.begin(session: a, question: "what's the weather in lisbon", line: "Looking at Safari", epoch: 1)
        #expect(overlay.progress.isEmpty, "the pill shows it")
        pill = nil // a new listen took the pill
        board.refresh()
        #expect(overlay.progress.rows.map(\.title) == ["what's the weather in"])
        #expect(overlay.progress.rows.map(\.line) == ["Looking at Safari"])
    }

    @Test func oneCapsulePerRunningQueryOldestFirstAndEachEndsWithItsAnswer() {
        let board = ProgressBoard(overlay: overlay)
        let first = board.begin(session: a, question: "trip", epoch: 1)
        let second = board.begin(session: b, question: "budget", epoch: 2)
        let third = board.begin(session: a, question: "repo", epoch: 3)
        #expect(overlay.progress.rows.map(\.id) == [first, second, third])
        board.event(.session(.turnEnded(TurnEnd(kind: .voice, markdown: "Done"))), query: second)
        #expect(overlay.progress.rows.map(\.id) == [first, third])
        board.event(.cascade(BuddyCoordinatorTests.done(nil)), query: first)
        board.end(third)
        #expect(overlay.progress.isEmpty)
    }

    /// A voice answer that finished behind waits its turn: its capsule says Ready until it plays.
    @Test func aReadyAnswersCapsuleSaysReadyUntilItPlays() {
        let board = ProgressBoard(overlay: overlay)
        let id = board.begin(session: a, question: "trip", epoch: 1)
        board.ready(id)
        #expect(overlay.progress.rows.map(\.line) == [ProgressBoard.readyLine])
        board.event(.cascade(BuddyCoordinatorTests.done(nil)), query: id)
        board.end(id)
        #expect(overlay.progress.rows.map(\.line) == ["Ready"], "the turn's own end leaves it")
        board.played(id)
        #expect(overlay.progress.isEmpty)
    }

    @Test func liveLinesComeFromRealEventsAndThinkingNeverHidesAStep() {
        let board = ProgressBoard(overlay: overlay)
        let q = board.begin(session: a, question: "qt", epoch: 1)
        #expect(overlay.progress.rows.first?.line == StatusMapper.thinking)
        board.event(step("Searching the web for", "“QT”"), query: q)
        #expect(overlay.progress.rows.first?.line == "Searching the web for “QT”")
        board.event(.cascade(.turn(lane: .quick, .status(StatusMapper.thinking))), query: q)
        #expect(overlay.progress.rows.first?.line == "Searching the web for “QT”")
        board.event(step("Reading", "notes.md", subagent: "helper"), query: q)
        #expect(overlay.progress.rows.first?.line == "Searching the web for “QT”", "a teammate's step isn't the lead's line")
    }

    @Test func aQuestionWaitingOnTheUserTurnsNeedsYouUntilItsAnswered() {
        let board = ProgressBoard(overlay: overlay)
        let q = board.begin(session: a, question: "clean up", epoch: 1)
        #expect(overlay.progress.rows.first?.session == a)
        board.event(.session(.permissionRequested(PermissionAsk(id: "r", title: "Run ls", toolName: "Bash",
                                                                 detail: .command("ls"), tier: .reversible))), query: q)
        #expect(overlay.progress.rows.first?.needsYou == true)
        #expect(overlay.progress.rows.first?.line == "Needs your OK")
        board.event(.session(.permissionResolved(id: "r")), query: q)
        #expect(overlay.progress.rows.first?.needsYou == false)
        board.event(.session(.questionAsked(QuestionAsk(id: "q", items: []))), query: q)
        #expect(overlay.progress.rows.first?.line == "Has a question")
    }

    @Test func aClickOnANeedsYouCapsuleOpensItsSession() async {
        let c = coordinator(HeldTurns())
        var opened: [SessionID] = []
        c.onOpenWaiting = { opened.append($0) }
        overlay.send(.progressClicked(b))
        await waitFor { !opened.isEmpty }
        #expect(opened == [b])
    }

    @Test func aTurnInAVisiblePageHasNoCapsuleUntilThePageIsHidden() {
        let board = ProgressBoard(overlay: overlay)
        var pages: [SessionID: PageKind] = [a: .panel]
        board.visiblePages = { pages }
        board.begin(session: a, question: "") // a composer turn
        #expect(overlay.progress.isEmpty)
        pages = [:]
        board.refresh()
        #expect(overlay.progress.rows.count == 1)
    }

    /// A page showing the session follows every turn in it, the Glance's voice turns too, so it
    /// already shows what the capsule would.
    @Test func aVoiceTurnInASessionAPageShowsHasNoCapsule() {
        let board = ProgressBoard(overlay: overlay)
        var pages: [SessionID: PageKind] = [a: .studio]
        board.visiblePages = { pages }
        board.begin(session: a, question: "fix this", epoch: 1)
        #expect(overlay.progress.isEmpty)
        pages = [:]
        board.refresh()
        #expect(overlay.progress.rows.count == 1)
    }

    // MARK: One source of truth (owner, Oct 29)

    /// The capsule shows its session's snapshot: only while its turn runs, with its live line and
    /// an ask the user hasn't seen. A seen ask still waits, without amber.
    @Test func aCapsuleShowsItsSessionsRunningStateLineAndUnseenAsk() {
        let board = ProgressBoard(overlay: overlay)
        var s = SessionSnapshot(id: a, title: "Q3", color: .ember, harness: .open, status: .done(at: .now, unread: false), lastUsed: .now)
        board.snapshot = { _ in s }
        board.begin(session: a, question: "split it", epoch: 1)
        #expect(overlay.progress.isEmpty, "the page shows nothing running: no capsule either")
        s.status = .thinking(since: .now, progress: nil)
        s.liveLine = "Reading budget.md"
        s.lastEventAt = Date(timeIntervalSince1970: 1_000)
        board.refresh()
        #expect(overlay.progress.rows.map(\.line) == ["Reading budget.md"])
        #expect(overlay.progress.rows.first?.lastEventAt == s.lastEventAt, "the capsule ages it once quiet (inspire #4)")
        let ask = PermissionAsk(id: "r", title: "Run ls", toolName: "Bash", detail: .command("ls"), tier: .reversible)
        s.status = .needsYou(NeedsYou(kind: .permission(ask), since: .now))
        board.refresh()
        #expect(overlay.progress.rows.first?.needsYou == true)
        #expect(overlay.progress.rows.first?.line == "Needs your OK")
        s.status = .needsYou(NeedsYou(kind: .permission(ask), since: .now, seen: true))
        board.refresh()
        #expect(overlay.progress.rows.first?.needsYou == false, "seen: no more amber")
        #expect(overlay.progress.rows.first?.line == "Reading budget.md")
    }

    /// A Quick turn has no session events: its question still makes the session run, with the
    /// capsule's own line, until it ends. One that never started a turn goes back to how it was.
    @Test func aQuestionRunsInItsSessionFromSendToEnd() async throws {
        let h = try LiveSessionsTests.Harness()
        let plan = await h.sessions.plan(SummonInput(source: .talkKey, kind: .voice, now: .now),
                                         packet: ContextPacket(askedAt: .now, utterance: "what's this"))
        let board = ProgressBoard(overlay: overlay)
        board.live = h.sessions
        board.snapshot = { id in h.sessions.snapshots.first { $0.id == id } }
        func snap() -> SessionSnapshot? { h.sessions.snapshots.first { $0.id == plan.id } }
        let before = snap()?.status
        let q = board.begin(session: plan.id, question: "what's this", line: "Looking at Safari", epoch: 1)
        #expect(snap()?.turnRunning == true)
        #expect(snap()?.liveLine == "Looking at Safari")
        board.event(.cascade(.turn(lane: .quick, .status("Searching the web for “QT”"))), query: q)
        #expect(snap()?.liveLine == "Searching the web for “QT”")
        #expect(overlay.progress.rows.first?.line == "Searching the web for “QT”")
        board.end(q)
        #expect(snap()?.turnRunning == false)
        #expect(snap()?.status == before)
        #expect(overlay.progress.isEmpty)
    }

    @Test func theSessionsTitleAndGlyphWinOverTheQuestionsWords() {
        let board = ProgressBoard(overlay: overlay)
        var title = "New session"
        board.snapshot = { id in
            SessionSnapshot(id: id, title: title, symbol: "airplane", color: .sage, harness: .open,
                            status: .thinking(since: .now, progress: nil), lastUsed: .now)
        }
        board.begin(session: a, question: "book me a flight to lisbon please", epoch: 1)
        #expect(overlay.progress.rows.first?.title == "book me a flight")
        #expect(overlay.progress.rows.first?.symbol == "airplane")
        title = "Lisbon trip"
        board.refresh()
        #expect(overlay.progress.rows.first?.title == "Lisbon trip")
        #expect(overlay.progress.rows.first?.color == .sage)
    }

    /// A query whose session runs teammates says how many still work ("· +2"); a teammate that
    /// handed back stops counting, and a team that's over shows nothing.
    @Test func aCapsuleCountsTheSessionsWorkingTeammates() {
        let board = ProgressBoard(overlay: overlay)
        var team = [TeammateSnapshot(id: "t1", toolUseID: "u1", name: "Scout", state: .working),
                    TeammateSnapshot(id: "t2", toolUseID: "u2", name: "Writer", state: .working)]
        var live = true
        board.snapshot = { id in
            SessionSnapshot(id: id, title: "Q3", color: .ember, harness: .open, status: .thinking(since: .now, progress: nil),
                            teammates: team, teamLive: live, lastUsed: .now)
        }
        board.begin(session: a, question: "split it")
        #expect(overlay.progress.rows.first?.teammatesNote == "+2")
        team[0].state = .done
        board.event(step("Reading", "a.md"), query: 1)
        #expect(overlay.progress.rows.first?.teammatesNote == "+1")
        team[1].state = .done
        live = false
        board.refresh()
        #expect(overlay.progress.rows.first?.teammatesNote == nil)
    }

    @Test func endingASessionsQuestionKeepsAPagesOwnTurn() {
        let board = ProgressBoard(overlay: overlay)
        board.begin(session: a, question: "one", epoch: 1)
        let page = board.begin(session: a, question: "")
        board.end(session: a)
        #expect(board.queries.keys.sorted() == [page])
    }

    @Test func linesForEvents() {
        #expect(ProgressBoard.line(for: .cascade(.turn(lane: .deep, .reconnecting(attempt: 1)))) == "Reconnecting…")
        #expect(ProgressBoard.line(for: .cascade(.handingOff(say: "Let me dig in."))) == "Going deeper")
        #expect(ProgressBoard.line(for: .session(.text("secret file contents", subagent: nil))) == nil, "never content")
        #expect(ProgressBoard.ends(.session(.processEnded(status: 1, midTurn: true))))
        #expect(!ProgressBoard.ends(.session(.runState(.idle))))
    }

    // MARK: The coordinator

    fileprivate func coordinator(_ turns: HeldTurns) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(settings: settings, voice: FakeVoice(), context: FakeContext.packet(), turns: turns,
                                 overlay: overlay, pointer: FixedPointer())
        c.start()
        return c
    }

    func ask(_ c: BuddyCoordinator) async {
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
    }

    @Test func aSpokenQuestionLeavingThePillGetsACapsuleUntilItsAnswer() async {
        let turns = HeldTurns()
        let c = coordinator(turns)
        await ask(c)
        await waitFor { turns.count == 1 }
        #expect(c.phase == .thinking)
        #expect(overlay.progress.isEmpty, "the pill is its capsule")
        // The pill goes while the turn keeps running (a page took it, the user moved on).
        c.phase = .idle
        #expect(overlay.progress.rows.count == 1)
        turns.emit(step("Searching the web for", "“QT”"))
        await waitFor { overlay.progress.rows.first?.line == "Searching the web for “QT”" }
        #expect(overlay.progress.rows.first?.line == "Searching the web for “QT”")
        turns.emit(.cascade(BuddyCoordinatorTests.done(nil)))
        await waitFor { overlay.progress.isEmpty }
        #expect(overlay.progress.isEmpty)
        turns.finish()
    }

    @Test func askingAgainOrEscWhileThinkingNeverFlashesACapsule() async {
        let turns = HeldTurns()
        let c = coordinator(turns)
        await ask(c)
        await waitFor { turns.count == 1 }
        // Asked again: the first question is cancelled, so it gets no capsule.
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await waitFor { !turns.cancelled.isEmpty }
        #expect(overlay.progress.isEmpty)
        await c.handle(.gesture(.holdEnded))
        await waitFor { turns.count == 2 }
        await c.escapePressed()
        #expect(c.phase == .idle)
        #expect(overlay.progress.isEmpty)
        turns.finish(turn: 0)
        turns.finish(turn: 1)
    }
}
