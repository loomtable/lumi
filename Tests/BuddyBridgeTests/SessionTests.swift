import BuddyCore
import Foundation
import Testing
@testable import BuddyBridge

struct SessionTests {
    private func session(_ transport: ReplayTransport, resume: String? = nil) async -> ClaudeSession {
        let s = ClaudeSession(spec: spec(resume: resume), transport: transport)
        await s.startPump()
        return s
    }

    @Test func replaysARecordedQuickTurn() async throws {
        let transport = try ReplayTransport(fixture: Fixture.url("quick-text-partials.jsonl"))
        let s = await session(transport)
        let events = await collect(await s.ask(TurnInput(text: "Reply with just: ok")))
        #expect(events.contains { if case .initialized(let i) = $0 { i.permissionMode == "auto" } else { false } })
        #expect(events.contains(.text("ok")))
        guard case .finished(let outcome) = events.last else { Issue.record("no finish: \(events)"); return }
        #expect(outcome.result.text == "ok")
        #expect(outcome.extraction.block == nil)
        #expect(outcome.timing.firstText != nil)
        #expect(await s.sessionID == outcome.result.sessionID)
        #expect(transport.sentLines.count == 1)
    }

    @Test func theResultCarriesTheMainSessionsLastContextSize() async throws {
        func assistant(_ input: Int, read: Int, write: Int, parent: String? = nil) -> Data {
            let o: [String: Any] = [
                "type": "assistant", "parent_tool_use_id": parent ?? NSNull(), "session_id": "s-1",
                "message": ["content": [["type": "text", "text": "…"]],
                            "usage": ["input_tokens": input, "cache_read_input_tokens": read, "cache_creation_input_tokens": write,
                                      "output_tokens": 9]],
            ]
            var d = try! JSONSerialization.data(withJSONObject: o)
            d.append(0x0A)
            return d
        }
        let s = await session(ReplayTransport(lines: [
            Line.initLine(), assistant(3, read: 40_000, write: 1_000), assistant(5, read: 41_000, write: 2_000),
            assistant(2, read: 90_000, write: 0, parent: "toolu_sub"), Line.result("ok"),
        ]))
        let events = await collect(await s.ask(TurnInput(text: "q")))
        guard case .finished(let outcome) = events.last else { Issue.record("no finish"); return }
        #expect(outcome.result.contextTokens == 43_005, "the last main-session call, not a subagent's, not a sum")
    }

    @Test func aCompactionIsReportedOnTheResult() async throws {
        var line = try JSONSerialization.data(withJSONObject: [
            "type": "system", "subtype": "compact_boundary", "session_id": "s-1",
            "compact_metadata": ["trigger": "auto", "pre_tokens": 190_000],
        ] as [String: Any])
        line.append(0x0A)
        let s = await session(ReplayTransport(lines: [Line.initLine(), line, Line.result("ok")]))
        let events = await collect(await s.ask(TurnInput(text: "q")))
        guard case .finished(let outcome) = events.last else { Issue.record("no finish"); return }
        #expect(outcome.result.compacted)
    }

    @Test func threeTurnsInOneProcess() async throws {
        let s = await session(try ReplayTransport(fixture: Fixture.url("quick-multiturn-3.jsonl")))
        var texts: [String?] = []
        for q in ["one", "two", "three"] {
            let events = await collect(await s.ask(TurnInput(text: q)))
            if case .finished(let o) = events.last { texts.append(o.result.text) } else { texts.append(nil) }
        }
        #expect(texts.count == 3)
        #expect(texts.prefix(2) == ["one", "two"])
        #expect(texts[2]?.contains("Reply with just: one") == true)
    }

    @Test func deepTurnShowsRealSteps() async throws {
        let s = await session(try ReplayTransport(fixture: Fixture.url("deep-tooluse-thinking-3turns.jsonl")))
        let events = await collect(await s.ask(TurnInput(text: "read the package")))
        let statuses = events.compactMap { if case .status(let s) = $0 { s } else { nil } }
        #expect(statuses.contains("Thinking"))
        #expect(statuses.contains("Show the package manifest and StreamJSON source"))
        guard case .finished = events.last else { Issue.record("no finish"); return }
    }

    @Test func errorResultFailsTheTurn() async throws {
        let s = await session(try ReplayTransport(fixture: Fixture.url("error-unknown-model.jsonl")))
        let events = await collect(await s.ask(TurnInput(text: "hi")))
        guard case .failed(.turnFailed(let r)) = events.last else { Issue.record("\(events)"); return }
        #expect(r.apiErrorStatus == 404)
    }

    @Test func sayArrivesBeforeTheTurnEnds() async throws {
        let block = #"{"say": "Your new filter drops last week.", "shape": "card", "card_html": "<div>diff</div>"}"#
        let full = "```buddy\n\(block)\n```"
        let chunks = stride(from: 0, to: full.count, by: 7).map { i in
            String(full.dropFirst(i).prefix(7))
        }
        let lines = [Line.initLine()] + chunks.map(Line.textDelta) + [Line.result(full)]
        let s = await session(ReplayTransport(lines: lines))
        let events = await collect(await s.ask(TurnInput(text: "why?")))
        let firstIndex = try #require(events.firstIndex(of: .sayFirstSentence("Your new filter drops last week.")))
        let sayIndex = try #require(events.firstIndex(of: .say("Your new filter drops last week.")))
        #expect(firstIndex < sayIndex)
        let finishIndex = try #require(events.firstIndex { if case .finished = $0 { true } else { false } })
        #expect(sayIndex < finishIndex)
        guard case .finished(let o) = events[finishIndex] else { return }
        #expect(o.extraction.block?.shape == .card)
        #expect(o.timing.say != nil)
        #expect(o.timing.firstSentence != nil)
    }

    @Test func toolStepsBecomeStatusLines() async {
        let lines = [Line.initLine(), Line.toolUse("Read", ["file_path": "/Users/me/web/useFeed.ts"]),
                     Line.result("done")]
        let s = await session(ReplayTransport(lines: lines))
        let events = await collect(await s.ask(TurnInput(text: "x")))
        #expect(events.contains(.status("Reading useFeed.ts")))
    }

    @Test func crashMidTurnFailsWithExitStatus() async throws {
        let transport = ReplayTransport(lines: [Line.initLine(), Line.textDelta("partial")])
        let s = await session(transport)
        let stream = await s.ask(TurnInput(text: "x"))
        transport.crash(status: 9)
        let events = await collect(stream)
        #expect(events.last == .failed(.processExited(status: 9, stderr: "")))
        #expect(await s.isAlive == false)
    }

    @Test func secondAskWhileBusyIsRefused() async {
        let s = await session(ReplayTransport(lines: [Line.initLine()]))
        _ = await s.ask(TurnInput(text: "first"))
        let second = await collect(await s.ask(TurnInput(text: "second")))
        #expect(second == [.failed(.busy)])
    }

    @Test func deadlineEndsASilentTurn() async {
        let transport = ReplayTransport(lines: [])
        let s = await session(transport)
        let events = await collect(await s.ask(TurnInput(text: "x"), deadline: .milliseconds(50)))
        #expect(events == [.failed(.timedOut)])
        #expect(await s.isAlive == false)
    }

    @Test func cancelEndsTheTurn() async {
        let s = await session(ReplayTransport(lines: [Line.initLine()]))
        let stream = await s.ask(TurnInput(text: "x"))
        #expect(await s.cancel())
        let events = await collect(stream)
        #expect(events.last == .failed(.cancelled))
        #expect(await s.isAlive == false)
    }

    @Test func escAfterTheAnswerKeepsTheWarmProcess() async {
        let s = await session(ReplayTransport(lines: [Line.initLine(), Line.result("ok")]))
        _ = await collect(await s.ask(TurnInput(text: "x")))
        #expect(await s.cancel() == false)
        #expect(await s.isAlive)
    }

    @Test func shutdownFinishesARunningTurn() async {
        let s = await session(ReplayTransport(lines: [Line.initLine()]))
        let stream = await s.ask(TurnInput(text: "x"))
        await s.shutdown()
        #expect(await collect(stream).last == .failed(.cancelled))
    }

    @Test func aRetiredSessionFinishesItsTurnThenStops() async {
        let transport = ReplayTransport(lines: [Line.initLine(), Line.textDelta("a"), Line.result("a")])
        let s = ClaudeSession(spec: spec(), transport: transport)
        await s.startPump()
        let stream = await s.ask(TurnInput(text: "x"))
        await s.retire()
        guard case .finished = await collect(stream).last else { Issue.record("turn was cut off"); return }
        #expect(await eventually { await s.isAlive == false })
    }
}

/// The real transport, against /bin/cat and /bin/sh: the Foundation callbacks run on their
/// own threads, which is where a main-actor-isolated closure would trap (S5).
struct ProcessTransportTests {
    @Test func echoesLinesAndExits() async throws {
        let t = try ProcessTransport(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                                     workingDirectory: URL(fileURLWithPath: "/"), environment: [:])
        try await t.send(Data("{\"type\":\"a\"}\n{\"type\":\"b\"}\n".utf8))
        t.closeInput()
        var got: [String] = []
        for await line in t.lines { got.append(String(decoding: line, as: UTF8.self)) }
        #expect(got == [#"{"type":"a"}"#, #"{"type":"b"}"#])
        #expect(await t.exitStatus() == 0)
    }

    @Test func flushesALastLineWithoutNewline() async throws {
        let t = try ProcessTransport(executable: URL(fileURLWithPath: "/bin/sh"),
                                     arguments: ["-c", "printf '{\"type\":\"result\"}'; echo oops >&2; exit 3"],
                                     workingDirectory: URL(fileURLWithPath: "/"), environment: [:])
        var got: [Data] = []
        for await line in t.lines { got.append(line) }
        #expect(got == [Data(#"{"type":"result"}"#.utf8)])
        #expect(await t.exitStatus() == 3)
        #expect(await eventually { t.stderrTail.contains("oops") })
    }

    @Test func writingAfterExitThrowsInsteadOfCrashing() async throws {
        let t = try ProcessTransport(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                                     workingDirectory: URL(fileURLWithPath: "/"), environment: [:])
        _ = await t.exitStatus()
        await #expect(throws: TransportError.inputClosed) {
            for _ in 0..<64 { try await t.send(Data(repeating: 0x41, count: 65_536)) }
        }
    }

    @Test func aGrandchildHoldingStdoutDoesNotHangTheStream() async throws {
        let t = try ProcessTransport(executable: URL(fileURLWithPath: "/bin/sh"),
                                     arguments: ["-c", "(sleep 30 &) ; echo '{\"type\":\"x\"}'"],
                                     workingDirectory: URL(fileURLWithPath: "/"), environment: [:])
        let start = ContinuousClock.now
        for await _ in t.lines {}
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// Esc during a multi-MB write to a child that isn't reading. Terminate, then
    /// close: the blocked write fails cleanly and the fd is closed only after it.
    @Test func stopDuringABlockedWrite() async throws {
        let t = try ProcessTransport(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                     workingDirectory: URL(fileURLWithPath: "/"), environment: [:])
        let write = Task { try await t.send(Data(repeating: 0x41, count: 8_000_000)) }
        try await Task.sleep(for: .milliseconds(100))
        t.terminate()
        t.closeInput()
        await #expect(throws: TransportError.inputClosed) { try await write.value }
        #expect(await t.exitStatus() == 143)
    }

    /// Stopping claude must also stop what it started (hooks, MCP servers,
    /// browsers, Bash children). The child runs in its own process group.
    @Test func terminateStopsGrandchildren() async throws {
        let t = try ProcessTransport(executable: URL(fileURLWithPath: "/bin/sh"),
                                     arguments: ["-c", "sleep 60 & echo \"{\\\"pid\\\":$!}\"; wait"],
                                     workingDirectory: URL(fileURLWithPath: "/"), environment: [:])
        var it = t.lines.makeAsyncIterator()
        let line = try #require(await it.next())
        let grandchild = try #require((try JSONSerialization.jsonObject(with: line) as? [String: Int])?["pid"])
        #expect(kill(pid_t(grandchild), 0) == 0, "the grandchild is running")
        t.terminate()
        _ = await t.exitStatus()
        #expect(await eventually { kill(pid_t(grandchild), 0) != 0 }, "the grandchild was stopped with its group")
    }

    /// PR B review: dropping the transport before the child exits must not leave a zombie.
    @Test func aDroppedTransportStillReapsItsChild() async throws {
        var t: ProcessTransport? = try ProcessTransport(executable: URL(fileURLWithPath: "/bin/sh"),
                                                        arguments: ["-c", "exec 1>&- 2>&-; sleep 0.3"],
                                                        workingDirectory: URL(fileURLWithPath: "/"), environment: [:])
        let pid = try #require(t?.pid)
        t = nil
        // kill(pid, 0) still succeeds on an unreaped zombie; ESRCH means the transport reaped it.
        // (Polling with waitpid would reap the child itself, so the test couldn't fail.)
        #expect(await eventually { kill(pid, 0) == -1 && errno == ESRCH })
    }

    @Test func aMissingFolderIsReportedAsSuch() {
        #expect(throws: TransportError.launchFailed("no such folder: /nonexistent/folder")) {
            try ProcessTransport(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                                 workingDirectory: URL(fileURLWithPath: "/nonexistent/folder"), environment: [:])
        }
    }

    @Test func launchFailureIsReported() {
        #expect(throws: TransportError.self) {
            try ProcessTransport(executable: URL(fileURLWithPath: "/nonexistent/claude"), arguments: [],
                                 workingDirectory: URL(fileURLWithPath: "/"), environment: [:])
        }
    }
}

/// ClaudeSession over the real ProcessTransport, with a shell script standing in for claude.
struct RealProcessSessionTests {
    private let fakeClaude = #"""
    while read -r line; do
      printf '%s\n' '{"type":"system","subtype":"init","session_id":"sh-1","model":"m","cwd":"/","permissionMode":"auto"}'
      printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"```buddy\n{\"say\": \"Hi there.\"}\n```"}}}'
      printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"sh-1","result":"```buddy\n{\"say\": \"Hi there.\"}\n```"}'
    done
    """#

    @Test func aTurnRoundTripsThroughARealProcess() async throws {
        let t = try ProcessTransport(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", fakeClaude],
                                     workingDirectory: URL(fileURLWithPath: "/"), environment: [:])
        let s = ClaudeSession(spec: spec(), transport: t)
        await s.startPump()
        let big = TurnInput(text: "q", images: [.init(data: Data(repeating: 7, count: 3_000_000), mediaType: "image/png")])
        let events = await collect(await s.ask(big, deadline: .seconds(10)))
        #expect(events.contains(.say("Hi there.")))
        guard case .finished(let o) = events.last else { Issue.record("\(events)"); return }
        #expect(o.extraction.block?.say == "Hi there.")
        #expect(await s.sessionID == "sh-1")
        await s.shutdown()
        // Closing stdin ends the script's read loop (0) unless SIGTERM lands first (143).
        #expect([0, 143].contains(await t.exitStatus()))
    }
}

/// Recorded with claude 2.1.296 (M3 probe): the Agent tool backgrounds the subagent, the turn
/// returns "still running", then the session continues on its own with the real answer.
struct BackgroundSubagentTests {
    @Test func aTurnWaitsForBackgroundSubagents() async throws {
        let transport = try ReplayTransport(fixture: Fixture.url("background-subagent.jsonl"), wholeStream: true)
        let s = ClaudeSession(spec: spec(mode: .deep), transport: transport)
        await s.startPump()
        let events = await collect(await s.ask(TurnInput(text: "read the note via a subagent")))
        #expect(events.contains(.status("Waiting on a subagent")))
        // The subagent's own Read is forwarded with its parent id.
        #expect(events.contains { if case .toolUse(let t, let parent?) = $0 { t.name == "Read" && !parent.isEmpty } else { false } })
        guard case .finished(let o) = events.last else { Issue.record("\(events.suffix(3))"); return }
        #expect(o.result.text?.contains("PROBE-LINE-42") == true, "the answer comes from the follow-up turn, not \"still running\"")
        #expect(events.filter { if case .finished = $0 { true } else { false } }.count == 1)
    }

    @Test func backgroundTaskCountIsParsed() {
        let line = Line.json(["type": "system", "subtype": "background_tasks_changed", "tasks": [["task_id": "a"], ["task_id": "b"]]])
        #expect(StreamEvent(line: line) == .backgroundTasks(count: 2))
    }
}
