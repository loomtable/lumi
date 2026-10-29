import BuddyCore
import Foundation
import Testing
@testable import BuddyConversations

@Suite("SessionActivity")
struct SessionActivityTests {
    let end = TurnEnd(kind: .voice, markdown: "Done.", block: BuddyBlock(say: "Done.", shape: .chip))

    @Test func aVoiceTurnClearsTheVoiceRulesUnlessItCompacted() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: nil, kind: .voice), at: t0, onScreen: false)
        #expect(a.apply(.turnEnded(end), at: t0.addingTimeInterval(4), onScreen: false).contains(.voiceRules(needed: false)))
        #expect(a.ranFor == 4)
        _ = a.apply(.turnStarted(userUUID: nil, kind: .voice), at: t0, onScreen: false)
        #expect(a.apply(.compacted, at: t0, onScreen: false) == [.voiceRules(needed: true)])
        #expect(!a.apply(.turnEnded(end), at: t0, onScreen: false).contains(.voiceRules(needed: false)))
        var typed = SessionActivity()
        _ = typed.apply(.turnStarted(userUUID: nil, kind: .typed), at: t0, onScreen: false)
        #expect(!typed.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "x")), at: t0, onScreen: false)
            .contains { if case .voiceRules = $0 { true } else { false } })
    }

    @Test func onScreenAnswersAreSeenAndAsksUserIsASoftNeedsYou() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: nil, kind: .typed), at: t0, onScreen: true)
        #expect(a.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "x")), at: t0, onScreen: true).contains(.status(.idle)))
        #expect(a.status == .done(at: t0, unread: false))
        _ = a.apply(.turnStarted(userUUID: nil, kind: .voice), at: t0, onScreen: false)
        let asks = TurnEnd(kind: .voice, markdown: "", block: BuddyBlock(say: "Which one?", shape: .chip, asksUser: "Which one?"))
        _ = a.apply(.turnEnded(asks), at: t0, onScreen: false)
        guard case .needsYou(let n) = a.status, case .soft("Which one?") = n.kind else { Issue.record("soft"); return }
    }

    @Test func runningAfterTheTurnEndedIsNotThinking() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: nil, kind: .typed), at: t0, onScreen: false)
        _ = a.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "x")), at: t0, onScreen: false)
        _ = a.apply(.runState(.running), at: t0, onScreen: false)
        #expect(a.status == .done(at: t0, unread: true))
    }

    @Test func aCrashMidTurnAndARejectedRateLimitFail() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: nil, kind: .typed), at: t0, onScreen: false)
        _ = a.apply(.step(TrailStep(id: "1", kind: .bash, verb: "Running", object: "tests")), at: t0, onScreen: false)
        #expect(a.apply(.processEnded(status: 9, midTurn: true), at: t0, onScreen: false) == [.status(.failed)])
        guard case .failed(let f) = a.status else { Issue.record("failed"); return }
        #expect(f.reason == .crashed && f.lastStep == "Running tests")
        // A process ending between turns is a suspend, not a failure.
        var idle = SessionActivity()
        #expect(idle.apply(.processEnded(status: 0, midTurn: false), at: t0, onScreen: false).isEmpty)
        var limited = SessionActivity()
        _ = limited.apply(.turnStarted(userUUID: nil, kind: .typed), at: t0, onScreen: false)
        _ = limited.apply(.rateLimit(status: "rejected", resetsAt: t0), at: t0, onScreen: false)
        guard case .failed(let r) = limited.status, case .rateLimited = r.reason else { Issue.record("rate limited"); return }
    }

    @Test func twoAsksQueueAndTheSecondShowsWhenTheFirstIsAnswered() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: nil, kind: .typed), at: t0, onScreen: false)
        let one = PermissionAsk(id: "1", title: "Run a", toolName: "Bash", detail: .command("a"), tier: .needsClick)
        let two = PermissionAsk(id: "2", title: "Run b", toolName: "Bash", detail: .command("b"), tier: .needsClick)
        _ = a.apply(.permissionRequested(one), at: t0, onScreen: false)
        _ = a.apply(.permissionRequested(two), at: t0, onScreen: false)
        _ = a.apply(.permissionResolved(id: "1"), at: t0, onScreen: false)
        guard case .needsYou(let n) = a.status, case .permission(two) = n.kind else { Issue.record("second ask"); return }
        _ = a.apply(.permissionResolved(id: "2"), at: t0, onScreen: false)
        guard case .thinking = a.status else { Issue.record("thinking"); return }
    }
}

/// QA R9: a background teammate's ask outlives the lead's turn.
@Suite("SessionActivity teammate asks")
struct SessionActivityTeammateAskTests {
    let lead = PermissionAsk(id: "r0", title: "Edit a.md", toolName: "Edit", detail: .plain("x"), tier: .reversible)
    let scout = PermissionAsk(id: "r1", title: "Run npm test", toolName: "Bash", detail: .plain("npm test"), tier: .needsClick,
                              asker: "scout")
    let end = TurnEnd(kind: .typed, markdown: "Done.")

    @Test func aTeammatesAskStaysNeedsYouPastTheTurnAndTheLeadsDoesNot() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0, onScreen: false)
        _ = a.apply(.permissionRequested(lead), at: t0, onScreen: false)
        _ = a.apply(.permissionRequested(scout), at: t0, onScreen: false)
        let effects = a.apply(.turnEnded(end), at: t0.addingTimeInterval(5), onScreen: false)
        #expect(effects.contains(.finishTurn(answerPreview: "Done.")), "the turn itself still finished")
        guard case .needsYou(let n) = a.status, case .permission(scout) = n.kind else { Issue.record("scout's ask, not \(a.status)"); return }
        _ = a.apply(.permissionResolved(id: "r1"), at: t0.addingTimeInterval(9), onScreen: false)
        #expect(a.status == .done(at: t0.addingTimeInterval(5), unread: true), "back to how the turn ended")
    }

    @Test func aWaitingTeammateAskShowsAgainWhenTheNextTurnStarts() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0, onScreen: false)
        _ = a.apply(.permissionRequested(scout), at: t0, onScreen: false)
        _ = a.apply(.turnEnded(end), at: t0, onScreen: false)
        _ = a.apply(.turnStarted(userUUID: "u2", kind: .typed), at: t0.addingTimeInterval(20), onScreen: false)
        guard case .needsYou(let n) = a.status, case .permission(scout) = n.kind else { Issue.record("still waiting"); return }
        _ = a.apply(.permissionResolved(id: "r1"), at: t0.addingTimeInterval(21), onScreen: false)
        guard case .thinking = a.status else { Issue.record("thinking, not \(a.status)"); return }
    }
}

/// The owner (Oct 29): teammate lanes came and went between the lead's answers.
@Suite("SessionActivity team")
struct SessionActivityTeamTests {
    let start = SessionEvent.task(.started(taskID: "t1", toolUseID: "tu1", name: "Scout", description: "Read", kind: .agent))

    @Test func theTeamStaysLiveThroughTheInterimAnswerAndFoldsAfterTheMergedOne() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0, onScreen: false)
        _ = a.apply(start, at: t0, onScreen: false)
        _ = a.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Scout is on it.")), at: t0.addingTimeInterval(2), onScreen: false)
        #expect(a.team.isLive && a.teammates.map(\.state) == [.working])
        // A teammate's own step is on its lane, not the session's line.
        _ = a.apply(.step(TrailStep(id: "r1", kind: .read, verb: "Reading", object: "a.md", subagent: "tu1")), at: t0.addingTimeInterval(3),
                    onScreen: false)
        #expect(a.liveLine == nil)
        _ = a.apply(.task(.ended(taskID: "t1", status: .completed, summary: "ok")), at: t0.addingTimeInterval(9), onScreen: false)
        #expect(a.team.isLive, "until the lead answers")
        _ = a.apply(.turnStarted(userUUID: nil, kind: .typed), at: t0.addingTimeInterval(9), onScreen: false)
        _ = a.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Scout found it.")), at: t0.addingTimeInterval(11), onScreen: false)
        #expect(!a.team.isLive && a.teammates.map(\.state) == [.done])
    }

    @Test func aTeammatesAskMarksItNeedsYou() {
        var a = SessionActivity()
        _ = a.apply(start, at: t0, onScreen: false)
        let ask = PermissionAsk(id: "r1", title: "Run", toolName: "Bash", detail: .plain("x"), tier: .needsClick, asker: "Scout")
        _ = a.apply(.permissionRequested(ask), at: t0, onScreen: false)
        #expect(a.teammates.first?.state == .needsYou)
        _ = a.apply(.permissionResolved(id: "r1"), at: t0, onScreen: false)
        #expect(a.teammates.first?.state == .working)
    }

    /// An edited prompt: a team that started in the dropped turns goes; an earlier one stays.
    @Test func anEditDropsOnlyATeamFromTheDroppedTurns() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0, onScreen: false)
        _ = a.apply(start, at: t0.addingTimeInterval(1), onScreen: false)
        a.dropTeam(startedSince: t0.addingTimeInterval(5))
        #expect(a.teammates.count == 1, "the team started before the edited prompt")
        a.dropTeam(startedSince: t0)
        #expect(a.teammates.isEmpty && !a.team.isLive)
    }
}

/// The owner (Oct 29): a running indicator only while something runs, and a Needs-you that clears
/// once seen, answered or gone.
@Suite("SessionActivity running and seen")
struct SessionActivityRunningTests {
    let start = SessionEvent.task(.started(taskID: "t1", toolUseID: "tu1", name: "Scout", description: "Read", kind: .agent))
    let scout = PermissionAsk(id: "r1", title: "Run npm test", toolName: "Bash", detail: .plain("npm test"), tier: .needsClick,
                              asker: "Scout")

    /// An answer's `asks_user` and a team that handed back were shown as running forever.
    @Test func nothingRunsAfterAnAsksUserAnswerOrATeamThatHandedBack() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0, onScreen: false)
        #expect(a.status.turnRunning)
        _ = a.apply(start, at: t0, onScreen: false)
        let asks = TurnEnd(kind: .voice, markdown: "", block: BuddyBlock(say: "Which?", shape: .chip, asksUser: "Which?"))
        _ = a.apply(.turnEnded(asks), at: t0, onScreen: false)
        _ = a.apply(.task(.ended(taskID: "t1", status: .completed, summary: "ok")), at: t0, onScreen: false)
        #expect(!a.status.turnRunning)
        #expect(a.team.isLive && !a.team.isWorking, "the team waits for the lead's answer, but nothing runs")
        let s = SessionSnapshot(id: SessionID(rawValue: "s"), title: "s", color: .ember, harness: .open, status: a.status,
                                teammates: a.teammates, teamLive: a.team.isLive, lastUsed: t0)
        #expect(!s.isRunning)
        #expect(s.needsAttention, "the question still asks for attention until it's seen")
    }

    @Test func seeingAnAskAcknowledgesItAndSeeingAnAsksUserClearsIt() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0, onScreen: false)
        _ = a.apply(.permissionRequested(scout), at: t0, onScreen: false)
        #expect(a.markSeen().isEmpty)
        guard case .needsYou(let n) = a.status else { Issue.record("still waits"); return }
        #expect(n.seen)
        _ = a.apply(.permissionResolved(id: "r1"), at: t0, onScreen: false)
        let asks = TurnEnd(kind: .voice, markdown: "", block: BuddyBlock(say: "Which?", shape: .chip, asksUser: "Which?"))
        _ = a.apply(.turnEnded(asks), at: t0.addingTimeInterval(3), onScreen: false)
        #expect(a.markSeen() == [.status(.idle)])
        #expect(a.status == .done(at: t0.addingTimeInterval(3), unread: false))
    }

    @Test func anAskOnScreenArrivesSeen() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0, onScreen: true)
        _ = a.apply(.permissionRequested(scout), at: t0, onScreen: true)
        guard case .needsYou(let n) = a.status else { Issue.record("waits"); return }
        #expect(n.seen)
    }

    /// An ask nobody can answer any more never stays amber: its teammate ended, or the process went.
    @Test func anAskWhoseTeammateEndedOrWhoseProcessDiedClears() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0, onScreen: false)
        _ = a.apply(start, at: t0, onScreen: false)
        _ = a.apply(.permissionRequested(scout), at: t0, onScreen: false)
        _ = a.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Scout is on it.")), at: t0.addingTimeInterval(2), onScreen: false)
        guard case .needsYou = a.status else { Issue.record("scout's ask waits"); return }
        _ = a.apply(.task(.ended(taskID: "t1", status: .stopped, summary: nil)), at: t0.addingTimeInterval(5), onScreen: false)
        #expect(a.status == .done(at: t0.addingTimeInterval(2), unread: true))

        var b = SessionActivity()
        _ = b.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0, onScreen: false)
        _ = b.apply(start, at: t0, onScreen: false)
        _ = b.apply(.permissionRequested(scout), at: t0, onScreen: false)
        _ = b.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Scout is on it.")), at: t0.addingTimeInterval(2), onScreen: false)
        _ = b.apply(.processEnded(status: 0, midTurn: false), at: t0.addingTimeInterval(5), onScreen: false)
        #expect(b.status == .done(at: t0.addingTimeInterval(2), unread: true))
    }

    /// A question runs from the moment it's sent; one that never started a turn goes back.
    @Test func aQuestionRunsFromSendAndOneThatNeverStartedGoesBack() {
        var a = SessionActivity(status: .done(at: t0, unread: true))
        a.queryBegan(line: "Looking at Safari", at: t0)
        #expect(a.status.turnRunning && a.liveLine == "Looking at Safari")
        a.queryLine("Searching the web for “QT”", at: t0)
        #expect(a.liveLine == "Searching the web for “QT”")
        a.queryEnded()
        #expect(!a.status.turnRunning && a.status == .done(at: t0, unread: true) && a.liveLine == nil)

        var b = SessionActivity()
        b.queryBegan(line: nil, at: t0)
        _ = b.apply(.turnStarted(userUUID: "u1", kind: .voice), at: t0, onScreen: false)
        b.queryEnded()
        #expect(b.status.turnRunning, "the session's own turn runs on until it ends")
    }

    @Test func aBashStepReadsAsTheTrailDoes() {
        var a = SessionActivity()
        _ = a.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0, onScreen: false)
        _ = a.apply(.step(TrailStep(id: "b", kind: .bash, verb: "Run the auth tests")), at: t0, onScreen: false)
        #expect(a.liveLine == "Running the auth tests")
    }
}
