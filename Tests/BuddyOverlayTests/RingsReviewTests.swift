import AppKit
import BuddyCore
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import BuddyOverlay

// Lead re-verification of #50: click-through with only rings left, proven with an injected
// pointer (these fail with either reset removed).

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

@Test(.overlayExclusive) func closingACardUnderThePointerLeavesRingsClickThrough() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.ringDuration = .seconds(10)
    let screen = ScreenSpace.topLeft(NSScreen.screens[0].frame)
    let centre = CGPoint(x: screen.midX, y: screen.midY)
    overlay.showAnswer(card(), anchor: .point(centre))
    await overlay.presentationFinished()
    guard case .answer(_, let p, _) = overlay.model.surface else { Issue.record("no card"); return }
    overlay.pointerLocation = { CGPoint(x: p.frame.midX, y: p.frame.midY) }   // pointer over the card
    overlay.showRings([Ring(rect: CGRect(x: screen.minX + 100, y: screen.minY + 100, width: 80, height: 18))])
    overlay.pointerMovedForTesting()
    #expect(overlay.anyPanelBlocksClicksForTesting)          // precondition: the card takes clicks
    overlay.dismiss(.closeButton)
    #expect(await waitUntil { overlay.model.surface == .none })
    #expect(overlay.visiblePanelCountForTesting == 1)         // the ring is still up
    #expect(!overlay.anyPanelBlocksClicksForTesting)          // and nothing swallows clicks
}

@Test(.overlayExclusive) func aPanelOrderedInForRingsStartsClickThrough() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.ringDuration = .seconds(10)
    let screen = ScreenSpace.topLeft(NSScreen.screens[0].frame)
    overlay.pointerLocation = { CGPoint(x: screen.minX + 140, y: screen.minY + 109) }  // pointer on the ring
    overlay.showListening(at: CGPoint(x: screen.midX, y: screen.midY), hint: "h")
    overlay.dismiss(.requested)
    #expect(await waitUntil { overlay.visiblePanelCountForTesting == 0 })
    overlay.makePanelsBlockClicksForTesting()                 // a hidden panel left click-blocking
    overlay.showRings([Ring(rect: CGRect(x: screen.minX + 100, y: screen.minY + 100, width: 80, height: 18))])
    #expect(overlay.visiblePanelCountForTesting == 1)
    #expect(!overlay.anyPanelBlocksClicksForTesting)          // ordered in click-through; rings take no clicks
}

@Test(.overlayExclusive) func jumpLabelsWithAPercentSignSurvive() {
    let url = URL(string: "buddy://jump/50%25")!               // the label "50%"
    #expect(CardWebContent.policy(type: .linkActivated, url: url, isMainFrame: true, initialLoadDone: true) == .jump("50%"))
}

// MARK: Soft wash: borderless, nothing traces the words

/// Renders the wash over white and returns the green channel (ember is low in green), so a
/// solid ember stroke reads near 0.38 and a light wash stays high.
@MainActor private func greens(_ v: Tokens.Variant, label: String? = nil, on ground: Color = .white)
    -> (min: Double, centre: Double, centreColor: NSColor?) {
    let size = CGSize(width: 240, height: 60), spot = CGRect(x: 40, y: 20, width: 140, height: 18)
    let wash = RingWash.washRect(for: spot)
    let view = NSHostingView(rootView: ZStack(alignment: .topLeading) {
        ground
        RingWash(label: label, t: Tokens(v))
            .frame(width: wash.width, height: wash.height)
            .offset(x: wash.minX, y: wash.minY)
    }.frame(width: size.width, height: size.height))
    view.frame = CGRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    func green(_ x: Int, _ y: Int) -> Double { Double(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.greenComponent ?? 1) }
    var lowest = 1.0
    for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide { lowest = min(lowest, green(x, y)) } }
    let scale = Double(rep.pixelsWide) / size.width
    let (cx, cy) = (Int(spot.midX * scale), Int(spot.midY * scale))
    return (lowest, green(cx, cy), rep.colorAt(x: cx, y: cy)?.usingColorSpace(.sRGB))
}

@Test(.overlayExclusive) func washTintsTheSpotWithNoStroke() {
    let light = greens(.init(dark: false))
    #expect(light.centre < 0.95)   // visibly tinted behind the words
    #expect(light.min > 0.75)      // no solid ember anywhere: no border, no halo ring
}

@Test(.overlayExclusive) func darkWashIsMistNotEmber() throws {
    let c = try #require(greens(.init(dark: true), on: .black).centreColor)
    #expect(c.blueComponent > c.redComponent)   // mist (#8FB8D8) is blue-leaning; ember is red
    #expect(c.blueComponent > 0.08)             // visibly lit on a black screen
}

@Test(.overlayExclusive) func increaseContrastAddsAnUnderlineNotAFrame() {
    #expect(greens(.init(dark: false, increaseContrast: true)).min < 0.5)
    #expect(RingWash.washColor(Tokens(.init(dark: false, increaseContrast: true))).alpha > RingWash.washColor(Tokens(.init(dark: false))).alpha)
    #expect(RingWash.washColor(Tokens(.init(dark: true, increaseContrast: true))).alpha > RingWash.washColor(Tokens(.init(dark: true))).alpha)
}

@Test(.overlayExclusive) func numberedWashShowsItsDot() {
    #expect(greens(.init(dark: false), label: "2").min < 0.5)   // the solid ember number dot
}

@Test func washGeometryAndStrength() {
    let spot = CGRect(x: 100, y: 50, width: 80, height: 18)
    #expect(RingWash.washRect(for: spot) == spot.insetBy(dx: -RingWash.padding.width, dy: -RingWash.padding.height))
    let caret = RingWash.washRect(for: CGRect(x: 200, y: 50, width: 0, height: 18))
    #expect(caret.width == RingWash.minWidth + 2 * RingWash.padding.width)
    #expect(caret.midX == 200)
    let light = Tokens(.init(dark: false)), dark = Tokens(.init(dark: true))
    #expect(RingWash.washColor(light) == light.emberMark.opacity(0.36))   // ember wash, stronger since Oct 17
    #expect(RingWash.washColor(dark) == dark.mist.opacity(0.25))          // a softer, greyer mist on dark Macs
    #expect(RingWash.washColor(Tokens(.init(dark: false, increaseContrast: true))) == light.emberMark.opacity(0.50))
    #expect(RingWash.washColor(Tokens(.init(dark: true, increaseContrast: true))) == dark.mist.opacity(0.34))
}

@Test(.overlayExclusive) func ringsStaySixSecondsAndBloomThenSettle() {
    #expect(BuddyOverlayController(observesSystem: false).ringDuration == .seconds(6))
    #expect(RingView.bloomPeak > RingView.bloomRest && RingView.bloomRest > 0)  // lands bright, rests soft
}

@Test(.overlayExclusive) func aSpotRungAgainRestartsItsRingInsteadOfStacking() {
    let overlay = BuddyOverlayController(observesSystem: false)
    let spot = CGRect(x: 200, y: 200, width: 80, height: 18)
    overlay.showRings([Ring(rect: spot, label: "1")])
    overlay.showRings([Ring(rect: spot, label: "1")])   // the answer's jump link for the same point
    #expect(overlay.model.rings.count == 1)
    overlay.showRings([Ring(rect: spot.offsetBy(dx: 0, dy: 40), label: "2")])
    #expect(overlay.model.rings.count == 2)
}

@Test(.overlayExclusive) func aNewQuestionClearsTheLastAnswersRings() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showRings([Ring(rect: CGRect(x: 200, y: 200, width: 80, height: 18), label: nil)])
    overlay.showThinking(Lane(mode: .quick, model: .haiku), status: nil)
    #expect(overlay.model.rings.isEmpty)
    overlay.dismiss(.requested)
}
