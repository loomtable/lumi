import BuddyCore
import Foundation
import Synchronization
import Testing
@testable import BuddyBridge

/// The transports a pool made, in order, and the launches it asked for.
final class Launches: Sendable {
    private let state = Mutex<(launches: [SessionLaunch], transports: [ScriptedTransport])>(([], []))
    let make: @Sendable (Int) -> ScriptedTransport

    init(make: @escaping @Sendable (Int) -> ScriptedTransport = { _ in ScriptedTransport(script: { uuid, _ in SLine.turn(uuid) }) }) {
        self.make = make
    }

    var launches: [SessionLaunch] { state.withLock { $0.launches } }
    var transports: [ScriptedTransport] { state.withLock { $0.transports } }
    var count: Int { state.withLock { $0.transports.count } }

    func spec(_ launch: SessionLaunch) -> LaunchSpec {
        state.withLock { $0.launches.append(launch) }
        return Self.args(launch)
    }

    static func args(_ launch: SessionLaunch) -> LaunchSpec {
        .open(executable: URL(fileURLWithPath: "/c"), launch: launch, permissionMode: nil, environment: [:])
    }

    func transport(_ spec: LaunchSpec) -> any ClaudeTransport {
        state.withLock { s in
            let t = make(s.transports.count)
            s.transports.append(t)
            return t
        }
    }
}

/// A test clock: `now` moves only when told.
final class TestClock: Sendable {
    private let base = ContinuousClock.now
    private let offset = Mutex<Duration>(.zero)
    var now: ContinuousClock.Instant { base + offset.withLock { $0 } }
    func advance(_ d: Duration) { offset.withLock { $0 += d } }
}

private func launch(_ uuid: UUID = UUID(), exists: Bool = false, dirs: [URL] = []) -> SessionLaunch {
    SessionLaunch(claudeSession: uuid, exists: exists, cwd: URL(fileURLWithPath: "/Users/me"), addDirs: dirs)
}

private func pool(_ l: Launches, caps: PoolCaps = PoolCaps(live: 4), clock: TestClock = TestClock(),
                  pressure: AsyncStream<Void>? = nil, restart: RestartPolicy = RestartPolicy(delays: [.zero, .zero]),
                  hosts: Bool = true, mapper: MapperFactory? = nil,
                  lifecycle: (@Sendable (PoolLifecycle) -> Void)? = nil) -> SessionPool {
    SessionPool(caps: caps, spec: { l.spec($0) }, transport: { l.transport($0) }, mapper: mapper ?? SessionPool.defaultMapper,
                memoryPressure: pressure, restart: restart, hostsPermissions: { hosts }, suspendGrace: .milliseconds(50),
                lifecycle: lifecycle, now: { clock.now }, sleep: { _ in })
}

private func collect(_ stream: AsyncStream<SessionEvent>) async -> [SessionEvent] {
    var out: [SessionEvent] = []
    for await e in stream { out.append(e) }
    return out
}

struct SessionPoolTests {
    let a = SessionID(rawValue: "s_a"), b = SessionID(rawValue: "s_b"), c = SessionID(rawValue: "s_c")

    /// Lumi mints the id: `--session-id` first; after a suspend, `--resume` with every folder again.
    @Test func launchesWithSessionIDAndResumesWithAllDirs() async throws {
        let l = Launches()
        let p = pool(l)
        let id = UUID()
        let dirs = [URL(fileURLWithPath: "/Users/me/a"), URL(fileURLWithPath: "/Users/me/b")]
        let events = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch(id, dirs: dirs)))
        #expect(events.contains { if case .turnEnded = $0 { true } else { false } })
        let first = Launches.args(l.launches[0]).arguments
        #expect(first.contains("--session-id") && !first.contains("--resume"))
        await p.suspend(a)
        #expect(await p.liveCount == 0)
        _ = await collect(await p.turn(TurnInput(text: "again"), kind: .typed, to: a, launch: launch(id, dirs: dirs)))
        let second = Launches.args(l.launches[1]).arguments
        #expect(second.contains("--resume") && second.contains(id.uuidString.lowercased()))
        #expect(second.filter { $0 == "/Users/me/a" || $0 == "/Users/me/b" }.count == 2)
    }

    /// At most one process ever holds a Claude session id, however many sends race.
    @Test func singleHolderUnderConcurrentSends() async throws {
        let l = Launches()
        let p = pool(l)
        let l0 = launch()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask { _ = try? await p.send(TurnInput(text: "q\(i)"), kind: .typed, to: a, launch: l0) }
            }
        }
        #expect(l.count == 1)
        #expect(l.transports[0].userLines.count == 5)
    }

    /// Over the cap, the least recently used idle session is suspended.
    @Test func capSuspendsLeastRecentlyUsedIdleSession() async throws {
        let l = Launches()
        let clock = TestClock()
        let p = pool(l, caps: PoolCaps(live: 2), clock: clock)
        for id in [a, b, c] {
            _ = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: id, launch: launch()))
            clock.advance(.seconds(1))
        }
        #expect(await p.liveCount == 2)
        #expect(await !p.isLive(a))
        #expect(await p.isLive(b))
        #expect(await p.isLive(c))
    }

    /// Working sessions count towards the cap but are never picked: the cap is soft.
    @Test func capIsSoftForWorkingSessions() async throws {
        let l = Launches(make: { _ in ScriptedTransport(script: { uuid, _ in [SLine.echo(uuid), SLine.state("running")] }) })
        let clock = TestClock()
        let p = pool(l, caps: PoolCaps(live: 1), clock: clock)
        for id in [a, b] {
            try await p.send(TurnInput(text: "hi"), kind: .typed, to: id, launch: launch())
            clock.advance(.seconds(1))
        }
        #expect(await p.liveCount == 2)
    }

    /// After ten idle minutes the process goes; pinned and on-screen sessions stay.
    @Test func idleSuspendSparesPinnedAndOnScreen() async throws {
        let l = Launches()
        let clock = TestClock()
        let p = pool(l, clock: clock)
        for id in [a, b, c] { _ = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: id, launch: launch())) }
        await p.setPinned(true, b)
        await p.setOnScreen([c])
        clock.advance(.seconds(599))
        await p.sweep(pressure: false)
        #expect(await p.liveCount == 3)
        clock.advance(.seconds(2))
        await p.sweep(pressure: false)
        #expect(await !p.isLive(a))
        #expect(await p.isLive(b))
        #expect(await p.isLive(c))
    }

    /// Never while running, waiting on a permission, or with a teammate open.
    @Test func neverSuspendsWorkingSessions() async throws {
        let scripts: [@Sendable (String, String) -> [Data]] = [
            { u, _ in [SLine.echo(u), SLine.state("running")] },
            { u, _ in [SLine.echo(u), SLine.state("running"), SLine.canUseTool("r1"), SLine.state("requires_action")] },
            { u, _ in SLine.turn(u) + [SLine.taskStarted("t1")] },
        ]
        let l = Launches(make: { i in ScriptedTransport(script: scripts[i]) })
        let clock = TestClock()
        let p = pool(l, clock: clock)
        for id in [a, b, c] { try await p.send(TurnInput(text: "go"), kind: .typed, to: id, launch: launch()) }
        try? await Task.sleep(for: .milliseconds(50))
        clock.advance(.seconds(3600))
        await p.sweep(pressure: true)
        #expect(await p.liveCount == 3)
        // The teammate finishes: now it may go.
        l.transports[2].emit(SLine.taskDone("t1"))
        #expect(await eventually { await p.sweep(pressure: true); return await !p.isLive(c) })
        #expect(await p.isLive(a))
        #expect(await p.isLive(b))
    }

    /// A memory-pressure warning suspends every idle session.
    @Test func memoryPressureSuspendsIdleSessions() async throws {
        let l = Launches()
        let (pressure, warn) = AsyncStream<Void>.makeStream()
        let p = pool(l, pressure: pressure)
        for id in [a, b] { _ = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: id, launch: launch())) }
        #expect(await p.liveCount == 2)
        warn.yield()
        #expect(await eventually { await p.liveCount == 0 })
    }

    /// A project change restarts the process only between turns, with every folder.
    @Test func absorbIsIdleOnlyAndPassesAllDirs() async throws {
        let l = Launches(make: { i in
            ScriptedTransport(script: { u, text in text == "slow" ? [SLine.echo(u), SLine.state("running")] : SLine.turn(u) })
        })
        let p = pool(l)
        let id = UUID()
        let one = URL(fileURLWithPath: "/Users/me/one"), two = URL(fileURLWithPath: "/Users/me/two")
        _ = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch(id, dirs: [one])))
        try await p.absorb(two, session: a, launch: launch(id, exists: true, dirs: [one]))
        #expect(l.count == 2)
        #expect(l.launches[1].addDirs == [one, two])
        #expect(l.transports[0].exited != nil)
        try await p.send(TurnInput(text: "slow"), kind: .typed, to: a, launch: launch(id, exists: true, dirs: [one, two]))
        try? await Task.sleep(for: .milliseconds(30))
        // Working: queued, never skipped, and applied as soon as the session is idle (QA E5).
        let three = URL(fileURLWithPath: "/Users/me/three")
        try await p.absorb(three, session: a, launch: launch(id, exists: true, dirs: [one, two]))
        #expect(l.count == 2)
        l.transports[1].emit(SLine.result("done"))
        l.transports[1].emit(SLine.state("idle"))
        #expect(await eventually { l.count == 3 })
        #expect(l.launches[2].addDirs == [one, two, three])
    }

    /// AskUserQuestion through the Panel's port: the original input plus `answers`.
    @Test func questionAnswersEchoTheInput() async throws {
        let l = Launches(make: { _ in ScriptedTransport(script: { u, _ in
            let ask: [String: Any] = ["questions": [["question": "Which?", "header": "Pick", "multiSelect": false,
                                                     "options": [["label": "A"], ["label": "B"]]]]]
            return [SLine.echo(u), SLine.state("running"), SLine.canUseTool("q1", tool: "AskUserQuestion", input: ask)]
        }) })
        let p = pool(l)
        try await p.send(TurnInput(text: "go"), kind: .typed, to: a, launch: launch())
        #expect(await eventually { await p.isWorking(a) })
        try? await Task.sleep(for: .milliseconds(20))
        await p.answer("q1", answers: ["Which?": ["B"]], session: a)
        let reply = l.transports[0].controlResponses.first { $0["request_id"] as? String == "q1" }
        let input = (reply?["response"] as? [String: Any])?["updatedInput"] as? [String: Any]
        #expect((input?["answers"] as? [String: String]) == ["Which?": "B"])
        #expect((input?["questions"] as? [Any])?.count == 1)
    }

    /// The router absorbed a folder: the next send restarts an idle process with every folder; a
    /// working one keeps going.
    @Test func sendWithNewFoldersRespawnsOnlyWhenIdle() async throws {
        let l = Launches(make: { _ in
            ScriptedTransport(script: { u, text in text == "slow" ? [SLine.echo(u), SLine.state("running")] : SLine.turn(u) })
        })
        let p = pool(l)
        let id = UUID()
        let one = URL(fileURLWithPath: "/Users/me/one"), two = URL(fileURLWithPath: "/Users/me/two")
        _ = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch(id, dirs: [one])))
        _ = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch(id, exists: true, dirs: [one, two])))
        #expect(l.count == 2)
        #expect(l.launches[1].addDirs == [one, two] && l.launches[1].exists)
        try await p.send(TurnInput(text: "slow"), kind: .typed, to: a, launch: launch(id, exists: true, dirs: [one, two]))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await p.isWorking(a))
        try await p.send(TurnInput(text: "more"), kind: .typed, to: a,
                         launch: launch(id, exists: true, dirs: [one, two, URL(fileURLWithPath: "/Users/me/three")]))
        #expect(l.count == 2)
        // A different Claude session never lands in the running one (QA E7).
        await #expect(throws: PoolError.busy) {
            try await p.send(TurnInput(text: "x"), kind: .typed, to: a, launch: launch(UUID(), exists: false))
        }
    }

    /// Live (Oct 29): a hand-off whose session restarts for its folder. The old process looked free
    /// (idle, nothing waiting) while its mapper still held a turn open (a result that never came);
    /// its exit must not end the hand-off's turn on the new process.
    @Test func aRestartForNewFoldersNeverEndsTheTurnWaitingOnTheNewProcess() async throws {
        let l = Launches(make: { n in
            ScriptedTransport(script: { u, _ in n == 0 ? [SLine.echo(u), SLine.state("running"), SLine.state("idle")] : SLine.turn(u) })
        })
        let p = pool(l)
        let id = UUID()
        let one = URL(fileURLWithPath: "/Users/me/one"), two = URL(fileURLWithPath: "/Users/me/two")
        try await p.send(TurnInput(text: "earlier"), kind: .voice, to: a, launch: launch(id, dirs: [one]))
        let deadline = ContinuousClock.now + .seconds(30)
        while await p.isWorking(a), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await !p.isWorking(a), "free by the pool's rules")
        let events = await collect(await p.turn(TurnInput(text: "hand-off"), kind: .voice, to: a,
                                                launch: launch(id, exists: true, dirs: [one, two])))
        #expect(l.count == 2, "restarted with the new folder")
        #expect(events.contains { if case .turnEnded(let e) = $0 { e.markdown == "Done." } else { false } },
                "the hand-off's answer arrives")
        #expect(!events.contains(.processEnded(status: 0, midTurn: true)))
    }

    /// QA R20, on a recorded stream (`background-subagent.jsonl`): a background teammate finishes just
    /// after the user sends, and the CLI runs a turn of its own before the user's. That turn goes to
    /// the session's feed, never into the user's turn stream.
    @Test func aTurnTheCLIStartsItselfNeverLeaksIntoTheUsersTurn() async throws {
        let recorded = try Fixture.lines("background-subagent.jsonl")
        let firstTurn = Array(recorded[0...72]), autoTurn = Array(recorded[73...103])
        let sends = Mutex(0)
        let l = Launches(make: { _ in ScriptedTransport(script: { u, _ in
            let n = sends.withLock { $0 += 1; return $0 }
            if n == 1 { return [SLine.echo(u), SLine.state("running")] + firstTurn }
            return autoTurn + [SLine.echo(u), SLine.text("Mine."), SLine.result("Mine.", uuids: [u]), SLine.state("idle")]
        }) })
        let p = pool(l)
        let all = await p.allEvents()
        let claude = UUID()
        _ = await collect(await p.turn(TurnInput(text: "start a teammate"), kind: .typed, to: a, launch: launch(claude)))
        let mine = await collect(await p.turn(TurnInput(text: "and now?"), kind: .voice, to: a, launch: launch(claude, exists: true)))
        let texts = mine.compactMap { if case .text(let t, _) = $0 { t } else { nil } }.joined()
        #expect(texts == "Mine.")
        #expect(!mine.contains { if case .say = $0 { true } else { false } })
        let ends = mine.compactMap { if case .turnEnded(let e) = $0 { e } else { nil } }
        #expect(ends.map(\.markdown) == ["Mine."])
        #expect(ends.first?.kind == .voice)
        // The teammate's turn reached the session's feed, as a turn of its own.
        var feed: [TurnEnd] = []
        for await e in all {
            if case .turnEnded(let end) = e.event { feed.append(end) }
            if feed.count == 3 { break }
        }
        #expect(feed.map(\.kind) == [.typed, .typed, .voice])
        #expect(feed[1].markdown.contains("The subagent reported"))
    }

    /// The user's line lands inside the CLI's own turn: that turn's end answers it, and only what came
    /// after the line is this turn's.
    @Test func aLineFoldedIntoTheCLIsTurnEndsWithIt() async throws {
        let l = Launches(make: { _ in ScriptedTransport(script: { u, _ in
            [SLine.state("running"), SLine.text("Teammate done. "), SLine.echo(u), SLine.text("Also yours."),
             SLine.result("Teammate done. Also yours."), SLine.state("idle")]
        }) })
        let p = pool(l)
        let events = await collect(await p.turn(TurnInput(text: "and?"), kind: .typed, to: a, launch: launch()))
        let texts = events.compactMap { if case .text(let t, _) = $0 { t } else { nil } }.joined()
        #expect(texts == "Also yours.")
        #expect(events.contains { if case .turnEnded(let e) = $0 { e.markdown == "Teammate done. Also yours." } else { false } })
    }

    /// QA E1: a minted Claude id that never got a line (prelaunch, then suspend) has no JSONL; a later
    /// send that says `exists` starts it fresh instead of failing for good.
    @Test func aPrelaunchedSessionThatNeverSentStartsFresh() async throws {
        let l = Launches()
        let p = pool(l)
        let id = UUID()
        await p.prelaunch(a, launch(id))
        #expect(await p.suspend(a))
        let events = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch(id, exists: true)))
        #expect(events.contains { if case .turnEnded(let e) = $0 { !e.isError } else { false } })
        let args = Launches.args(l.launches[1]).arguments
        #expect(args.contains("--session-id") && !args.contains("--resume"))
    }

    /// An edited prompt: the process is relaunched at once, resuming at the prompt's parent; the
    /// edited line goes to that process, and once the CLI took it later launches resume plainly.
    /// Another Claude session never gets the resume point.
    @Test func rewindResumesOnceAtTheParent() async throws {
        let l = Launches()
        let p = pool(l)
        let id = UUID()
        _ = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch(id)))
        #expect(await p.rewind(a, launch: launch(id, exists: true), to: "parent-1"))
        #expect(l.count == 2 && l.transports[0].exited != nil)
        #expect(l.launches[1].resumeAt == "parent-1")
        let args = Launches.args(l.launches[1]).arguments
        #expect(args.firstIndex(of: "--resume-session-at").map { args[$0 + 1] } == "parent-1")
        let events = await collect(await p.turn(TurnInput(text: "edited"), kind: .typed, to: a, launch: launch(id, exists: true)))
        #expect(events.contains { if case .turnEnded(let e) = $0 { !e.isError } else { false } })
        #expect(l.count == 2, "the edited line goes to the relaunched process")
        #expect(l.transports[1].userLines.count == 1)
        #expect(await p.suspend(a))
        _ = await collect(await p.turn(TurnInput(text: "next"), kind: .typed, to: a, launch: launch(id, exists: true)))
        #expect(l.launches[2].resumeAt == nil)

        #expect(await p.rewind(a, launch: launch(id, exists: true), to: "parent-2"))
        _ = await collect(await p.turn(TurnInput(text: "other"), kind: .typed, to: a, launch: launch(UUID())))
        #expect(l.launches[4].resumeAt == nil)
    }

    /// The CLI refuses the resume point (it exits at boot, "No message found"): false at once, no
    /// retries, and the next launch resumes the conversation as it was.
    @Test func aRefusedResumePointFailsAtOnceAndIsDropped() async throws {
        let l = Launches(make: { i in
            let t = ScriptedTransport(answersInitialize: i != 1, script: { u, _ in SLine.turn(u) })
            if i == 1 { t.crash(stderr: "No message found with message.uuid of: parent-1") }
            return t
        })
        let p = pool(l)
        let id = UUID()
        _ = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch(id)))
        #expect(await p.rewind(a, launch: launch(id, exists: true), to: "parent-1") == false)
        #expect(l.count == 2)
        _ = await collect(await p.turn(TurnInput(text: "again"), kind: .typed, to: a, launch: launch(id, exists: true)))
        #expect(l.launches[2].resumeAt == nil)
    }

    /// Never while the session works: the running turn keeps its process.
    @Test func rewindIsRefusedWhileWorking() async throws {
        let l = Launches(make: { _ in ScriptedTransport(script: { u, _ in [SLine.echo(u), SLine.state("running")] }) })
        let p = pool(l)
        let id = UUID()
        _ = try await p.send(TurnInput(text: "long"), kind: .typed, to: a, launch: launch(id))
        #expect(await eventually { await p.isWorking(a) })
        #expect(await p.rewind(a, launch: launch(id, exists: true), to: "parent-1") == false)
        #expect(await p.liveCount == 1 && l.count == 1)
    }

    /// QA E7: a new Claude session for the same Lumi session restarts an idle process.
    @Test func aNewClaudeSessionRestartsTheProcess() async throws {
        let l = Launches()
        let p = pool(l)
        _ = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch()))
        let fresh = UUID()
        _ = await collect(await p.turn(TurnInput(text: "again"), kind: .typed, to: a, launch: launch(fresh)))
        #expect(l.count == 2)
        #expect(l.launches[1].claudeSession == fresh)
        #expect(l.transports[0].exited != nil)
    }

    /// QA E2/E11: Continue relaunches with RESUME_INTERRUPTED_TURN and no user line; the turn keeps
    /// its kind and uuid, and ends at its result.
    @Test func continueResumesTheTurnWithItsKind() async throws {
        let l = Launches(make: { _ in ScriptedTransport() })
        let p = pool(l)
        let id = UUID()
        let stream = await p.resume(a, launch: launch(id, exists: true), kind: .voice, uuid: "u-orig")
        #expect(await eventually { l.count == 1 })
        let t = l.transports[0]
        t.emit(SLine.state("running"))
        t.emit(SLine.text("Picking up where I was."))
        t.emit(SLine.result("Picking up where I was.", uuids: ["u-orig"]))
        t.emit(SLine.state("idle"))
        let events = await collect(stream)
        #expect(events.contains(.turnStarted(userUUID: "u-orig", kind: .voice)))
        #expect(events.contains { if case .turnEnded(let e) = $0 { e.kind == .voice } else { false } })
        #expect(t.userLines.isEmpty)
        #expect(l.launches[0].continueInterrupted)
        #expect(Launches.args(l.launches[0]).environment["CLAUDE_CODE_RESUME_INTERRUPTED_TURN"] == "1")
        #expect(await eventually { await !p.isWorking(a) })
    }

    /// QA R22: at quit, a session where only a teammate still works isn't Interrupted (there's no
    /// lead turn to resume); its teammate "didn't finish". A lead turn in flight is Interrupted.
    @Test func quitWithOnlyATeammateWorkingIsNotInterrupted() async throws {
        let l = Launches(make: { i in ScriptedTransport(script: { u, _ in
            i == 0 ? SLine.turn(u) + [SLine.taskStarted("t1"), SLine.state("running")] : [SLine.echo(u), SLine.state("running")]
        }) })
        let p = pool(l)
        let feed = await p.allEvents()
        _ = await collect(await p.turn(TurnInput(text: "start a teammate"), kind: .typed, to: a, launch: launch()))
        try await p.send(TurnInput(text: "go"), kind: .typed, to: b, launch: launch())
        try? await Task.sleep(for: .milliseconds(30))
        let mid = await p.shutdownAll()
        #expect(mid == [b])
        #expect(l.transports[0].exited == 143)
        var ended: TaskEnd?
        for await e in feed where e.id == a {
            if case .task(.ended("t1", let status, let summary)) = e.event {
                ended = status
                #expect(summary == "Didn't finish")
            }
            if case .processEnded = e.event { break }
        }
        #expect(ended == .stopped)
    }

    /// QA R22: a Continue that finds nothing to resume (the CLI goes idle with no turn) ends at once
    /// as nothing_to_resume and releases the process, instead of spinning.
    @Test func continueWithNothingToResumeEnds() async throws {
        let l = Launches(make: { _ in ScriptedTransport() })
        let p = pool(l)
        let stream = await p.continueInterrupted(a, launch: launch(UUID(), exists: true), kind: .voice, uuid: "u-orig")
        #expect(await eventually { l.count == 1 })
        l.transports[0].emit(SLine.state("idle"))
        let events = await collect(stream)
        guard case .turnEnded(let end)? = events.last else { Issue.record("no end: \(events)"); return }
        #expect(end.error?.reason == .unavailable(SessionPool.nothingToResume))
        #expect(await eventually { await p.liveCount == 0 })
    }

    /// QA R22, live: the CLI may instead run an empty turn (attributed to the lead's uuid) and go idle.
    /// That's nothing resumed too, not an empty answer.
    @Test func continueThatRunsAnEmptyTurnIsNothingToResume() async throws {
        let l = Launches(make: { _ in ScriptedTransport() })
        let p = pool(l)
        let stream = await p.continueInterrupted(a, launch: launch(UUID(), exists: true), kind: .typed, uuid: "u-lead")
        #expect(await eventually { l.count == 1 })
        let t = l.transports[0]
        t.emit(SLine.state("running"))
        t.emit(SLine.result("", uuids: ["u-lead"]))
        t.emit(SLine.state("idle"))
        let events = await collect(stream)
        guard case .turnEnded(let end)? = events.last else { Issue.record("no end: \(events)"); return }
        #expect(end.error?.reason == .unavailable(SessionPool.nothingToResume))
    }

    /// QA E12: "interrupt and redirect" sends the line with priority now.
    @Test func priorityNowGoesOnTheLine() async throws {
        let l = Launches()
        let p = pool(l)
        try await p.send(TurnInput(text: "stop, do this instead"), kind: .typed, to: a, launch: launch(), priority: "now")
        #expect(l.transports[0].userLines.first?["priority"] as? String == "now")
    }

    /// The read model hears every session, background ones included.
    @Test func allEventsCoverEverySession() async throws {
        let l = Launches()
        let p = pool(l)
        let all = await p.allEvents()
        _ = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch()))
        _ = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: b, launch: launch()))
        var ended: Set<SessionID> = []
        for await e in all {
            if case .turnEnded = e.event { ended.insert(e.id) }
            if ended == [a, b] { break }
        }
        #expect(ended == [a, b])
    }

    /// A `claude` that dies before starting up is restarted; one that keeps dying is unavailable.
    @Test func crashAtBootRetriesThenGivesUp() async throws {
        let l = Launches(make: { i in
            let t = ScriptedTransport(answersInitialize: i >= 2, script: { u, _ in SLine.turn(u) })
            if i < 2 { t.crash(stderr: "boom") }
            return t
        })
        let p = pool(l)
        let events = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch()))
        #expect(l.count == 3)
        #expect(events.contains { if case .turnEnded(let e) = $0 { !e.isError } else { false } })

        let dead = Launches(make: { _ in let t = ScriptedTransport(answersInitialize: false); t.crash(stderr: "logged out"); return t })
        let q = pool(dead)
        await #expect(throws: PoolError.unavailable("logged out")) {
            try await q.send(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch())
        }
        #expect(dead.count == 3)
    }

    /// Mid-turn (the CLI took the line) a crash is reported, never retried.
    @Test func crashMidTurnIsReportedNotRetried() async throws {
        let l = Launches(make: { _ in ScriptedTransport(script: { u, _ in [SLine.echo(u), SLine.state("running")] }) })
        let p = pool(l)
        let stream = await p.turn(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch())
        let crasher = Task {
            #expect(await eventually { l.transports.first?.userLines.isEmpty == false })
            try? await Task.sleep(for: .milliseconds(20))
            l.transports[0].crash(status: 9)
        }
        let events = await collect(stream)
        await crasher.value
        #expect(events.last == .processEnded(status: 9, midTurn: true))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(l.count == 1)
    }

    /// `--resume` of a session Claude Code no longer has.
    @Test func missingSessionOnResume() async throws {
        let marker = "No conversation found with session ID: x"
        let l = Launches(make: { _ in
            let t = ScriptedTransport(answersInitialize: false)
            t.emit(SLine.result("", isError: true, errors: [marker]))
            t.crash(stderr: marker)
            return t
        })
        let p = pool(l)
        await #expect(throws: PoolError.sessionNotFound) {
            try await p.send(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch(exists: true))
        }
        #expect(l.count == 1)
    }

    /// Quit: running turns are interrupted and reported; every process stops.
    @Test func shutdownAllReportsMidTurnSessions() async throws {
        let l = Launches(make: { i in
            ScriptedTransport(script: { u, _ in i == 0 ? [SLine.echo(u), SLine.state("running")] : SLine.turn(u) })
        })
        let p = pool(l)
        try await p.send(TurnInput(text: "go"), kind: .typed, to: a, launch: launch())
        _ = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: b, launch: launch()))
        try? await Task.sleep(for: .milliseconds(20))
        let mid = await p.shutdownAll()
        #expect(mid == [a])
        // SIGTERM, no interrupt: an interrupt would be recorded as the user's (QA E2).
        #expect(l.transports[0].controlRequests("interrupt").isEmpty)
        #expect(l.transports[0].exited == 143)
        #expect(l.transports.allSatisfy { $0.exited != nil })
        await #expect(throws: PoolError.closed) { try await p.send(TurnInput(text: "x"), kind: .typed, to: a, launch: launch()) }
    }

    /// Launch, resume and suspend reach the trace log, with start-up time and idle time.
    @Test func lifecycleIsReportedForTheTraceLog() async throws {
        let l = Launches()
        let clock = TestClock()
        let seen = Mutex<[PoolLifecycle]>([])
        let p = pool(l, clock: clock, lifecycle: { e in seen.withLock { $0.append(e) } })
        let id = UUID()
        _ = await collect(await p.turn(TurnInput(text: "hi"), kind: .typed, to: a, launch: launch(id)))
        clock.advance(.seconds(601))
        await p.sweep(pressure: false)
        _ = await collect(await p.turn(TurnInput(text: "again"), kind: .typed, to: a, launch: launch(id)))
        let events = seen.withLock { $0 }
        guard events.count == 3, case .launched(a, false, _) = events[0], case .suspended(a, let idle, .idle) = events[1],
              case .launched(a, true, let startup) = events[2] else {
            Issue.record("unexpected \(events)")
            return
        }
        #expect(idle >= .seconds(601))
        #expect(startup < .seconds(1))
    }

    /// Every subscriber gets the events; a late one first gets the current state and open asks.
    @Test func eventsFanOutAndReplayTheLatestState() async throws {
        let l = Launches(make: { _ in
            ScriptedTransport(script: { u, _ in [SLine.echo(u), SLine.state("running"), SLine.canUseTool("r1"), SLine.state("requires_action")] })
        })
        let p = pool(l)
        let early = await p.events(for: a)
        try await p.send(TurnInput(text: "go"), kind: .typed, to: a, launch: launch())
        var seen: [SessionEvent] = []
        for await e in early {
            seen.append(e)
            if e == .runState(.requiresAction) { break }
        }
        #expect(seen.contains { if case .permissionRequested = $0 { true } else { false } })
        var late: [SessionEvent] = []
        for await e in await p.events(for: a) {
            late.append(e)
            if late.count == 2 { break }
        }
        #expect(late.first == .runState(.requiresAction))
        if case .permissionRequested(let ask)? = late.last { #expect(ask.id == "r1") } else { Issue.record("no replayed ask") }
        // Answered: the CLI gets the reply, once.
        #expect(await p.answer("r1", .allow(updatedInput: nil), session: a))
        #expect(await !p.answer("r1", .deny(message: nil), session: a))
        let replies = l.transports[0].controlResponses.filter { $0["request_id"] as? String == "r1" }
        #expect(replies.count == 1)
        #expect((replies.first?["response"] as? [String: Any])?["behavior"] as? String == "allow")
    }
}

struct SuspendPolicyTests {
    @Test func neverSuspendWhileAnyRuleHolds() {
        let free = SuspendFacts(runState: .idle)
        #expect(SuspendPolicy.canSuspend(free))
        #expect(SuspendPolicy.canSuspend(SuspendFacts()))
        let busy: [SuspendFacts] = [
            SuspendFacts(runState: .running), SuspendFacts(runState: .requiresAction),
            SuspendFacts(runState: .idle, turnInFlight: true), SuspendFacts(runState: .idle, openTasks: 1),
            SuspendFacts(runState: .idle, pendingPermissions: 1), SuspendFacts(runState: .idle, pinned: true),
            SuspendFacts(runState: .idle, onScreen: true),
        ]
        for f in busy { #expect(!SuspendPolicy.canSuspend(f)) }
        #expect(SuspendPolicy.canRespawn(SuspendFacts(runState: .idle, pinned: true, onScreen: true)))
        #expect(!SuspendPolicy.canRespawn(SuspendFacts(runState: .running, pinned: true)))
    }

    @Test func victimsAreLeastRecentlyUsedFirst() {
        let t0 = ContinuousClock.now
        let ids = (0..<4).map { SessionID(rawValue: "s_\($0)") }
        let live = ids.enumerated().map { i, id in
            SuspendPolicy.Candidate(id: id, facts: SuspendFacts(runState: i == 0 ? .running : .idle), lastUsed: t0 + .seconds(i))
        }
        let caps = PoolCaps(live: 2)
        #expect(SuspendPolicy.victims(live, caps: caps, now: t0 + .seconds(5), pressure: false) == [ids[1], ids[2]])
        #expect(SuspendPolicy.victims(live, caps: caps, now: t0 + .seconds(5), pressure: false, keep: ids[1]) == [ids[2], ids[3]])
        #expect(SuspendPolicy.victims(live, caps: caps, now: t0 + .seconds(5), pressure: true) == [ids[1], ids[2], ids[3]])
        #expect(SuspendPolicy.victims(live, caps: PoolCaps(live: 8), now: t0 + .seconds(602), pressure: false) == [ids[1], ids[2]])
    }

    @Test func capsFollowMemory() {
        let gb: UInt64 = 1_073_741_824
        #expect(PoolCaps.forMemory(8 * gb).live == 2)
        #expect(PoolCaps.forMemory(16 * gb).live == 4)
        #expect(PoolCaps.forMemory(24 * gb).live == 6)
        #expect(PoolCaps.forMemory(32 * gb).live == 8)
        #expect(PoolCaps.forMemory(128 * gb).live == 8)
        #expect(PoolCaps.forMemory(16 * gb).idleSuspend == .seconds(600))
    }

    @Test func ledgerReapsOnlyTheSameClaudeProcessesAndClears() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = "/Users/me/.local/share/claude/versions/2.1.312"
        // A fake process table: what each pid is now.
        let table = FakeProcessTable([
            101: .init(start: 1_000, path: claude), 102: .init(start: 2_000, path: claude),
            103: .init(start: 3_000, path: claude), 104: .init(start: 4_000, path: "/bin/zsh"),
        ])
        let ledger = ProcessLedger(file: dir.appendingPathComponent("sessions.json"), table: { table.identity($0) })
        for pid: pid_t in [101, 102, 103, 104, 101, 105] { ledger.record(pid) }
        ledger.remove(103)
        #expect(ledger.read().map(\.pid) == [101, 102, 104], "no duplicates; 105 has no identity, so it isn't kept")

        // Next launch: 101 is the same claude; 102's pid was reused by the user's own claude in a
        // terminal (same path, later start); 104 isn't a claude.
        table.set(102, .init(start: 9_000, path: claude))
        let stopped = Mutex<[pid_t]>([])
        let reaped = ledger.reapOrphans(stop: { pid in stopped.withLock { $0.append(pid) } })
        #expect(reaped == [101])
        #expect(stopped.withLock { $0 } == [101], "a reused pid is never signalled")
        #expect(ledger.read().isEmpty)
    }

    @Test func ledgerSkipsGonePidsAndUnverifiableFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sessions.json")
        let gone = ProcessLedger(file: file, table: { _ in .init(start: 1, path: "/opt/claude") })
        gone.record(201)
        let reaped = ProcessLedger(file: file, table: { _ in nil }).reapOrphans(stop: { _ in Issue.record("signalled a gone pid") })
        #expect(reaped.isEmpty)

        // An earlier build's bare pid list: nothing to verify, so nothing is signalled.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("[301, 302]".utf8).write(to: file)
        let old = ProcessLedger(file: file, table: { _ in .init(start: 1, path: "/opt/claude") })
        #expect(old.reapOrphans(stop: { _ in Issue.record("signalled an unverified pid") }).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path), "and the file is cleared")
    }

    @Test func theLiveTableKnowsThisProcess() throws {
        let me = try #require(ProcessLedger.identity(getpid()))
        #expect(me.start > 0 && me.path.hasPrefix("/"))
        #expect(ProcessLedger.identity(getpid()) == me, "stable across reads")
    }
}

/// A process table for ledger tests: what each pid is now.
final class FakeProcessTable: Sendable {
    private let rows: Mutex<[pid_t: ProcessIdentity]>
    init(_ rows: [pid_t: ProcessIdentity]) { self.rows = Mutex(rows) }
    func set(_ pid: pid_t, _ identity: ProcessIdentity?) { rows.withLock { $0[pid] = identity } }
    func identity(_ pid: pid_t) -> ProcessIdentity? { rows.withLock { $0[pid] } }
}
