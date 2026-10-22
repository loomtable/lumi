import AppKit
import BuddyCore
import Foundation
import SwiftUI
import Testing
@testable import BuddyOverlay

@Test func keyHintsShowOnAFocusedCardWhoseReplyIsntBeingEdited() {
    #expect(AnswerContent.showsKeyHints(isChip: false, cardFocused: true, replyEditing: false))
    #expect(!AnswerContent.showsKeyHints(isChip: false, cardFocused: true, replyEditing: true))  // 1–3 type into the field
    #expect(!AnswerContent.showsKeyHints(isChip: false, cardFocused: false, replyEditing: false))
    #expect(!AnswerContent.showsKeyHints(isChip: true, cardFocused: true, replyEditing: false))
}

@Test func eachActionShowsItsNumberButApproveKeepsCommandReturn() {
    #expect(AnswerContent.keyHint(forAction: 0, kind: .primary, shown: true) == "1")
    #expect(AnswerContent.keyHint(forAction: 2, kind: .quiet, shown: true) == "3")
    #expect(AnswerContent.keyHint(forAction: 0, kind: .approve, shown: true) == nil)
    #expect(AnswerContent.keyHint(forAction: 1, kind: .quiet, shown: false) == nil)
}

@Test(.overlayExclusive) func aChipIsTheSameSizeSpeakingOrNot() {
    let a = Answer(block: BuddyBlock(say: "Press Return to send it.", shape: .chip,
                                     actions: [.init(label: "Copy", prompt: "p")]),
                   lane: Lane(mode: .quick, model: .haiku), conversation: .ember, turn: 1, replyHint: "")
    func size(speaking: Bool) -> CGSize {
        // Natural size, as measure() takes it: a slot shown only while speaking would change the width.
        NSHostingView(rootView: AnswerContent(answer: a, style: .chip, t: Tokens(.init(dark: false)), web: nil,
                                              webHeight: 0, speaking: speaking, sizing: true)
            .fixedSize()).fittingSize
    }
    #expect(size(speaking: true) == size(speaking: false))
}

// MARK: Chip Copy (chips couldn't be copied)

@Test func aChipOffersCopyUnlessItsButtonAlreadyCopies() {
    #expect(AnswerContent.showsChipCopy(mainAction: nil))
    #expect(AnswerContent.showsChipCopy(mainAction: .insert))
    #expect(AnswerContent.showsChipCopy(mainAction: .replace))
    #expect(!AnswerContent.showsChipCopy(mainAction: .copy))
}

@Test(.overlayExclusive) func aPlainChipShowsItsCopyBesideTheLine() {
    // Laid out like measure(): the line row is wider by the Copy icon when the chip shows it.
    func width(_ main: MainAction?) -> CGFloat {
        let a = Answer(block: BuddyBlock(say: "It's 14 items, £82.40 in total.", shape: .chip),
                       lane: Lane(mode: .quick, model: .haiku), conversation: .ember, turn: 1, replyHint: "", mainAction: main)
        return NSHostingView(rootView: AnswerContent(answer: a, style: .chip, t: Tokens(.init(dark: false)), web: nil,
                                                     webHeight: 0, sizing: true).fixedSize()).fittingSize.width
    }
    #expect(width(nil) - width(.copy) >= 20, "a chip without a Copy button gets the Copy icon by its line")
}

// MARK: Card header fits ("continuing…" was cut off)

@Test func theHeaderCopyGoesWhenTheMainButtonCopies() {
    #expect(!CardHeader.showsCopy(shownMain: .copy))
    #expect(CardHeader.showsCopy(shownMain: .insert))
    #expect(CardHeader.showsCopy(shownMain: nil))   // e.g. an approval card, which shows no main button
    #expect(Answer(block: BuddyBlock(say: "x", shape: .card), lane: Lane(mode: .quick, model: .haiku), conversation: .ember,
                   turn: 12, replyHint: "", isLong: true).shortHeaderLabel == "continuing · 12")
    #expect(Answer(block: BuddyBlock(say: "x", shape: .card), lane: Lane(mode: .quick, model: .haiku), conversation: .ember,
                   turn: 12, replyHint: "").compactHeaderLabel == "turn 12")
}

@Test(.overlayExclusive) func theTurnLabelFitsACardHeader() {
    // The header's tightest layout ("Go deeper" as an icon, the short label) fits the card's inner width.
    func width(_ view: some View) -> CGFloat { NSHostingView(rootView: view.fixedSize()).fittingSize.width }
    let available = BuddyOverlayController.cardWidth - 2 * Tokens.rimInset
    let goDeeperSaving = width(Text("Go deeper").font(Typeface.label)) + 2 - 18
    for (turn, long, main, speaking) in [(2, false, MainAction?.some(.copy), true), (2, false, MainAction?.some(.insert), true),
                                         (12, true, .insert, false), (12, false, .replace, false)] {
        let a = Answer(block: BuddyBlock(say: "x", shape: .card), lane: Lane(mode: .quick, model: .haiku),
                       conversation: .ember, turn: turn, replyHint: "", isLong: long, mainAction: main)
        let ideal = width(CardHeader(answer: a, t: Tokens(.init(dark: false)), speaking: speaking, onEvent: { _ in }, onClose: {}))
        let labelSaving = width(Text(a.headerLabel).font(Typeface.label)) - width(Text(a.compactHeaderLabel).font(Typeface.label))
        #expect(ideal - goDeeperSaving - labelSaving <= available, "turn \(turn), long \(long), \(String(describing: main)), speaking \(speaking)")
    }
}

// MARK: Reply hint learned (default: learn-then-hide)

@Test(.overlayExclusive) func aLearnedReplyHintLeavesNoBlankRow() {
    func height(_ hint: String) -> CGFloat {
        let a = Answer(block: BuddyBlock(say: "It's in the Edit menu.", shape: .card),
                       lane: Lane(mode: .quick, model: .haiku), conversation: .ember, turn: 1, replyHint: hint)
        return NSHostingView(rootView: AnswerContent(answer: a, style: .card, t: Tokens(.init(dark: false)), web: nil,
                                                     webHeight: 0, sizing: true).fixedSize()).fittingSize.height
    }
    #expect(height("tap ⌥ to reply · click to type") - height("") >= 12, "an empty hint takes no row")
}
