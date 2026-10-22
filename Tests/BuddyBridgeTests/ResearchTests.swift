import BuddyCore
import Foundation
import Synchronization
import Testing
@testable import BuddyBridge

private func tool(_ name: String, _ input: [String: String], id: String = UUID().uuidString) -> StreamEvent.ToolUse {
    StreamEvent.ToolUse(id: id, name: name, input: input)
}

private func toolLine(_ name: String, _ input: [String: String], id: String = UUID().uuidString, parent: String? = nil) -> Data {
    Line.json(["type": "assistant", "parent_tool_use_id": parent.map { $0 as Any } ?? NSNull(),
               "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
}

private func resultLine(_ id: String, error: Bool = false, parent: String? = nil) -> Data {
    Line.json(["type": "user", "parent_tool_use_id": parent.map { $0 as Any } ?? NSNull(),
               "message": ["content": [["type": "tool_result", "tool_use_id": id, "is_error": error, "content": "…"]]]])
}

private func toolStartLine(_ name: String) -> Data {
    Line.json(["type": "stream_event", "event": ["type": "content_block_start", "index": 1,
                                                 "content_block": ["type": "tool_use", "id": "x", "name": name, "input": [:]]]])
}

struct ResearchTrackerTests {
    @Test func phasesFollowToolEvents() {
        var t = ResearchTracker(reportPath: "/r/report.md")
        #expect(t.phase == .planning)
        t.record(tool("WebSearch", ["query": "quantitative tightening 2026"]))
        #expect(t.phase == .searching)
        t.record(tool("WebFetch", ["url": "https://example.com/qt"], id: "f1"))
        #expect(t.phase == .reading)
        let started = t.starting("Write")
        #expect(started)
        #expect(t.phase == .writing, "Writing starts while the report streams into Write")
    }

    @Test func sourcesCountOnlyWhenTheReadSucceeds() {
        var t = ResearchTracker(reportPath: "/r/report.md", ignoredPrefixes: ["/Users/me/.claude/"])
        t.record(tool("WebFetch", ["url": "https://Example.com/qt/#intro"], id: "a"))
        t.record(tool("WebFetch", ["url": "http://example.com/qt"], id: "b"))
        t.record(tool("WebFetch", ["url": "https://example.org/gone"], id: "c"))
        t.record(tool("Read", ["file_path": "/Users/me/notes/qt.md"], id: "d"))
        t.record(tool("Read", ["file_path": "/Users/me/.claude/projects/x.jsonl"], id: "e"))
        t.record(tool("Read", ["file_path": "/r/report.md"], id: "f"))
        #expect(t.sources.isEmpty, "nothing counts until its result is back")
        t.result(id: "a", isError: false)
        t.result(id: "b", isError: false)
        t.result(id: "c", isError: true)
        t.result(id: "d", isError: false)
        t.result(id: "e", isError: false)
        t.result(id: "f", isError: false)
        #expect(t.sources == ["https://example.com/qt", "/Users/me/notes/qt.md"])
    }

    @Test func browserPageLoadsAreReads() {
        var t = ResearchTracker(reportPath: "/r.md")
        t.record(tool("mcp__playwright__browser_navigate", ["url": "https://example.net/chart"], id: "n"))
        t.result(id: "n", isError: false)
        #expect(t.phase == .reading)
        #expect(t.sources.count == 1)
    }

    @Test func stepsKeepUpdatingPastTheCap() {
        var t = ResearchTracker(reportPath: "/r.md")
        for i in 0..<25 { t.record(tool("WebSearch", ["query": "q\(i)"])) }
        let changed = t.record(tool("WebSearch", ["query": "latest"]))
        #expect(changed, "a new step changes the peek even with the step count capped")
        #expect(t.steps.count == ResearchTracker.maxSteps)
        #expect(t.steps.last == "Searching the web for “latest”")
    }

    /// An edited project README must never become "Report ready".
    @Test func onlyReportsCreatedInTheReportsFolderCount() {
        var t = ResearchTracker(reportPath: "/r/report.md")
        let changed = t.record(tool("TodoWrite", [:]))
        #expect(!changed)
        t.record(tool("Edit", ["file_path": "/Users/me/Developer/app/README.md"], id: "e"))
        t.result(id: "e", isError: false)
        t.record(tool("Write", ["file_path": "/Users/me/elsewhere/QT.md"], id: "w1"))
        t.result(id: "w1", isError: false)
        t.record(tool("Write", ["file_path": "/r/QT-final.md"], id: "w2"))
        #expect(t.writtenReports.isEmpty, "nothing until the write succeeds")
        t.result(id: "w2", isError: false)
        t.record(tool("Write", ["file_path": "/r/denied.md"], id: "w3"))
        t.result(id: "w3", isError: true)
        #expect(t.writtenReports == ["/r/QT-final.md"])
    }

    /// Only Write creates a report; editing a Markdown file in the folder doesn't make it one.
    @Test func editsInTheReportsFolderAreNotReports() {
        var t = ResearchTracker(reportPath: "/r/report.md")
        t.record(tool("Edit", ["file_path": "/r/x.md"], id: "e1"))
        t.result(id: "e1", isError: false)
        t.record(tool("MultiEdit", ["file_path": "/r/y.md"], id: "e2"))
        t.result(id: "e2", isError: false)
        #expect(t.writtenReports.isEmpty)
    }
}

final class FakeSleepGuard: SleepGuard, Sendable {
    private let active = Mutex(0)
    private let begun = Mutex(0)
    func begin(reason: String) -> any Sendable {
        active.withLock { $0 += 1 }
        begun.withLock { $0 += 1 }
        return reason
    }
    func end(_ token: any Sendable) { active.withLock { $0 -= 1 } }
    var activeCount: Int { active.withLock { $0 } }
    var begunCount: Int { begun.withLock { $0 } }
}

final class Recorder: Sendable {
    private let items = Mutex<[String?]>([])
    func append(_ item: String?) { items.withLock { $0.append(item) } }
    var values: [String?] { items.withLock { $0 } }
}

final class Counter: Sendable {
    private let n = Mutex(0)
    func add() { n.withLock { $0 += 1 } }
    var value: Int { n.withLock { $0 } }
}

private let reports = URL(fileURLWithPath: "/Users/me/Library/Application Support/com.loomtable.lumi/reports")

private func request(_ topic: String = "quantitative tightening", conversation: String = "c1") -> ResearchRequest {
    ResearchRequest(conversationID: conversation, topic: topic,
                    packet: ContextPacket(askedAt: Date(timeIntervalSince1970: 1_791_900_000), utterance: "research \(topic)"))
}

private let doneSay = "```buddy\n{\"say\": \"Your research on QT is ready.\", \"shape\": \"rich\"}\n```"

/// A research turn: search, two subagent fetches (one 404), a Write of `writePath`, then the block.
private func researchLines(writePath: String) -> [Data] {
    [Line.initLine(session: "r-1"),
     toolLine("WebSearch", ["query": "qt"], id: "s"), resultLine("s"),
     toolLine("WebFetch", ["url": "https://example.com/a"], id: "f1", parent: "agent1"), resultLine("f1", parent: "agent1"),
     toolLine("WebFetch", ["url": "https://example.org/b"], id: "f2", parent: "agent2"), resultLine("f2", error: true, parent: "agent2"),
     toolStartLine("Write"),
     toolLine("Write", ["file_path": writePath, "content": "# Report"], id: "w"), resultLine("w"),
     Line.result(doneSay, session: "r-1")]
}

private func manager(_ transport: @escaping TransportFactory, sleep: FakeSleepGuard = FakeSleepGuard(),
                     exists: @escaping @Sendable (URL) -> Bool = { _ in true },
                     mkdir: @escaping @Sendable (URL) throws -> Void = { _ in },
                     restart: RestartPolicy = fastRestart, specs: Recorder? = nil,
                     wake: any WakeSource = NoWake(), maxConcurrent: Int = ResearchManager.maxConcurrent) -> ResearchManager {
    ResearchManager(reportsDir: reports, spec: { _, _, resume in
        specs?.append(resume)
        return spec(mode: .research, resume: resume)
    }, sleepGuard: sleep, wake: wake, restart: restart, maxConcurrent: maxConcurrent, fileExists: exists,
       createDirectory: mkdir, transport: transport)
}

struct NoWake: WakeSource {
    func wakes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

final class ManualWake: WakeSource, Sendable {
    private let pair = AsyncStream<Void>.makeStream()
    func wakes() -> AsyncStream<Void> { pair.stream }
    func fire() { pair.continuation.yield() }
}

private func finalJob(_ updates: AsyncStream<ResearchJob>, _ id: UUID) async -> ResearchJob? {
    for await job in updates where job.id == id {
        switch job.state {
        case .done, .failed, .cancelled: return job
        default: continue
        }
    }
    return nil
}

struct ResearchManagerTests {
    @Test func aJobRunsToADoneReportWithRealPhasesAndSources() async throws {
        let sleep = FakeSleepGuard()
        let m = manager({ _ in ReplayTransport(lines: researchLines(writePath: "/elsewhere/draft.txt")) },
                        sleep: sleep, exists: { _ in true })
        let updates = await m.subscribe()
        let job = await m.start(request())
        var phases: [ResearchPhase] = []
        var done: ResearchJob?
        for await update in updates where update.id == job.id {
            if phases.last != update.phase { phases.append(update.phase) }
            if update.state == .done || update.state != .running && update.state != .queued { done = update; break }
        }
        let d = try #require(done)
        #expect(d.state == .done)
        #expect(phases == [.planning, .searching, .reading, .writing])
        #expect(d.sourceCount == 1, "the 404 fetch isn't a source; the subagent's good fetch is")
        #expect(d.sessionID == "r-1")
        #expect(d.say == "Your research on QT is ready.")
        #expect(d.reportPath == job.reportPath)
        #expect(await eventually { sleep.activeCount == 0 })
        #expect(sleep.begunCount == 1)
    }

    /// A missing report plus an edited project .md is a failure, not "ready".
    @Test func anEditedProjectFileIsNotAReport() async throws {
        let readme = URL(fileURLWithPath: "/Users/me/Developer/app/README.md")
        let lines = [Line.initLine(session: "r-1"),
                     toolLine("Edit", ["file_path": readme.path], id: "e"), resultLine("e"),
                     toolLine("Write", ["file_path": readme.path], id: "w"), resultLine("w"),
                     Line.result(doneSay, session: "r-1")]
        let m = manager({ _ in ReplayTransport(lines: lines) }, exists: { $0 == readme })
        let updates = await m.subscribe()
        let job = await m.start(request())
        let end = try #require(await finalJob(updates, job.id))
        guard case .failed = end.state else { Issue.record("\(end.state)"); return }
        #expect(end.say == nil)
    }

    /// Stopping a conversation's research must not launch its queued jobs.
    @Test func cancelAllNeverStartsAQueuedJob() async throws {
        let launches = Counter()
        let m = manager({ _ in launches.add(); return ReplayTransport(lines: [Line.initLine(session: "x")]) })
        for t in ["a", "b", "c", "d"] { _ = await m.start(request(t)) }
        #expect(await eventually { launches.value == 2 })
        await m.cancelAll(conversation: "c1")
        // cancel(.running) returns once the job has settled, so this is exact, not timing.
        #expect(await m.all.allSatisfy { $0.state == .cancelled })
        #expect(launches.value == 2)
    }

    /// An 8 GB Mac: one job at a time, and queued jobs wait while Deep answers.
    @Test func oneAtATimeAndHeldWhileDeepAnswers() async throws {
        let launches = Counter()
        let m = manager({ _ in launches.add(); return ReplayTransport(lines: [Line.initLine(session: "x")]) },
                        maxConcurrent: 1)
        await m.setHeld(true)
        for t in ["a", "b"] { _ = await m.start(request(t)) }
        for _ in 0..<50 { await Task.yield() }
        #expect(launches.value == 0, "held: nothing starts while Deep answers")
        await m.setHeld(false)
        #expect(await eventually { launches.value == 1 })
        for _ in 0..<50 { await Task.yield() }
        #expect(launches.value == 1, "one at a time")
        await m.cancelAll(conversation: "c1")
    }

    @Test func afterWakeRunningJobsAreRechecked() async throws {
        let wake = ManualWake()
        let m = manager({ _ in ReplayTransport(lines: [Line.initLine(session: "x")]) }, wake: wake)
        let updates = await m.subscribe()
        let job = await m.start(request())
        #expect(await eventually { await m.job(job.id)?.state == .running })
        wake.fire()
        for await u in updates where u.id == job.id && u.checkedAt != nil {
            #expect(u.state == .running)
            break
        }
        await m.cancelAll(conversation: "c1")
    }

    @Test func runningOutOfRestartsFails() async throws {
        let m = manager({ _ in
            let t = ReplayTransport(lines: [Line.initLine(session: "r-1"), toolLine("WebSearch", ["query": "q"], id: UUID().uuidString)])
            Task { try? await Task.sleep(for: .milliseconds(20)); t.crash(status: 9) }
            return t
        }, restart: RestartPolicy(delays: [.milliseconds(1), .milliseconds(1)]))
        let updates = await m.subscribe()
        let job = await m.start(request())
        var sawReconnecting = false
        var end: ResearchJob?
        for await u in updates where u.id == job.id {
            if u.reconnecting { sawReconnecting = true }
            if case .failed = u.state { end = u; break }
        }
        #expect(sawReconnecting)
        #expect(end?.state == .failed("Claude Code stopped 3 times while researching."))
    }

    /// PR B review: progress resets the per-crash budget, but a job that crashes the same way
    /// every time still ends after `maxTotalRestarts`, and isn't left "reconnecting".
    @Test func progressThenCrashForeverStillEnds() async throws {
        let launches = Counter()
        let m = manager({ _ in
            launches.add()
            let t = ReplayTransport(lines: [Line.initLine(session: "r-1"), toolLine("WebSearch", ["query": "q"], id: "s\(launches.value)"),
                                            resultLine("s\(launches.value)")])
            Task { try? await Task.sleep(for: .milliseconds(20)); t.crash(status: 9) }
            return t
        }, restart: RestartPolicy(delays: [.milliseconds(1)]))
        let updates = await m.subscribe()
        let job = await m.start(request())
        let end = try #require(await finalJob(updates, job.id))
        #expect(end.state == .failed("Claude Code stopped \(ResearchManager.maxTotalRestarts + 1) times while researching."))
        #expect(end.reconnecting == false)
        #expect(launches.value == ResearchManager.maxTotalRestarts + 1, "progress reset the 1-attempt budget each time")
    }

    /// A denied or failed tool call is not progress (denials must not reset the budget).
    @Test func deniedCallsAreNotProgress() {
        #expect(ResearchManager.isProgress(.toolResult(id: "a", isError: false)))
        #expect(!ResearchManager.isProgress(.toolResult(id: "a", isError: true)))
        #expect(!ResearchManager.isProgress(.text("Resuming…")))
    }

    /// Every job has its own folder, so jobs can't read or overwrite each other.
    @Test func eachJobHasItsOwnFolder() async {
        let m = manager({ _ in ReplayTransport(lines: [Line.initLine(session: "x")]) })
        let a = await m.start(request("a"))
        let b = await m.start(request("b"))
        #expect(a.reportPath.deletingLastPathComponent() != b.reportPath.deletingLastPathComponent())
        #expect(a.reportPath.deletingLastPathComponent().deletingLastPathComponent().path == reports.path)
        await m.cancelAll(conversation: "c1")
    }

    @Test func aCrashBeforeInitFailsWithoutResuming() async throws {
        let specs = Recorder()
        let m = manager({ _ in let t = ReplayTransport(lines: []); t.crash(status: 1); return t }, specs: specs)
        let updates = await m.subscribe()
        let job = await m.start(request())
        let end = try #require(await finalJob(updates, job.id))
        guard case .failed = end.state else { Issue.record("\(end.state)"); return }
        #expect(specs.values == [nil])
    }

    @Test func noReportFileMeansFailedAndNoSuccessLine() async throws {
        let m = manager({ _ in ReplayTransport(lines: researchLines(writePath: "/tmp/x.txt")) }, exists: { _ in false })
        let updates = await m.subscribe()
        let job = await m.start(request())
        let end = try #require(await finalJob(updates, job.id))
        guard case .failed = end.state else { Issue.record("\(end.state)"); return }
        #expect(end.say == nil)
    }

    @Test func aReportsFolderErrorIsReported() async throws {
        struct Denied: LocalizedError { var errorDescription: String? { "Permission denied" } }
        let launches = Counter()
        let m = manager({ _ in launches.add(); return ReplayTransport(lines: []) }, mkdir: { _ in throw Denied() })
        let updates = await m.subscribe()
        let job = await m.start(request())
        let end = try #require(await finalJob(updates, job.id))
        #expect(end.state == .failed("Couldn't create the reports folder: Permission denied"))
        #expect(launches.value == 0)
    }

    @Test func aCrashMidJobResumesTheSession() async throws {
        let specs = Recorder()
        let attempt = Counter()
        let m = manager({ _ in
            attempt.add()
            if attempt.value == 1 {
                // Starts, reads, then the process dies mid-job.
                let t = ReplayTransport(lines: [Line.initLine(session: "r-1"), toolLine("WebSearch", ["query": "q"], id: "s")])
                Task { try? await Task.sleep(for: .milliseconds(30)); t.crash(status: 9) }
                return t
            }
            return ReplayTransport(lines: [Line.initLine(session: "r-1"), toolLine("Write", ["file_path": "/r.md"], id: "w"),
                                           Line.result(doneSay, session: "r-1")])
        }, specs: specs)
        let updates = await m.subscribe()
        let job = await m.start(request())
        let end = try #require(await finalJob(updates, job.id))
        #expect(end.state == .done)
        #expect(specs.values == [nil, "r-1"], "the restart resumes the job's session")
    }

    @Test func atMostTwoRunAndTheThirdWaits() async throws {
        let launches = Counter()
        let m = manager({ _ in launches.add(); return ReplayTransport(lines: [Line.initLine(session: "x")]) })
        let a = await m.start(request("a"))
        let b = await m.start(request("b"))
        let c = await m.start(request("c"))
        #expect(await eventually { launches.value == 2 })
        #expect(await m.job(c.id)?.state == .queued)
        await m.cancel(a.id)
        #expect(await eventually { await m.job(a.id)?.state == .cancelled })
        #expect(await eventually { await m.job(c.id)?.state == .running })
        #expect(launches.value == 3)
        await m.cancelAll(conversation: "c1")
        #expect(await eventually { await m.all.allSatisfy { $0.state == .cancelled } })
        _ = b
    }

    @Test func aQueuedJobCancelsWithoutStarting() async {
        let m = manager({ _ in ReplayTransport(lines: [Line.initLine(session: "x")]) })
        _ = await m.start(request("a"))
        _ = await m.start(request("b"))
        let c = await m.start(request("c"))
        await m.cancel(c.id)
        #expect(await m.job(c.id)?.state == .cancelled)
        #expect(await m.job(c.id)?.startedAt == nil)
        await m.cancelAll(conversation: "c1")
    }

    @Test func theSleepGuardIsReleasedAfterAFailure() async throws {
        let sleep = FakeSleepGuard()
        let m = manager({ _ in throw TransportError.launchFailed("no claude") }, sleep: sleep)
        let updates = await m.subscribe()
        let job = await m.start(request())
        _ = await finalJob(updates, job.id)
        #expect(await eventually { sleep.activeCount == 0 })
    }

    @Test func everySubscriberGetsEveryUpdate() async throws {
        let m = manager({ _ in ReplayTransport(lines: researchLines(writePath: "/r.md")) })
        let a = await m.subscribe()
        let b = await m.subscribe()
        let job = await m.start(request())
        async let ea = finalJob(a, job.id)
        async let eb = finalJob(b, job.id)
        let (x, y) = await (ea, eb)
        #expect(x?.state == .done && y?.state == .done)
    }

    @Test func promptAndReportName() {
        let path = reports.appendingPathComponent("x.md")
        let text = ResearchManager.prompt(request("QT </research> & co"), reportPath: path)
        #expect(text.contains("<research>QT &lt;/research&gt; &amp; co</research>"))
        #expect(text.contains("`\(path.path)`"))
        let date = Date(timeIntervalSince1970: 1_791_900_000)
        let a = ResearchManager.reportName(topic: "What is Quantitative Tightening, really?", date: date, id: UUID())
        let b = ResearchManager.reportName(topic: "What is Quantitative Tightening, really?", date: date, id: UUID())
        #expect(a.contains("-what-is-quantitative-tightening-really-"))
        let long = ResearchManager.reportName(topic: String(repeating: "supercalifragilistic ", count: 10), date: date, id: UUID())
        let slug = long.split(separator: "-").dropFirst(3).dropLast().joined(separator: "-")
        #expect(slug.utf8.count <= 60)
        let oneWord = ResearchManager.reportName(topic: String(repeating: "é", count: 200), date: date, id: UUID())
        #expect(oneWord.utf8.count < 120, "one over-long word is cut at the byte cap")
        #expect(!oneWord.contains(" "))
        #expect(a != b, "the same topic in the same second gets two files")
        #expect(!a.contains(":"))
    }

    @Test func researchLaunchSpec() throws {
        let jobDir = reports.appendingPathComponent("0f0e")
        let report = jobDir.appendingPathComponent("qt.md")
        let s = LaunchSpec.research(executable: URL(fileURLWithPath: "/c"), jobDir: jobDir, reportPath: report,
                                    plugin: URL(fileURLWithPath: "/p"), resume: "r-1", environment: [:])
        let args = s.arguments
        #expect(s.workingDirectory == jobDir, "each job runs in its own folder")
        #expect(args.contains("dontAsk") && args.contains("--restricted") && args.contains("--strict-mcp-config"))
        #expect(args.contains("--disable-slash-commands"))
        #expect(args.firstIndex(of: "--tools").map { args[$0 + 1] } == "WebSearch,WebFetch,Read,Write,Edit,Agent")
        #expect(!args.contains("--add-dir"))
        #expect(args.suffix(2) == ["--resume", "r-1"])
        let settingsText = try #require(s.settings)
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(settingsText.utf8)) as? [String: Any])
        let permissions = try #require(settings["permissions"] as? [String: [String]])
        let job = "//Users/me/Library/Application Support/com.loomtable.lumi/reports/0f0e"
        #expect(permissions["allow"] == ["WebSearch", "WebFetch", "Agent(general-purpose)", "Read(\(job)/**)", "Edit(\(job)/qt.md)"],
                "writes only to its own report; no bare Agent, no unscoped Read")
        let deny = try #require(permissions["deny"])
        #expect(deny.contains("Bash") && deny.contains("Edit(\(job)/CLAUDE.md)") && deny.contains("Edit(\(job)/.claude/**)"))
        #expect(deny.contains("Edit(//Users/me/Library/Application Support/com.loomtable.lumi/reports/CLAUDE.md)"))
        #expect(settings["autoMemoryEnabled"] as? Bool == false)
    }

}

/// Recorded with claude 2.1.296 (Haiku, the exact `LaunchSpec.research`
/// args; paths scrubbed, partial and rate-limit lines dropped). The model was told to read a canary
/// two levels up (twice) and through a symlink in the job folder, and to write the job folder's
/// CLAUDE.md and other.md and the reports folder's other.md and CLAUDE.md: all seven were denied
/// without a prompt; only the report was written.
struct ResearchSandboxFixtureTests {
    @Test func onlyTheReportWriteGetsThrough() throws {
        let events = try String(contentsOf: Fixture.url("research-sandbox-denials.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { StreamEvent(line: Data($0.utf8)) }
        guard case .initialized(let info)? = events.first else { Issue.record("no init"); return }
        #expect(info.permissionMode == "dontAsk")
        #expect(info.mcpServers.isEmpty)
        #expect(info.cwd.hasSuffix("/reports/job-1"), "runs in its own job folder")
        let results: [StreamEvent.ToolResult] = events.flatMap { event -> [StreamEvent.ToolResult] in if case .toolResults(let r) = event { r } else { [] } }
        #expect(results.filter(\.isError).count == 7)
        #expect(results.filter { !$0.isError }.count == 1, "the report write")
        guard case .result(let r)? = events.last else { Issue.record("no result"); return }
        #expect(r.permissionDenials == 7)
    }
}
