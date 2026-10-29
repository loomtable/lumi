import BuddyCore
import Foundation
import Testing
@testable import BuddyConversations

@Suite("Bridge state")
struct BridgeStateTests {
    @Test("state from .done round-trips through the index into the next question's state")
    func roundTrip() async throws {
        try await withTempDir { dir in
            let ids = Counter()
            let m = ConversationManager(
                index: try ConversationIndex(url: nil), sessionFiles: FakeSessionFiles(), screenshotDirectory: dir,
                clock: ManualConversationClock(t0), makeID: { ids.next() })
            let first = try await m.prepare(projectFolder: nil)
            #expect(first.bridgeState == ConversationState(id: first.id))

            var done = ConversationState(id: first.id)
            done.quickSessionID = "q"
            done.deepSessionID = "d"
            done.lastLane = .deep
            done.deepFolder = URL(fileURLWithPath: "/work/web", isDirectory: true)
            done.lastQuickAnswer = "not stored"
            _ = try await m.finish(id: first.id, update: TurnUpdate(done), utterance: "why empty")

            let next = try await m.prepare(projectFolder: "/work/web")
            var expected = done
            expected.lastQuickAnswer = nil
            // Persisted since migration 2: the Deep session by folder, and when Deep answered.
            expected.deepSessions = ["/work/web": "d"]
            expected.lastDeepAnswerAt = t0
            #expect(next.id == first.id)
            #expect(next.bridgeState == expected)
        }
    }
}
