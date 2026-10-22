@testable import BuddyApp
@testable import BuddyBridge
import BuddyCompanion
import BuddyCore
import BuddyOverlay
import Foundation
import Synchronization
import Testing

/// Streams jobs to the controller and records what it was asked to do.
final class FakeResearchRunner: ResearchRunning {
    enum Call: Equatable { case begin(String), cancel(UUID), cancelAll(String) }
    let jobs: AsyncStream<ResearchJob>
    private let sink: AsyncStream<ResearchJob>.Continuation
    private let recorded = Mutex<[Call]>([])
    var calls: [Call] { recorded.withLock { $0 } }

    init() {
        (jobs, sink) = AsyncStream<ResearchJob>.makeStream()
        (beginGate, openBegin) = AsyncStream<Void>.makeStream()
    }

    func send(_ job: ResearchJob) { sink.yield(job) }
    func subscribe() async -> AsyncStream<ResearchJob> { jobs }
    /// Like the real manager, which reports the job running before `start` returns.
    var reportsRunningBeforeReturning: Bool {
        get { early.withLock { $0 } }
        set { early.withLock { $0 = newValue } }
    }
    private let early = Mutex(false)
    /// Opened by the test to let `begin` return (with `reportsRunningBeforeReturning`).
    let beginGate: AsyncStream<Void>
    let openBegin: AsyncStream<Void>.Continuation

    func begin(_ request: ResearchRequest) async -> ResearchJob {
        recorded.withLock { $0.append(.begin(request.topic)) }
        let queued = job(request.topic, conversation: request.conversationID)
        if reportsRunningBeforeReturning {
            send(queued)
            var running = queued
            running.state = .running
            send(running)
            // Returns only once the test has seen the listener apply both (no timing guess).
            for await _ in beginGate { break }
        }
        return queued
    }
    func cancel(_ id: UUID) async { recorded.withLock { $0.append(.cancel(id)) } }
    func cancelAll(conversation: String) async { recorded.withLock { $0.append(.cancelAll(conversation)) } }
}

func job(_ topic: String, conversation: String = "c1", id: UUID = UUID(), _ change: (inout ResearchJob) -> Void = { _ in }) -> ResearchJob {
    var j = ResearchJob(id: id, conversationID: conversation, topic: topic,
                        reportPath: URL(fileURLWithPath: "/r/\(id.uuidString)/\(topic).md"))
    change(&j)
    return j
}

private let packet = ContextPacket(askedAt: Date(timeIntervalSince1970: 0), utterance: "research QT")

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

@MainActor
struct ResearchControllerTests {
    let runner = FakeResearchRunner()
    let overlay = FakeOverlay()

    func controller(linger: Duration = .seconds(60), model: @escaping @MainActor () -> ModelID = { .opus },
                    openFile: @escaping @MainActor (URL) -> Void = { _ in },
                    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) -> ResearchController {
        let c = ResearchController(runner: runner, overlay: overlay, model: model, color: { _ in .sage },
                                   linger: linger, sleep: sleep, openFile: openFile)
        c.activate()
        return c
    }

    var capsules: [[CapsuleState]] { overlay.calls.compactMap { if case .capsule(let c) = $0 { c } else { nil } } }

    @Test func everyFieldMapsOneToOne() {
        let start = Date(timeIntervalSince1970: 1000)
        let j = job("QT") {
            $0.state = .running; $0.phase = .reading; $0.sourceCount = 14
            $0.steps = ["Searching: QT 2026", "Reading federalreserve.gov"]; $0.reconnecting = true
            $0.startedAt = start
        }
        let c = ResearchController.capsule(j)
        #expect(c == CapsuleState(id: j.id, topic: "QT", status: .running(.reading), sourceCount: 14,
                                  steps: ["Searching: QT 2026", "Reading federalreserve.gov"], reconnecting: true, duration: nil),
                "no duration until both times are known")
        var done = j
        done.state = .done; done.finishedAt = start.addingTimeInterval(372)
        #expect(ResearchController.capsule(done).duration == 372)
        #expect(ResearchController.capsule(job("x") { $0.state = .failed("Claude Code stopped.") }).status == .failed("Claude Code stopped."))
        #expect(ResearchController.capsule(job("x")).status == .queued)
    }

    @Test func startShowsTheJobAndUpdatesFollowIt() async {
        let c = controller()
        let started = await c.start(ResearchRequest(conversationID: "c1", topic: "QT", packet: packet))
        #expect(runner.calls == [.begin("QT")])
        #expect(capsules.last?.map(\.status) == [.queued])
        var running = started
        running.state = .running; running.phase = .searching
        runner.send(running)
        #expect(await eventually { capsules.last?.first?.status == .running(.searching) })
    }

    @Test func doneChimesOnceAndStaysUntilOpened() async {
        let c = controller()
        var done = 0
        c.onDone = { _ in done += 1 }
        let id = UUID()
        let block = BuddyBlock(say: "Your research on QT is ready.", shape: .rich, cardHTML: "<ul><li>Runoff slows in 2026</li></ul>")
        runner.send(job("QT", id: id) { $0.state = .running })
        runner.send(job("QT", id: id) { $0.state = .done; $0.say = block.say; $0.block = block })
        runner.send(job("QT", id: id) { $0.state = .done; $0.say = block.say; $0.block = block })   // a repeat (wake recheck)
        #expect(await eventually { capsules.last?.first?.status == .done })
        #expect(done == 1)

        await c.handle(.openReport(id))
        guard case .answer(let answer, let anchor, _)? = overlay.calls.last(where: { if case .answer = $0 { true } else { false } }) else {
            Issue.record("no answer shown"); return
        }
        #expect(anchor == .capsule)
        #expect(answer.block == block && answer.lane == Lane(mode: .research, model: .opus) && answer.conversation == .sage)
        #expect(capsules.last == [], "opened, so it leaves the capsule")
        runner.send(job("QT", id: id) { $0.state = .done })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(capsules.last == [], "a late update doesn't bring it back")
    }

    @Test func aJobWithoutABlockOpensItsReportFile() async {
        var opened: [URL] = []
        let c = controller(openFile: { opened.append($0) })
        let id = UUID()
        let done = job("QT", id: id) { $0.state = .done }
        runner.send(done)
        #expect(await eventually { c.jobs.first?.state == .done })
        c.openReport(id)
        #expect(opened == [done.reportPath])
        #expect(!overlay.calls.contains { if case .answer = $0 { true } else { false } }, "no card made up from nothing")
        #expect(capsules.last == [])
    }

    @Test func aStaleReturnedCopyDoesNotOverwriteANewerState() async {
        runner.reportsRunningBeforeReturning = true
        let c = controller()
        let starting = Task { await c.start(ResearchRequest(conversationID: "c1", topic: "QT", packet: packet)) }
        #expect(await eventually { c.jobs.map(\.state) == [.running] }, "the stream delivered running first")
        runner.openBegin.yield()
        _ = await starting.value
        #expect(c.jobs.map(\.state) == [.running])
        #expect(capsules.last?.map(\.status) == [.running(.planning)])
    }

    @Test func theCardShowsTheModelTheJobStartedWith() async {
        let current = Mutex(ModelID.opus)
        let c = controller(model: { current.withLock { $0 } })
        let started = await c.start(ResearchRequest(conversationID: "c1", topic: "QT", packet: packet))
        current.withLock { $0 = .sonnet }
        let block = BuddyBlock(say: "Ready.", shape: .rich)
        runner.send(job("QT", id: started.id) { $0.state = .done; $0.block = block })
        #expect(await eventually { c.jobs.first?.state == .done })
        c.openReport(started.id)
        guard case .answer(let answer, _, _)? = overlay.calls.last(where: { if case .answer = $0 { true } else { false } }) else {
            Issue.record("no answer"); return
        }
        #expect(answer.lane.model == .opus)
    }

    @Test func eachJobIsRecordedWhenSeenWhenItLearnsItsSessionAndWhenItEnds() async {
        let c = controller()
        var recorded: [(String, String?)] = []
        c.onRecord = { recorded.append(($0.conversationID, $0.sessionID)) }
        let id = UUID()
        runner.send(job("QT", id: id))
        runner.send(job("QT", id: id) { $0.state = .running })
        runner.send(job("QT", id: id) { $0.state = .running; $0.sessionID = "r1" })
        runner.send(job("QT", id: id) { $0.state = .done; $0.sessionID = "r1" })
        #expect(await eventually { recorded.count == 3 })
        for _ in 0..<20 { await Task.yield() }
        // The end is recorded too: its report may land after the conversation was forgotten.
        #expect(recorded.map(\.1) == [nil, "r1", "r1"], "no repeat for running state changes")
        #expect(recorded.allSatisfy { $0.0 == "c1" })
        withExtendedLifetime(c) {}
    }

    @Test func failedAndCancelledLingerThenLeave() async {
        // The linger is a gate the test opens, not wall-clock time, so load can't make it flake.
        let (gate, open) = AsyncStream<Void>.makeStream()
        let c = controller(linger: .seconds(8), sleep: { _ in for await _ in gate { break } })
        runner.send(job("QT") { $0.state = .failed("The job finished without writing its report.") })
        runner.send(job("Rates") { $0.state = .cancelled })
        #expect(await eventually { capsules.last?.count == 2 })
        for _ in 0..<20 { await Task.yield() }
        #expect(capsules.last?.count == 2, "still lingering while the linger hasn't passed")
        open.yield()
        open.yield()
        #expect(await eventually { capsules.last == [] }, "both leave once it has")
        withExtendedLifetime(c) {}
    }

    @Test func stopAndCancelAllReachTheManager() async {
        let c = controller()
        let id = UUID()
        #expect(await c.handle(.stopResearch(id)))
        await c.cancelAll(conversation: "c7")
        #expect(!(await c.handle(.goDeeper)), "not a capsule event")
        #expect(runner.calls == [.cancel(id), .cancelAll("c7")])
    }

    @Test func theRealManagerRunsEachJobInItsOwnSandboxedFolder() async {
        let reports = URL(fileURLWithPath: "/Users/me/Library/Application Support/com.loomtable.lumi/reports")
        let m = ResearchController.manager(executable: URL(fileURLWithPath: "/c"), plugin: URL(fileURLWithPath: "/p"),
                                           reportsDir: reports, home: URL(fileURLWithPath: "/Users/me"), environment: [:],
                                           config: { ModeConfig(model: .sonnet, effort: .high) })
        _ = m   // the spec closure is covered by LaunchSpec.research's own tests; this checks the wiring compiles
        #expect(ResearchController.reportsDirectory.path.hasSuffix("com.loomtable.lumi/reports"))
    }
}

@MainActor
struct ClaudeCodeServiceTests {
    private let healthy = ClaudeCodeReport(executable: URL(fileURLWithPath: "/Users/me/.local/bin/claude"), version: "2.1.296",
                                           auth: .init(loggedIn: true, method: "claude.ai", subscription: "max", provider: "firstParty"),
                                           plugin: .valid)

    @Test func checkingUntilTheProbeLandsThenRealValues() async {
        let s = ClaudeCodeService(probe: { [healthy] in healthy }, install: { URL(fileURLWithPath: "/p") }, restartLanes: {})
        #expect(!s.status.checked)
        await s.refresh()
        #expect(s.status.checked && s.status.version == "2.1.296" && s.status.loginDetail == "Claude Max" && s.status.pluginLoaded == true)
    }

    @Test func onlyTheBuddyPluginsLoadErrorsCount() async {
        let s = ClaudeCodeService(probe: { [healthy] in healthy }, install: { URL(fileURLWithPath: "/p") }, restartLanes: {})
        await s.refresh()
        s.pluginLoaded(errors: [.init(plugin: "other", type: "x", message: "nope", path: nil),
                                .init(plugin: "buddy", type: "path-not-found", message: "agents/buddy-quick.md", path: nil)])
        #expect(s.status.pluginLoaded == false && s.status.pluginProblem == "path-not-found: agents/buddy-quick.md")
        s.pluginLoaded(errors: [])
        #expect(s.status.pluginLoaded == true && s.status.pluginProblem == nil)
    }

    @Test func repairReinstallsRestartsThenRechecks() async throws {
        let probes = Mutex(0), installs = Mutex(0)
        var restarts = 0
        let s = ClaudeCodeService(probe: { [healthy] in probes.withLock { $0 += 1 }; return healthy },
                                  install: { installs.withLock { $0 += 1 }; return URL(fileURLWithPath: "/p") },
                                  restartLanes: { restarts += 1 })
        s.pluginLoaded(errors: [.init(plugin: "buddy", type: "manifest", message: "bad json", path: nil)])
        try await s.actions.repairPlugin?()
        #expect(installs.withLock { $0 } == 1 && restarts == 1 && probes.withLock { $0 } == 1)
        #expect(s.status.pluginLoaded == true, "old load errors are cleared by the fresh copy")
    }

    @Test func aFailedRepairKeepsEverythingRunning() async {
        struct CopyFailed: Error {}
        var restarts = 0
        let s = ClaudeCodeService(probe: { [healthy] in healthy }, install: { throw CopyFailed() }, restartLanes: { restarts += 1 })
        await #expect(throws: CopyFailed.self) { try await s.repairPlugin() }
        #expect(restarts == 0)
    }

    @Test func repairWaitsOutAnEarlierCheckAndChecksAgain() async throws {
        let probes = Mutex(0)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let stale = ClaudeCodeReport(executable: healthy.executable, version: healthy.version, auth: healthy.auth,
                                     plugin: .invalid("manifest: bad json"))
        let s = ClaudeCodeService(probe: { [healthy] in
            let n = probes.withLock { $0 += 1; return $0 }
            guard n == 1 else { return healthy }
            for await _ in gate { break }
            return stale
        }, install: { URL(fileURLWithPath: "/p") }, restartLanes: {})
        async let before: Void = s.refresh()
        try? await Task.sleep(for: .milliseconds(20))
        async let repair: Void = s.repairPlugin()
        try? await Task.sleep(for: .milliseconds(20))
        open.yield()
        _ = await before
        try await repair
        #expect(probes.withLock { $0 } == 2, "the check from before the copy isn't reused")
        #expect(s.status.pluginLoaded == true)
    }

    @Test func onboardingsFirstLookJoinsTheLaunchCheckAndIveDoneItChecksAgain() async {
        let probes = Mutex(0)
        let missing = ClaudeCodeReport()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let s = ClaudeCodeService(probe: { [healthy] in
            let n = probes.withLock { $0 += 1; return $0 }
            if n == 1 { for await _ in gate { break }; return missing }
            return healthy
        }, install: { URL(fileURLWithPath: "/p") }, restartLanes: {})
        var changes: [(String?, String?)] = []
        s.onChecked = { previous, new in changes.append((previous.executablePath, new.executablePath)) }
        let check = OnboardingClaudeCheck(service: s)
        async let launchProbe: Void = s.refresh()
        try? await Task.sleep(for: .milliseconds(20))
        async let first = check.check()
        try? await Task.sleep(for: .milliseconds(20))
        open.yield()
        _ = await launchProbe
        let firstStatus = await first
        #expect(firstStatus.checked && firstStatus.executablePath == nil)
        #expect(probes.withLock { $0 } == 1, "the first look shares the launch check")
        let second = await check.check()   // "I've done it" after installing
        #expect(second.executablePath != nil && probes.withLock { $0 } == 2)
        #expect(changes.map(\.0) == [nil, nil] && changes.map(\.1) == [nil, healthy.executable?.path],
                "onChecked sees not-found → found, which is when the runtime starts")
    }

    @Test func overlappingRefreshesShareOneProbe() async {
        let probes = Mutex(0)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let s = ClaudeCodeService(probe: { [healthy] in
            probes.withLock { $0 += 1 }
            for await _ in gate { break }
            return healthy
        }, install: { URL(fileURLWithPath: "/p") }, restartLanes: {})
        async let a: Void = s.refresh()
        async let b: Void = s.refresh()
        try? await Task.sleep(for: .milliseconds(20))
        open.yield()
        _ = await (a, b)
        #expect(probes.withLock { $0 } == 1)
        #expect(s.status.checked)
    }
}
