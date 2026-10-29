@testable import BuddyApp
import BuddyCompanion
import BuddyConversations
import BuddyCore
import Foundation
import Testing

@MainActor
struct LiveConversationsTests {
    private func live(_ index: ConversationIndex? = nil, clock: ManualConversationClock = ManualConversationClock(),
                      reader: TranscriptReader? = nil) throws -> LiveConversations {
        let manager = ConversationManager(index: try index ?? ConversationIndex(url: nil), sessionFiles: FakeSessionFiles(),
                                          screenshotDirectory: FileManager.default.temporaryDirectory, clock: clock)
        return LiveConversations(manager: manager, reader: reader)
    }

    private func shown(_ question: String, _ say: String) -> TranscriptTurn {
        TranscriptTurn(question: question, block: BuddyBlock(say: say, shape: .chip), mode: .quick, model: .haiku)
    }

    private func done(_ turn: ConversationTurn, quick: String) -> ConversationState {
        var state = turn.state
        state.quickSessionID = quick
        state.lastLane = .quick
        return state
    }

    @Test func aTurnIsSavedWithItsSessionAndFollowUpsContinue() async throws {
        let c = try live()
        let first = await c.prepare(project: nil)
        #expect(first.turn == 0 && first.previous.isEmpty)
        await c.update(done(first, quick: "q1"))
        let after = await c.recordTurn(conversationID: first.state.id, question: "why is this list empty?", answer: "The filter.")
        #expect(after?.turn == 1 && after?.previous == ["Q: why is this list empty?\nA: The filter."])
        let saved = try await c.manager.list()
        #expect(saved.map(\.title) == ["why is this list empty?"] && saved.first?.quickSessionID == "q1")

        let next = await c.prepare(project: nil)
        #expect(next.state.id == first.state.id && next.state.quickSessionID == "q1", "continues, with its session")
        #expect(next.turn == 1 && next.previous.count == 1)
    }

    private func saved(_ c: LiveConversations, _ question: String) async -> ConversationTurn {
        let turn = await c.prepare(project: nil)
        await c.update(done(turn, quick: "q-\(question.count)"))
        _ = await c.recordTurn(conversationID: turn.state.id, question: question, answer: "Done.")
        return turn
    }

    @Test func aNewConversationTakesTheNextQuestionAndTheOldOneCanBePicked() async throws {
        let c = try live()
        let old = await saved(c, "refund flow")
        let fresh = await c.startNew()
        #expect(await c.prepare(project: nil).state.id == fresh.state.id)
        let picked = await c.switchTo(old.state.id)
        #expect(picked?.state.id == old.state.id && picked?.state.quickSessionID == "q-11")
        #expect(await c.prepare(project: nil).state.id == old.state.id, "the next question continues the picked one")
    }

    @Test func afterTheIdleLimitTheNextQuestionStartsFresh() async throws {
        let clock = ManualConversationClock()
        let c = try live(clock: clock)
        let old = await saved(c, "heat pumps")
        clock.advance(26 * 3600)
        let fresh = await c.prepare(project: nil)
        #expect(fresh.state.id != old.state.id)
        #expect(await c.switchTo(old.state.id)?.state.id == old.state.id, "still there to pick")
    }

    @Test func theQuestionCanArriveBeforeTheSessionIDs() async throws {
        let c = try live()
        let turn = await c.prepare(project: nil)
        _ = await c.recordTurn(conversationID: turn.state.id, question: "catch me up", answer: "Two things.")
        #expect(try await c.manager.list().isEmpty, "waits for the session ids")
        await c.update(done(turn, quick: "q1"))
        #expect(try await c.manager.list().map(\.quickSessionID) == ["q1"])
    }

    @Test func aTurnWhoseAnswerWasNeverShownStillKeepsItsSession() async throws {
        let c = try live()
        let turn = await c.prepare(project: nil)
        await c.update(done(turn, quick: "q-stale"))
        let fresh = await c.startNew()
        #expect(fresh.state.id != turn.state.id && fresh.turn == 0)
        let saved = try await c.manager.list()
        #expect(saved.map(\.quickSessionID) == ["q-stale"], "Forget and resume can still find it")
    }

    @Test func aConversationResumesAfterRelaunchWithItsSessions() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "live-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "index.sqlite")
        let before = try live(try ConversationIndex(url: url))
        let turn = await before.prepare(project: nil)
        await before.update(done(turn, quick: "q1"))
        _ = await before.recordTurn(conversationID: turn.state.id, question: "draw it", answer: "Here.")

        let after = try live(try ConversationIndex(url: url))
        _ = await after.switchTo(turn.state.id)
        #expect(after.current?.state.id == turn.state.id && after.current?.state.quickSessionID == "q1")
        #expect(after.current?.turn == 1)
        let next = await after.prepare(project: nil)
        #expect(next.state.id == turn.state.id, "the next question continues the resumed one")
    }

    @Test func callsTakeEffectInTheOrderTheyAreMade() async throws {
        let c = try live()
        let first = await c.prepare(project: nil)
        // A turn whose answer wasn't shown: ⌘N first saves it, suspending before it switches.
        await c.update(done(first, quick: "q1"))
        // ⌘N starts and suspends in the index; the question is asked before it finishes.
        let fresh = Task { @MainActor in await c.startNew() }
        await Task.yield()
        let q = await c.prepare(project: nil)
        let n = await fresh.value
        #expect(n.state.id != first.state.id)
        #expect(q.state.id == n.state.id, "the question lands in the new conversation")
        #expect(c.current?.state.id == n.state.id, "current is fresh once the call returns")
    }

    @Test func goingTemporarySavesWaitingTurnsFirstAndIgnoresLateOnes() async throws {
        let c = try live()
        let a = await c.prepare(project: nil)
        await c.update(done(a, quick: "q-a"))                 // answer not shown yet
        try await c.setTemporary(true)
        #expect(c.current == nil)
        // A's late question and ids must not land in the temporary index.
        _ = await c.recordTurn(conversationID: a.state.id, question: "about A", answer: "…")
        await c.update(done(a, quick: "q-a2"))
        #expect(try await c.manager.list().isEmpty, "the temporary index has nothing from A")
        try await c.setTemporary(false)
        let saved = try await c.manager.list()
        #expect(saved.map(\.id) == [a.state.id] && saved.first?.quickSessionID == "q-a", "A was saved before the switch")
    }

    @Test func leavingTemporaryModeSavesNothingFromIt() async throws {
        let c = try live()
        try await c.setTemporary(true)
        let t = await c.prepare(project: nil)
        await c.update(done(t, quick: "q-temp"))               // a temporary turn still waiting
        try await c.setTemporary(false)
        _ = await c.recordTurn(conversationID: t.state.id, question: "secret", answer: "…")
        _ = await c.prepare(project: nil)
        #expect(try await c.manager.list().isEmpty, "nothing from temporary mode reaches disk")
    }

    @Test func aQuestionThatArrivesAfterItsTurnWasSavedBecomesTheTitle() async throws {
        let c = try live()
        let a = await c.prepare(project: nil)
        await c.update(done(a, quick: "q-a"))
        _ = await c.startNew()                                  // saves A as "Untitled"
        #expect(try await c.manager.list().first?.title == "Untitled")
        _ = await c.recordTurn(conversationID: a.state.id, question: "why is this list empty?", answer: "…")
        let titles = try await c.manager.list().map(\.title)
        #expect(titles.contains("why is this list empty?") && !titles.contains("Untitled"))
    }

    @Test func recordedTurnsReachFullScreen() async throws {
        let c = try live()
        let a = await c.prepare(project: nil)
        await c.update(done(a, quick: "q1"))
        let first = await c.record(shown("one", "1"), conversationID: a.state.id)
        #expect(first?.turns.map(\.question) == ["one"], "the override is used, not the port's default")
        _ = await c.prepare(project: nil)
        await c.update(done(a, quick: "q1"))
        _ = await c.record(shown("two", "2"), conversationID: a.state.id)
        #expect(c.current?.turns.map(\.question) == ["one", "two"])
        #expect(try await c.manager.list().first?.turns == 2, "and the turn is still saved")
    }

    @Test func afterARelaunchAResumedConversationGetsItsEarlierTurns() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "live-transcript-\(UUID().uuidString)")
        let projects = dir.appending(path: "claude/projects/-Users-me")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let indexURL = dir.appending(path: "index.sqlite")
        let quick = UUID().uuidString
        let before = try live(try ConversationIndex(url: indexURL))
        let a = await before.prepare(project: nil)
        await before.update(done(a, quick: quick))
        _ = await before.record(shown("why is this list empty?", "Your filter."), conversationID: a.state.id)
        // What Claude Code wrote for that turn.
        let s = TranscriptReaderTests.Session()
        s.prompt("why is this list empty?", at: 1)
        s.answer("Your filter.", id: "a1")
        try s.write(to: projects, id: quick)

        let after = try live(try ConversationIndex(url: indexURL), reader: TranscriptReader(root: dir.appending(path: "claude")))
        _ = await after.switchTo(a.state.id)
        #expect(after.current?.state.id == a.state.id)
        for _ in 0..<200 where after.current?.turns.isEmpty != false { try await Task.sleep(for: .milliseconds(5)) }
        #expect(after.current?.turns.map(\.question) == ["why is this list empty?"])
        #expect(after.current?.turns.first?.block.say == "Your filter.")
        let next = await after.prepare(project: nil)
        #expect(next.turns.count == 1, "the next question keeps them")
    }

    @Test func aConversationFromBeforeATemporaryRoundTripStillRecords() async throws {
        let c = try live()
        let a = await c.prepare(project: nil)
        await c.update(done(a, quick: "q1"))
        _ = await c.record(shown("one", "1"), conversationID: a.state.id)
        try await c.setTemporary(true)
        try await c.setTemporary(false)
        _ = await c.switchTo(a.state.id)
        _ = await c.prepare(project: nil)
        await c.update(done(a, quick: "q1"))
        let after = await c.record(shown("two", "2"), conversationID: a.state.id)
        #expect(after != nil && after?.turns.last?.question == "two", "not ignored as the other index's")
    }
}

/// Screenshots and Forget (Studio forgets through the session store, which calls the manager).
@MainActor
struct LiveConversationsForgetTests {
    let files = FakeSessionFiles()

    private func live() throws -> LiveConversations {
        let manager = ConversationManager(index: try ConversationIndex(url: nil), sessionFiles: files,
                                          screenshotDirectory: FileManager.default.temporaryDirectory,
                                          clock: ManualConversationClock())
        return LiveConversations(manager: manager, reader: nil)
    }

    private func saved(_ c: LiveConversations, _ question: String) async -> ConversationTurn {
        let turn = await c.prepare(project: nil)
        var state = turn.state
        state.quickSessionID = "q-\(question.count)"
        state.lastLane = .quick
        await c.update(state)
        _ = await c.recordTurn(conversationID: turn.state.id, question: question, answer: "Done.")
        return turn
    }

    @Test func aScreenshotArrivingAfterForgetIsDeleted() async throws {
        let c = try live()
        let turn = await saved(c, "refund flow")
        let request = try #require(try await c.manager.prepareForget(turn.state.id))
        _ = try await c.manager.forget(request)
        let shot = FileManager.default.temporaryDirectory.appending(path: "late-\(UUID().uuidString).png")
        try Data([1]).write(to: shot)
        defer { try? FileManager.default.removeItem(at: shot) }
        await c.recordScreenshot(shot.path, conversationID: turn.state.id)
        #expect(!FileManager.default.fileExists(atPath: shot.path))
    }

    @Test func aTurnsScreenshotIsCountedForForget() async throws {
        let c = try live()
        let turn = await c.prepare(project: nil)
        await c.recordScreenshot("/tmp/shot-1.png", conversationID: turn.state.id)   // before its first save
        var state = turn.state
        state.quickSessionID = "q1"
        await c.update(state)
        _ = await c.recordTurn(conversationID: turn.state.id, question: "what's this?", answer: "A chart.")
        #expect(try await c.manager.prepareForget(turn.state.id)?.screenshotCount == 1)
    }
}
