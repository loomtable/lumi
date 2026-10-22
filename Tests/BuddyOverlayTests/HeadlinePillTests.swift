import BuddyCore
import Foundation
import SwiftUI
import AppKit
import Testing
@testable import BuddyOverlay

private let lane = Lane(mode: .quick, model: .haiku)

private func answer(say: String) -> Answer {
    Answer(block: BuddyBlock(say: say, shape: .card), lane: lane, conversation: .ember, turn: 1, replyHint: "")
}

@Test(.overlayExclusive) func headlineInThePillMarksItAndAProgressLineClearsIt() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showThinking(lane, status: "Reading the page")
    #expect(!overlay.model.statusIsHeadline)
    overlay.showHeadline("Your filter drops last week's data.")
    #expect(overlay.model.statusIsHeadline)
    #expect(overlay.model.surface == .thinking(lane, status: "Your filter drops last week's data."))
    overlay.updateStatus("Checking the sheet")
    #expect(!overlay.model.statusIsHeadline)
    overlay.dismiss(.escape)
}

@Test(.overlayExclusive) func headlineOutsideThinkingDoesNothing() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showHeadline("Too early")
    #expect(overlay.model.surface == .none)
    #expect(!overlay.model.statusIsHeadline)
}

@Test(.overlayExclusive) func anAnswerWithTheShownHeadlineSkipsInk() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showThinking(lane, status: nil)
    overlay.showHeadline("Your filter drops last week's data.")
    overlay.showAnswer(answer(say: " Your filter drops last week's data.\n"), anchor: .point(CGPoint(x: 300, y: 300)), snapshot: nil)
    #expect(overlay.model.headlineAlreadyShown)
    await overlay.presentationFinished()
    overlay.dismiss(.escape)
}

@Test(.overlayExclusive) func aDifferentOrProgressOnlyHeadlineStillInks() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showThinking(lane, status: nil)
    overlay.showHeadline("Your filter drops last week's data.")
    overlay.showAnswer(answer(say: "Your filter drops data from last week."), anchor: .point(CGPoint(x: 300, y: 300)), snapshot: nil)
    #expect(!overlay.model.headlineAlreadyShown)  // rewritten in the answer: ink as usual
    await overlay.presentationFinished()
    overlay.showThinking(lane, status: "Your filter drops last week's data.")  // a progress line, not the headline
    overlay.showAnswer(answer(say: "Your filter drops last week's data."), anchor: .point(CGPoint(x: 300, y: 300)), snapshot: nil)
    #expect(!overlay.model.headlineAlreadyShown)
    await overlay.presentationFinished()
    overlay.dismiss(.escape)
}

@Test func sameHeadlineIgnoresOnlySurroundingWhitespace() {
    #expect(BuddyOverlayController.sameHeadline("Hi there.", "  Hi there.\n"))
    #expect(!BuddyOverlayController.sameHeadline("Hi there.", "Hi there!"))
    #expect(!BuddyOverlayController.sameHeadline(nil, "Hi there."))
    #expect(!BuddyOverlayController.sameHeadline("", " "))
}

@Test func fakeRecordsTheHeadline() {
    let fake = FakeOverlay()
    fake.showHeadline("Hello")
    #expect(fake.calls == [.headline("Hello")])
}

@MainActor private func fitting<V: View>(_ view: V) -> CGSize {
    NSHostingView(rootView: view.fixedSize()).fittingSize
}

@Test(.overlayExclusive) func hugWrapHugsShortTextAndWrapsLongTextTaller() {
    let short = fitting(HugWrap(maxWidth: 200) { Text("Short").lineLimit(2) })
    #expect(short.width < 200)
    let one = fitting(HugWrap(maxWidth: 200) { Text("x").lineLimit(2) }).height
    let long = fitting(HugWrap(maxWidth: 200) {
        Text("Your filter drops last week's data, so the totals look low on Mondays.").lineLimit(2)
    })
    #expect(long.width <= 200)
    #expect(long.height > one * 1.5)  // measured as two lines, not one
}
