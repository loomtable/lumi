import BuddyCore
import Foundation
import Testing
@testable import BuddyBridge

/// Runs recorded fixtures through `SessionEventMapper` the way `SessionProcess` will: `beginTurn`
/// before each user line, `answered` once the host's reply is written (the CLI echoes it back
/// under --replay-user-messages, which stands in for "written" here).
enum MapperRun {
    static let probeDir = URL(fileURLWithPath: "/Users/me/probe")

    static func events(_ fixture: String, turns: [(TurnKind, String?)] = [], dirs: [URL] = [probeDir]) throws -> [SessionEvent] {
        var mapper = SessionEventMapper(sessionDirs: dirs)
        for (kind, uuid) in turns { mapper.beginTurn(kind: kind, userUUID: uuid) }
        return try Fixture.events(fixture).flatMap { e -> [SessionEvent] in
            if case .controlResponse(let id, _) = e, mapper.request(id) != nil { return mapper.answered(id) }
            return mapper.map(e)
        }
    }
}

extension Array where Element == SessionEvent {
    var turnsStarted: [(String?, TurnKind)] {
        compactMap { if case .turnStarted(let u, let k) = $0 { (u, k) } else { nil } }
    }
    var turnsEnded: [TurnEnd] { compactMap { if case .turnEnded(let t) = $0 { t } else { nil } } }
    var steps: [TrailStep] { compactMap { if case .step(let s) = $0 { s } else { nil } } }
    var tasks: [TaskEvent] { compactMap { if case .task(let t) = $0 { t } else { nil } } }
    var runStates: [RunState] { compactMap { if case .runState(let s) = $0 { s } else { nil } } }
}

struct MapperTests {
    let one = "11111111-1111-4111-8111-111111111111"
    let two = "22222222-2222-4222-8222-222222222222"

    @Test func aTypedTurnFromStartToEnd() throws {
        let events = try MapperRun.events("session-state.jsonl", turns: [(.typed, nil), (.typed, nil)])
        #expect(events.runStates == [.running, .idle, .running, .idle])
        // init repeats every turn with the same facts: reported once.
        #expect(events.filter { if case .initialized = $0 { true } else { false } }.count == 1)
        #expect(events.turnsStarted.map(\.1) == [.typed, .typed])
        #expect(events.turnsStarted.allSatisfy { $0.0 != nil })   // the CLI-minted echo uuid
        let read = try #require(events.steps.first)
        #expect(read.kind == .read && read.verb == "Reading" && read.object == "note.txt" && read.subagent == nil)
        #expect(events.contains { if case .stepFinished(read.id, false, let p) = $0 { p?.contains("hello from note") == true } else { false } })
        #expect(events.turnsEnded.map(\.markdown) == ["ok", "hello from note"])
        #expect(events.turnsEnded.allSatisfy { !$0.isError && $0.block == nil && ($0.contextTokens ?? 0) > 0 })
        // Typed turns never speak.
        #expect(!events.contains { if case .say = $0 { true } else { false } })
    }

    @Test func streamedTextMatchesTheAnswer() throws {
        let events = try MapperRun.events("session-state.jsonl")
        let text = SessionEvent.coalesce(events).compactMap { if case .text(let t, nil) = $0 { t } else { nil } }
        #expect(text == ["ok", "hello from note"])
    }

    @Test func permissionAskThenResolved() throws {
        let events = try MapperRun.events("can-use-tool.jsonl", turns: [(.typed, one)])
        let ask = try #require(events.compactMap { if case .permissionRequested(let a) = $0 { a } else { nil } }.first)
        #expect(ask.title == "Write note.txt")
        #expect(ask.toolName == "Write")
        #expect(ask.detail == .diff(path: "/Users/me/probe/note.txt", old: "", new: "hi\n"))
        #expect(ask.tier == .reversible)   // a write inside the session's folder
        #expect(ask.asker == nil)
        #expect(events.contains(.permissionResolved(id: ask.id)))
        #expect(events.turnsStarted.map(\.0) == [one])
        #expect(events.turnsEnded.map(\.markdown) == ["done"])
    }

    @Test func outsideTheSessionFolderNeedsAClick() throws {
        let events = try MapperRun.events("can-use-tool.jsonl", turns: [(.typed, one)], dirs: [URL(fileURLWithPath: "/Users/me/other")])
        let ask = try #require(events.compactMap { if case .permissionRequested(let a) = $0 { a } else { nil } }.first)
        #expect(ask.tier == .needsClick)
    }

    @Test func defaultToNoIsNeverVoiceApproved() {
        var mapper = SessionEventMapper(sessionDirs: [MapperRun.probeDir])
        let request: [String: Any] = ["subtype": "can_use_tool", "tool_name": "Read", "default_to_no": true,
                                      "input": ["file_path": "/Users/me/probe/a.txt"]]
        let events = mapper.map(.controlRequest(id: "r1", request: PermissionWire.parse(request)))
        guard case .permissionRequested(let ask)? = events.first else { Issue.record("no ask"); return }
        #expect(ask.tier == .needsClick)
    }

    @Test func bashAskShowsTheCommandAndCancelResolvesIt() throws {
        let events = try MapperRun.events("can-use-tool-cancel.jsonl", turns: [(.typed, nil)])
        let ask = try #require(events.compactMap { if case .permissionRequested(let a) = $0 { a } else { nil } }.first)
        // The CLI's description starts with its own verb: no "Run Run …" (QA E9).
        #expect(ask.title == "Create empty file made.txt in current directory")
        #expect(ask.detail == .command("touch made.txt"))
        #expect(ask.tier == .needsClick)
        #expect(events.contains(.permissionResolved(id: ask.id)))
        // The user's interrupt is no failure.
        let end = try #require(events.turnsEnded.first)
        #expect(!end.isError && end.error == nil)
    }

    @Test func askUserQuestionIsAQuestionNotAPermission() throws {
        let events = try MapperRun.events("can-use-tool-ask.jsonl", turns: [(.typed, nil)])
        let q = try #require(events.compactMap { if case .questionAsked(let q) = $0 { q } else { nil } }.first)
        #expect(q.items.map(\.question) == ["Tea or coffee?"])
        #expect(q.items.first?.header == "Drink")
        #expect(q.items.first?.options.map(\.label) == ["Tea", "Coffee"])
        #expect(!events.contains { if case .permissionRequested = $0 { true } else { false } })
        #expect(events.contains(.permissionResolved(id: q.id)))
        let step = try #require(events.steps.first { $0.kind == .ask })
        guard case .question(let detail)? = step.detail else { Issue.record("no question detail"); return }
        #expect(detail.items.first?.options.count == 2)
    }

    @Test func steerFoldsIntoTheOpenTurn() throws {
        let events = try MapperRun.events("replay-user.jsonl", turns: [(.typed, one), (.steer, two)])
        #expect(events.turnsStarted.map(\.0) == [one])
        #expect(events.turnsEnded.count == 1)
        #expect(events.turnsEnded.first?.markdown.hasSuffix("BANANA") == true)
        // Foreground Bash emits task events; it's no teammate or background job.
        #expect(events.tasks.isEmpty)
        let bash = try #require(events.steps.first)
        #expect(bash.kind == .bash)
        #expect(bash.detail == .command(description: "Sleep 8 seconds then echo one", command: "sleep 8; echo one"))
    }

    @Test func priorityNowEndsOneTurnAndStartsTheSteer() throws {
        let events = try MapperRun.events("replay-priority-now.jsonl", turns: [(.typed, one), (.steer, two)])
        #expect(events.turnsStarted.map(\.0) == [one, two])
        #expect(events.turnsStarted.map(\.1) == [.typed, .steer])
        #expect(events.turnsEnded.map(\.isError) == [false, false])
    }

    @Test func backgroundTeammateAndTheTurnTheCLIStarts() throws {
        let events = try MapperRun.events("task-agent.jsonl", turns: [(.typed, nil)])
        let agentStep = try #require(events.steps.first { $0.kind == .agent })
        #expect(agentStep.verb == "Starting" && agentStep.object == "scout")
        guard case .started(let taskID, let toolUseID, let name, _, let kind)? = events.tasks.first else {
            Issue.record("no task"); return
        }
        #expect(name == "scout" && kind == .agent && toolUseID == agentStep.id)
        #expect(events.tasks.contains { if case .progress(taskID, "Bash", _, _) = $0 { true } else { false } })
        #expect(events.tasks.last == .ended(taskID: taskID, status: .completed, summary: "The Bash command `echo hi` ran and printed:\n\n```\nhi\n```"))
        // The subagent's own step and text land in its lane.
        #expect(events.steps.contains { $0.kind == .bash && $0.subagent == agentStep.id })
        #expect(events.contains { if case .text(_, agentStep.id) = $0 { true } else { false } })
        // Two turns: the user's, then the one the CLI started when the agent handed back.
        #expect(events.turnsStarted.count == 2)
        #expect(events.turnsStarted.last?.0 == nil && events.turnsStarted.last?.1 == .typed)
        #expect(events.turnsEnded.last?.markdown == "hi")
    }

    @Test func bashAskWithoutDescriptionSaysRun() {
        var mapper = SessionEventMapper()
        let events = mapper.map(.controlRequest(id: "r1", request: PermissionWire.parse(
            ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "npm test"]])))
        guard case .permissionRequested(let ask)? = events.first else { Issue.record("no ask"); return }
        #expect(ask.title == "Run npm test")
    }

    /// QA E10: a teammate that handed back by message reports through `handback_report`; the
    /// notification's `summary` is the CLI's internal note and never surfaces.
    @Test func handbackSummaryIsTheReportNotTheCLINote() throws {
        var mapper = SessionEventMapper()
        mapper.beginTurn(kind: .typed, userUUID: nil)
        let events = try Fixture.events("background-subagent.jsonl").flatMap { mapper.map($0) }
        let summary = try #require(events.tasks.compactMap { if case .ended(_, _, let s) = $0 { s } else { nil } }.first)
        #expect(summary.hasPrefix("The first line of /Users/me/probe/note.txt reads exactly"))
        #expect(!summary.contains("SubagentHandback"))
    }

    @Test func internalNoteWithoutAReportIsDropped() {
        let line = Line.json(["type": "system", "subtype": "task_notification", "task_id": "t1", "status": "completed",
                              "handback": "send", "summary": "This agent's report was delivered to you as a message from \"t1\"."])
        guard case .taskNotification(let n) = StreamEvent(line: line) else { Issue.record("not parsed"); return }
        #expect(n.summary == nil)
    }

    @Test func onlyAgentsAreTeammates() throws {
        let events = try MapperRun.events("task-agent-cap.jsonl", turns: [(.typed, nil)])
        let started = events.tasks.compactMap { if case .started(_, _, let name, _, let kind) = $0 { (name, kind) } else { nil } }
        #expect(started.map(\.0) == ["alpha", "beta"])
        #expect(started.allSatisfy { $0.1 == .agent })
        #expect(events.steps.contains { $0.kind == .agent && $0.object == "beta" })
    }

    @Test func compactingIsReportedAndItsTurnEnds() throws {
        let events = try MapperRun.events("compact.jsonl", turns: [(.typed, nil), (.typed, nil), (.typed, nil)])
        #expect(events.contains(.compacted))
        #expect(events.turnsStarted.count == 3)
        // /compact's printed line is its answer (QA S-01), not an empty turn.
        #expect(events.turnsEnded.map(\.markdown) == ["ok", "Compacted", "42"])
    }

    @Test func aSlashCommandsOutputIsTheTurnsAnswer() {
        // `/context` and friends print through a replayed user line, and the result's text is "".
        var mapper = SessionEventMapper()
        mapper.beginTurn(kind: .typed, userUUID: nil)
        let table = "Context usage\n  Messages: 12k tokens"
        let output = mapper.map(.commandOutput(table))
        #expect(output == [.turnStarted(userUUID: nil, kind: .typed), .text("```\n\(table)\n```", subagent: nil)])
        let end = mapper.map(.result(StreamEvent.TurnResult(subtype: "success", isError: false, sessionID: "s", text: "", terminalReason: nil,
                                                            apiErrorStatus: nil, durationMS: nil, ttftMS: nil, costUSD: nil, permissionDenials: 0)))
        #expect(end.turnsEnded.map(\.markdown) == ["```\n\(table)\n```"])
    }

    @Test func editDiffComesFromTheInputThenTheHunks() throws {
        let events = try MapperRun.events("edit-structured-patch.jsonl", turns: [(.typed, nil)])
        let edits = events.steps.filter { $0.kind == .edit }
        #expect(edits.count == 2)
        #expect(edits.first?.detail == .diff(path: "/Users/me/probe/a.txt", old: "two", new: "TWO"))
        #expect(edits.last?.id == edits.first?.id)
        #expect(edits.last?.detail == .diff(path: "/Users/me/probe/a.txt", old: "one\ntwo\nthree", new: "one\nTWO\nthree"))
        let write = try #require(events.steps.first { $0.kind == .write })
        #expect(write.detail == .diff(path: "/Users/me/probe/a.txt", old: "", new: "one\ntwo\nthree\n"))
    }

    @Test func voiceTurnSpeaksAndExtractsTheBlock() {
        var mapper = SessionEventMapper()
        mapper.beginTurn(kind: .voice, userUUID: "u1")
        let answer = "Here.\n\n```buddy\n{\"say\": \"Your filter drops last week. Fix the date.\", \"shape\": \"chip\"}\n```"
        var events = mapper.map(.userEcho(.init(uuid: "u1", text: "<lumi-voice>…", imageCount: 0)))
        events += mapper.map(.partial(.messageStart))
        for chunk in answer.split(separator: " ", omittingEmptySubsequences: false).map({ $0 + " " }) {
            events += mapper.map(.partial(.textDelta(index: 0, text: String(chunk))))
        }
        events += mapper.map(.result(.init(subtype: "success", isError: false, sessionID: "s", text: answer, permissionDenials: 0, userMessageUUIDs: ["u1"])))
        #expect(events.turnsStarted.first?.1 == .voice)
        #expect(events.contains(.sayFirstSentence("Your filter drops last week.")))
        #expect(events.contains(.say("Your filter drops last week. Fix the date.")))
        let end = events.turnsEnded.first
        #expect(end?.block?.say == "Your filter drops last week. Fix the date.")
        #expect(end?.markdown == "Here.")
    }

    @Test func typedTurnKeepsFencesAndNeverExtracts() {
        var mapper = SessionEventMapper()
        mapper.beginTurn(kind: .typed, userUUID: "u1")
        let answer = "Code:\n\n```swift\nlet x = 1\n```\n\n```buddy\n{\"say\": \"Hi.\"}\n```"
        var events = mapper.map(.assistant(blocks: [.text(answer)], parentToolUseID: nil))
        events += mapper.map(.result(.init(subtype: "success", isError: false, sessionID: "s", text: answer, permissionDenials: 0)))
        #expect(events.turnsEnded.first?.markdown == answer)
        #expect(events.turnsEnded.first?.block == nil)
        #expect(events.contains(.text(answer, subagent: nil)))   // no partials: the whole text once
        #expect(!events.contains { if case .say = $0 { true } else { false } })
    }

    @Test func voiceInPageSpeaksOnlyWhenAsked() {
        var mapper = SessionEventMapper()
        mapper.beginTurn(kind: .voiceInPage, userUUID: "u1", speak: true)
        let answer = "```buddy\n{\"say\": \"Done.\"}\n```"
        var events = mapper.map(.assistant(blocks: [.text(answer)], parentToolUseID: nil))
        events += mapper.map(.result(.init(subtype: "success", isError: false, sessionID: "s", text: answer, permissionDenials: 0)))
        #expect(events.contains(.say("Done.")))
        #expect(events.turnsEnded.first?.block == nil)   // the block is a voice-turn thing only
    }

    @Test func failuresCarryAReason() {
        var mapper = SessionEventMapper()
        mapper.beginTurn(kind: .typed, userUUID: nil)
        let resets = Date(timeIntervalSince1970: 1_800_000_000)
        var events = mapper.map(.rateLimit(.init(status: "rejected", limitType: "five_hour", resetsAt: resets, windows: [:])))
        events += mapper.map(.assistant(blocks: [.text("limit")], parentToolUseID: nil, error: "rate_limit"))
        events += mapper.map(.result(.init(subtype: "success", isError: true, sessionID: "s", text: "limit", permissionDenials: 0)))
        #expect(events.contains(.rateLimit(status: "rejected", resetsAt: resets)))
        let end = events.turnsEnded.first
        #expect(end?.isError == true)
        #expect(end?.error == SessionFailure(reason: .rateLimited(resetsAt: resets), retryable: true))

        mapper.beginTurn(kind: .typed, userUUID: nil)
        let auth = mapper.map(.assistant(blocks: [.text("x")], parentToolUseID: nil, error: "authentication_failed"))
            + mapper.map(.result(.init(subtype: "success", isError: true, sessionID: "s", text: "x", permissionDenials: 0)))
        #expect(auth.turnsEnded.first?.error?.reason == .auth)
        #expect(auth.turnsEnded.first?.error?.retryable == false)
    }

    @Test func unknownControlRequestsGetAnImmediateErrorAndNoEvent() throws {
        var mapper = SessionEventMapper()
        let request = ControlRequest.other(subtype: "hook_callback")
        #expect(mapper.map(.controlRequest(id: "r1", request: request)).isEmpty)
        let reply = try #require(PermissionWire.autoReply(id: "r1", request: request))
        let o = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect((o["response"] as? [String: Any])?["subtype"] as? String == "error")
        #expect(PermissionWire.autoReply(id: "r2", request: .elicitation(.init(serverName: "x", message: "m"))) != nil)
        #expect(mapper.map(.other(type: "brand_new")).isEmpty)
    }

    @Test func coalesceMergesOnlyAdjacentTextOfOneLane() {
        let merged = SessionEvent.coalesce([.text("a", subagent: nil), .text("b", subagent: nil), .text("c", subagent: "t1"),
                                            .compacted, .text("d", subagent: nil)])
        #expect(merged == [.text("ab", subagent: nil), .text("c", subagent: "t1"), .compacted, .text("d", subagent: nil)])
    }
}
