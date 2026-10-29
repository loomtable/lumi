import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyCore
import BuddyKeys
import BuddyOverlay

/// A clock the test moves by hand.
final class TestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_000_000))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

@MainActor
struct PositionsAndApprovalTests {
    let bridge = FakeBridge()
    let overlay = FakeOverlay()
    let time = TestClock()

    func make() -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let time = time
        let c = BuddyCoordinator(
            settings: settings, voice: FakeVoice(), context: FakeContext.packet(), turns: bridge,
            overlay: overlay, pointer: FixedPointer(), clock: { time.now })
        c.start()
        return c
    }

    func ask(_ c: BuddyCoordinator) async {
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + waitCeiling
        while c.phase != .showing, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    var resets: Int { overlay.calls.count { $0 == .resetPositions } }

    @Test func anApprovalCardsCancelSlotIsntAModelAction() async {
        let block = BuddyBlock(
            say: "Convert column C to numbers?", shape: .rich,
            actions: [.init(label: "Convert", prompt: "Convert column C"), .init(label: "Keep", prompt: "Keep as text"),
                      .init(label: "Delete", prompt: "Delete column C")],
            needsApproval: true)
        bridge.setScript([BuddyCoordinatorTests.done(block)])
        let c = make()
        await ask(c)

        overlay.send(.action(index: 2)) // key 3: the overlay's own Cancel sits there
        for _ in 0..<100 { await Task.yield() }
        #expect(bridge.asked.count == 1)
        overlay.send(.action(index: 1))
        let deadline = ContinuousClock.now + waitCeiling
        while bridge.asked.count < 2, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(bridge.asked.last?.packet.utterance == "Keep as text")
    }

    @Test func aNewConversationResetsPositions() async {
        bridge.setScript([BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .card))])
        let c = make()
        await ask(c)
        overlay.send(.newConversation)
        let deadline = ContinuousClock.now + waitCeiling
        while resets == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(resets == 1)
    }

    @Test func aSummonAfterTheIdleLimitResetsBeforeThePill() async {
        bridge.setScript([BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .card))])
        let c = make()
        await ask(c)
        overlay.dismiss(.clickAway)

        time.advance(5 * 60) // 5 min later: same conversation
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        #expect(resets == 0)
        await c.escapePressed()

        time.advance(ConversationBook.idleLimit) // past the idle limit: fresh
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        let reset = overlay.calls.lastIndex(of: .resetPositions)
        let pill = overlay.calls.lastIndex { if case .listening = $0 { true } else { false } }
        #expect(resets == 1)
        #expect(reset != nil && pill != nil && reset! < pill!)
    }
}
