import AppKit
import BuddyCore
import Foundation
import SwiftUI
import Testing
@testable import BuddyOverlay

// Lead re-verification of #52: the fold into listening can be interrupted without leaving
// state behind, and toasts/chips stay on their display through their fades.

private func card() -> Answer {
    Answer(block: BuddyBlock(say: "Your filter drops last week's data.", shape: .card),
           lane: Lane(mode: .quick, model: .haiku), conversation: .ember, turn: 1, replyHint: "r")
}

private func waitUntil(_ condition: () -> Bool) async -> Bool {
    // Generous: it returns as soon as the condition holds, so only a failure waits this long.
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// A card on screen, then the buddy key: the card starts folding into listening.
private func overlayFoldingIntoListening() async -> BuddyOverlayController {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(card(), anchor: .point(CGPoint(x: 400, y: 400)))
    await overlay.presentationFinished()
    overlay.showListening(at: CGPoint(x: 400, y: 400), hint: "h")
    return overlay
}

@Test(.overlayExclusive) func textBoxDuringTheFoldClearsTheListeningFold() async {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    let overlay = await overlayFoldingIntoListening()
    #expect(overlay.model.folding)
    overlay.showTextBox(at: CGPoint(x: 400, y: 400))
    overlay.focusChanged(true)
    #expect(!overlay.wantsEscape)              // a focused text box gets Esc directly (IME)
    overlay.dismiss(.requested)
    #expect(overlay.model.folding)             // folds rather than cutting instantly
    #expect(await waitUntil { overlay.model.surface == .none })
}

@Test(.overlayExclusive) func secondListeningDuringTheFoldStillDismissesWithAFold() async {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    let overlay = await overlayFoldingIntoListening()
    overlay.showListening(at: CGPoint(x: 400, y: 400), hint: "h")
    guard case .listening = overlay.model.surface else { Issue.record("not listening"); return }
    overlay.dismiss(.requested)
    #expect(overlay.model.folding)
    #expect(await waitUntil { overlay.model.surface == .none })
}

@Test(.overlayExclusive) func toastIsPulledBackInsideOnceMeasured() {
    let model = OverlayModel()
    let bounds = CGRect(x: 0, y: 33, width: 1512, height: 949)
    model.toastBounds = bounds
    model.toast = OverlayModel.Toast(text: "Back to the previous conversation", origin: CGPoint(x: 1300, y: 500))
    model.toastSize = CGSize(width: 320, height: 32)
    let origin = model.toast?.origin ?? .zero
    #expect(origin.x + 320 <= bounds.maxX - Placer.edgeMargin)
    #expect(origin.y == 500)
}

@Test(.overlayExclusive) func chipPanelStaysUpThroughTheFade() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    let screen = ScreenSpace.topLeft(NSScreen.screens[0].visibleFrame)
    overlay.showResumeChip(title: "QT", detail: nil, at: CGPoint(x: screen.midX, y: screen.midY))
    #expect(overlay.visiblePanelCountForTesting == 1)
    overlay.hideConversationChip()
    #expect(overlay.model.conversationChip == nil)
    #expect(overlay.visiblePanelCountForTesting == 1)   // still up while the chip fades
    #expect(await waitUntil { overlay.visiblePanelCountForTesting == 0 })
}

@Test(.overlayExclusive) func toastIsMeasuredWithoutItsPositionOffset() async {
    let model = OverlayModel()
    let display = CGRect(x: 0, y: 0, width: 1200, height: 800)
    model.toastBounds = display
    model.toast = OverlayModel.Toast(text: "Discarded", origin: CGPoint(x: 600, y: 300))
    let view = NSHostingView(rootView: ToastLayer(model: model, displayFrame: display, onEvent: { _ in })
        .frame(width: display.width, height: display.height, alignment: .topLeading))
    view.frame = display
    view.layoutSubtreeIfNeeded()
    // Measured including the 600 pt leading offset, the toast would be ~700 wide and get
    // clamped back from x = 600.
    #expect(await waitUntil { model.toastSize.width < 200 && model.toastSize.height < 60 })
    #expect(model.toast?.origin == CGPoint(x: 600, y: 300))
    withExtendedLifetime(view) {}   // keep it alive until the measurement has arrived
}
