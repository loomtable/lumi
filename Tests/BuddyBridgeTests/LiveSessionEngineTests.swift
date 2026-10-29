import BuddyCore
import Foundation
import Synchronization
import Testing
@testable import BuddyBridge

/// The v2 session engine against the installed `claude` (QA, 30-QA.md "Engine"): open launches,
/// resume, suspend rules, the permission round trip, steer, interrupt, `priority: "now"`,
/// teammates. Each test runs a few tiny Haiku turns in its own folder under
/// `worktrees/_probe-scratch/qa-engine/` (never a real project; the folder's settings pin Haiku).
/// Opt in:
///   BUDDYBRIDGE_LIVE_SESSIONS=1 Scripts/test.sh --filter LiveSessionEngine
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUDDYBRIDGE_LIVE_SESSIONS"] == "1"), .serialized)
struct LiveSessionEngineTests {

    // MARK: 1. Launch, resume, history, resume time, idle RSS

    @Test func anOpenSessionLaunchesWithSessionIDResumesAndKeepsItsHistory() async throws {
        let rig = try await LiveRig.make("launch")
        let folder = try rig.folder("a")
        let pool = rig.pool()
        let id = SessionID.new()
        let claude = UUID()
        let first = SessionLaunch(claudeSession: claude, exists: false, cwd: folder)
        let trace = LiveRig.Recorder(await pool.events(for: id))

        let one = await rig.turn(pool, "Remember the word PLUM. Reply with just: ok", id: id, launch: first)
        let end1 = try #require(one.turnEnd, "first turn ended: \(one)")
        #expect(!end1.isError, "\(end1)")
        let args1 = try #require(rig.specs.first?.arguments)
        #expect(args1.contains("--session-id") && args1.contains(claude.uuidString.lowercased()), "\(args1)")
        #expect(!args1.contains("--resume") && !args1.contains("--model"), "\(args1)")
        let info = one.compactMap { if case .initialized(let i) = $0 { i } else { nil } }.first
        #expect(info?.sessionID == claude.uuidString.lowercased(), "init carries Lumi's id: \(String(describing: info))")
        print("QA launch: model \(info?.model ?? "?"), permissionMode \(info?.permissionMode ?? "?"), version \(info?.version ?? "?")")

        // Idle RSS of the live process (memory budget, 02 §D3).
        try await Task.sleep(for: .seconds(3))
        if let pid = rig.transports.last?.inner.pid { print("QA idle RSS after 1 turn: \(LiveRig.rssMB(pid)) MB (pid \(pid))") }

        #expect(await pool.suspend(id))
        #expect(await pool.liveCount == 0)
        #expect(LiveRig.jsonl(claude) != nil, "the session's JSONL is on disk")

        // Resume (as LiveSessions passes it: exists true) and ask about the first turn.
        let resumed = SessionLaunch(claudeSession: claude, exists: true, cwd: folder)
        let two = await rig.turn(pool, "What word did I ask you to remember? Reply with the word only.", id: id, launch: resumed)
        let end2 = try #require(two.turnEnd)
        #expect(end2.markdown.uppercased().contains("PLUM"), "history persisted across suspend: \(end2.markdown)")
        let args2 = try #require(rig.specs.last?.arguments)
        #expect(args2.contains("--resume") && args2.contains(claude.uuidString.lowercased()), "\(args2)")
        try await Task.sleep(for: .seconds(2))
        print("QA after resumed turn: working=\(await pool.isWorking(id)) events=\(trace.all.compactMap { e -> String? in switch e { case .runState(let s): "state:\(s)"; case .turnStarted(let u, _): "start:\(u?.prefix(4) ?? "nil")"; case .turnEnded(let t): "end(err:\(t.isError))"; case .launched(let r): "launched(resumed:\(r))"; case .processEnded: "exit"; case .task(let t): "task:\(t)"; default: nil } })")

        // Resume start-up time, three times, no API call (prelaunch answers `initialize` only).
        var startups: [Duration] = []
        for _ in 0..<3 {
            #expect(await pool.suspend(id))
            rig.lifecycle.withLock { $0 = [] }
            await pool.prelaunch(id, resumed)
            let launched = rig.lifecycle.withLock { $0 }.compactMap { if case .launched(_, true, let d) = $0 { d } else { nil } }
            startups += launched
        }
        let ms = startups.map { Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) }
        print("QA resume start-up (spawn → initialize answered): \(ms) ms; budget ≤ 1200 ms")
        #expect(ms.count == 3 && ms.allSatisfy { $0 <= 1200 }, "resume ≤ 1.2 s: \(ms)")
        _ = await pool.shutdownAll()
        rig.report()
    }

    /// LiveSessions mints the Claude id when it plans a turn and passes `exists: true` from then
    /// on. A process that started (prelaunch) but never got a message, then was suspended, must
    /// still be usable (30-QA E1).
    @Test func aPrelaunchedSessionThatNeverSentStillResumes() async throws {
        let rig = try await LiveRig.make("prelaunch")
        let folder = try rig.folder("a")
        let pool = rig.pool()
        let id = SessionID.new()
        let claude = UUID()
        await pool.prelaunch(id, SessionLaunch(claudeSession: claude, exists: false, cwd: folder))
        #expect(await pool.liveCount == 1)
        #expect(await pool.suspend(id))
        print("QA prelaunch-only JSONL on disk: \(LiveRig.jsonl(claude) != nil)")
        let next = await rig.turn(pool, "Reply with just: ok", id: id, launch: SessionLaunch(claudeSession: claude, exists: true, cwd: folder))
        let end = try #require(next.turnEnd)
        print("QA prelaunch-then-resume end: \(end) stderr=\(rig.transports.last?.stderrTail.suffix(200) ?? "")")
        #expect(!end.isError, "a never-used session resumes or restarts cleanly: \(end)")
        _ = await pool.shutdownAll()
        rig.report()
    }

    // MARK: 2. Idle suspend and the never-suspend rules

    @Test func idleSessionsSuspendAndBusyPinnedOnScreenOnesDont() async throws {
        let rig = try await LiveRig.make("suspend")
        let folder = try rig.folder("a", prompts: true)
        let clock = QALocked<Duration>(.zero)
        let base = ContinuousClock.now
        let pool = rig.pool(now: { base + clock.withLock { $0 } })
        let advance = { clock.withLock { $0 += .seconds(11 * 60) } }
        let id = SessionID.new()
        let launch = SessionLaunch(claudeSession: UUID(), exists: false, cwd: folder)

        let seen = LiveRig.Recorder(await pool.events(for: id))
        _ = await rig.turn(pool, "Reply with just: ok", id: id, launch: launch)
        let idleAfter = await seen.first(timeout: .seconds(20)) { if case .runState(.idle) = $0 { true } else { nil } }
        #expect(idleAfter == true, "the session reports idle after the turn")
        // Pinned: kept.
        await pool.setPinned(true, id)
        advance(); await pool.sweep(pressure: false)
        #expect(await pool.liveCount == 1, "pinned is never suspended")
        await pool.setPinned(false, id)
        // On screen: kept.
        await pool.setOnScreen([id])
        advance(); await pool.sweep(pressure: false)
        #expect(await pool.liveCount == 1, "on screen is never suspended")
        await pool.setOnScreen([])
        // Idle 11 min: suspended.
        advance(); await pool.sweep(pressure: false)
        #expect(await pool.liveCount == 0, "idle 10 min → suspended")
        #expect(rig.lifecycle.withLock { $0 }.contains { if case .suspended(_, _, .idle) = $0 { true } else { false } })

        // Needs-you, then running: a prompted Bash.
        seen.reset()
        _ = try await pool.send(TypedTurn.input(text: "Use the Bash tool to run exactly `touch qa-marker && sleep 6 && echo slept`, then reply with its output.", screen: nil),
                                kind: .typed, to: id, launch: SessionLaunch(claudeSession: launch.claudeSession, exists: true, cwd: folder))
        let ask = try #require(await seen.first(timeout: .seconds(60)) { if case .permissionRequested(let a) = $0 { a } else { nil } })
        advance(); await pool.sweep(pressure: true)
        #expect(await pool.liveCount == 1, "needs-you is never suspended, even under memory pressure")
        #expect(await pool.answer(ask.id, .allow(updatedInput: nil), session: id))
        _ = await seen.first(timeout: .seconds(30)) { if case .step(let s) = $0, s.kind == .bash { s } else { nil } }
        try await Task.sleep(for: .seconds(2))
        advance(); await pool.sweep(pressure: true)
        #expect(await pool.liveCount == 1, "running is never suspended")
        _ = await seen.first(timeout: .seconds(60)) { if case .turnEnded(let e) = $0 { e } else { nil } }

        // An open background task: kept while it runs.
        _ = try await pool.send(TypedTurn.input(text: "Use the Bash tool with run_in_background set to true to run `sleep 12` (allowed). Reply with just: started. Don't wait for it.", screen: nil),
                                kind: .typed, to: id, launch: SessionLaunch(claudeSession: launch.claudeSession, exists: true, cwd: folder))
        if let bgAsk = await seen.first(timeout: .seconds(45), { if case .permissionRequested(let a) = $0 { a } else { nil } }) {
            await pool.answer(bgAsk.id, .allow(updatedInput: nil), session: id)
        }
        let started = await seen.first(timeout: .seconds(45)) { if case .task(.started(let t, _, _, _, let k)) = $0 { (t, k) } else { nil } }
        print("QA background task started: \(String(describing: started))")
        _ = await seen.first(timeout: .seconds(45)) { if case .turnEnded(let e) = $0 { e } else { nil } }
        advance(); await pool.sweep(pressure: false)
        let liveWithTask = await pool.liveCount
        #expect(started == nil || liveWithTask == 1, "an open task keeps the process")
        _ = await seen.first(timeout: .seconds(40)) { if case .task(.ended(let t, let s, _)) = $0 { (t, s) } else { nil } }
        // The CLI starts a turn of its own to report the finished task; wait for it to settle.
        #expect(await seen.settled(timeout: .seconds(60)), "idle again after the task's own turn")
        advance(); await pool.sweep(pressure: false)
        #expect(await pool.liveCount == 0, "after the task ends the idle session suspends")
        print("QA suspend trace: working=\(await pool.isWorking(id)) \(LiveRig.brief(seen.all))")
        _ = await pool.shutdownAll()
        rig.report()
    }

    // MARK: 3. Permission round trip

    @Test func permissionsRoundTripAllowDenyAlwaysAndQuestions() async throws {
        let rig = try await LiveRig.make("perm")
        let folder = try rig.folder("a", prompts: true)
        let pool = rig.pool()
        let id = SessionID.new()
        let claude = UUID()
        var launch = SessionLaunch(claudeSession: claude, exists: false, cwd: folder)
        let seen = LiveRig.Recorder(await pool.events(for: id))

        // Allow.
        _ = try await pool.send(TypedTurn.input(text: "Use the Bash tool to run exactly `ls -1 /tmp > /dev/null; echo qa-allow-7781`, then reply with its output only.", screen: nil), kind: .typed, to: id, launch: launch)
        launch.exists = true
        let allow = try #require(await seen.first(timeout: .seconds(60)) { if case .permissionRequested(let a) = $0 { a } else { nil } })
        print("QA ask: \(allow.title) tool=\(allow.toolName) tier=\(allow.tier)")
        #expect(allow.toolName == "Bash" && allow.tier == .needsClick)
        #expect(await pool.answer(allow.id, .allow(updatedInput: nil), session: id))
        let allowEnd = try #require(await seen.first(timeout: .seconds(60)) { if case .turnEnded(let e) = $0 { e } else { nil } })
        #expect(allowEnd.markdown.contains("qa-allow-7781"), "\(allowEnd.markdown)")
        // The CLI echoes our control_response; it must be ignored (one resolve, process alive).
        let echoes = rig.stdout.filter { $0.contains("\"control_response\"") && $0.contains(allow.id) }
        print("QA control_response echoes for \(allow.id): \(echoes.count)")
        #expect(seen.all.filter { $0 == .permissionResolved(id: allow.id) }.count == 1)
        #expect(await pool.liveCount == 1)

        // Deny.
        _ = try await pool.send(TypedTurn.input(text: "Use the Bash tool to run exactly `ls -1 /tmp > /dev/null; echo qa-deny-5521`. If it is declined, reply with just: declined.", screen: nil), kind: .typed, to: id, launch: launch)
        let deny = try #require(await seen.first(timeout: .seconds(60)) { if case .permissionRequested(let a) = $0, a.id != allow.id { a } else { nil } })
        #expect(await pool.answer(deny.id, .deny(message: "QA declined this."), session: id))
        let denied = await seen.first(timeout: .seconds(30)) { if case .stepFinished(_, true, let p) = $0 { p ?? "" } else { nil } }
        print("QA denied tool_result: \(denied ?? "none")")
        #expect(denied != nil, "the denied tool result is an error")
        let denyEnd = try #require(await seen.first(timeout: .seconds(60)) { if case .turnEnded(let e) = $0, e != allowEnd { e } else { nil } })
        print("QA deny turn: deniedTools=\(denyEnd.deniedTools) answer=\(denyEnd.markdown.prefix(80))")

        // Always this session: the second identical command doesn't ask.
        seen.reset()
        _ = try await pool.send(TypedTurn.input(text: "Use the Bash tool to run exactly `ls -1 /tmp > /dev/null; echo qa-always-1`, then reply with its output only.", screen: nil), kind: .typed, to: id, launch: launch)
        let always = try #require(await seen.first(timeout: .seconds(60)) { if case .permissionRequested(let a) = $0 { a } else { nil } })
        #expect(await pool.answer(always.id, .allowForSession, session: id))
        _ = await seen.first(timeout: .seconds(60)) { if case .turnEnded(let e) = $0 { e } else { nil } }
        seen.reset()
        _ = try await pool.send(TypedTurn.input(text: "Run that exact same Bash command once more, then reply with its output only.", screen: nil), kind: .typed, to: id, launch: launch)
        let again = try #require(await seen.first(timeout: .seconds(60)) { if case .turnEnded(let e) = $0 { e } else { nil } })
        let asked = seen.all.contains { if case .permissionRequested = $0 { true } else { false } }
        #expect(!asked && again.markdown.contains("qa-always-1"), "always-this-session: no second ask; \(again.markdown)")
        let local = folder.appendingPathComponent(".claude/settings.local.json")
        #expect(!FileManager.default.fileExists(atPath: local.path), "'this session' wrote nothing to settings.local.json")

        // AskUserQuestion.
        seen.reset()
        _ = try await pool.send(TypedTurn.input(text: "Use the AskUserQuestion tool to ask me which fruit I prefer, with exactly two options: Mango and Pear. Then reply with exactly the fruit I picked, one word.", screen: nil), kind: .typed, to: id, launch: launch)
        let q = try #require(await seen.first(timeout: .seconds(60)) { if case .questionAsked(let q) = $0 { q } else { nil } })
        let item = try #require(q.items.first)
        print("QA question: \(item.question) options=\(item.options.map(\.label))")
        #expect(await pool.answer(q.id, answers: [item.question: ["Pear"]], session: id))
        let qEnd = try #require(await seen.first(timeout: .seconds(60)) { if case .turnEnded(let e) = $0 { e } else { nil } })
        #expect(qEnd.markdown.contains("Pear"), "\(qEnd.markdown)")
        _ = await pool.shutdownAll()
        rig.report()
    }

    // MARK: 4. Steer, interrupt, priority now

    @Test func aSteerFoldsIntoTheRunningTurnAndAnInterruptKeepsTheProcess() async throws {
        let rig = try await LiveRig.make("steer")
        let folder = try rig.folder("a")
        let pool = rig.pool()
        let id = SessionID.new()
        let launch = SessionLaunch(claudeSession: UUID(), exists: false, cwd: folder)
        let seen = LiveRig.Recorder(await pool.events(for: id))

        let first = try await pool.send(TypedTurn.input(text: "Use the Bash tool to run exactly `sleep 5; echo first-step`, then reply with its output.", screen: nil), kind: .typed, to: id, launch: launch)
        _ = try #require(await seen.first(timeout: .seconds(60)) { if case .step(let s) = $0, s.kind == .bash { s } else { nil } })
        let steer = try await pool.steer("Also end your reply with the word KIWI.", session: id)
        let end = try #require(await seen.first(timeout: .seconds(90)) { if case .turnEnded(let e) = $0 { e } else { nil } })
        try await Task.sleep(for: .seconds(2))
        let results = rig.json.filter { $0["type"] as? String == "result" }
        let uuids = results.compactMap { $0["user_message_uuids"] as? [String] }
        print("QA steer: results=\(results.count) user_message_uuids=\(uuids) answer=\(end.markdown.prefix(80))")
        #expect(results.count == 1 && uuids.first.map { Set($0) == [first, steer] } == true, "one turn holds both lines")
        #expect(end.markdown.uppercased().contains("KIWI"))
        let turnEnds = seen.all.filter { if case .turnEnded = $0 { true } else { false } }
        #expect(turnEnds.count == 1)

        // Interrupt mid-answer: the turn ends quickly; the same process answers next.
        seen.reset()
        _ = try await pool.send(TypedTurn.input(text: "Count from 1 to 400, one number per line, nothing else.", screen: nil), kind: .typed, to: id, launch: launch)
        _ = await seen.first(timeout: .seconds(60)) { if case .text = $0 { true } else { nil } }
        let t0 = ContinuousClock.now
        await pool.interrupt(id)
        let stopped = await seen.first(timeout: .seconds(10)) { if case .turnEnded(let e) = $0 { e } else { nil } }
        print("QA interrupt → turnEnded in \(ContinuousClock.now - t0): \(String(describing: stopped?.isError))")
        #expect(stopped != nil)
        let specsBefore = rig.specs.count
        seen.reset()
        _ = try await pool.send(TypedTurn.input(text: "Reply with just: ok", screen: nil), kind: .typed, to: id, launch: launch)
        let after = try #require(await seen.first(timeout: .seconds(60)) { if case .turnEnded(let e) = $0 { e } else { nil } })
        #expect(!after.isError && rig.specs.count == specsBefore, "same warm process after an interrupt")
        _ = await pool.shutdownAll()
        rig.report()
    }

    /// 30-QA E12: the pool takes `priority: "now"`.
    @Test func priorityNowAbortsTheRunningToolAndRunsAsItsOwnTurn() async throws {
        let rig = try await LiveRig.make("now")
        let folder = try rig.folder("a")
        let pool = rig.pool()
        let id = SessionID.new()
        let launch = SessionLaunch(claudeSession: UUID(), exists: false, cwd: folder)
        let seen = LiveRig.Recorder(await pool.events(for: id))
        _ = try await pool.send(TypedTurn.input(text: "Use the Bash tool to run exactly `sleep 30; echo late`, then reply with its output.", screen: nil), kind: .typed, to: id, launch: launch)
        _ = try #require(await seen.first(timeout: .seconds(60)) { if case .step(let s) = $0, s.kind == .bash { s } else { nil } })
        try await Task.sleep(for: .seconds(1))
        let t0 = ContinuousClock.now
        _ = try await pool.send(TypedTurn.input(text: "Reply with just: NOW-OK", screen: nil), kind: .typed, to: id,
                                launch: SessionLaunch(claudeSession: launch.claudeSession, exists: true, cwd: folder), priority: "now")
        var ends: [TurnEnd] = []
        while ends.count < 2 {
            let known = ends
            guard let e = await seen.first(timeout: .seconds(60), { if case .turnEnded(let e) = $0, !known.contains(e) { e } else { nil } }) else { break }
            ends.append(e)
        }
        print("QA priority now: \(ends.count) turn ends in \(ContinuousClock.now - t0): \(ends.map { $0.markdown.prefix(40) })")
        #expect(ends.last?.markdown.contains("NOW-OK") == true)
        #expect(ContinuousClock.now - t0 < .seconds(25), "the sleep was aborted")
        _ = await pool.shutdownAll()
        rig.report()
    }

    // MARK: 5. Teammates

    @Test func teammatesAreNamedCappedAndTheParentFinishes() async throws {
        let rig = try await LiveRig.make("team")
        let folder = try rig.folder("a")
        let pool = rig.pool()
        let id = SessionID.new()
        let launch = SessionLaunch(claudeSession: UUID(), exists: false, cwd: folder, maxSubagents: 3)
        #expect(rig.spec(launch).environment["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"] == "3")
        let seen = LiveRig.Recorder(await pool.events(for: id))
        _ = try await pool.send(TypedTurn.input(text: """
            In ONE message, call the Agent tool four times in parallel, each with run_in_background: true. \
            Name them alpha, beta, gamma and delta (the `name` field), description "say hi", prompt "Reply with the single word hi.". \
            Then reply with just: launched. Don't wait for them.
            """, screen: nil), kind: .typed, to: id, launch: launch)
        // Wait for the parent to settle: idle after every task ended (the CLI runs its own turns).
        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(2))
            let started = seen.taskStarts.filter { $0.kind == .agent }.count
            let ended = seen.all.filter { if case .task(.ended) = $0 { true } else { false } }.count
            if started > 0, ended >= started, seen.all.last == .runState(.idle) { break }
        }
        let starts = seen.taskStarts
        print("QA teammates started: \(starts.map { "\($0.name ?? "nil")/\($0.kind)" })")
        let capped = rig.stdout.filter { $0.contains("Concurrent subagent limit") }.count
        print("QA cap errors: \(capped)")
        #expect(starts.filter { $0.kind == .agent }.count <= 3, "never more than 3 at once")
        #expect(starts.contains { ["alpha", "beta", "gamma", "delta"].contains($0.name ?? "") }, "names come from the tool input")
        let ends = seen.all.compactMap { if case .task(.ended(let t, let s, _)) = $0 { (t, s) } else { nil } }
        print("QA teammate ends: \(ends)")
        #expect(seen.all.last == .runState(.idle), "parent ends idle")
        #expect(await pool.isWorking(id) == false)
        // Foreground Bash is no teammate.
        seen.reset()
        _ = try await pool.send(TypedTurn.input(text: "Use the Bash tool to run exactly `echo fg-check` (not in the background), then reply with its output.", screen: nil), kind: .typed, to: id, launch: SessionLaunch(claudeSession: launch.claudeSession, exists: true, cwd: folder))
        _ = await seen.first(timeout: .seconds(60)) { if case .turnEnded(let e) = $0 { e } else { nil } }
        let fgTasks = seen.taskStarts
        let rawFg = rig.stdout.filter { $0.contains("task_started") && $0.contains("local_bash") }.count
        print("QA foreground bash: raw task_started local_bash lines=\(rawFg), mapped task starts=\(fgTasks)")
        #expect(fgTasks.isEmpty, "foreground Bash isn't shown as a teammate")
        _ = await pool.shutdownAll()
        rig.report()
    }

    // MARK: 10. Quit mid-turn → Continue

    /// 30-QA E2: quit must leave a turn the env flag can resume.
    @Test func quitMidTurnThenContinueResumesTheInterruptedTurn() async throws {
        let rig = try await LiveRig.make("quit")
        let folder = try rig.folder("a")
        let pool = rig.pool()
        let id = SessionID.new()
        let claude = UUID()
        let launch = SessionLaunch(claudeSession: claude, exists: false, cwd: folder)
        let seen = LiveRig.Recorder(await pool.events(for: id))
        let sent = try await pool.send(TypedTurn.input(text: "Use the Bash tool to run exactly `sleep 8; echo resumed-ok`, then reply with its output only.", screen: nil), kind: .typed, to: id, launch: launch)
        _ = try #require(await seen.first(timeout: .seconds(60)) { if case .step(let s) = $0, s.kind == .bash { s } else { nil } })
        let mid = await pool.shutdownAll()
        #expect(mid == [id], "quit reports the session as mid-turn")
        let tail = (LiveRig.jsonl(claude).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "").split(separator: "\n").suffix(3)
        print("QA JSONL tail after quit: \(tail.map { $0.prefix(160) })")

        // Relaunch: a new pool, Continue = resume with CLAUDE_CODE_RESUME_INTERRUPTED_TURN.
        let pool2 = rig.pool()
        let seen2 = LiveRig.Recorder(await pool2.events(for: id))
        let cont = SessionLaunch(claudeSession: claude, exists: true, cwd: folder, continueInterrupted: true)
        #expect(rig.spec(cont).environment["CLAUDE_CODE_RESUME_INTERRUPTED_TURN"] == "1")
        // What "Interrupted · Continue" calls (AppRuntime.continueInterrupted): the turn's kind and uuid.
        let resumed = await LiveRig.collect(await pool2.continueInterrupted(id, launch: SessionLaunch(claudeSession: claude, exists: true, cwd: folder),
                                                                            kind: .typed, uuid: sent), timeout: .seconds(90))
        let end = resumed.turnEnd
        #expect(await seen2.settled(timeout: .seconds(20)), "idle after the resumed turn")
        #expect(await pool2.isWorking(id) == false, "not stuck working (E2)")
        print("QA continue: \(String(describing: end?.markdown.prefix(120))) working=\(await pool2.isWorking(id)) trace=\(LiveRig.brief(seen2.all))")
        let users = (LiveRig.jsonl(claude).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "").split(separator: "\n")
            .filter { $0.contains("\"type\":\"user\"") }.suffix(2).map { String($0.suffix(220)) }
        print("QA last user lines: \(users)")
        #expect(end?.markdown.contains("resumed-ok") == true, "Continue picks the interrupted turn up")
        _ = await pool2.shutdownAll()
        rig.report()
    }
}

extension LiveSessionEngineTests {
    /// The probe's path: SIGTERM mid-tool (a crash, a force quit), no interrupt first.
    @Test func sigtermMidTurnThenContinueResumesTheTurn() async throws {
        let rig = try await LiveRig.make("sigterm")
        let folder = try rig.folder("a")
        let claude = UUID()
        let launch = SessionLaunch(claudeSession: claude, exists: false, cwd: folder)
        let transport = try rig.transportFactory(rig.spec(launch))
        let p = SessionProcess(id: .new(), launch: launch, transport: transport, mapper: SessionEventMapper(sessionDirs: [folder]),
                               hostsPermissions: { true })
        let seen = LiveRig.Recorder(LiveRig.events(of: p))
        await p.start()
        #expect(await p.ready())
        try await p.send(TypedTurn.input(text: "Use the Bash tool to run exactly `sleep 8; echo resumed-ok`, then reply with its output only.", screen: nil), kind: .typed, uuid: UUID().uuidString.lowercased())
        _ = try #require(await seen.first(timeout: .seconds(60)) { if case .step(let s) = $0, s.kind == .bash { s } else { nil } })
        transport.terminate()
        _ = await p.waitForExit()
        let id = SessionID.new()
        let pool = rig.pool()
        let seen2 = LiveRig.Recorder(await pool.events(for: id))
        await pool.prelaunch(id, SessionLaunch(claudeSession: claude, exists: true, cwd: folder, continueInterrupted: true))
        let end = await seen2.first(timeout: .seconds(90)) { if case .turnEnded(let e) = $0 { e } else { nil } }
        print("QA sigterm continue: \(String(describing: end?.markdown.prefix(120))) trace=\(LiveRig.brief(seen2.all))")
        #expect(end?.markdown.contains("resumed-ok") == true)
        _ = await pool.shutdownAll()
        rig.report()
    }
}

extension LiveSessionEngineTests {
    /// 30-QA R22: Lumi quits while only a background teammate works (the lead already answered).
    /// The session isn't Interrupted, the teammate "didn't finish", and a Continue pressed anyway
    /// ends at once instead of spinning.
    @Test func quitWithOnlyATeammateRunningIsNotInterruptedAndContinueEndsAtOnce() async throws {
        let rig = try await LiveRig.make("r22")
        let folder = try rig.folder("a")
        let pool = rig.pool()
        let id = SessionID.new()
        let claude = UUID()
        let launch = SessionLaunch(claudeSession: claude, exists: false, cwd: folder)
        let seen = LiveRig.Recorder(await pool.events(for: id))
        let lead = try await pool.send(TypedTurn.input(text: """
            Call the Agent tool once with run_in_background: true, name "helper", description "wait a bit", \
            prompt "Use the Bash tool to run exactly `sleep 40`, then reply with the single word done.". \
            Then reply with just: started. Don't wait for it.
            """, screen: nil), kind: .typed, to: id, launch: launch)
        _ = try #require(await seen.first(timeout: .seconds(60)) { if case .turnEnded(let e) = $0 { e } else { nil } })
        let teammate = try #require(await seen.first(timeout: .seconds(30)) { if case .task(.started(let t, _, _, _, .agent)) = $0 { t } else { nil } })
        try await Task.sleep(for: .seconds(4))
        let stillRunning = !seen.all.contains { if case .task(.ended(teammate, _, _)) = $0 { true } else { false } }
        print("QA R22 before quit: teammate \(teammate) running=\(stillRunning) working=\(await pool.isWorking(id))")
        #expect(stillRunning, "the teammate is still working when Lumi quits")

        let t0 = ContinuousClock.now
        let mid = await pool.shutdownAll()
        print("QA R22 quit took \(ContinuousClock.now - t0); midTurn=\(mid)")
        #expect(mid.isEmpty, "not Interrupted: the lead's turn had finished")
        let ended = await seen.first(timeout: .seconds(5)) { if case .task(.ended(teammate, let st, let sum)) = $0 { (st, sum) } else { nil } }
        print("QA R22 teammate end: \(String(describing: ended))")
        #expect(ended?.0 == .stopped && ended?.1 == "Didn't finish")

        // Continue anyway (a stale Interrupted from before the fix, or a double press).
        let pool2 = rig.pool()
        let t1 = ContinuousClock.now
        let resumed = await LiveRig.collect(await pool2.continueInterrupted(id, launch: SessionLaunch(claudeSession: claude, exists: true, cwd: folder),
                                                                            kind: .typed, uuid: lead), timeout: .seconds(60))
        let took = ContinuousClock.now - t1
        print("QA R22 continue: \(took) → \(LiveRig.brief(resumed)) error=\(String(describing: resumed.turnEnd?.error)) live=\(await pool2.liveCount)")
        print("QA R22 resumed text: \(resumed.turnEnd?.markdown.prefix(160) ?? "nil"); started uuid matches lead: \(resumed.contains(.turnStarted(userUUID: lead, kind: .typed)))")
        let after = LiveRig.Recorder(await pool2.events(for: id))
        try await Task.sleep(for: .seconds(3))
        print("QA R22 after continue: \(LiveRig.brief(after.all)) tasks in JSONL tail: \((LiveRig.jsonl(claude).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "").components(separatedBy: "task_started").count - 1)")
        #expect(took < .seconds(20), "Continue ends at once, no spinning")
        // 2.1.312 starts a turn of its own here (attributed to the lead's uuid) with an empty result;
        // the pool ends that Continue as "nothing to resume" so the page keeps Interrupted.
        let end = try #require(resumed.turnEnd, "the Continue stream ends with a turn end")
        #expect(end.error?.reason == .unavailable("nothing_to_resume"), "no empty answer: \(end)")
        #expect(await pool2.isWorking(id) == false)
        _ = await pool2.shutdownAll()
        rig.report()
    }
}

// MARK: - Rig

/// The real `claude` behind a tee that keeps every line, in a scratch folder pinned to Haiku.
final class LiveRig: Sendable {
    /// `LUMI_LIVE_SCRATCH`, else `_probe-scratch/qa-engine` beside the checkout.
    static let scratch = ProcessInfo.processInfo.environment["LUMI_LIVE_SCRATCH"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("_probe-scratch/qa-engine")

    let root: URL
    let claude: URL
    let environment: [String: String]
    let specsBox = QALocked<[LaunchSpec]>([])
    let transportsBox = QALocked<[TeeTransport]>([])
    let lifecycle = QALocked<[PoolLifecycle]>([])

    var specs: [LaunchSpec] { specsBox.withLock { $0 } }
    var transports: [TeeTransport] { transportsBox.withLock { $0 } }
    var stdout: [String] { transports.flatMap { $0.stdout } }
    var json: [[String: Any]] { stdout.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } }

    init(root: URL, claude: URL, environment: [String: String]) {
        self.root = root
        self.claude = claude
        self.environment = environment
    }

    static func make(_ name: String) async throws -> LiveRig {
        let home = NSHomeDirectory()
        var base = ProcessInfo.processInfo.environment
        for key in base.keys where key.hasPrefix("CLAUDE_CODE") || key == "CLAUDECODE" { base[key] = nil }
        let loginPath = await LaunchEnvironment.loginShellPath(shell: base["SHELL"] ?? "/bin/zsh", home: home)
        var env = LaunchEnvironment.make(base: base, loginShellPath: loginPath, home: home)
        env["ANTHROPIC_MODEL"] = "haiku"
        env["CLAUDE_CODE_SUBAGENT_MODEL"] = "haiku"
        let claude = try #require(LaunchEnvironment.locateClaude(preferred: nil, path: env["PATH"] ?? "", home: home), "claude not found")
        let root = scratch.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6).lowercased())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return LiveRig(root: root, claude: claude, environment: env)
    }

    /// A folder with `.claude/settings.json` pinning Haiku. `prompts`: default mode (Bash asks)
    /// instead of the open-session fallback `auto`. Echo and sleep are always allowed.
    func folder(_ name: String, prompts: Bool = false, claudeMD: String? = nil) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        var permissions: [String: Any] = ["allow": prompts ? [] : ["Bash(sleep:*)", "Bash(echo:*)", "Bash(sleep *)", "Bash(echo *)"]]
        if prompts { permissions["defaultMode"] = "default" }
        let settings: [String: Any] = ["model": "haiku", "permissions": permissions]
        try JSONSerialization.data(withJSONObject: settings).write(to: dir.appendingPathComponent(".claude/settings.json"))
        if let claudeMD { try claudeMD.write(to: dir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8) }
        return dir
    }

    /// As `SessionEngine.make` builds it: the user's settings decide `--permission-mode`.
    func spec(_ launch: SessionLaunch) -> LaunchSpec {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let mode = LaunchSpec.openPermissionMode(settingsFiles: LaunchSpec.openSettingsFiles(home: home, cwd: launch.cwd))
        return .open(executable: claude, launch: launch, permissionMode: mode, environment: environment)
    }

    var transportFactory: TransportFactory {
        { [self] spec in
            specsBox.withLock { $0.append(spec) }
            let t = TeeTransport(try ProcessTransport(spec: spec))
            transportsBox.withLock { $0.append(t) }
            return t
        }
    }

    func pool(caps: PoolCaps = PoolCaps(live: 4), now: (@Sendable () -> ContinuousClock.Instant)? = nil) -> SessionPool {
        let lifecycle = lifecycle
        return SessionPool(caps: caps, spec: { [self] in spec($0) }, transport: transportFactory, mapper: SessionPool.defaultMapper,
                           hostsPermissions: { true }, suspendGrace: .seconds(2),
                           lifecycle: { e in lifecycle.withLock { $0.append(e) } }, now: now ?? { .now })
    }

    /// One turn through the pool, collected until it ends.
    func turn(_ pool: SessionPool, _ text: String, id: SessionID, launch: SessionLaunch, kind: TurnKind = .typed) async -> [SessionEvent] {
        await LiveRig.collect(await pool.turn(TypedTurn.input(text: text, screen: nil), kind: kind, to: id, launch: launch))
    }

    static func collect(_ stream: AsyncStream<SessionEvent>, timeout: Duration = .seconds(120)) async -> [SessionEvent] {
        let box = QALocked<[SessionEvent]>([])
        let task = Task { for await e in stream { box.withLock { $0.append(e) } } }
        let killer = Task { try? await Task.sleep(for: timeout); task.cancel() }
        await task.value
        killer.cancel()
        return box.withLock { $0 }
    }

    /// Cost from every `result` (cumulative per process: the last one of each).
    func report() {
        let cost = transports.map { t in
            t.stdout.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                .filter { $0["type"] as? String == "result" }.compactMap { $0["total_cost_usd"] as? Double }.last ?? 0
        }.reduce(0, +)
        print("QA cost (approx): $\(String(format: "%.4f", cost)) over \(transports.count) process(es)")
    }

    /// A process's mapped events alone.
    static func events(of p: SessionProcess) -> AsyncStream<SessionEvent> {
        let (stream, out) = AsyncStream<SessionEvent>.makeStream()
        Task {
            for await o in p.output { if case .event(let e) = o { out.yield(e) } }
            out.finish()
        }
        return stream
    }

    static func jsonl(_ claude: UUID) -> URL? {
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let name = claude.uuidString.lowercased() + ".jsonl"
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func rssMB(_ pid: pid_t) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "rss=", "-p", "\(pid)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let kb = Int(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return kb / 1024
    }

    static func brief(_ events: [SessionEvent]) -> [String] {
        events.compactMap { e -> String? in
            switch e {
            case .runState(let s): "state:\(s)"
            case .turnStarted(let u, _): "start:\(u?.prefix(4) ?? "nil")"
            case .turnEnded(let t): "end(err:\(t.isError))"
            case .launched(let r): "launched(resumed:\(r))"
            case .processEnded(let s, let m): "exit(\(s),mid:\(m))"
            case .task(let t): "task:\(t)"
            case .permissionRequested(let a): "ask:\(a.toolName)"
            case .permissionResolved: "resolved"
            case .step(let s): "step:\(s.kind)"
            case .compacted: "compacted"
            default: nil
            }
        }
    }

    /// Keeps a session's events and finds the first match, waiting for it.
    final class Recorder: Sendable {
        private let box: QALocked<[SessionEvent]>
        private let task: Task<Void, Never>?

        init(_ stream: AsyncStream<SessionEvent>) {
            let box = QALocked<[SessionEvent]>([])
            self.box = box
            task = Task { for await e in stream { box.withLock { $0.append(e) } } }
        }

        deinit { task?.cancel() }

        var all: [SessionEvent] { box.withLock { $0 } }
        /// From now on, `first` and `all` look only at later events.
        func reset() { box.withLock { $0 = [] } }

        var taskStarts: [(name: String?, kind: TaskKind)] {
            all.compactMap { if case .task(.started(_, _, let name, _, let kind)) = $0 { (name, kind) } else { nil } }
        }

        /// The latest run state is idle and has stayed so for a second.
        func settled(timeout: Duration) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                let lastState = all.last { if case .runState = $0 { true } else { false } }
                if lastState == .runState(.idle) {
                    let count = all.count
                    try? await Task.sleep(for: .seconds(1))
                    if all.count == count { return true }
                } else {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            return false
        }

        func first<T: Sendable>(timeout: Duration, _ match: @Sendable (SessionEvent) -> T?) async -> T? {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let hit = all.lazy.compactMap(match).first { return hit }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return all.lazy.compactMap(match).first
        }
    }
}

/// A `ProcessTransport` that keeps every stdout line.
final class TeeTransport: ClaudeTransport {
    let inner: ProcessTransport
    private let out = QALocked<[String]>([])
    let lines: AsyncStream<Data>

    init(_ inner: ProcessTransport) {
        self.inner = inner
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lines = stream
        let out = out
        let source = inner.lines
        Task {
            for await line in source {
                out.withLock { $0.append(String(decoding: line, as: UTF8.self)) }
                continuation.yield(line)
            }
            continuation.finish()
        }
    }

    var stdout: [String] { out.withLock { $0 } }
    func send(_ line: Data) async throws { try await inner.send(line) }
    func closeInput() { inner.closeInput() }
    func terminate() { inner.terminate() }
    func exitStatus() async -> Int32 { await inner.exitStatus() }
    var stderrTail: String { inner.stderrTail }
    var answersStartupHandshake: Bool { inner.answersStartupHandshake }
}

extension [SessionEvent] {
    var turnEnd: TurnEnd? { compactMap { if case .turnEnded(let e) = $0 { e } else { nil } }.last }
}

/// A lock-protected value held by reference, so closures and tasks can share it.
final class QALocked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
