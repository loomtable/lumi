import AppKit
import Foundation
import Testing
@testable import BuddyOverlay

@Test func toastTimeGrowsWithLengthUpToFourSeconds() {
    #expect(BuddyOverlayController.toastDuration(for: "Discarded") == .milliseconds(1400))
    #expect(BuddyOverlayController.toastDuration(for: "Copied to clipboard") == .milliseconds(1400))
    #expect(BuddyOverlayController.toastDuration(for: "Couldn't reach Claude Code just now") == .milliseconds(2150))  // 6 words
    #expect(BuddyOverlayController.toastDuration(for: Array(repeating: "word", count: 40).joined(separator: " "))
            == .seconds(4))
}

@Test(.overlayExclusive) func aHoveredToastStaysUntilThePointerLeaves() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.toastDuration = .milliseconds(50)
    let screen = ScreenSpace.topLeft(NSScreen.screens[0].visibleFrame)
    let pointer = CGPoint(x: screen.midX, y: screen.midY)
    nonisolated(unsafe) var hovering = true
    overlay.showToast("Discarded", at: pointer)
    let toast = overlay.model.toast!
    overlay.pointerLocation = { hovering ? CGPoint(x: toast.origin.x + 4, y: toast.origin.y + 4) : .zero }
    try? await Task.sleep(for: .milliseconds(400))
    #expect(overlay.model.toast != nil)  // held while hovered
    hovering = false
    let deadline = ContinuousClock.now + .seconds(5)
    while overlay.model.toast != nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    #expect(overlay.model.toast == nil)
}

@Test(.overlayExclusive) func aToastPlacedUnderAStillPointerIsNotHeld() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.toastDuration = .milliseconds(50)
    let screen = ScreenSpace.topLeft(NSScreen.screens[0].visibleFrame)
    let anchor = CGPoint(x: screen.midX, y: screen.midY)
    // The toast goes at anchor + (18, -30); the pointer already sits inside it and never moves,
    // as when an edge clamp puts the toast under it.
    let inside = CGPoint(x: anchor.x + 22, y: anchor.y - 26)
    overlay.pointerLocation = { inside }
    overlay.showToast("Discarded", at: anchor)
    #expect(overlay.model.toast.map { CGRect(origin: $0.origin, size: overlay.model.toastSize).contains(inside) } == true)
    let deadline = ContinuousClock.now + .seconds(3)
    while overlay.model.toast != nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    #expect(overlay.model.toast == nil)
}
