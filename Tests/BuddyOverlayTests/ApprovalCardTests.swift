import AppKit
import BuddyCore
import Foundation
import Testing
@testable import BuddyOverlay

private func block(approval: Bool, shape: BuddyBlock.Shape = .rich, actions: Int = 3) -> BuddyBlock {
    BuddyBlock(say: "Convert column C to numbers.", shape: shape,
               actions: (1...actions).map { BuddyBlock.Action(label: "A\($0)", prompt: "p\($0)") },
               needsApproval: approval)
}

@Test func approvalCardShowsTheVerbInSageBesideAnOverlayCancel() {
    let b = block(approval: true)
    #expect(b.needsApproval)
    let shown = AnswerContent.shownActions(b, isChip: false)
    #expect(shown.map(\.label) == ["A1", "A2"], "two model actions leave room for Cancel within three")
    #expect(AnswerContent.kind(ofAction: 0, block: b, isChip: false) == .approve)
    #expect(AnswerContent.kind(ofAction: 1, block: b, isChip: false) == .quiet)
}

@Test func ordinaryCardsKeepTheEmberPrimaryAndThreeActions() {
    let b = block(approval: false, shape: .card)
    #expect(AnswerContent.shownActions(b, isChip: false).count == 3)
    #expect(AnswerContent.kind(ofAction: 0, block: b, isChip: false) == .primary)
    #expect(AnswerContent.shownActions(b, isChip: true).count == 1)
    #expect(AnswerContent.kind(ofAction: 0, block: b, isChip: true) == .quiet)
}

@Test func numberKeysOnlyReachActionsOnScreen() {
    let b = block(approval: true)
    let count = AnswerContent.shownActions(b, isChip: false).count
    let three = KeyCommand.map(keyCode: 0x14, characters: "3", modifiers: [], plainKeysActive: true, actionCount: count)
    #expect(three == nil, "the third model action isn't shown on an approval card")
    let verb = KeyCommand.map(keyCode: KeyCommand.returnKeyCode, characters: "\r", modifiers: .command,
                              plainKeysActive: true, actionCount: count)
    #expect(verb == .event(.action(index: 0)), "⌘↵ runs the verb")
}

@Test func theAmberOutlineIsTheDesignToken() {
    #expect(Tokens.amberBorder == TokenColor(245 / 255, 192 / 255, 96 / 255, 0.6))
}

private func answer(_ b: BuddyBlock) -> Answer {
    Answer(block: b, lane: Lane(mode: .deep, model: .opus), conversation: .amber, turn: 1, replyHint: "r")
}

@Test func theApprovalLabelIsMeasuredIntoTheCard() {
    let overlay = BuddyOverlayController()
    let plain = overlay.measureForTesting(answer(block(approval: false)), style: .centered)
    let approval = overlay.measureForTesting(answer(block(approval: true)), style: .centered)
    #expect(approval.height > plain.height, "the Needs your OK row adds height")
}

@Test func aKeyForAnActionNotOnScreenDoesNothing() async {
    let overlay = BuddyOverlayController()
    overlay.showAnswer(answer(block(approval: true)), anchor: .point(CGPoint(x: 400, y: 400)))
    await overlay.presentationFinished()
    func key(_ c: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!
    }
    #expect(!overlay.handleKey(key("3")), "the third model action is hidden beside Cancel")
    #expect(overlay.handleKey(key("2")))
    overlay.dismiss(.requested)
}
