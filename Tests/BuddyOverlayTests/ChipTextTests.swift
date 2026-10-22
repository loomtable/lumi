import AppKit
import BuddyCore
import CoreGraphics
import Testing
@testable import BuddyOverlay

private func chip(_ say: String) -> Answer {
    Answer(block: BuddyBlock(say: say, shape: .chip), lane: Lane(mode: .quick, model: .haiku),
           conversation: .ember, turn: 0, replyHint: "")
}

@MainActor
@Test(.overlayExclusive) func chipTextUpdatesInPlace() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(chip("Still setting up voice · 12%"), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    guard case .answer(_, let before, _) = overlay.model.surface else { Issue.record("no chip"); return }
    let id = overlay.model.answerID

    overlay.updateChipText("Still setting up voice · compiling the speech model, 61%")
    guard case .answer(let shown, let after, let style) = overlay.model.surface else { Issue.record("no chip"); return }
    #expect(shown.block.say == "Still setting up voice · compiling the speech model, 61%")
    #expect(style == .chip)
    #expect(overlay.model.answerID == id) // no new answer: no pop, no ink-in rerun
    #expect(after.frame.origin == before.frame.origin)
    #expect(after.frame.width > before.frame.width)
    #expect(after.frame.width <= BuddyOverlayController.chipMaxWidth)
    overlay.dismiss(.requested)
}

@MainActor
@Test(.overlayExclusive) func chipTextDoesNothingWithoutAChip() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.updateChipText("nothing showing")
    #expect(overlay.model.surface == .none)

    let card = Answer(block: BuddyBlock(say: "A card.", shape: .card), lane: Lane(mode: .quick, model: .haiku),
                      conversation: .ember, turn: 1, replyHint: "")
    overlay.showAnswer(card, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    overlay.updateChipText("not for cards")
    guard case .answer(let shown, _, _) = overlay.model.surface else { Issue.record("no card"); return }
    #expect(shown.block.say == "A card.")
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func grownChipStaysOnTheDisplay() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let frame = CGRect(x: 800, y: 700, width: 150, height: 30)
    let grown = BuddyOverlayController.resizedChipFrame(frame, to: CGSize(width: 300, height: 50), edge: .below, in: bounds)
    #expect(grown.size == CGSize(width: 300, height: 50))
    #expect(grown.maxX == 1000 - Placer.edgeMargin)
    #expect(grown.minY == 700)

    let fits = BuddyOverlayController.resizedChipFrame(CGRect(x: 100, y: 100, width: 150, height: 30),
                                                       to: CGSize(width: 200, height: 30), edge: .below, in: bounds)
    #expect(fits.origin == CGPoint(x: 100, y: 100))
}

@Test(.overlayExclusive) func grownChipKeepsTheSideFacingItsAnchor() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let frame = CGRect(x: 400, y: 300, width: 150, height: 30)
    let size = CGSize(width: 300, height: 50)
    // Above the anchor: the bottom stays; to its leading side: the trailing edge stays.
    let above = BuddyOverlayController.resizedChipFrame(frame, to: size, edge: .above, in: bounds)
    #expect(above.maxY == frame.maxY)
    #expect(above.minX == frame.minX)
    let leading = BuddyOverlayController.resizedChipFrame(frame, to: size, edge: .leading, in: bounds)
    #expect(leading.maxX == frame.maxX)
    #expect(leading.minY == frame.minY)
    let trailing = BuddyOverlayController.resizedChipFrame(frame, to: size, edge: .trailing, in: bounds)
    #expect(trailing.origin == frame.origin)
}

@Test(.overlayExclusive) func chipNeverShrinks() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let frame = CGRect(x: 100, y: 100, width: 260, height: 40)
    let r = BuddyOverlayController.resizedChipFrame(frame, to: CGSize(width: 200, height: 30), edge: .below, in: bounds)
    #expect(r == frame)
}

@MainActor
@Test(.overlayExclusive) func chipTextSentWhileAnAnswerIsPresentingLandsOnTheNewChip() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(chip("An earlier chip."), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()

    overlay.showAnswer(chip("Still setting up voice · 10%"), anchor: .point(CGPoint(x: 300, y: 300)))
    overlay.updateChipText("Still setting up voice · 20%") // before the new chip has landed
    guard case .answer(let old, _, _) = overlay.model.surface else { Issue.record("no chip"); return }
    #expect(old.block.say == "An earlier chip.")

    await overlay.presentationFinished()
    guard case .answer(let shown, _, _) = overlay.model.surface else { Issue.record("no chip"); return }
    #expect(shown.block.say == "Still setting up voice · 20%")
    overlay.dismiss(.requested)
}

@MainActor
@Test(.overlayExclusive) func chipTextWhileFoldingDoesNothing() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(chip("Folding away."), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    overlay.dismiss(.requested)
    overlay.updateChipText("too late")
    if case .answer(let shown, _, _) = overlay.model.surface { #expect(shown.block.say == "Folding away.") }
}

@MainActor
@Test(.overlayExclusive) func fakeRecordsChipText() {
    let fake = FakeOverlay()
    fake.updateChipText("42%")
    #expect(fake.calls == [.chipText("42%")])
}
