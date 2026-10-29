import BuddyConversations
import BuddyCore
import Foundation
import Synchronization
import Testing
@testable import BuddyApp
@testable import BuddyBridge

/// The v2 session flow against the installed `claude` (QA, 30-QA.md "Engine"): LiveSessions and
/// SummonRouter plan each turn, LiveSessionTurns builds it, the real pool runs it, and the
/// session's JSONL is read back. Haiku, tiny prompts, folders under
/// `worktrees/_probe-scratch/qa-engine/` (a stand-in home and stand-in repos, never real ones).
/// Opt in:
///   BUDDYBRIDGE_LIVE_SESSIONS=1 Scripts/test.sh --filter LiveSessionFlow
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUDDYBRIDGE_LIVE_SESSIONS"] == "1"), .serialized)
struct LiveSessionFlowTests {
    nonisolated static let plugin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("buddy-plugin")

    // MARK: 6 + 11. Voice envelope, typed turns raw, compaction; TranscriptReader on the real JSONL

    @Test func voiceTurnsCarryTheEnvelopeTypedTurnsGoRawAndTheReaderShowsEveryTurn() async throws {
        let flow = try await Flow.make("envelope")
        let plan = await flow.sessions.plan(flow.input(.typed, at: flow.t0, current: nil), packet: flow.packet("start"))
        let launch = try #require(plan.launch)
        let id = plan.id

        let v1 = await flow.run(.voice, "What is two plus two?", id: id, launch: launch)
        let v2 = await flow.run(.voice, "And three plus three?", id: id, launch: launch)
        let typed = await flow.run(.typed, "Reply with only a fenced python code block that prints hi.", id: id, launch: launch)
        let before = await flow.sessions.transcript(id)
        print("QA transcript before compaction: \(before.map { "\($0.kind.map { "\($0)" } ?? "v1"): \($0.question.prefix(30)) → \(($0.markdown ?? $0.block.say).prefix(30))" })")
        #expect(before.filter { $0.kind == .voice }.count == 2 && before.contains { $0.kind == .typed && $0.markdown?.contains("```") == true },
                "voice turns and the typed code-fence turn are read back")
        let compact = await flow.run(.typed, "/compact", id: id, launch: launch)
        let v3 = await flow.run(.voice, "What is four plus four?", id: id, launch: launch)

        #expect(v1.turnEnd?.block != nil && v2.turnEnd?.block != nil && v3.turnEnd?.block != nil, "voice turns get a buddy block")
        #expect(v1.contains { if case .say = $0 { true } else { false } }, "voice turns speak")
        #expect(typed.turnEnd?.block == nil && typed.turnEnd?.markdown.contains("```") == true, "\(String(describing: typed.turnEnd))")
        #expect(!typed.contains { if case .say = $0 { true } else { false } }, "typed turns are silent")
        #expect(compact.contains(.compacted), "/compact compacts: \(compact.suffix(4))")

        // What the CLI recorded as each user message.
        let texts = Flow.userTexts(launch.claudeSession)
        print("QA user lines: \(texts.map { String($0.prefix(60)).replacingOccurrences(of: "\n", with: "⏎") })")
        let voice = texts.filter { $0.hasPrefix("<lumi-voice>") }
        #expect(voice.count == 3)
        #expect(voice.count == 3 && voice[0].contains("<lumi-voice-rules>") && !voice[1].contains("<lumi-voice-rules>")
                && voice[1].contains("Voice turn: reply with exactly one") && voice[2].contains("<lumi-voice-rules>"),
                "full rules, then reminder, then full after compaction")
        #expect(texts.contains("Reply with only a fenced python code block that prints hi."), "typed turn goes raw")
        #expect(!texts.contains { $0.contains("<lumi-voice>") && $0.contains("python") }, "no Lumi prompt on typed turns")

        // TranscriptReader v2 over the same JSONL. 30-QA E3: turns before the compact_boundary
        // stay (its parentUuid is null; logicalParentUuid links back).
        let turns = await flow.sessions.transcript(id)
        print("QA transcript: \(turns.map { "\($0.kind.map { "\($0)" } ?? "v1"): \($0.question.prefix(30)) → \(($0.markdown ?? $0.block.say).prefix(30))" })")
        #expect(turns.map(\.question).contains("What is two plus two?"), "turns before a compaction stay in the transcript")
        #expect(turns.contains { $0.kind == .typed && $0.markdown?.contains("```") == true }, "typed turn with a code fence kept")
        #expect(turns.filter { $0.kind == .voice }.count == 3, "three voice turns")
        #expect(!turns.contains { $0.question == "/compact" || $0.question.contains("<lumi-voice") })
        await flow.end()
    }

    @Test func theReaderShowsTeammatesAndHidesARewoundBranch() async throws {
        let flow = try await Flow.make("reader")
        let plan = await flow.sessions.plan(flow.input(.typed, at: flow.t0, current: nil), packet: flow.packet("start"))
        var launch = try #require(plan.launch)
        let id = plan.id
        _ = await flow.run(.typed, "Remember the word APPLE. Reply with just: ok", id: id, launch: launch)
        launch.exists = true
        let team = await flow.run(.typed, "Use the Agent tool once (foreground, not background) with name scout, description \"say hi\" and prompt \"Reply with the single word hi.\" Then reply with just: done.", id: id, launch: launch)
        print("QA reader teammate events: \(team.compactMap { if case .task(let t) = $0 { "\(t)" } else { nil } })")
        _ = await flow.run(.typed, "Forget APPLE. Remember the word BANANA instead. Reply with just: ok", id: id, launch: launch)

        // Rewind: resume at the end of the teammate turn, so the BANANA turn is a dead branch.
        let lines = Flow.lines(launch.claudeSession)
        let anchor = try #require(lines.last { ($0["type"] as? String) == "assistant" && Flow.text($0).contains("done") }?["uuid"] as? String,
                                  "the teammate turn's last assistant line")
        flow.extraArgs.withLock { $0 = ["--resume-session-at", anchor] }
        await flow.pool.suspend(id)
        _ = await flow.run(.typed, "Which word did I ask you to remember? Reply with the word only.", id: id, launch: launch)
        flow.extraArgs.withLock { $0 = [] }

        let turns = await flow.sessions.transcript(id)
        print("QA rewound transcript: \(turns.map { "\($0.question.prefix(40)) → \(($0.markdown ?? "").prefix(20)) team=\($0.teammates)" })")
        #expect(!turns.contains { $0.question.contains("BANANA") }, "the rewound turn isn't shown")
        #expect(turns.contains { $0.question.contains("Which word") && ($0.markdown ?? "").uppercased().contains("APPLE") })
        // 30-QA E8: 2.1.312 writes sidechains to <session>/subagents/agent-*.jsonl.
        #expect(turns.contains { !$0.teammates.isEmpty }, "the teammate turn names its teammate")
        await flow.end()
    }

    // MARK: 7 + 8. Project change absorbs with --add-dir; the Oct 25 / Oct 26–27 replays don't split

    /// Oct 25: A asked from Safari (Deep ran in home), then four questions with ~/Developer/lumi in
    /// front split off B. v2: they stay in A, which absorbs the repo.
    @Test func oct25ReplayStaysInOneSessionAndAbsorbsTheRepo() async throws {
        let flow = try await Flow.make("oct25")
        let lumi = try flow.repo("lumi", claudeMD: "Project codename: CEDAR-17.")
        let at = { (s: TimeInterval) in flow.t0.addingTimeInterval(s) }

        let a = await flow.sessions.plan(flow.input(.voice, key: Flow.safari, at: at(0), current: nil), packet: flow.packet("trip ideas"))
        #expect(a.harness == .quick, "a fresh spoken summons starts on Quick")
        // Quick hands off to Deep → in v2 an open session under A (AppRuntime's resolve, still nil today).
        let open = try #require(await flow.sessions.launch(for: a.id))
        _ = await flow.run(.voice, "Remember the word MAPLE. Say ok.", id: a.id, launch: open)

        var claude: Set<UUID> = [open.claudeSession]
        var ids: Set<SessionID> = [a.id]
        for (n, s) in [128.0, 140, 150, 152].enumerated() {
            let plan = await flow.sessions.plan(flow.input(.voice, key: Flow.iterm, project: lumi.path, trusted: true, at: at(s), current: a.id),
                                                packet: flow.packet("question \(n)"))
            ids.insert(plan.id)
            if let l = plan.launch { claude.insert(l.claudeSession) }
            #expect(plan.launch?.addDirs.map(\.path).contains(lumi.path) == true, "the repo is absorbed: \(String(describing: plan.launch))")
            if n == 0, let l = plan.launch {
                let r = await flow.run(.voice, "What is the project codename, and which word did I ask you to remember? Answer as CODENAME WORD.", id: plan.id, launch: l)
                let said = (r.turnEnd?.block?.say ?? "") + (r.turnEnd?.markdown ?? "")
                print("QA oct25 absorbed turn: \(said.prefix(160))")
                #expect(said.uppercased().contains("MAPLE"), "same Claude session, history kept")
                #expect(said.uppercased().contains("CEDAR"), "the absorbed repo's CLAUDE.md is loaded")
            }
        }
        #expect(ids == [a.id], "no split: \(ids)")
        #expect(claude.count == 1, "one Claude session: \(claude)")
        let args = flow.specs.map(\.arguments)
        print("QA oct25 launches: \(args.map { $0.drop { $0 != "--session-id" && $0 != "--resume" }.joined(separator: " ") })")
        #expect(args.last.map { $0.contains("--resume") && $0.contains(lumi.path) } == true)
        await flow.end()
    }

    /// Oct 26–27: conversation C ran from home; a trusted acme-app folder in front split off D
    /// for one turn. v2: C absorbs the folder, then continues with every folder kept.
    @Test func oct26ReplayAbsorbsTheTrustedFolderKeepsAllDirsAndOffersUntrustedOnes() async throws {
        let flow = try await Flow.make("oct26")
        let acme = try flow.repo("acme-app", claudeMD: "Project codename: BIRCH-9.")
        let other = try flow.repo("other")
        let untrusted = try flow.folder("untrusted")
        let at = { (m: TimeInterval) in flow.t0.addingTimeInterval(m * 60) }

        let c = await flow.sessions.plan(flow.input(.typed, key: Flow.safari, at: at(0), current: nil), packet: flow.packet("notes"))
        let first = try #require(c.launch)
        let states = await flow.pool.events(for: c.id)
        _ = await flow.run(.typed, "Remember the word HAZEL. Reply with just: ok", id: c.id, launch: first)
        // Real turns are seconds apart; let the CLI report idle so the absorb respawn can run.
        for await e in states { if e == .runState(.idle) { break } }
        for m in [3.0, 6] {
            let p = await flow.sessions.plan(flow.input(.typed, key: Flow.safari, at: at(m), current: c.id), packet: flow.packet("more"))
            #expect(p.id == c.id)
        }
        // 10:08:06: acme-app in front.
        let d = await flow.sessions.plan(flow.input(.voice, key: Flow.iterm, project: acme.path, trusted: true, at: at(8.1), current: c.id),
                                         packet: flow.packet("in acme"))
        #expect(d.id == c.id, "no split into D")
        // An untrusted folder: offered, not absorbed.
        let u = await flow.sessions.plan(flow.input(.voice, key: Flow.iterm, project: untrusted.path, trusted: false, at: at(9), current: c.id),
                                         packet: flow.packet("in untrusted"))
        #expect(u.id == c.id && u.offerDirectory == untrusted.path, "offerAbsorb: \(String(describing: u.offerDirectory))")
        #expect(u.launch?.addDirs.map(\.path).contains(untrusted.path) == false)
        // Another trusted folder: both kept.
        let o = await flow.sessions.plan(flow.input(.voice, key: Flow.iterm, project: other.path, trusted: true, at: at(10), current: c.id),
                                         packet: flow.packet("in other"))
        let dirs = Set(o.launch?.addDirs.map(\.path) ?? [])
        #expect(o.id == c.id && dirs.isSuperset(of: [acme.path, other.path]), "all dirs kept: \(dirs)")
        // From Safari again: C, resumed with every folder. (Times are compressed: only the first
        // turn ran, and the router measures idle from the last finished turn.)
        let back = await flow.sessions.plan(flow.input(.typed, key: Flow.safari, at: at(14), current: c.id), packet: flow.packet("back"))
        let l = try #require(back.launch)
        #expect(back.id == c.id && l.claudeSession == first.claudeSession && l.exists)
        let r = await flow.run(.typed, "What is the project codename in your CLAUDE.md context, and which word did I ask you to remember? Answer as CODENAME WORD.", id: c.id, launch: l)
        print("QA oct26 back turn: \(r.turnEnd?.markdown.prefix(160) ?? "nil")")
        #expect(r.turnEnd?.markdown.uppercased().contains("HAZEL") == true)
        #expect(r.turnEnd?.markdown.uppercased().contains("BIRCH") == true, "absorbed folder's CLAUDE.md")
        let last = try #require(flow.specs.last?.arguments)
        #expect(last.contains(acme.path) && last.contains(other.path) && !last.contains(untrusted.path), "\(last)")
        await flow.end()
    }

    /// The pool also absorbs on its own when a live idle process gets a launch with a new folder.
    @Test func absorbBetweenTurnsRespawnsWithEveryFolder() async throws {
        let flow = try await Flow.make("absorb")
        let one = try flow.repo("one"), two = try flow.repo("two")
        let id = SessionID.new()
        var launch = SessionLaunch(claudeSession: UUID(), exists: false, cwd: flow.home)
        let states = await flow.pool.events(for: id)
        _ = await flow.run(.typed, "Reply with just: ok", id: id, launch: launch)
        launch.exists = true
        // Right at the turn's end the CLI hasn't reported idle yet: absorb refuses.
        var early: PoolError?
        do { try await flow.pool.absorb(one, session: id, launch: launch) } catch { early = error }
        print("QA absorb right after turnEnded: \(String(describing: early))")
        for await e in states { if e == .runState(.idle) { break } }
        if early != nil { try await flow.pool.absorb(one, session: id, launch: launch) }
        launch.addDirs = [one]
        try await flow.pool.absorb(two, session: id, launch: launch)
        let last = try #require(flow.specs.last?.arguments)
        #expect(last.contains(one.path) && last.contains(two.path) && last.contains("--resume"), "\(last)")
        print("QA absorb respawns: \(flow.specs.count) launches; lifecycle \(flow.lifecycle.withLock { $0 })")
        await flow.end()
    }

    // MARK: E1. A lost Claude session recovers in a new seeded one

    /// The minted id never reached Claude Code (planned, then Lumi relaunched before any turn ran):
    /// the next plan resumes it, the CLI has no such session, and the turn must still answer.
    @Test func aMintedIdThatNeverRanStillAnswers() async throws {
        let flow = try await Flow.make("lost-never")
        let first = await flow.sessions.plan(flow.input(.typed, key: Flow.safari, at: flow.t0, current: nil), packet: flow.packet("x"))
        let again = await flow.sessions.plan(flow.input(.typed, key: Flow.safari, at: flow.t0.addingTimeInterval(30), current: first.id),
                                             packet: flow.packet("y"))
        let launch = try #require(again.launch)
        #expect(again.id == first.id)
        let r = await flow.run(.typed, "Reply with just: ok", id: again.id, launch: launch)
        print("QA E1 never-ran: \(String(describing: r.turnEnd)) launches=\(flow.specs.map { $0.arguments.drop { $0 != "--session-id" && $0 != "--resume" }.prefix(2).joined(separator: " ") })")
        #expect(r.turnEnd?.isError == false && r.turnEnd?.markdown.lowercased().contains("ok") == true)
        // And the next turn resumes the session that answered.
        try await Task.sleep(for: .seconds(1))
        let next = try #require(await flow.sessions.composerPlan(first.id)?.launch)
        #expect(next.exists, "the started session is recorded and resumed")
        let r2 = await flow.run(.typed, "Reply with just: two", id: first.id, launch: next)
        #expect(r2.turnEnd?.isError == false)
        await flow.end()
    }

    /// Claude Code removed the session file (the 30-day cleanup): the next turn recovers in a new
    /// Claude session seeded with the recap.
    @Test func aSessionWhoseFileWasRemovedRecoversSeeded() async throws {
        let flow = try await Flow.make("lost-file")
        let plan = await flow.sessions.plan(flow.input(.typed, key: Flow.safari, at: flow.t0, current: nil), packet: flow.packet("x"))
        var launch = try #require(plan.launch)
        let states = await flow.pool.events(for: plan.id)
        _ = await flow.run(.typed, "Remember the word QUINCE. Reply with just: ok", id: plan.id, launch: launch)
        for await e in states { if e == .runState(.idle) { break } }
        try await flow.store.finishTurn(plan.id, answerPreview: "ok", recap: ["Q: Remember the word QUINCE.\nA: ok"], at: flow.t0, lane: nil)
        await flow.pool.suspend(plan.id)
        let file = try #require(LiveSessionFlowJSONL.file(launch.claudeSession))
        try FileManager.default.removeItem(at: file)
        launch.exists = true
        let r = await flow.run(.typed, "Which word did I ask you to remember? Reply with the word only.", id: plan.id, launch: launch)
        print("QA E1 file removed: \(String(describing: r.turnEnd?.markdown.prefix(80))) err=\(String(describing: r.turnEnd?.error))")
        #expect(r.turnEnd?.isError == false, "recovered, not session_not_found")
        #expect(r.turnEnd?.markdown.uppercased().contains("QUINCE") == true, "seeded with the recap")
        await flow.end()
    }

    /// 30-QA E5: a folder change that arrives before the CLI reports idle.
    @Test func aFolderChangeRightAfterATurnIsAppliedWhenIdle() async throws {
        let flow = try await Flow.make("e5")
        let acme = try flow.repo("acme-app", claudeMD: "Project codename: ROWAN-3.")
        let c = await flow.sessions.plan(flow.input(.typed, key: Flow.safari, at: flow.t0, current: nil), packet: flow.packet("x"))
        let first = try #require(c.launch)
        let states = await flow.pool.events(for: c.id)
        _ = await flow.run(.typed, "Reply with just: ok", id: c.id, launch: first)
        let d = await flow.sessions.plan(flow.input(.voice, key: Flow.iterm, project: acme.path, trusted: true, at: flow.t0.addingTimeInterval(60), current: c.id),
                                         packet: flow.packet("in acme"))
        let l = try #require(d.launch)
        let r = await flow.run(.typed, "What is the project codename in your CLAUDE.md context? One word.", id: c.id, launch: l)
        let now = r.turnEnd?.markdown.uppercased().contains("ROWAN") == true
        for await e in states { if e == .runState(.idle) { break } }
        try await Task.sleep(for: .seconds(3))
        let args = flow.specs.map(\.arguments)
        print("QA E5: codename in the same turn=\(now); launches=\(args.count), last has acme=\(args.last?.contains(acme.path) == true)")
        #expect(now || args.last?.contains(acme.path) == true, "the folder applies this turn or right after it")
        await flow.end()
    }

    // MARK: Mixed voice/typed eval (10-ENG §5 step 10)

    /// One open session, 12 interleaved turns. Voice turns: a buddy block, `say` first sentence
    /// ≤ 15 words, no Markdown in `say`. Typed turns: full Markdown in the shape asked for, no block,
    /// nothing spoken. Halfway, the process is suspended so the next turn measures a resume.
    /// Opt in on top of the suite flag: BUDDYBRIDGE_LIVE_EVAL=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDYBRIDGE_LIVE_EVAL"] == "1"))
    func mixedVoiceAndTypedTurnsInOneOpenSession() async throws {
        let flow = try await Flow.make("eval")
        let plan = await flow.sessions.plan(flow.input(.typed, key: Flow.safari, at: flow.t0, current: nil), packet: flow.packet("eval"))
        var launch = try #require(plan.launch)
        let id = plan.id
        let states = LiveStates(await flow.pool.events(for: id))
        let has: (String) -> @Sendable (String) -> Bool = { needle in { $0.contains(needle) } }
        let turns: [(TurnKind, String, (@Sendable (String) -> Bool)?)] = [
            (.voice, "What's a good name for a git branch that fixes the login timeout?", nil),
            (.typed, "Write a Python function that checks whether a string is a palindrome, in a code block, then explain it in exactly 3 bullet points.",
             { $0.contains("```") && $0.components(separatedBy: "\n").filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }.count >= 3 }),
            (.voice, "And what's the time complexity of that function?", nil),
            (.typed, "Make a Markdown table comparing Python lists, tuples and sets on mutability, ordering and duplicates.",
             { $0.components(separatedBy: "\n").filter { $0.hasPrefix("|") }.count >= 4 }),
            (.voice, "Which of those should I use for unique tags?", nil),
            (.typed, "Give me a numbered list of 5 steps to set up a Python virtual environment, with the shell commands in code blocks.",
             { $0.contains("```") && $0.contains("1.") && $0.contains("5.") }),
            (.voice, "Roughly how long will that setup take me?", nil),
            (.typed, "Summarise everything we discussed so far under three Markdown headings.",
             { $0.components(separatedBy: "\n").filter { $0.hasPrefix("#") }.count >= 3 }),
            (.voice, "What did we call the palindrome function?", nil),
            (.typed, "Rewrite the palindrome function so it ignores punctuation and case. Full code in a code block.", has("```")),
            (.voice, "Is that version slower?", nil),
            (.typed, "Write a commit message for that change: a subject line, a blank line, then one short paragraph.",
             { $0.trimmingCharacters(in: .whitespacesAndNewlines).count > 60 }),
        ]
        var rows: [String] = []
        var failures = 0
        var spentBefore = 0.0, lastCost = 0.0
        for (n, (kind, text, shape)) in turns.enumerated() {
            if n == 6 {
                // Halfway: suspend the idle process, so turn 7 resumes it (`--resume`).
                _ = await states.idle(timeout: .seconds(20))
                #expect(await flow.pool.suspend(id), "suspended before turn 7")
                spentBefore += lastCost
                lastCost = 0
            }
            let t0 = ContinuousClock.now
            var firstSay: Duration?
            let request = TurnRequest(question: Question(packet: flow.packet(text)), state: ConversationState(id: id.rawValue),
                                      kind: kind, target: .session(id, launch))
            var events: [SessionEvent] = []
            for await e in await flow.turns.run(request, id: id, launch: launch) {
                if firstSay == nil, case .sayFirstSentence = e { firstSay = ContinuousClock.now - t0 }
                events.append(e)
            }
            launch.exists = true
            let total = ContinuousClock.now - t0
            let end = events.turnEnd
            lastCost = end?.costUSD ?? lastCost
            let spoke = events.contains { if case .say = $0 { true } else { false } }
            var ok: Bool
            var note: String
            if kind == .voice {
                let say = end?.block?.say ?? ""
                let first = say.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? say
                let words = first.split(whereSeparator: \.isWhitespace).count
                let markdownInSay = say.contains("```") || say.contains("**") || say.contains("# ")
                ok = end?.isError == false && end?.block != nil && !say.isEmpty && words <= 15 && !markdownInSay && spoke
                note = "say \(words)w/\(say.split(whereSeparator: \.isWhitespace).count)w: \(say.prefix(70))"
            } else {
                let md = end?.markdown ?? ""
                ok = end?.isError == false && end?.block == nil && !spoke && !md.contains("```buddy") && (shape?(md) ?? true)
                note = "\(md.count) chars, \(md.components(separatedBy: "\n").count) lines: \(md.prefix(50).replacingOccurrences(of: "\n", with: "⏎"))"
            }
            if !ok { failures += 1 }
            let secs = { (d: Duration?) in d.map { String(format: "%.2f", Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) } ?? "-" }
            rows.append("| \(n + 1) | \(kind) | \(ok ? "pass" : "FAIL") | \(secs(firstSay)) | \(secs(total)) | \(note.replacingOccurrences(of: "|", with: "\\|")) |")
        }
        print("QA EVAL\n| # | Kind | Result | First say (s) | Turn (s) | Notes |\n|---|---|---|---|---|---|\n" + rows.joined(separator: "\n"))
        let launches = flow.lifecycle.withLock { $0 }.compactMap { e -> String? in
            if case .launched(_, let resumed, let d) = e { "\(resumed ? "resume" : "cold") \(Int(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)) ms" } else { nil }
        }
        print("QA EVAL launches: \(launches)")
        print(String(format: "QA EVAL cost: $%.4f", spentBefore + lastCost))
        #expect(failures == 0, "\(failures) turn(s) failed")
        await flow.end()
    }

    // MARK: 9. Quick → Continue opens a new seeded open session

    @Test func continueFromQuickStartsANewSeededOpenSessionNeverAResumeOfQuick() async throws {
        let flow = try await Flow.make("continue")
        let q = await flow.sessions.plan(flow.input(.voice, key: Flow.safari, at: flow.t0, current: nil), packet: flow.packet("capital of peru"))
        #expect(q.harness == .quick)
        let quickClaude = UUID()
        try await flow.store.addClaudeSession(quickClaude, role: .quick, cwd: flow.home, to: q.id, at: flow.t0)
        try await flow.store.finishTurn(q.id, answerPreview: "Lima.", recap: ["Q: What's the capital of Peru?\nA: Lima."], at: flow.t0, lane: .quick)

        let plan = try #require(await flow.sessions.continueAsOpen(q.id))
        let launch = try #require(plan.launch)
        #expect(plan.id == q.id && plan.harness == .open && !launch.exists && launch.claudeSession != quickClaude)
        #expect(plan.seed?.contains("Lima") == true, "seeded with the recap")
        let r = await flow.run(.typed, "Which city did we just talk about? One word.", id: q.id, launch: launch, seed: plan.seed)
        #expect(r.turnEnd?.markdown.contains("Lima") == true, "\(String(describing: r.turnEnd?.markdown))")
        let args = try #require(flow.specs.first?.arguments)
        #expect(args.contains("--session-id") && !args.contains(quickClaude.uuidString.lowercased()), "\(args)")
        let first = Flow.userTexts(launch.claudeSession).first ?? ""
        #expect(first.hasPrefix("<quick-note>"), "first message carries the note: \(first.prefix(80))")
        await flow.end()
    }
}

// MARK: - Flow rig

@MainActor
final class Flow {
    nonisolated static let safari = ContextKey(bundleID: "com.apple.Safari", target: "example.com/trip")
    nonisolated static let iterm = ContextKey(bundleID: "com.googlecode.iterm2", target: "zsh")

    let root: URL
    let home: URL
    let store: SessionStore
    let sessions: LiveSessions
    let pool: SessionPool
    let turns: LiveSessionTurns
    let t0 = Date()
    let specsBox: QALocked<[LaunchSpec]>
    let lifecycle: QALocked<[PoolLifecycle]>
    /// Extra CLI flags for the next launch (the rewind test).
    let extraArgs: QALocked<[String]>
    private let trusted: QALocked<Set<String>>
    var feed: Task<Void, Never>?

    var specs: [LaunchSpec] { specsBox.withLock { $0 } }

    private init(root: URL, home: URL, store: SessionStore, sessions: LiveSessions, pool: SessionPool, turns: LiveSessionTurns,
                 specs: QALocked<[LaunchSpec]>, lifecycle: QALocked<[PoolLifecycle]>, extra: QALocked<[String]>, trusted: QALocked<Set<String>>) {
        self.root = root
        self.home = home
        self.store = store
        self.sessions = sessions
        self.pool = pool
        self.turns = turns
        self.specsBox = specs
        self.lifecycle = lifecycle
        self.extraArgs = extra
        self.trusted = trusted
    }

    static func make(_ name: String) async throws -> Flow {
        let realHome = NSHomeDirectory()
        var base = ProcessInfo.processInfo.environment
        for key in base.keys where key.hasPrefix("CLAUDE_CODE") || key == "CLAUDECODE" { base[key] = nil }
        let loginPath = await LaunchEnvironment.loginShellPath(shell: base["SHELL"] ?? "/bin/zsh", home: realHome)
        var made = LaunchEnvironment.make(base: base, loginShellPath: loginPath, home: realHome)
        made["ANTHROPIC_MODEL"] = "haiku"
        made["CLAUDE_CODE_SUBAGENT_MODEL"] = "haiku"
        let env = made
        let claude = try #require(LaunchEnvironment.locateClaude(preferred: nil, path: env["PATH"] ?? "", home: realHome))
        let scratch = ProcessInfo.processInfo.environment["LUMI_LIVE_SCRATCH"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("_probe-scratch/qa-engine")
        let root = scratch.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6).lowercased())")
        let home = root.appendingPathComponent("home", isDirectory: true)
        try Self.haikuFolder(home)

        let index = try ConversationIndex(url: nil)
        let manager = ConversationManager(index: index, sessionFiles: FakeSessionFiles(), screenshotDirectory: FileManager.default.temporaryDirectory)
        let store = SessionStore(index: index, files: FakeSessionFiles(), home: home.path)
        let trusted = QALocked<Set<String>>([])
        let sessions = LiveSessions(store: store, manager: manager, policy: RoutingPolicy(home: home.path), home: home,
                                    trust: { FolderTrust(trustedPaths: trusted.withLock { $0 }) })
        let specs = QALocked<[LaunchSpec]>([]), lifecycle = QALocked<[PoolLifecycle]>([]), extra = QALocked<[String]>([])
        let realHomeURL = URL(fileURLWithPath: realHome)
        let pool = SessionPool(caps: PoolCaps(live: 4), spec: { launch in
            let mode = LaunchSpec.openPermissionMode(settingsFiles: LaunchSpec.openSettingsFiles(home: realHomeURL, cwd: launch.cwd))
            return .open(executable: claude, launch: launch, permissionMode: mode, environment: env)
        }, transport: { spec in
            specs.withLock { $0.append(spec) }
            return try ProcessTransport(executable: spec.executable, arguments: spec.arguments + extra.withLock { $0 },
                                        workingDirectory: spec.workingDirectory, environment: spec.environment)
        }, hostsPermissions: { true }, sweepEvery: nil, lifecycle: { e in lifecycle.withLock { $0.append(e) } })
        let turns = LiveSessionTurns(pool: pool, plugin: LiveSessionFlowTests.plugin, settings: { SessionSettings() },
                                     rules: MemoryVoiceRules(),
                                     turnCount: { id in ((try? await store.userTurns(of: id)) ?? []).count },
                                     onSent: { uuid, kind, shown, claude, id in
                                         await sessions.recordSent(userUUID: uuid, kind: kind, shown: shown, claudeSession: claude, in: id)
                                     },
                                     // As AppRuntime.recoverLostSession (30-QA E1).
                                     recover: { id, _ in
                                         await sessions.claudeSessionLost(id)
                                         guard let plan = await sessions.composerPlan(id), let launch = plan.launch else { return nil }
                                         return (launch, plan.seed)
                                     })
        // As AppRuntime with `panel` on: typed asks open sessions, and the read model follows every
        // session's events (that's how a minted Claude session gets recorded, R7).
        sessions.typedOpensSessions = true
        let flow = Flow(root: root, home: home, store: store, sessions: sessions, pool: pool, turns: turns, specs: specs,
                        lifecycle: lifecycle, extra: extra, trusted: trusted)
        let all = await pool.allEvents()
        flow.feed = Task { [weak sessions] in
            for await e in all { sessions?.apply(e.event, to: e.id) }
        }
        return flow
    }

    nonisolated static func haikuFolder(_ dir: URL, claudeMD: String? = nil) throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let settings: [String: Any] = ["model": "haiku", "permissions": ["allow": ["Bash(echo:*)", "Bash(echo *)"]]]
        try JSONSerialization.data(withJSONObject: settings).write(to: dir.appendingPathComponent(".claude/settings.json"))
        if let claudeMD { try claudeMD.write(to: dir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8) }
    }

    /// A trusted stand-in repo.
    func repo(_ name: String, claudeMD: String? = nil) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try Self.haikuFolder(dir, claudeMD: claudeMD)
        trusted.withLock { _ = $0.insert(dir.path) }
        return dir
    }

    /// An untrusted folder.
    func folder(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try Self.haikuFolder(dir)
        return dir
    }

    func input(_ kind: TurnKind, key: ContextKey? = nil, project: String? = nil, trusted: Bool = false, at now: Date, current: SessionID?) -> SummonInput {
        SummonInput(source: kind == .voice ? .talkKey : .textBox, kind: kind, contextKey: key, project: project,
                    projectTrusted: trusted, current: current, now: now)
    }

    func packet(_ utterance: String) -> ContextPacket {
        var p = ContextPacket(askedAt: .now, utterance: utterance)
        p.app = .init(name: "Safari", bundle: "com.apple.Safari", kind: .browser)
        return p
    }

    func run(_ kind: TurnKind, _ text: String, id: SessionID, launch: SessionLaunch, seed: String? = nil) async -> [SessionEvent] {
        var p = packet(text)
        p.app = .init(name: "Notes", bundle: "com.apple.Notes", kind: .other)
        let request = TurnRequest(question: Question(packet: p), state: ConversationState(id: id.rawValue), kind: kind,
                                  target: .session(id, launch), seed: seed)
        let stream = await turns.run(request, id: id, launch: launch)
        let box = QALocked<[SessionEvent]>([])
        let task = Task { for await e in stream { box.withLock { $0.append(e) } } }
        let killer = Task { try? await Task.sleep(for: .seconds(150)); task.cancel() }
        await task.value
        killer.cancel()
        let events = box.withLock { $0 }
        for case .turnEnded(let e) in events {
            print("QA turn \(kind): error=\(e.isError) cost=\(e.costUSD.map { String(format: "%.4f", $0) } ?? "?") say=\(e.block?.say.prefix(50) ?? "-")")
        }
        return events
    }

    func end() async {
        _ = await pool.shutdownAll()
        feed?.cancel()
    }

    // MARK: JSONL

    nonisolated static func lines(_ claude: UUID) -> [[String: Any]] {
        guard let file = LiveSessionFlowJSONL.file(claude), let data = try? Data(contentsOf: file) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    nonisolated static func text(_ line: [String: Any]) -> String {
        let content = (line["message"] as? [String: Any])?["content"]
        if let s = content as? String { return s }
        return ((content as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
    }

    /// The user messages as the CLI recorded them (no meta, summaries or tool results).
    nonisolated static func userTexts(_ claude: UUID) -> [String] {
        lines(claude).filter { $0["type"] as? String == "user" && $0["isMeta"] as? Bool != true && $0["isCompactSummary"] as? Bool != true }
            .map(text).filter { !$0.isEmpty && !$0.hasPrefix("<local-command") && !$0.hasPrefix("<command-") }
    }
}

/// A session's run states, to wait for idle.
final class LiveStates: Sendable {
    private let box = QALocked<[SessionEvent]>([])
    private let task: Task<Void, Never>
    init(_ stream: AsyncStream<SessionEvent>) {
        let box = box
        task = Task { for await e in stream { box.withLock { $0.append(e) } } }
    }
    deinit { task.cancel() }
    func idle(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let last = box.withLock { $0 }.last { if case .runState = $0 { true } else { false } }
            if last == .runState(.idle) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

enum LiveSessionFlowJSONL {
    static func file(_ claude: UUID) -> URL? {
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let name = claude.uuidString.lowercased() + ".jsonl"
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
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
