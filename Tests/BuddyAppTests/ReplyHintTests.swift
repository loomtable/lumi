import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyCore
import BuddyOverlay

/// "tap ⌥ to reply · click to type" until the user has replied once by the key and once by
/// clicking (typing in the card); then it's gone for good.
extension BuddyCoordinatorTests {
    private var hints: [String] {
        overlay.calls.compactMap { if case .answer(let a, _, _) = $0, a.block.say.hasPrefix("A") { a.replyHint } else { nil } }
    }

    private func answer(_ n: Int) -> CascadeEvent { Self.done(BuddyBlock(say: "A\(n).", shape: .chip)) }

    private func replyByClick(_ coordinator: BuddyCoordinator) async {
        let before = hints.count
        overlay.send(.submitted(text: "and then?", source: .reply))
        await settle(until: { hints.count > before && coordinator.phase == .showing })
    }

    @Test func theHintStaysUntilBothWaysToReplyWereUsed() async {
        bridge.setScript([answer(1)])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        bridge.setScript([answer(2)])
        await tapToTalk(coordinator) // a reply by the key
        bridge.setScript([answer(3)])
        await replyByClick(coordinator)
        bridge.setScript([answer(4)])
        await tapToTalk(coordinator)

        let full = "tap ⌥ to reply · click to type"
        #expect(hints == [full, full, "", ""])
    }

    @Test func aKeyPressOverAChipIsntAReply() async {
        bridge.setScript([Self.failed(code: "something_new"), Self.done(nil)])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator) // a failure chip
        bridge.setScript([answer(1)])
        await tapToTalk(coordinator) // the key over the chip: a new question, not a reply
        bridge.setScript([answer(2)])
        await replyByClick(coordinator)
        bridge.setScript([answer(3)])
        await tapToTalk(coordinator)
        let full = "tap ⌥ to reply · click to type"
        #expect(hints == [full, full, ""], "learned only once the key replied over an answer")
    }

    @Test func theLessonIsKeptAcrossLaunches() async {
        let defaults = UserDefaults(suiteName: NSTemporaryDirectory() + "reply-hint-\(UUID().uuidString)")!
        bridge.setScript([answer(1)])
        let first = makeCoordinator()
        first.hintDefaults = defaults
        await tapToTalk(first)
        bridge.setScript([answer(2)])
        await replyByClick(first)
        bridge.setScript([answer(3)])
        await tapToTalk(first)
        #expect(hints.last == "")

        let next = makeCoordinator()
        next.hintDefaults = defaults
        bridge.setScript([answer(4)])
        await tapToTalk(next)
        #expect(hints.last == "", "learned in an earlier run")
        _ = first
    }
}
