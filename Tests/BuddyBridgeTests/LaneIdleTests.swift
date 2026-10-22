import BuddyCore
import Foundation
import Synchronization
import Testing
@testable import BuddyBridge

/// Idle processes are freed (compute audit); the countdown is a gate the test opens.
struct LaneIdleTests {
    /// Each countdown waits on its own continuation; `open()` ends the oldest still waiting.
    /// Cancellation doesn't end a wait (the timer checks it after), so every countdown is opened explicitly.
    final class Gate: Sendable {
        private let waiting = Mutex<[CheckedContinuation<Void, Never>]>([])
        var count: Int { waiting.withLock { $0.count } }
        func open() { waiting.withLock { $0.isEmpty ? nil : $0.removeFirst() }?.resume() }
        var sleep: @Sendable (Duration) async -> Void {
            { [self] _ in await withCheckedContinuation { c in waiting.withLock { $0.append(c) } } }
        }
    }

    private func outcome(_ s: AsyncStream<TurnEvent>) async -> TurnOutcome? {
        for await e in s { if case .finished(let o) = e { return o } }
        return nil
    }

    private func deepLane(_ fake: FakeLauncher, gate: Gate) -> DeepLane {
        DeepLane(spec: { folder, resume in
            var s = spec(mode: .deep, resume: resume)
            s.workingDirectory = folder
            return s
        }, transport: fake.factory, idleAfter: .seconds(600), sleep: gate.sleep)
    }

    @Test func anIdleDeepProcessStopsAndTheNextHandoffResumesItsSession() async {
        let fake = FakeLauncher(), gate = Gate()
        let lane = deepLane(fake, gate: gate)
        let web = DeepFolder(url: URL(fileURLWithPath: "/Users/me/Developer/web"))
        _ = await outcome(await lane.ask(conversation: "c1", folder: web, resumeSessionID: nil, input: TurnInput(text: "q")))
        #expect(await eventually { gate.count == 1 })
        #expect(fake.all[0].exited == nil, "kept while the countdown runs")
        gate.open()
        #expect(await eventually { fake.all[0].exited != nil }, "freed after the idle limit")
        _ = await outcome(await lane.ask(conversation: "c1", folder: web, resumeSessionID: nil, input: TurnInput(text: "again")))
        #expect(fake.specs.last?.resumeSessionID == "new-1", "the conversation picks up its session")
    }

    @Test func aQuestionBeforeTheLimitKeepsTheDeepProcess() async {
        let fake = FakeLauncher(), gate = Gate()
        let lane = deepLane(fake, gate: gate)
        let web = DeepFolder(url: URL(fileURLWithPath: "/Users/me/Developer/web"))
        _ = await outcome(await lane.ask(conversation: "c1", folder: web, resumeSessionID: nil, input: TurnInput(text: "q")))
        _ = await outcome(await lane.ask(conversation: "c1", folder: web, resumeSessionID: "new-1", input: TurnInput(text: "follow-up")))
        #expect(await eventually { gate.count == 2 })
        gate.open()   // the first countdown: the follow-up cancelled it
        for _ in 0..<50 { await Task.yield() }
        #expect(fake.all[0].exited == nil, "the follow-up restarted the idle limit")
        #expect(fake.specs.count == 1, "one process for both questions")
        gate.open()   // the countdown from the follow-up's end
        #expect(await eventually { fake.all[0].exited != nil }, "freed once idle after the last question")
    }

    @Test func anIdleQuickLaneFreesItsSpareAndProcessThenComesBackOnPrewarm() async {
        let fake = FakeLauncher(), gate = Gate()
        let lane = QuickLane(spec: spec(), transport: fake.factory, idleAfter: .seconds(1800), sleep: gate.sleep)
        await lane.prewarm()
        _ = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "1")))
        #expect(await eventually { fake.specs.count == 2 }, "a new spare after c1 took the first")
        #expect(await eventually { gate.count == 2 })
        gate.open()   // the countdown from the first prewarm (cancelled by the ask)
        for _ in 0..<50 { await Task.yield() }
        #expect(fake.all.allSatisfy { $0.exited == nil }, "a cancelled countdown frees nothing")
        gate.open()   // the one armed when c1's question ended
        #expect(await eventually { fake.all.allSatisfy { $0.exited != nil } }, "spare and current process freed")
        await lane.prewarm()   // the buddy key went down
        #expect(fake.specs.count == 3 && fake.specs.last?.resumeSessionID == nil, "a fresh spare")
        _ = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "2")))
        #expect(fake.specs.last?.resumeSessionID == "new-1", "c1 resumes its own session")
    }
}

extension LaneIdleTests {
    @Test func aKeyPressCancelsAPendingCountdown() async {
        let fake = FakeLauncher(), gate = Gate()
        let lane = QuickLane(spec: spec(), transport: fake.factory, idleAfter: .seconds(1800), sleep: gate.sleep)
        await lane.prewarm()                 // arms countdown 1
        #expect(await eventually { gate.count == 1 })
        await lane.prewarm()                 // the key went down: countdown 1 is cancelled
        gate.open()
        for _ in 0..<50 { await Task.yield() }
        #expect(fake.specs.count == 1 && fake.all[0].exited == nil, "the spare stays")
    }
}

/// An 8 GB Mac keeps fewer processes alive.
extension LaneIdleTests {
    @Test func withoutAKeptSpareNoneIsRelaunchedOrLeftBesideTheCurrentProcess() async {
        let fake = FakeLauncher()
        let lane = QuickLane(spec: spec(), transport: fake.factory, keepSpare: false)
        await lane.prewarm()                                         // app launch
        _ = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "1")))
        for _ in 0..<50 { await Task.yield() }
        #expect(fake.specs.count == 1, "the spare was taken and not relaunched")
        await lane.prewarm()                                         // the buddy key went down
        #expect(fake.specs.count == 2)
        _ = await outcome(await lane.ask(conversation: "c1", resumeSessionID: nil, input: TurnInput(text: "2")))
        #expect(await eventually { fake.all[1].exited != nil }, "c1 continued in its process; the spare goes")
        #expect(fake.all[0].exited == nil, "the current process stays")
    }

    @Test func deepSaysWhenItIsAnswering() async {
        let fake = FakeLauncher()
        let busy = Mutex<[Bool]>([])
        let lane = DeepLane(spec: { folder, resume in
            var s = spec(mode: .deep, resume: resume)
            s.workingDirectory = folder
            return s
        }, transport: fake.factory, onBusy: { b in busy.withLock { $0.append(b) } })
        let web = DeepFolder(url: URL(fileURLWithPath: "/Users/me/Developer/web"))
        _ = await outcome(await lane.ask(conversation: "c1", folder: web, resumeSessionID: nil, input: TurnInput(text: "q")))
        #expect(await eventually { busy.withLock { $0 } == [true, false] })
        // Back to back, in other conversations: busy-idle pairs in order, ending idle. A question
        // can start once the previous one's answer is in, before its driver has finished; Deep
        // then stays busy across both, so there may be fewer than four pairs, never a lone signal.
        for c in ["c2", "c3", "c4"] {
            _ = await outcome(await lane.ask(conversation: c, folder: web, resumeSessionID: nil, input: TurnInput(text: c)))
        }
        #expect(await eventually { let b = busy.withLock { $0 }; return b.count >= 4 && pairs(b) })
        // Signals that land in the next moments keep the pairs (an out-of-order one never would).
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await eventually { pairs(busy.withLock { $0 }) }, "in order, ending idle: \(busy.withLock { $0 })")
        #expect(busy.withLock { $0 }.count <= 8)
    }

    @Test func deepCanStopAsEachQuestionEnds() async {
        let fake = FakeLauncher()
        let lane = DeepLane(spec: { folder, resume in
            var s = spec(mode: .deep, resume: resume)
            s.workingDirectory = folder
            return s
        }, transport: fake.factory, idleAfter: .zero)
        let web = DeepFolder(url: URL(fileURLWithPath: "/Users/me/Developer/web"))
        _ = await outcome(await lane.ask(conversation: "c1", folder: web, resumeSessionID: nil, input: TurnInput(text: "q")))
        #expect(await eventually { fake.all[0].exited != nil })
        _ = await outcome(await lane.ask(conversation: "c1", folder: web, resumeSessionID: nil, input: TurnInput(text: "again")))
        #expect(fake.specs.last?.resumeSessionID == "new-1", "the follow-up resumes its session")
    }
}

/// Busy-idle pairs in order: true, false, true, false…, ending idle.
private func pairs(_ b: [Bool]) -> Bool {
    b.count.isMultiple(of: 2) && b.enumerated().allSatisfy { $0.element == $0.offset.isMultiple(of: 2) }
}
