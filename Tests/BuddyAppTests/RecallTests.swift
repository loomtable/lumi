import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyContext
import BuddyCompanion
import BuddyCore
import BuddyKeys
import BuddyOverlay

/// An answer is never lost: the menu-bar dot, "Show Last Answer" or reopening the app brings the
/// last one back where it sat, silently, until the next question.
extension BuddyCoordinatorTests {
    private var recalled: [Answer] {
        overlay.calls.compactMap { if case .recall(let a, _) = $0 { a } else { nil } }
    }

    private var shown: [Answer] {
        overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a } else { nil } }
    }

    private func answered(_ say: String = "Yes.") async -> BuddyCoordinator {
        bridge.setScript([Self.done(BuddyBlock(say: say, shape: .chip, actions: [.init(label: "More", prompt: "more")]))])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        return coordinator
    }

    @Test func aClosedAnswerComesBackAsItWasWithoutSpeaking() async {
        let coordinator = await answered()
        #expect(coordinator.isShowingKeptAnswer)
        #expect(!coordinator.recallLastAnswer(), "already on screen")

        overlay.send(.dismissed(.clickAway))
        await settle()
        #expect(coordinator.hasKeptAnswer && !coordinator.isShowingKeptAnswer)
        let spoken = voice.calls.count
        #expect(coordinator.recallLastAnswer())
        #expect(recalled == [shown.last!], "the very Answer shown, so the overlay finds its spot")
        #expect(coordinator.phase == .showing && coordinator.isShowingKeptAnswer)
        await settle()
        #expect(voice.calls.count == spoken, "no speech")

        // Its actions work again: key 1 asks "more".
        bridge.setScript([Self.done(BuddyBlock(say: "More.", shape: .chip))])
        overlay.send(.action(index: 0))
        await settle(until: { bridge.asked.count == 2 })
        #expect(bridge.asked.last?.packet.utterance == "more")
    }

    @Test func tuckingKeepsItAndANewQuestionClearsIt() async {
        let coordinator = await answered()
        coordinator.setMissingPermission(.accessibility)
        coordinator.tuckAnswer()
        #expect(overlay.calls.last == .dismiss(.closeButton), "a tuck reason, so it folds into the dot")
        overlay.send(.dismissed(.closeButton)) // the overlay's echo
        await settle()
        #expect(!shown.contains { $0.block.say == BuddyCoordinator.permissionLine(.accessibility) },
                "a tuck isn't the user closing an answer: no permission chip")
        coordinator.setMissingPermission(nil)
        #expect(coordinator.phase == .idle && coordinator.hasKeptAnswer)

        bridge.setScript([Self.failed(code: "something_new"), Self.done(nil)])
        await tapToTalk(coordinator)
        #expect(!coordinator.hasKeptAnswer, "the failed question's answer is the one to recall: none")
        overlay.send(.dismissed(.clickAway))
        await settle()
        #expect(!coordinator.recallLastAnswer())
        #expect(recalled.isEmpty)
    }

    @Test func notWhileListeningNorAfterANewConversation() async {
        let coordinator = await answered()
        overlay.send(.dismissed(.escape))
        await settle()
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        #expect(!coordinator.recallLastAnswer(), "never over a live mic")
        await coordinator.escapePressed()
        await settle() // the overlay echoes the Esc
        #expect(coordinator.phase == .idle && coordinator.hasKeptAnswer)

        overlay.send(.newConversation)
        await settle(until: { !coordinator.hasKeptAnswer })
        #expect(!coordinator.hasKeptAnswer)
        #expect(!coordinator.recallLastAnswer())
    }

    @Test func aNewQuestionThatNeverAsksStillTakesTheTurnAway() async {
        // The next summon is in an app the buddy won't read: the target app is gone, so the old
        // answer's Insert would go nowhere it belongs.
        let context = SwitchingContext(FakeContext.packet())
        bridge.setScript([Self.done(BuddyBlock(say: "Yes.", shape: .chip))])
        let coordinator = BuddyCoordinator(
            settings: .init(), voice: voice, context: context, bridge: bridge,
            overlay: overlay, inserter: inserter, pointer: FixedPointer())
        coordinator.start()
        await tapToTalk(coordinator)
        overlay.send(.dismissed(.clickAway))
        await settle()
        #expect(coordinator.hasKeptAnswer)

        context.inner = FakeContext(result: .blocked(app: "1Password"))
        await tapToTalk(coordinator)
        #expect(shown.last?.block.say == "I don't look at 1Password.")
        #expect(!coordinator.hasKeptAnswer)
    }

    @Test func aStaleFixNeverFiresOnARecalledAnswer() async {
        let coordinator = await answered()
        var granted: [PermissionKind] = []
        coordinator.onGrantPermission = { granted.append($0) }
        coordinator.setMissingPermission(.accessibility)
        overlay.send(.dismissed(.clickAway)) // offers the Fix chip
        await settle(until: { shown.count == 2 })
        coordinator.tuckAnswer() // the chip is up, not the kept answer: nothing
        #expect(coordinator.phase == .showing && !coordinator.isShowingKeptAnswer)

        #expect(!coordinator.recallLastAnswer(), "the Fix chip is up")
        overlay.send(.dismissed(.clickAway))
        await settle()
        #expect(coordinator.recallLastAnswer())
        overlay.send(.action(index: 0))
        await settle()
        #expect(granted.isEmpty, "key 1 is the answer's action, not the chip's Fix")
    }
}

/// A context whose result the test changes between summons.
private final class SwitchingContext: ContextPort, @unchecked Sendable {
    var inner: FakeContext
    init(_ inner: FakeContext) { self.inner = inner }
    func capture() async -> SummonContext { await inner.capture() }
    func screenshot(displayID: UInt32?) async -> ShotOutcome { await inner.screenshot(displayID: displayID) }
}
