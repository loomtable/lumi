import Foundation
import Synchronization
import Testing
@testable import BuddyVoice

struct IdleWarmUpTests {
    final class Log: Sendable {
        let entries = Mutex<[String]>([])
        func add(_ s: String) { entries.withLock { $0.append(s) } }
        var all: [String] { entries.withLock { $0 } }
    }

    /// Not awaited, as in the app: awaiting the task would raise it to the awaiter's priority.
    @Test func stepsRunAfterTheDelayAtUtilityPriority() async {
        let log = Log()
        let start = ContinuousClock.now
        IdleWarmUp.schedule(
            [{ log.add("a \(Task.currentPriority == .utility)") }, { log.add("b") }],
            after: .milliseconds(100), isQuiet: { true })
        for _ in 0..<200 where log.all.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(log.all == ["a true", "b"])
        #expect(ContinuousClock.now - start >= .milliseconds(100))
    }

    /// Busy: wait and check again; it runs once quiet.
    @Test func aBusyMomentWaitsInsteadOfDropping() async {
        let log = Log()
        let busyChecks = Mutex(3)
        let ran = await IdleWarmUp.schedule(
            [{ log.add("a") }, { log.add("b") }], after: .zero, poll: .milliseconds(10),
            isQuiet: { busyChecks.withLock { n in defer { n -= 1 }; return n <= 0 } }).value
        #expect(ran == 2 && log.all == ["a", "b"])
    }

    /// Under memory pressure or heat, the rest is dropped.
    @Test func pressureDropsTheRest() async {
        let log = Log()
        let checks = Mutex(0)
        let ran = await IdleWarmUp.schedule(
            [{ log.add("a") }, { log.add("b") }], after: .zero, isQuiet: { true },
            skip: { checks.withLock { n in defer { n += 1 }; return n >= 1 } }).value
        #expect(ran == 1 && log.all == ["a"])
    }

    @Test func neverQuietGivesUp() async {
        let log = Log()
        let ran = await IdleWarmUp.schedule([{ log.add("a") }], after: .zero, poll: .milliseconds(10), giveUpAfter: .milliseconds(100),
                                            isQuiet: { false }).value
        #expect(ran == 0 && log.all.isEmpty)
    }

    /// Review: read from the kernel when asked, so a Mac already under pressure at launch reads high,
    /// and a warning that has passed doesn't stick.
    @Test func memoryPressureIsTheKernelsCurrentLevel() {
        let level = SystemPressure.memoryPressureLevel()
        #expect([1, 2, 4].contains(level), "normal, warning or critical: \(level)")
    }
}
