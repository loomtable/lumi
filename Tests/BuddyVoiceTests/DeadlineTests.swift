import Foundation
import Testing
@testable import BuddyVoice

struct DeadlineTests {
    @Test func workFirstWins() async {
        let work = Task<Int, any Error> { 7 }
        guard case .done(.success(7)) = await race(work, within: .seconds(2)) else { Issue.record("expected 7"); return }
    }

    @Test func theDeadlineFirstWins() async {
        let work = Task<Int, any Error> { try? await Task.sleep(for: .seconds(5)); return 1 }
        guard case .timedOut = await race(work, within: .milliseconds(50)) else { Issue.record("expected a timeout"); return }
    }

    /// Review: a cancelled caller (Esc) doesn't wait for the work or the deadline.
    @Test func aCancelledCallerReturnsAtOnce() async {
        let work = Task<Int, any Error> { try? await Task.sleep(for: .seconds(5)); return 1 }
        let caller = Task { await race(work, within: .seconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        caller.cancel()
        let outcome = await caller.value
        #expect(ContinuousClock.now - start < .seconds(1))
        guard case .done(.failure(is CancellationError)) = outcome else { Issue.record("\(outcome)"); return }
    }
}
