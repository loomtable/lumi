import BuddyCore
import Foundation
import Synchronization
import Testing
@testable import BuddyBridge

/// Records every launch and hands out replay transports that answer each turn.
final class FakeLauncher: Sendable {
    private let launched = Mutex<[LaunchSpec]>([])
    private let transports = Mutex<[ReplayTransport]>([])
    /// Turns per process; nil = a process that never answers (its turn stays open).
    private let answers: Bool
    private let crashAtBoot: Bool

    init(answers: Bool = true, crashAtBoot: Bool = false) {
        self.answers = answers
        self.crashAtBoot = crashAtBoot
    }

    var specs: [LaunchSpec] { launched.withLock { $0 } }
    var all: [ReplayTransport] { transports.withLock { $0 } }

    var factory: TransportFactory {
        { [self] spec in
            let n = launched.withLock { $0.append(spec); return $0.count }
            let session = spec.resumeSessionID ?? "new-\(n)"
            let turns = answers
                ? (0..<5).flatMap { _ in [Line.initLine(session: session), Line.textDelta("hi"), Line.result("hi", session: session)] }
                : [Line.initLine(session: session)]
            let t = ReplayTransport(lines: turns)
            if crashAtBoot { t.crash(status: 1) }
            transports.withLock { $0.append(t) }
            return t
        }
    }
}

struct MissingSessionTests {
    @Test func theRealCLIResultIsRecognised() throws {
        let events = try Fixture.events("resume-missing-session.jsonl")
        guard case .result(let r) = try #require(events.first) else { Issue.record("not a result"); return }
        #expect(r.isError && r.errors.first?.hasPrefix("No conversation found with session ID") == true)
        #expect(TurnEvent.failed(.turnFailed(r)).isMissingSession)
        #expect(!TurnEvent.failed(.processExited(status: 1, stderr: "Error: not logged in")).isMissingSession)
    }

    @Test(arguments: [false, true])
    func aMissingSessionIsReportedOnceWithoutRetries(exitsBeforeAsk: Bool) async {
        let launched = Mutex(0)
        let lane = QuickLane(spec: spec(), restart: fastRestart, transport: { _ in
            launched.withLock { $0 += 1 }
            let t = try ReplayTransport(fixture: Fixture.url("resume-missing-session.jsonl"))
            // Either the CLI's result reaches the turn, or the process is gone before the question.
            if exitsBeforeAsk { t.crash(status: 1, stderr: "No conversation found with session ID: gone\n") }
            return t
        })
        let events = await collect(await lane.ask(conversation: "c1", resumeSessionID: "gone", input: TurnInput(text: "q")))
        #expect(events == [.failed(.sessionNotFound)])
        #expect(launched.withLock { $0 } == 1, "the dead ID isn't retried")
    }
}

struct LaneTests {
    private func outcome(_ s: AsyncStream<TurnEvent>) async -> TurnOutcome? {
        for await e in s { if case .finished(let o) = e { return o } }
        return nil
    }

    @Test func newConversationTakesThePrewarmedSpare() async {
        let fake = FakeLauncher()
        let lane = QuickLane(spec: spec(), transport: fake.factory)
        await lane.prewarm()
        #expect(fake.specs.count == 1)
        let o = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "q")))
        #expect(o?.result.sessionID == "new-1")
        #expect(await eventually { fake.specs.count == 2 }, "a new spare boots after the old one is taken")
        #expect(fake.specs.allSatisfy { $0.resumeSessionID == nil })
    }

    @Test func followUpsReuseTheProcess() async {
        let fake = FakeLauncher()
        let lane = QuickLane(spec: spec(), transport: fake.factory)
        _ = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "1")))
        _ = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "2")))
        #expect(fake.specs.count == 1)
        #expect(await lane.sessionID(for: "c1") == "new-1")
    }

    @Test func anOlderConversationResumesItsSession() async {
        let fake = FakeLauncher()
        let lane = QuickLane(spec: spec(), transport: fake.factory)
        _ = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "1")))
        let o = await outcome(await lane.ask(conversation: "c0", resumeSessionID: "old-session", input: TurnInput(text: "2")))
        #expect(o?.result.sessionID == "old-session")
        #expect(fake.specs.last?.arguments.suffix(2) == ["--resume", "old-session"])
    }

    /// Review finding: two concurrent new conversations must not share the spare.
    @Test func concurrentConversationsGetTheirOwnSessions() async {
        let fake = FakeLauncher()
        let lane = QuickLane(spec: spec(), transport: fake.factory)
        await lane.prewarm()
        let sa = await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "1"))
        let sb = await lane.ask(conversation: "c2", resumeSessionID: nil, input: TurnInput(text: "2"))
        async let a = outcome(sa)
        async let b = outcome(sb)
        let (oa, ob) = await (a, b)
        // The second conversation in replaces the first; each answered in its own session.
        #expect(oa != nil && ob != nil)
        #expect(oa?.result.sessionID != ob?.result.sessionID)
    }

    /// Review finding: switching conversation mid-turn must not leave the first turn hanging.
    @Test func switchingConversationLetsTheRunningTurnEnd() async {
        let fake = FakeLauncher(answers: false)
        let lane = QuickLane(spec: spec(), transport: fake.factory)
        let first = await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "1"), deadline: .milliseconds(300))
        #expect(await eventually { fake.specs.count == 1 })
        // Keep c2's stream: dropping a stream cancels its question.
        let second = await lane.ask(conversation: "c2", resumeSessionID: nil, input: TurnInput(text: "2"), deadline: .milliseconds(300))
        #expect(await eventually { fake.specs.count == 2 })
        // c1's process was retired, not killed: its turn ends on its own terms (here, its deadline).
        let events = await collect(first)
        #expect(events.last == .failed(.timedOut))
        withExtendedLifetime(second) {}
    }

    @Test func aCrashedProcessComesBackInTheSameSession() async {
        let fake = FakeLauncher()
        let lane = QuickLane(spec: spec(), restart: fastRestart, transport: fake.factory)
        _ = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "1")))
        fake.all.last?.crash()
        let events = await collect(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "2")))
        guard case .finished(let o) = events.last else { Issue.record("\(events)"); return }
        #expect(o.result.sessionID == "new-1")
        #expect(fake.specs.last?.resumeSessionID == "new-1")
    }

    /// Review finding: a claude that launches and dies at once must back off, show
    /// Reconnecting, and give up after three restarts.
    @Test func aCrashLoopReconnectsThenGivesUp() async {
        let fake = FakeLauncher(crashAtBoot: true)
        let lane = QuickLane(spec: spec(), restart: fastRestart, transport: fake.factory)
        let events = await collect(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "q")))
        #expect(events.prefix(3) == [.reconnecting(attempt: 1), .reconnecting(attempt: 2), .reconnecting(attempt: 3)])
        guard case .failed(.unavailable) = events.last else { Issue.record("\(events)"); return }
        #expect(fake.specs.count == 4)
    }

    @Test func launchFailuresAlsoBackOff() async {
        let attempts = Mutex(0)
        let lane = QuickLane(spec: spec(), restart: fastRestart) { _ in
            attempts.withLock { $0 += 1 }
            throw TransportError.launchFailed("no claude")
        }
        let events = await collect(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "q")))
        guard case .failed(.unavailable) = events.last else { Issue.record("\(events)"); return }
        #expect(attempts.withLock { $0 } == 4)
    }

    @Test func deepStartsOnHandoffAndKeepsOneProcessPerConversation() async {
        let fake = FakeLauncher()
        let lane = DeepLane(spec: { folder, resume in
            var s = spec(mode: .deep, resume: resume)
            s.workingDirectory = folder
            return s
        }, transport: fake.factory)
        #expect(fake.specs.isEmpty, "nothing starts before a handoff")
        let web = DeepFolder(url: URL(fileURLWithPath: "/Users/me/Developer/aipulse/web"))
        let first = await outcome(await lane.ask(conversation: "c1", folder: web, resumeSessionID: nil, input: TurnInput(text: "q")))
        _ = await outcome(await lane.ask(conversation: "c1", folder: web, resumeSessionID: first?.result.sessionID, input: TurnInput(text: "follow-up")))
        #expect(fake.specs.count == 1)
        // Review finding: another conversation in the same folder gets its own session.
        let other = await outcome(await lane.ask(conversation: "c2", folder: web, resumeSessionID: nil, input: TurnInput(text: "q")))
        #expect(fake.specs.count == 2)
        #expect(other?.result.sessionID != first?.result.sessionID)
        _ = await outcome(await lane.ask(conversation: "c2", folder: DeepFolder(url: URL(fileURLWithPath: "/Users/me")), resumeSessionID: nil, input: TurnInput(text: "q")))
        #expect(fake.specs.last?.workingDirectory.path == "/Users/me")
    }

    @Test func reloadRestartsQuickFromTheNewSpecAndResumesTheConversation() async {
        let fake = FakeLauncher()
        let lane = QuickLane(spec: spec(), transport: fake.factory)
        await lane.prewarm()
        _ = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "1")))
        #expect(await eventually { fake.specs.count == 2 }, "spare replaced after c1 took it")
        var sonnet = spec()
        sonnet.config = ModeConfig(model: .sonnet, effort: .low)
        await lane.reload(spec: sonnet)
        #expect(fake.specs.count == 3 && fake.specs.last?.config.model == .sonnet && fake.specs.last?.resumeSessionID == nil,
                "a new spare from the new spec")
        #expect(fake.all[1].exited == 143, "the old spare is stopped")
        let o = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "2")))
        #expect(o?.result.sessionID == "new-1", "the conversation keeps its session")
        #expect(fake.specs.last?.resumeSessionID == "new-1" && fake.specs.last?.config.model == .sonnet)
        let fresh = await outcome(await lane.ask(conversation: "c2", resumeSessionID: nil, input: TurnInput(text: "3")))
        #expect(fresh?.result.sessionID == "new-3", "a new conversation takes the new spare")
    }

    @Test func reloadLetsAQuickAnswerInFlightFinish() async {
        let fake = FakeLauncher(answers: false)
        let lane = QuickLane(spec: spec(), transport: fake.factory)
        let running = await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "1"), deadline: .milliseconds(300))
        #expect(await eventually { fake.specs.count == 1 })
        await lane.reload()
        #expect(fake.all[0].exited == nil, "retired, not killed, while answering")
        #expect(await collect(running).last == .failed(.timedOut), "it ends on its own terms")
    }

    /// Review finding: a reload while a question runs must not cut it off, even between picking
    /// its session and sending; the process moves once that question ends.
    @Test func reloadDuringAQuestionMovesTheProcessWhenItEnds() async {
        let fake = FakeLauncher()
        let lane = QuickLane(spec: spec(), transport: fake.factory)
        let running = await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "1"))
        await lane.reload()
        let events = await collect(running)
        #expect(!events.contains(.reconnecting(attempt: 1)), "no fake crash")
        guard case .finished = events.last else { Issue.record("\(events)"); return }
        _ = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "2")))
        #expect(fake.specs.last?.resumeSessionID == "new-1", "the next turn resumes in a new process")
    }

    @Test func aReloadResumeIsUsedOnceEvenWhenTheCallerPassesAnID() async {
        let fake = FakeLauncher()
        let lane = QuickLane(spec: spec(), transport: fake.factory)
        _ = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "1")))
        await lane.reload()
        _ = await outcome(await lane.ask(conversation: "c1", resumeSessionID: "new-1", input: TurnInput(text: "2")))
        _ = await outcome(await lane.ask(conversation: "c2", resumeSessionID: nil, input: TurnInput(text: "3")))
        let o = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "4")))
        #expect(o?.result.sessionID != "new-1", "the reload entry was used up, so a new c1 turn without an ID starts fresh")
    }

    @Test func reloadRetiresDeepAndTheNextHandoffResumesInTheSameFolderOnly() async {
        let fake = FakeLauncher()
        let model = Mutex(ModelID.opus)
        let lane = DeepLane(spec: { folder, resume in
            var s = spec(mode: .deep, resume: resume)
            s.workingDirectory = folder
            s.config = ModeConfig(model: model.withLock { $0 }, effort: .high)
            return s
        }, transport: fake.factory)
        let web = DeepFolder(url: URL(fileURLWithPath: "/Users/me/Developer/aipulse/web"))
        _ = await outcome(await lane.ask(conversation: "c1", folder: web, resumeSessionID: nil, input: TurnInput(text: "q")))
        model.withLock { $0 = .sonnet }
        await lane.reload()
        #expect(fake.all[0].exited == 143, "an idle Deep process stops at once")
        let o = await outcome(await lane.ask(conversation: "c1", folder: web, resumeSessionID: nil, input: TurnInput(text: "again")))
        #expect(o?.result.sessionID == "new-1")
        #expect(fake.specs.last?.resumeSessionID == "new-1" && fake.specs.last?.config.model == .sonnet)

        await lane.reload()
        let home = DeepFolder(url: URL(fileURLWithPath: "/Users/me"))
        _ = await outcome(await lane.ask(conversation: "c1", folder: home, resumeSessionID: nil, input: TurnInput(text: "elsewhere")))
        #expect(fake.specs.last?.resumeSessionID == nil, "another folder's session is never resumed")
    }

    /// Esc during reconnect backoff must stop the question, not answer it later.
    @Test func escDuringBackoffStopsTheQuestion() async {
        let fake = FakeLauncher(crashAtBoot: true)
        let lane = QuickLane(spec: spec(), restart: RestartPolicy(delays: [.seconds(5), .seconds(5), .seconds(5)]),
                             transport: fake.factory)
        let stream = await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "q"))
        var events: [TurnEvent] = []
        for await e in stream {
            events.append(e)
            if case .reconnecting = e { await lane.cancel(conversation: "c1") }
        }
        #expect(events == [.reconnecting(attempt: 1), .failed(.cancelled)])
        #expect(fake.specs.count == 1)
    }

    @Test func cancelReachesARetiredSession() async {
        let fake = FakeLauncher(answers: false)
        let lane = QuickLane(spec: spec(), transport: fake.factory)
        let first = await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "1"), deadline: .seconds(30))
        #expect(await eventually { fake.specs.count == 1 })
        let second = await lane.ask(conversation: "c2", resumeSessionID: nil, input: TurnInput(text: "2"), deadline: .seconds(30))
        #expect(await eventually { fake.specs.count == 2 })
        await lane.cancel(conversation: "c1")
        #expect(await collect(first).last == .failed(.cancelled))
        await lane.shutdown()
        withExtendedLifetime(second) {}
    }

    @Test func cancellingTheConsumerCancelsTheQuestion() async {
        let fake = FakeLauncher(answers: false)
        let lane = QuickLane(spec: spec(), transport: fake.factory)
        let stream = await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "1"), deadline: .seconds(30))
        let consumer = Task { for await _ in stream {} }
        #expect(await eventually { fake.specs.count == 1 && !(fake.all.first?.sentLines.isEmpty ?? true) })
        consumer.cancel()
        // The CLI can't cancel a turn in place, so the question's process is stopped.
        #expect(await eventually { fake.all.first?.exited == 143 })
    }

    @Test func nothingStartsAfterShutdown() async {
        let fake = FakeLauncher()
        let lane = QuickLane(spec: spec(), transport: fake.factory)
        await lane.shutdown()
        await lane.prewarm()
        let events = await collect(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "q")))
        #expect(events == [.failed(.cancelled)])
        #expect(fake.specs.isEmpty)
    }

    @Test func deepFailsATurnThatGoesQuiet() async {
        let fake = FakeLauncher(answers: false)
        let lane = DeepLane(spec: { _, resume in spec(mode: .deep, resume: resume) }, inactivity: .milliseconds(100),
                            transport: fake.factory)
        let events = await collect(await lane.ask(conversation: "c1", folder: DeepFolder(url: URL(fileURLWithPath: "/p")),
                                                  resumeSessionID: nil, input: TurnInput(text: "q")))
        #expect(events.last == .failed(.timedOut))
    }
}
