@testable import BuddyApp
import BuddyBridge
import BuddyConversations
import BuddyCore
import Foundation
import Testing

@MainActor
struct LiveSessionsTests {
    nonisolated static let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    nonisolated static let repo = "/Users/tester/Developer/app"

    @MainActor final class Harness {
        let index: ConversationIndex
        let files = FakeSessionFiles()
        let manager: ConversationManager
        let sessions: LiveSessions

        init() throws {
            index = try ConversationIndex(url: nil)
            manager = ConversationManager(index: index, sessionFiles: files, screenshotDirectory: FileManager.default.temporaryDirectory)
            let store = SessionStore(index: index, files: files, home: LiveSessionsTests.home.path)
            var policy = RoutingPolicy(home: LiveSessionsTests.home.path)
            policy.idleLimit = 30 * 60
            sessions = LiveSessions(store: store, manager: manager, policy: policy, home: LiveSessionsTests.home,
                                    trust: { FolderTrust(trustedPaths: [LiveSessionsTests.repo]) })
            sessions.typedOpensSessions = true // the Panel is on
        }
    }
    nonisolated static let t0Date = Date(timeIntervalSince1970: 1_790_000_000)

    private func input(_ kind: TurnKind, project: String? = nil, trusted: Bool = false, at now: Date, current: SessionID?,
                       key: ContextKey? = nil) -> SummonInput {
        SummonInput(source: kind == .voice ? .talkKey : .textBox, kind: kind, contextKey: key, project: project,
                    projectTrusted: trusted, current: current, now: now)
    }

    private func packet(_ utterance: String) -> ContextPacket {
        var p = ContextPacket(askedAt: .now, utterance: utterance)
        p.app = .init(name: "Safari", bundle: "com.apple.Safari", kind: .browser)
        return p
    }

    /// Claude Code acknowledged the minted session (its `system/init`): it's recorded.
    private func ack(_ h: Harness, _ id: SessionID) async throws {
        h.sessions.apply(.initialized(InitSummary()), to: id)
        let deadline = ContinuousClock.now + waitCeiling
        while try await h.index.record(id: id.rawValue)?.claudeSessions.contains(where: { $0.role == .open }) != true,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    }

    /// V-02: a Quick answer is seen while the Glance shows its session; once the turn moved to the
    /// background it lands unread.
    @Test func aQuickAnswerBehindTheGlanceLandsUnread() async throws {
        let h = try Harness()
        let plan = await h.sessions.plan(input(.voice, at: Self.t0Date, current: nil), packet: packet("what's this word"))
        #expect(plan.harness == .quick)
        let id = plan.id
        func status() -> SessionStatus? { h.sessions.snapshots.first { $0.id == id }?.status }

        h.sessions.glanceSession = id
        #expect(h.sessions.onScreen == [id])
        h.sessions.finishCascadeTurn(id, kind: .voice, question: "what's this word", block: BuddyBlock(say: "It means tidy.", shape: .chip))
        guard case .done(_, false)? = status() else { Issue.record("seen, not \(String(describing: status()))"); return }

        h.sessions.glanceSession = nil // a new press: the next turn runs behind
        h.sessions.finishCascadeTurn(id, kind: .voice, question: "and this one", block: BuddyBlock(say: "It means neat.", shape: .chip))
        guard case .done(_, true)? = status() else { Issue.record("unread, not \(String(describing: status()))"); return }
    }

    @Test func aTypedAskStartsAnOpenSessionThenResumesItsClaudeSession() async throws {
        let h = try Harness()
        let first = await h.sessions.plan(input(.typed, at: Self.t0Date, current: nil), packet: packet("plan a trip to Lisbon"))
        #expect(first.harness == .open && first.kind == .typed)
        let launch = try #require(first.launch)
        #expect(!launch.exists && launch.cwd.path == Self.home.path && launch.maxSubagents == 3)
        let record = try #require(try await h.index.record(id: first.id.rawValue))
        #expect(record.title == "Plan trip Lisbon" && record.harness == .open && record.symbol == nil)
        #expect(record.claudeSessions.isEmpty, "recorded only once Claude Code acknowledges it")
        try await ack(h, first.id)
        #expect(try await h.index.record(id: first.id.rawValue)?.claudeSessions.map(\.sessionID)
                == [launch.claudeSession.uuidString.lowercased()])
        #expect(h.sessions.current == first.id)
        #expect(h.sessions.snapshots.map(\.id) == [first.id])

        let second = await h.sessions.plan(input(.typed, at: Self.t0Date.addingTimeInterval(60), current: first.id), packet: packet("and hotels"))
        #expect(second.id == first.id)
        #expect(second.launch?.exists == true && second.launch?.claudeSession == launch.claudeSession, "one Claude session, resumed")
    }

    @Test func voiceStartsOnQuickAndATypedFollowUpContinuesOpenSeededWithTheRecap() async throws {
        let h = try Harness()
        let voice = await h.sessions.plan(input(.voice, at: Self.t0Date, current: nil), packet: packet("what is this chart"))
        #expect(voice.harness == .quick && voice.launch == nil)
        try await h.index.setRecap(["Q: what is this chart\nA: Revenue by month."], id: voice.id.rawValue)
        let again = await h.sessions.plan(input(.voice, at: Self.t0Date.addingTimeInterval(30), current: voice.id), packet: packet("why"))
        #expect(again.id == voice.id && again.harness == .quick)
        let typed = await h.sessions.plan(input(.typed, at: Self.t0Date.addingTimeInterval(60), current: voice.id), packet: packet("dig in"))
        #expect(typed.id == voice.id && typed.harness == .open)
        #expect(typed.launch?.exists == false)
        #expect(typed.seed == "Q: what is this chart\nA: Revenue by month.")
        #expect(try await h.index.record(id: voice.id.rawValue)?.harness == .quick, "still Quick until Claude Code starts it")
        try await ack(h, voice.id)
        #expect(try await h.index.record(id: voice.id.rawValue)?.harness == .open)
    }

    /// V-06: once a hand-off (or a typed turn) made the session open, a spoken follow-up still starts
    /// on Quick; Quick hands off into the same open Claude session when it needs to.
    @Test func oneHandOffDoesntKeepLaterSpokenTurnsOnTheOpenSession() async throws {
        let h = try Harness()
        let voice = await h.sessions.plan(input(.voice, at: Self.t0Date, current: nil), packet: packet("what is this chart"))
        let handoff = try #require(await h.sessions.handoffLaunch(conversation: voice.id.rawValue))
        try await ack(h, voice.id)
        #expect(try await h.index.record(id: voice.id.rawValue)?.harness == .open)
        let next = await h.sessions.plan(input(.voice, at: Self.t0Date.addingTimeInterval(300), current: voice.id), packet: packet("and May?"))
        #expect(next.id == voice.id && next.harness == .quick && next.launch == nil, "back on Quick")
        let again = try #require(await h.sessions.handoffLaunch(conversation: voice.id.rawValue))
        #expect(again.1.exists && again.1.claudeSession == handoff.1.claudeSession, "a later hand-off resumes the same open session")
        // Typed and spoken-in-page turns still go to the open session.
        let typed = await h.sessions.plan(input(.typed, at: Self.t0Date.addingTimeInterval(360), current: voice.id), packet: packet("dig in"))
        #expect(typed.harness == .open && typed.launch?.claudeSession == handoff.1.claudeSession)
    }

    @Test func aV1DeepConversationContinuesAsANewOpenSessionUnderTheSameID() async throws {
        let h = try Harness()
        _ = try await h.index.create(id: "c_old", title: "Old deep", at: Self.t0Date, projectFolder: nil)
        try await h.index.recordTurn(id: "c_old", at: Self.t0Date, quickSessionID: nil, deepSessionID: "22222222-2222-4222-8222-222222222222",
                                     lastLane: .deep, projectFolder: Self.home.path, deepFolder: Self.home.path)
        try await h.index.setRecap(["Q: a\nA: b"], id: "c_old")
        let plan = try #require(await h.sessions.continueAsOpen(SessionID(rawValue: "c_old")))
        #expect(plan.id.rawValue == "c_old" && plan.harness == .open && plan.launch?.exists == false && plan.seed == "Q: a\nA: b")
        try await ack(h, SessionID(rawValue: "c_old"))
        let record = try #require(try await h.index.record(id: "c_old"))
        #expect(record.harness == .open)
        #expect(record.claudeSessions.map(\.role) == [.deepLegacy, .open])
        // Forget deletes both: the v1 Deep session and the new open one.
        try await h.sessions.forget(SessionID(rawValue: "c_old"))
        #expect(Set(h.files.deletedSessions.flatMap { $0 }) == Set(record.claudeSessions.map(\.sessionID)))
        #expect(try await h.index.record(id: "c_old") == nil)
    }

    @Test func theComposerResumesTheOpenSessionOrMintsOneSeeded() async throws {
        let h = try Harness()
        let typed = await h.sessions.plan(input(.typed, at: Self.t0Date, current: nil), packet: packet("hello"))
        try await ack(h, typed.id)
        let again = try #require(await h.sessions.composerPlan(typed.id))
        #expect(again.launch == SessionLaunch(claudeSession: typed.launch!.claudeSession, exists: true, cwd: Self.home))
        let voice = await h.sessions.plan(input(.voice, at: Self.t0Date.addingTimeInterval(4000), current: nil), packet: packet("what is it"))
        try await h.index.setRecap(["Q: what is it\nA: A chart."], id: voice.id.rawValue)
        let minted = try #require(await h.sessions.composerPlan(voice.id))
        #expect(minted.launch?.exists == false && minted.seed == "Q: what is it\nA: A chart.")
        #expect(await h.sessions.launch(for: voice.id)?.claudeSession == minted.launch?.claudeSession, "minted once")
        #expect(await h.sessions.launch(for: SessionID(rawValue: "s_gone")) == nil)
    }

    /// QA R7: a minted open session whose first turn never reached Claude Code (Esc, a launch
    /// failure) launches again as new, with the same id and the recap seed.
    @Test func aMintedSessionStaysNewAndSeededUntilClaudeCodeStartsIt() async throws {
        let h = try Harness()
        let voice = await h.sessions.plan(input(.voice, at: Self.t0Date, current: nil), packet: packet("what is this chart"))
        try await h.index.setRecap(["Q: what is this chart\nA: Revenue by month."], id: voice.id.rawValue)
        let first = try #require(await h.sessions.composerPlan(voice.id))
        let retry = try #require(await h.sessions.composerPlan(voice.id))
        #expect(retry.launch?.exists == false && retry.launch?.claudeSession == first.launch?.claudeSession)
        #expect(retry.seed == first.seed && retry.seed != nil)
        // A replayed user turn acknowledges it too; then it resumes, with no seed.
        h.sessions.apply(.turnStarted(userUUID: "u1", kind: .typed), to: voice.id)
        let deadline = ContinuousClock.now + waitCeiling
        while try await h.index.record(id: voice.id.rawValue)?.harness != .open, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let resumed = try #require(await h.sessions.composerPlan(voice.id))
        #expect(resumed.launch?.exists == true && resumed.launch?.claudeSession == first.launch?.claudeSession && resumed.seed == nil)
    }

    /// QA E1: Claude Code lost the open session (30-day cleanup): the next turn mints a new one
    /// under the same Lumi session, seeded, instead of failing on every turn.
    @Test func aLostOpenSessionIsReplacedSeededWithTheRecap() async throws {
        let h = try Harness()
        let typed = await h.sessions.plan(input(.typed, at: Self.t0Date, current: nil), packet: packet("plan a trip"))
        try await ack(h, typed.id)
        try await h.index.setRecap(["Q: plan a trip\nA: Three days."], id: typed.id.rawValue)
        let lost = try #require(typed.launch?.claudeSession)
        h.sessions.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "", isError: true,
                                            error: SessionFailure(reason: .unavailable(LiveSessions.sessionNotFound), retryable: false))),
                         to: typed.id)
        let deadline = ContinuousClock.now + waitCeiling
        while try await h.index.record(id: typed.id.rawValue)?.claudeSessions.isEmpty == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let next = try #require(await h.sessions.composerPlan(typed.id))
        #expect(next.id == typed.id && next.launch?.exists == false && next.launch?.claudeSession != lost)
        #expect(next.seed == "Q: plan a trip\nA: Three days.")
    }

    /// QA R12: archiving the current session leaves none current.
    @Test func archivingTheCurrentSessionClearsCurrent() async throws {
        let h = try Harness()
        let typed = await h.sessions.plan(input(.typed, at: Self.t0Date, current: nil), packet: packet("hello"))
        #expect(h.sessions.current == typed.id)
        await h.sessions.setArchived(true, for: typed.id)
        #expect(h.sessions.current == nil)
    }

    /// QA R17: a turn the CLI starts itself (no user line) adds no recap entry and leaves the user's
    /// last answer preview alone.
    @Test func anAutoTurnAddsNoRecapEntry() async throws {
        let h = try Harness()
        let plan = await h.sessions.plan(input(.typed, at: Self.t0Date, current: nil), packet: packet("plan a trip"))
        let id = plan.id
        await h.sessions.recordSent(userUUID: "u1", kind: .typed, shown: "plan a trip", claudeSession: plan.launch!.claudeSession, in: id)
        h.sessions.apply(.turnStarted(userUUID: "u1", kind: .typed), to: id)
        h.sessions.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Three days.")), to: id)
        h.sessions.apply(.turnStarted(userUUID: nil, kind: .typed), to: id)   // a background agent reported
        h.sessions.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "The scout found two hotels.")), to: id)
        let deadline = ContinuousClock.now + waitCeiling
        while try await h.index.record(id: id.rawValue)?.turns != 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let record = try #require(try await h.index.record(id: id.rawValue))
        #expect(record.recap == ["Q: plan a trip\nA: Three days."], "one entry, the user's")
        #expect(try await h.index.userTurns(of: id.rawValue).map(\.answerPreview) == ["Three days."])
    }

    @Test func forgettingASessionWithAnUnacknowledgedMintDeletesItsFilesToo() async throws {
        let h = try Harness()
        let typed = await h.sessions.plan(input(.typed, at: Self.t0Date, current: nil), packet: packet("hello"))
        let minted = try #require(typed.launch?.claudeSession.uuidString.lowercased())
        try await h.sessions.forget(typed.id)
        #expect(h.files.deletedSessions.flatMap { $0 }.contains(minted))
    }

    @Test func aTrustedProjectIsAbsorbedAndPassedAsAnAddedDirectory() async throws {
        let h = try Harness()
        let first = await h.sessions.plan(input(.typed, at: Self.t0Date, current: nil), packet: packet("hello"))
        let next = await h.sessions.plan(input(.typed, project: Self.repo, trusted: true, at: Self.t0Date.addingTimeInterval(10),
                                               current: first.id), packet: packet("look at the repo"))
        #expect(next.id == first.id, "no split")
        #expect(next.launch?.addDirs.map(\.path) == [Self.repo])
        #expect(next.launch?.cwd.path == Self.home.path, "it resumes where it was created")
        let untrusted = await h.sessions.plan(input(.typed, project: "/Users/tester/Downloads/x", at: Self.t0Date.addingTimeInterval(20),
                                                    current: first.id), packet: packet("and this"))
        #expect(untrusted.id == first.id && untrusted.offerDirectory == "/Users/tester/Downloads/x")
    }

    @Test func eventsDriveTheStatusAndAFinishedTurnPersists() async throws {
        let h = try Harness()
        let plan = await h.sessions.plan(input(.typed, at: Self.t0Date, current: nil), packet: packet("plan a trip"))
        let id = plan.id
        await h.sessions.recordSent(userUUID: "u1", kind: .typed, shown: "plan a trip", claudeSession: plan.launch!.claudeSession, in: id)
        var updates = h.sessions.changes().makeAsyncIterator()
        _ = await updates.next()

        h.sessions.apply(.turnStarted(userUUID: "u1", kind: .typed), to: id)
        guard case .thinking = h.sessions.snapshots.first?.status else { Issue.record("thinking"); return }
        h.sessions.apply(.step(TrailStep(id: "t1", kind: .read, verb: "Reading", object: "itinerary.md")), to: id)
        #expect(h.sessions.snapshots.first?.liveLine == "Reading itinerary.md")
        let ask = PermissionAsk(id: "r1", title: "Edit plan.md", toolName: "Edit", detail: .plain("x"), tier: .reversible)
        h.sessions.apply(.permissionRequested(ask), to: id)
        guard case .needsYou(let needs) = h.sessions.snapshots.first?.status, case .permission(ask) = needs.kind else {
            Issue.record("needs you"); return
        }
        h.sessions.apply(.permissionResolved(id: "r1"), to: id)
        guard case .thinking = h.sessions.snapshots.first?.status else { Issue.record("thinking again"); return }
        h.sessions.apply(.task(.started(taskID: "k1", toolUseID: "tu1", name: "scout", description: "Find hotels", kind: .agent)), to: id)
        h.sessions.apply(.task(.started(taskID: "k2", toolUseID: nil, name: nil, description: "npm test", kind: .bash)), to: id)
        #expect(h.sessions.snapshots.first?.teammates.map(\.name) == ["scout"], "a background shell is not a teammate")

        let block = BuddyBlock(say: "Three days is enough.", shape: .chip, topic: SessionTopic(title: "Trip to Lisbon", symbol: "airplane"))
        h.sessions.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Three days is enough.", block: block)), to: id)
        guard case .done(_, true) = h.sessions.snapshots.first?.status else { Issue.record("done, unread"); return }
        #expect(h.sessions.snapshots.first?.lastSay == "Three days is enough.")

        // The effects persist off the main path.
        for _ in 0..<50 where (try await h.index.record(id: id.rawValue))?.status != .doneUnread { await Task.yield() }
        try await waitUntil { try await h.index.record(id: id.rawValue)?.title == "Trip to Lisbon" }
        let record = try #require(try await h.index.record(id: id.rawValue))
        #expect(record.status == .doneUnread && record.turns == 1)
        #expect(record.recap == ["Q: plan a trip\nA: Three days is enough."])
        #expect(record.symbol == "airplane")
        #expect(try await h.index.userTurns(of: id.rawValue).first?.answerPreview == "Three days is enough.")

        await h.sessions.setCurrent(id)
        guard case .done(_, false) = h.sessions.snapshots.first?.status else { Issue.record("seen"); return }
        try await waitUntil { try await h.index.record(id: id.rawValue)?.status == .idle }
    }

    @Test func quittingMidTurnIsInterruptedAfterARelaunch() async throws {
        let h = try Harness()
        let plan = await h.sessions.plan(input(.typed, at: Self.t0Date, current: nil), packet: packet("long job"))
        h.sessions.apply(.turnStarted(userUUID: nil, kind: .typed), to: plan.id)
        await h.sessions.markInterrupted([plan.id])
        try await waitUntil { try await h.index.record(id: plan.id.rawValue)?.status == .interrupted }

        let store = SessionStore(index: h.index, files: h.files, home: Self.home.path)
        let relaunched = LiveSessions(store: store, manager: h.manager, home: Self.home, trust: { FolderTrust(trustedPaths: []) })
        await relaunched.reload()
        guard case .interrupted = relaunched.snapshots.first?.status else { Issue.record("interrupted"); return }
    }

    private func waitUntil(_ done: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + waitCeiling
        while try await !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(try await done())
    }
}
