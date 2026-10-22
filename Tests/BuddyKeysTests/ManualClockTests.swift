import Synchronization
import Testing
@testable import BuddyKeys

@Suite("ManualClock")
struct ManualClockTests {
    final class Flag: Sendable {
        let value = Atomic(false)
    }

    @Test("now starts where told and only moves forward")
    func now() {
        let clock = ManualClock(now: 100)
        #expect(clock.now() == 100)
        clock.advance(to: 250)
        #expect(clock.now() == 250)
        clock.advance(to: 200)
        #expect(clock.now() == 250)
    }

    @Test("a sleeper wakes when advance passes its deadline")
    func sleeperWakes() async throws {
        let clock = ManualClock()
        let woke = Flag()
        let task = Task {
            try await clock.sleep(until: 100)
            woke.value.store(true, ordering: .sequentiallyConsistent)
        }
        let settled = await eventually { [clock] in clock.sleeperCount == 1 }
        #expect(settled)
        clock.advance(to: 99)
        #expect(clock.sleeperCount == 1)
        let wokeEarly = woke.value.load(ordering: .sequentiallyConsistent)
        #expect(!wokeEarly)
        clock.advance(to: 100)
        #expect(clock.sleeperCount == 0)
        try await task.value
        let wokeLate = woke.value.load(ordering: .sequentiallyConsistent)
        #expect(wokeLate)
    }

    @Test("only due sleepers wake")
    func onlyDueWake() async throws {
        let clock = ManualClock()
        let early = Task { try await clock.sleep(until: 10) }
        let late = Task { try await clock.sleep(until: 1000) }
        let settled = await eventually { [clock] in clock.sleeperCount == 2 }
        #expect(settled)
        clock.advance(to: 500)
        try await early.value
        #expect(clock.sleeperCount == 1)
        late.cancel()
        await #expect(throws: CancellationError.self) { try await late.value }
    }

    @Test("a deadline at or before now returns immediately", arguments: [UInt64(0), 50, 100])
    func pastDeadline(deadline: Nanos) async throws {
        let clock = ManualClock(now: 100)
        try await clock.sleep(until: deadline)
        #expect(clock.sleeperCount == 0)
    }

    @Test("cancellation throws CancellationError and removes the sleeper")
    func cancellation() async {
        let clock = ManualClock()
        let task = Task { try await clock.sleep(until: 1000) }
        let settled = await eventually { [clock] in clock.sleeperCount == 1 }
        #expect(settled)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.sleeperCount == 0)
        clock.advance(to: 2000)  // nothing left to resume
    }

    @Test("sleeping in an already cancelled task throws at once")
    func alreadyCancelled() async {
        let clock = ManualClock()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(until: 1000)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.sleeperCount == 0)
    }
}
