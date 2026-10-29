import BuddyCore
import Foundation
import Testing
@testable import BuddyBridge

struct StreamEventTests {
    @Test func everyFixtureLineParses() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Fixture.dir.path).filter { $0.hasSuffix(".jsonl") }
        #expect(names.count == 25)
        for name in names {
            let lines = try Fixture.lines(name)
            #expect(lines.compactMap(StreamEvent.init(line:)).count == lines.count, "\(name)")
        }
    }

    @Test func initCarriesModeModelAndSession() throws {
        let info = try #require(try Fixture.events("quick-text-partials.jsonl").compactMap {
            if case .initialized(let i) = $0 { i } else { nil }
        }.first)
        #expect(info.permissionMode == "auto")
        #expect(info.model == "claude-haiku-5-5")
        #expect(!info.sessionID.isEmpty)
        #expect(info.pluginErrors.isEmpty)
    }

    /// The composer's `/` menu lists what the live session can run: its commands and skills.
    @Test func initCarriesTheSessionsCommandsAndSkills() throws {
        let line = Data(#"{"type":"system","subtype":"init","session_id":"s","slash_commands":["compact","review"],"skills":["deck:slides",{"name":"ship"}],"terminal_slash_commands":["doctor"]}"#.utf8)
        guard case .initialized(let info)? = StreamEvent(line: line) else { Issue.record("no init"); return }
        #expect(info.commands == ["compact", "review", "deck:slides", "ship"], "terminal-only commands left out")
        var mapper = SessionEventMapper()
        guard case .initialized(let summary)? = mapper.map(.initialized(info)).first else { Issue.record("not mapped"); return }
        #expect(summary.commands == info.commands)
    }

    @Test func pluginErrorsAreParsed() throws {
        let info = try #require(try Fixture.events("init-plugin-errors.jsonl").compactMap {
            if case .initialized(let i) = $0 { i } else { nil }
        }.first)
        #expect(info.pluginErrors.map(\.type) == ["path-not-found"])
        #expect(info.plugins.contains("buddy-probe"))
    }

    @Test func unknownModelIsAnErrorThoughSubtypeSaysSuccess() throws {
        let result = try #require(try Fixture.events("error-unknown-model.jsonl").compactMap {
            if case .result(let r) = $0 { r } else { nil }
        }.first)
        #expect(result.subtype == "success")
        #expect(result.isError)
        #expect(result.terminalReason == "api_error")
        #expect(result.apiErrorStatus == 404)
    }

    @Test func toolUseKeepsStringInputs() throws {
        let tools = try Fixture.events("deep-tooluse-thinking-3turns.jsonl").flatMap { e -> [StreamEvent.ToolUse] in
            guard case .assistant(let blocks, _, _, _) = e else { return [] }
            return blocks.compactMap { if case .toolUse(let t) = $0 { t } else { nil } }
        }
        let bash = try #require(tools.first { $0.name == "Bash" })
        #expect(bash.input["description"] != nil)
        #expect(bash.input["command"] != nil)
    }

    @Test func rateLimitWindows() throws {
        let rl = try #require(try Fixture.events("quick-text-partials.jsonl").compactMap {
            if case .rateLimit(let r) = $0 { r } else { nil }
        }.first)
        #expect(rl.status == "allowed")
        #expect(Set(rl.windows.keys) == ["five_hour", "seven_day"])
        #expect(rl.resetsAt != nil)
    }

    @Test func initRepeatsEveryTurn() throws {
        let events = try Fixture.events("quick-multiturn-3.jsonl")
        #expect(events.filter { if case .initialized = $0 { true } else { false } }.count == 3)
    }

    @Test func apiRetryFields() {
        let line = Line.json(["type": "system", "subtype": "api_retry", "attempt": 2, "max_retries": 10,
                              "retry_delay_ms": 1200, "error_status": 529, "error": "overloaded"])
        #expect(StreamEvent(line: line) == .apiRetry(.init(attempt: 2, maxRetries: 10, retryDelayMS: 1200,
                                                           errorStatus: 529, error: "overloaded")))
    }

    @Test func unknownTypesDoNotFail() {
        #expect(StreamEvent(line: Line.json(["type": "brand_new"])) == .other(type: "brand_new"))
        #expect(StreamEvent(line: Line.json(["type": "system", "subtype": "x"])) == .system(subtype: "x"))
        #expect(StreamEvent(line: Data("not json".utf8)) == nil)
    }

    @Test func splitterFlushesTheLastLine() {
        var s = LineSplitter()
        #expect(s.append(Data("{\"a\":1}\n{\"b\"".utf8)).count == 1)
        #expect(s.append(Data(":2}".utf8)).isEmpty)
        #expect(s.finish() == Data("{\"b\":2}".utf8))
        #expect(s.finish() == nil)
    }
}

/// Open-session lines recorded from claude 2.1.312 (docs/v2-sessions 10 "Probe results").
struct OpenSessionStreamEventTests {
    private func events(_ name: String) throws -> [StreamEvent] { try Fixture.events(name) }

    @Test func sessionStateRunsThenIdlesEachTurn() throws {
        let states = try events("session-state.jsonl").compactMap { if case .sessionState(let s) = $0 { s } else { nil } }
        #expect(states == ["running", "idle", "running", "idle"])
    }

    @Test func permissionPromptIsAControlRequestWithRequiresAction() throws {
        let all = try events("can-use-tool.jsonl")
        let states = all.compactMap { if case .sessionState(let s) = $0 { s } else { nil } }
        #expect(states == ["running", "requires_action", "running", "idle"])
        let (id, request) = try #require(all.compactMap { e -> (String, ControlRequest)? in
            if case .controlRequest(let id, let r) = e { (id, r) } else { nil }
        }.first)
        #expect(!id.isEmpty)
        guard case .canUseTool(let ask) = request else { Issue.record("not can_use_tool"); return }
        #expect(ask.toolName == "Write")
        #expect(ask.description == "note.txt")
        #expect(ask.stringInput["file_path"] == "/Users/me/probe/note.txt")
        #expect(ask.toolUseID?.hasPrefix("toolu_") == true)
        #expect(ask.suggestions != nil)
        #expect(!ask.defaultToNo && !ask.requiresUserInteraction)
        // --replay-user-messages echoes our own reply back; it decodes as a control_response.
        #expect(all.contains(.controlResponse(requestID: id, success: true)))
    }

    @Test func askUserQuestionCarriesItsQuestions() throws {
        let ask = try #require(try events("can-use-tool-ask.jsonl").compactMap { e -> CanUseTool? in
            if case .controlRequest(_, .canUseTool(let a)) = e { a } else { nil }
        }.first)
        #expect(ask.toolName == "AskUserQuestion")
        #expect(ask.requiresUserInteraction)
        #expect(ask.questions.map(\.question) == ["Tea or coffee?"])
        #expect(ask.questions.first?.header == "Drink")
        #expect(ask.questions.first?.options.map(\.label) == ["Tea", "Coffee"])
    }

    @Test func interruptCancelsThePendingPrompt() throws {
        let all = try events("can-use-tool-cancel.jsonl")
        let requestID = try #require(all.compactMap { e -> String? in
            if case .controlRequest(let id, _) = e { id } else { nil }
        }.first)
        #expect(all.contains(.controlCancel(requestID: requestID)))
        #expect(all.contains(.controlResponse(requestID: "probe_int", success: true)))
        let result = try #require(all.compactMap { if case .result(let r) = $0 { r } else { nil } }.last)
        #expect(result.subtype == "error_during_execution")
    }

    @Test func noHostDeniesAndSaysSo() throws {
        let all = try events("permission-denied-no-host.jsonl")
        let denial = try #require(all.compactMap { if case .permissionDenied(let d) = $0 { d } else { nil } }.first)
        #expect(denial.toolName == "Write")
        #expect(denial.toolUseID?.hasPrefix("toolu_") == true)
        #expect(!all.contains { if case .controlRequest = $0 { true } else { false } })
    }

    @Test func replayEchoCarriesOurUUIDAndTheSteerFoldsIn() throws {
        let all = try events("replay-user.jsonl")
        let echoes = all.compactMap { if case .userEcho(let u) = $0 { u } else { nil } }
        #expect(echoes.map(\.uuid) == ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"])
        #expect(echoes.last?.text == "Also end your reply with the word BANANA.")
        #expect(all.contains(.commandLifecycle(uuid: "22222222-2222-4222-8222-222222222222", state: "queued")))
        let results = all.compactMap { if case .result(let r) = $0 { r } else { nil } }
        #expect(results.count == 1)
        #expect(results.first?.userMessageUUIDs == echoes.map(\.uuid))
    }

    @Test func priorityNowEndsTheTurnAndStartsAnother() throws {
        let all = try events("replay-priority-now.jsonl")
        let results = all.compactMap { if case .result(let r) = $0 { r } else { nil } }
        #expect(results.map(\.userMessageUUIDs) == [["11111111-1111-4111-8111-111111111111"],
                                                    ["22222222-2222-4222-8222-222222222222"]])
        #expect(all.contains(.commandLifecycle(uuid: "11111111-1111-4111-8111-111111111111", state: "cancelled")))
    }

    @Test func backgroundAgentTaskEvents() throws {
        let all = try events("task-agent.jsonl")
        let started = try #require(all.compactMap { if case .taskStarted(let t) = $0 { t } else { nil } }.first)
        #expect(started.taskType == "local_agent")
        #expect(started.isBackgrounded)
        #expect(started.subagentType == "general-purpose")
        // The name lives on the Agent tool_use, joined by tool_use_id.
        let agent = try #require(all.flatMap { e -> [StreamEvent.ToolUse] in
            guard case .assistant(let blocks, nil, _, _) = e else { return [] }
            return blocks.compactMap { if case .toolUse(let t) = $0, t.name == "Agent" { t } else { nil } }
        }.first)
        #expect(agent.id == started.toolUseID)
        #expect(agent.input["name"] == "scout")
        #expect(agent.rawInput != nil)
        let progress = try #require(all.compactMap { if case .taskProgress(let p) = $0 { p } else { nil } }.first)
        #expect(progress.lastToolName == "Bash")
        #expect(all.contains(.taskUpdated(taskID: started.taskID, status: "completed")))
        let done = try #require(all.compactMap { if case .taskNotification(let n) = $0 { n } else { nil } }.last)
        #expect(done.taskID == started.taskID && done.status == "completed")
        // The CLI starts a turn of its own when the agent hands back: no user uuid on it.
        let results = all.compactMap { if case .result(let r) = $0 { r } else { nil } }
        #expect(results.count == 2)
        #expect(results.last?.userMessageUUIDs == [])
    }

    @Test func foregroundAndSubagentBashAlsoEmitTasks() throws {
        let tasks = try events("task-agent-cap.jsonl").compactMap { if case .taskStarted(let t) = $0 { t } else { nil } }
        let bash = tasks.filter { $0.taskType == "local_bash" }
        #expect(!bash.isEmpty)
        #expect(bash.allSatisfy { !$0.isBackgrounded && $0.parentTaskID != nil })
        #expect(tasks.filter { $0.taskType == "local_agent" }.count == 2)
    }

    @Test func subagentCapIsAnErrorToolResult() throws {
        let results = try events("task-agent-cap.jsonl").flatMap { e -> [StreamEvent.ToolResult] in
            if case .toolResults(let r) = e { r } else { [] }
        }
        let capped = try #require(results.first { $0.preview?.hasPrefix("Concurrent subagent limit reached") == true })
        #expect(capped.isError)
    }

    @Test func compactBoundaryAndTheSummaryIsNoEcho() throws {
        let all = try events("compact.jsonl")
        let c = try #require(all.compactMap { if case .compactBoundary(let c) = $0 { c } else { nil } }.first)
        #expect(c.trigger == "manual")
        #expect((c.preTokens ?? 0) > (c.postTokens ?? 0))
        // Echoes: the two typed turns and /compact; the summary and the command output aren't.
        let echoes = all.compactMap { if case .userEcho(let u) = $0 { u.text } else { nil } }
        #expect(echoes == ["Remember the number 42. Reply ok.", "What number did I ask you to remember? One word."])
        // The command's printed output is its own event (QA S-01).
        #expect(all.compactMap { if case .commandOutput(let o) = $0 { o } else { nil } } == ["Compacted"])
    }

    @Test func commandOutputUnwrapsStdoutAndStderrOnly() {
        #expect(StreamEvent.commandOutput("<local-command-stdout>Total cost: $0.01\n</local-command-stdout>") == "Total cost: $0.01")
        #expect(StreamEvent.commandOutput("<local-command-stderr>Unknown command: /nope</local-command-stderr>") == "Unknown command: /nope")
        #expect(StreamEvent.commandOutput("<local-command-stdout> </local-command-stdout>") == nil)
        #expect(StreamEvent.commandOutput("This session is being continued from a previous conversation.") == nil)
    }

    @Test func editCarriesStructuredPatch() throws {
        let edits = try events("edit-structured-patch.jsonl").flatMap { e -> [StreamEvent.FileEdit] in
            if case .toolResults(let r) = e { r.compactMap(\.edit) } else { [] }
        }
        #expect(edits.count == 2)
        #expect(edits[0].created && edits[0].hunks.isEmpty)
        #expect(edits[1].path == "/Users/me/probe/a.txt")
        #expect(edits[1].hunks == [.init(oldStart: 1, oldLines: 3, newStart: 1, newLines: 3,
                                         lines: [" one", "-two", "+TWO", " three"])])
    }

    @Test func interruptedTurnResumesWithItsOriginalUUID() throws {
        let killed = try events("interrupted-sigterm.jsonl")
        #expect(!killed.contains { if case .result = $0 { true } else { false } })
        let echo = try #require(killed.compactMap { if case .userEcho(let u) = $0 { u.uuid } else { nil } }.first)
        let resumed = try events("interrupted-continue.jsonl")
        #expect(!resumed.contains { if case .userEcho = $0 { true } else { false } })
        let result = try #require(resumed.compactMap { if case .result(let r) = $0 { r } else { nil } }.first)
        #expect(result.userMessageUUIDs == [echo])
    }

    @Test func previewIsClippedToTwoKilobytesOnACharacterBoundary() {
        let long = String(repeating: "é", count: 3000)   // 2 bytes each
        let line = Line.json(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": long]]]])
        guard case .toolResults(let r) = StreamEvent(line: line) else { Issue.record("no results"); return }
        #expect(r.first?.preview?.utf8.count == 2048)
    }

    @Test func unknownControlSubtypeStillDecodes() {
        let line = Line.json(["type": "control_request", "request_id": "r1", "request": ["subtype": "hook_callback"]])
        #expect(StreamEvent(line: line) == .controlRequest(id: "r1", request: .other(subtype: "hook_callback")))
        #expect(StreamEvent(line: Line.json(["type": "system", "subtype": "brand_new_thing"])) == .system(subtype: "brand_new_thing"))
    }
}
