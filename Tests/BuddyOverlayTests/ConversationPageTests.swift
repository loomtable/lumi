import BuddyCore
import Foundation
import Testing
@testable import BuddyOverlay

struct ConversationPageTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func page() -> ConversationPage { ConversationPage(session: SessionID(rawValue: "s_1"), title: "Fix login bug") }

    let ask = PermissionAsk(id: "p1", title: "Run swift test", toolName: "Bash", detail: .command("swift test"), tier: .needsClick)

    /// Owner, Oct 29: a Needs-you click opens the page, which shows the ask even when the page
    /// never saw it asked; one it already has (being answered) is left alone.
    @Test func aPageOpenedOnAWaitingSessionShowsItsAsk() {
        var p = page()
        let block = BuddyBlock(say: "On it.", shape: .chip)
        p.load(history: [TranscriptTurn(id: "u1", question: "Test it", block: block, mode: .quick, model: .haiku)], at: at(1))
        p.seed(ask: NeedsYou(kind: .permission(ask), since: at(2)), at: at(3))
        #expect(p.pendingApprovals.map(\.id) == ["p1"])
        #expect(!p.isRunning, "seeding an ask runs nothing")
        p.seed(ask: NeedsYou(kind: .permission(ask), since: at(2)), at: at(4))
        #expect(p.turns.flatMap(\.approvals).count == 1)
        let q = QuestionAsk(id: "q", items: [.init(question: "Which?", header: "W", options: [.init(label: "A")])])
        var empty = page()
        empty.seed(ask: NeedsYou(kind: .question(q), since: at(2)), at: at(3))
        #expect(empty.pendingQuestions.map(\.id) == ["q"])
        empty.seed(ask: NeedsYou(kind: .soft("Which?"), since: at(2)), at: at(3))
        #expect(empty.pendingQuestions.count == 1)
    }

    /// Inspire #2 and #5: 1 · 2 · 3 answer a focused card; an answered one is a one-line receipt.
    @Test func anApprovalAnswersByNumberAndLeavesAReceipt() throws {
        #expect(ApprovalCard.answer(forKey: "1").map { [$0.allow, $0.always] } == [true, false])
        #expect(ApprovalCard.answer(forKey: "2").map { [$0.allow, $0.always] } == [true, true])
        #expect(ApprovalCard.answer(forKey: "3").map { [$0.allow, $0.always] } == [false, false])
        #expect(ApprovalCard.answer(forKey: "4") == nil)
        var p = page()
        p.send("Test it", kind: .typed, context: nil, at: at(0))
        p.apply(.permissionRequested(ask), at: at(1))
        #expect(ApprovalCard.receipt(p.pendingApprovals[0]) == nil, "waiting: the card itself")
        p.resolveApproval("p1", allow: true, at: at(1.5))
        p.apply(.permissionResolved(id: "p1"), at: at(2))
        let done = try #require(p.turns.flatMap(\.approvals).first)
        #expect(done.state == .allowed && done.resolvedAt == at(2))
        #expect(ApprovalCard.receipt(done)?.hasPrefix("Allowed · swift test · ") == true)
    }

    @Test func aTypedTurnStreamsAsMarkdownAndNeverNeedsABuddyBlock() {
        var p = page()
        #expect(p.send("Why?", kind: .typed, context: nil, at: at(0)) == .turn(id: "turn-0"))
        #expect(p.isRunning)
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: at(0.1))
        p.apply(.text("Here:\n\n```swift\nlet a = 1\n```\n", subagent: nil), at: at(1))
        p.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Here:\n\n```swift\nlet a = 1\n```")), at: at(2))
        let turn = p.turns[0]
        #expect(turn.userUUID == "u1")
        #expect(turn.finished)
        #expect(!p.isRunning)
        #expect(turn.answer.frozen.map(\.kind) == [.paragraph, .code(language: "swift")])
    }

    @Test func aSendWhileRunningIsASteerInsideTheTrail() {
        var p = page()
        p.send("Fix it", kind: .typed, context: nil, at: at(0))
        p.apply(.step(TrailStep(id: "r", kind: .read, verb: "Reading", object: "a.swift")), at: at(1))
        #expect(p.send("Only the TTL", kind: .typed, context: nil, at: at(2)) == .steer)
        #expect(p.turns.count == 1)
        #expect(p.turns[0].trail.rows.last?.content == .steer("Only the TTL"))
        // The steer's own turnStarted doesn't open a turn.
        p.apply(.turnStarted(userUUID: "u2", kind: .steer), at: at(2.1))
        #expect(p.turns.count == 1)
    }

    @Test func approvalsArePendingUntilAnsweredAndCancelledWhenTheTurnEnds() {
        var p = page()
        p.send("Test it", kind: .typed, context: nil, at: at(0))
        p.apply(.permissionRequested(ask), at: at(1))
        #expect(p.pendingApprovals.map(\.id) == ["p1"])
        #expect(p.turns[0].trail.phase == .needsYou)
        p.resolveApproval("p1", allow: true, at: at(2))
        // Never cleared before the reply is written: "Sending…" until the engine resolves it.
        #expect(p.turns[0].approvals[0].state == .sending(allow: true))
        #expect(p.pendingApprovals.map(\.id) == ["p1"])
        #expect(p.turns[0].trail.phase == .needsYou)
        p.apply(.permissionResolved(id: "p1"), at: at(2.1))
        #expect(p.pendingApprovals.isEmpty)
        #expect(p.turns[0].approvals[0].state == .allowed)
        #expect(p.turns[0].trail.phase == .working)

        p.apply(.permissionRequested(PermissionAsk(id: "p2", title: "Run x", toolName: "Bash", detail: .command("x"), tier: .needsClick)), at: at(3))
        p.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "")), at: at(4))
        #expect(p.turns[0].approvals[1].state == .cancelled)
    }

    @Test func aTeammatesCardStaysAfterTheLeadsTurnEnds() {
        var p = page()
        p.send("Split", kind: .typed, context: nil, at: at(0))
        p.apply(.permissionRequested(PermissionAsk(id: "t", title: "Edit", toolName: "Edit", detail: .plain(""), tier: .reversible,
                                                   asker: "Analyst")), at: at(1))
        p.apply(.permissionRequested(ask), at: at(1))
        p.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Working on it.")), at: at(2))
        #expect(p.pendingApprovals.map(\.id) == ["t"])
    }

    @Test func anAnswerThatWasNotSentComesBack() {
        var p = page()
        p.send("Test it", kind: .typed, context: nil, at: at(0))
        p.apply(.permissionRequested(ask), at: at(1))
        p.resolveApproval("p1", allow: false, at: at(2))
        p.apply(.permissionRequested(ask), at: at(3))
        #expect(p.turns[0].approvals.count == 1)
        #expect(p.turns[0].approvals[0].state == .pending)
    }

    @Test func anApprovalResolvedElsewhereLeavesTheCard() {
        var p = page()
        p.send("Test it", kind: .typed, context: nil, at: at(0))
        p.apply(.permissionRequested(ask), at: at(1))
        p.apply(.permissionResolved(id: "p1"), at: at(2))
        #expect(p.pendingApprovals.isEmpty)
        #expect(p.turns[0].trail.phase == .working)
    }

    @Test func stopKeepsThePartialAnswer() {
        var p = page()
        p.send("Go", kind: .typed, context: nil, at: at(0))
        p.apply(.text("Half an", subagent: nil), at: at(1))
        p.stop(at: at(2))
        #expect(!p.isRunning)
        #expect(p.turns[0].trail.phase == .stopped)
        #expect(p.turns[0].answer.text == "Half an")
        // A late result doesn't revive the turn.
        p.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Half an answer")), at: at(3))
        #expect(p.turns[0].answer.text == "Half an")
    }

    @Test func teammatesTakeTheirNameFromTheAgentStepAndGetLanes() {
        var p = page()
        p.send("Split it", kind: .typed, context: nil, at: at(0))
        p.apply(.step(TrailStep(id: "tu1", kind: .agent, verb: "Starting", object: "Researcher")), at: at(1))
        // The mapper names it from the Agent call's input.
        p.apply(.task(.started(taskID: "t1", toolUseID: "tu1", name: "Researcher", description: "Pull March invoices", kind: .agent)), at: at(1))
        p.apply(.task(.started(taskID: "b1", toolUseID: "tu2", name: nil, description: "npm test", kind: .bash)), at: at(1))
        #expect(p.teammates.map(\.name) == ["Researcher"])
        #expect(p.teammates[0].glyph == "magnifyingglass")
        p.apply(.step(TrailStep(id: "x", kind: .read, verb: "Reading", object: "inv.pdf", subagent: "tu1")), at: at(2))
        p.apply(.text("Found 3", subagent: "tu1"), at: at(3))
        #expect(p.teammates[0].lane.rows.map(\.id) == ["x"])
        #expect(p.turns[0].trail.rows.map(\.id) == ["tu1"])
        p.apply(.task(.progress(taskID: "t1", lastTool: "Read", line: "Reading 4 sources")), at: at(4))
        #expect(p.teammates[0].liveLine == "Reading 4 sources")

        p.apply(.permissionRequested(PermissionAsk(id: "p", title: "Edit", toolName: "Edit", detail: .plain(""), tier: .reversible, asker: "Researcher")), at: at(5))
        #expect(p.teammates[0].state == .needsYou)
        p.resolveApproval("p", allow: true, at: at(6))
        p.apply(.permissionResolved(id: "p"), at: at(6.1))
        #expect(p.teammates[0].state == .working)

        p.apply(.task(.ended(taskID: "t1", status: .completed, summary: "3 findings")), at: at(7))
        #expect(p.teammates[0].state == .done)
        #expect(p.turns[0].trail.rows.last?.content == .handoff(name: "Researcher", summary: "3 findings"))
    }

    /// The owner (Oct 29): lanes "come and go". Three teammates interleaved with the lead's
    /// interim answers and the CLI's hand-back turns: every lane stays, in place, until the lead
    /// answers after the last one; a repeated notification adds no second handoff.
    @Test func lanesStayFromSpawnToTheMergedAnswer() {
        var p = page()
        p.send("Split it", kind: .typed, context: nil, at: at(0))
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: at(0))
        let names = ["Scout", "Analyst", "Writer"]
        for i in 0..<3 {
            p.apply(.task(.started(taskID: "t\(i)", toolUseID: "tu\(i)", name: names[i], description: "Part \(i)", kind: .agent)), at: at(2))
        }
        p.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Three teammates are on it.")), at: at(3))
        #expect(!p.isRunning && p.team.isLive, "the interim answer keeps the roster")
        p.apply(.step(TrailStep(id: "r1", kind: .read, verb: "Reading", object: "a.md", subagent: "tu2")), at: at(4))
        p.apply(.text("Drafting", subagent: "tu2"), at: at(4))
        p.apply(.task(.progress(taskID: "t1", lastTool: "Grep", line: "Searching for March", steps: 2)), at: at(5))
        p.apply(.task(.ended(taskID: "t0", status: .completed, summary: "3 findings")), at: at(6))
        p.apply(.task(.ended(taskID: "t0", status: .completed, summary: "3 findings")), at: at(6.5))
        p.apply(.turnStarted(userUUID: nil, kind: .typed), at: at(7))
        p.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Scout is done.")), at: at(8))
        #expect(p.team.isLive && p.teammates.map(\.name) == names)
        #expect(p.teammates.map(\.state) == [.done, .working, .working])
        #expect(p.teammates[1].liveLine == "Searching for March" && p.teammates[1].member.steps == 2)
        #expect(p.teammates[2].lane.rows.map(\.id) == ["r1"] && p.teammates[2].laneText.text == "Drafting")
        p.apply(.task(.ended(taskID: "t1", status: .completed, summary: "table")), at: at(9))
        p.apply(.task(.ended(taskID: "t2", status: .failed, summary: nil)), at: at(9))
        #expect(p.team.isLive, "folds after the answer, not before")
        p.apply(.turnStarted(userUUID: nil, kind: .typed), at: at(10))
        p.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Here's the note.")), at: at(12))
        #expect(!p.team.isLive)
        #expect(p.teammates.count == 3 && p.teammates[2].laneText.text == "Drafting", "the work stays readable")
        let handoffs = p.turns.flatMap(\.trail.rows).filter { if case .handoff = $0.content { true } else { false } }
        #expect(handoffs.count == 2, "one per completed teammate, none for the repeat")
    }

    @Test func teammateNamesFallBack() {
        var p = page()
        p.send("Split", kind: .typed, context: nil, at: at(0))
        p.apply(.task(.started(taskID: "t1", toolUseID: nil, name: "Analyst", description: "x y", kind: .agent)), at: at(1))
        p.apply(.task(.started(taskID: "t2", toolUseID: nil, name: nil, description: "reviewer", kind: .agent)), at: at(1))
        p.apply(.task(.started(taskID: "t3", toolUseID: nil, name: nil, description: "do many things", kind: .agent)), at: at(1))
        #expect(p.teammates.map(\.name) == ["Analyst", "Reviewer", "Teammate 3"])
    }

    @Test func eventsWithNoSentTurnOpenOne() {
        var p = page()
        p.apply(.turnStarted(userUUID: nil, kind: .typed), at: at(0))
        p.apply(.text("A teammate finished.", subagent: nil), at: at(1))
        #expect(p.turns.count == 1)
        #expect(p.turns[0].question.isEmpty)
    }

    @Test func voiceTurnsDropTheBuddyFence() {
        var p = page()
        p.send("What is it?", kind: .voice, context: nil, at: at(0))
        let md = "It's a token bug.\n\n```buddy\n{\"say\":\"A token bug.\"}\n```"
        p.apply(.turnEnded(TurnEnd(kind: .voice, markdown: md)), at: at(1))
        #expect(p.turns[0].answer.text == "It's a token bug.")
        #expect(ConversationPage.strippingBuddyFence("```buddy\n{}\n```", fallback: "Said") == "Said")
    }

    @Test func planTileFollowsTodoWrite() {
        var p = page()
        p.send("Plan", kind: .typed, context: nil, at: at(0))
        let todos = [StepDetail.Todo(content: "Read", state: .completed), .init(content: "Fix", state: .inProgress)]
        p.apply(.step(TrailStep(id: "t", kind: .plan, verb: "Updating the plan", detail: .todos(todos))), at: at(1))
        #expect(p.turns[0].plan == todos)
    }

    @Test func historyLoadsFinishedTurns() {
        var p = page()
        let block = BuddyBlock(say: "It's March.", shape: .card, cardHTML: "<p>Two invoices.</p>")
        p.load(history: [TranscriptTurn(id: "h1", question: "Why?", block: block, mode: .quick, model: .haiku)], at: at(0))
        #expect(p.turns.count == 1)
        #expect(p.turns[0].finished)
        #expect(p.turns[0].answer.text == "It's March.\n\nTwo invoices.")
        #expect(p.send("And April?", kind: .typed, context: nil, at: at(1)) == .turn(id: "turn-1"))
    }

    @Test func aReopenedTypedTurnShowsItsWholeMarkdown() {
        // QA U1: typed turns keep only their first line in `block`.
        var p = page()
        let md = "The TTL was 60 s.\n\n```swift\nlet ttl = 3600\n```\n\nTests pass now."
        let typed = TranscriptTurn(id: "t", question: "Fix it", block: BuddyBlock(say: "The TTL was 60 s.", shape: .chip),
                                   mode: .deep, model: .opus, kind: .typed, markdown: md, teammates: ["Reviewer"])
        let voice = TranscriptTurn(id: "v", question: "Why?", block: BuddyBlock(say: "A token bug.", shape: .chip),
                                   mode: .deep, model: .opus, kind: .voice, markdown: "It's a token bug.\n\n```buddy\n{}\n```")
        p.load(history: [typed, voice], at: at(0))
        #expect(p.turns[0].answer.text == md)
        #expect(p.turns[0].answer.frozen.map(\.kind) == [.paragraph, .code(language: "swift"), .paragraph])
        #expect(p.turns[0].fromHistory)
        #expect(p.turns[0].historyTeammates == ["Reviewer"])
        #expect(p.turns[1].answer.text == "It's a token bug.")
    }

    @Test func contextStripCopy() {
        var packet = ContextPacket(askedAt: t0, utterance: "")
        packet.app = .init(name: "Numbers", bundle: "com.apple.Numbers", kind: .other)
        packet.window = .init(title: "Q3 budget", document: "/d/Q3 budget.numbers")
        let strip = ContextStrip.from(packet)
        #expect(strip.headline == "Read from Numbers")
        #expect(strip.subline == "Q3 budget")
        #expect(ContextStrip.from(packet, withScreen: false).headline == nil)
        #expect(ContextStrip.from(nil).headline == nil)
    }

    @Test func diffCountsAndPreview() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        var lines = (1...20).map { "line \($0)" }
        lines[9] = "LINE 10"
        lines.insert("new", at: 15)
        let d = DiffModel(path: "/r/a.txt", old: old, new: lines.joined(separator: "\n"))
        #expect(d.counts == "+2 −1")
        let rows = d.preview()
        #expect(rows.first == .line(.init(kind: .context, text: "line 7")))
        #expect(rows.contains(.gap) == false)
        #expect(rows.filter { if case .line(let l) = $0 { l.kind != .context } else { false } }.count == 3)

        let created = DiffModel(path: nil, old: "", new: "a\nb")
        #expect(created.counts == "+2 −0")
        #expect(DiffModel(.command(description: nil, command: "ls")) == nil)
    }

    @Test func diffPreviewStopsAfterEightChangedLines() {
        let old = (1...30).map { "l\($0)" }
        let new = old.map { $0 + "!" }
        let rows = DiffModel(path: nil, old: old.joined(separator: "\n"), new: new.joined(separator: "\n")).preview()
        let changed = rows.filter { if case .line(let l) = $0 { l.kind != .context } else { false } }
        #expect(changed.count == 8)
        #expect(rows.last == .gap)
    }
}
