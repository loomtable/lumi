import BuddyCore
import CoreGraphics
import Foundation
import SwiftUI
import WebKit
import AppKit
import Observation
import Synchronization
import Testing
@testable import BuddyOverlay

// MARK: Tokens

@Test(.overlayExclusive) func tokensMatchDesign() {
    let light = Tokens(.init(dark: false))
    let dark = Tokens(.init(dark: true))
    #expect(light.well == TokenColor(hex: 0xFBFAF7, alpha: 0.94))
    #expect(dark.well == TokenColor(hex: 0x16181D, alpha: 0.94))
    #expect(light.glassTint == TokenColor(251 / 255, 250 / 255, 247 / 255, 0.40))
    #expect(dark.glassTint == TokenColor(18 / 255, 20 / 255, 24 / 255, 0.45))
    #expect(light.innerHighlight.alpha == 0.55)
    #expect(dark.innerHighlight.alpha == 0.14)
    #expect(light.hairline == TokenColor(0, 0, 0, 0.16))
    #expect(light.hairlineBright == TokenColor(0, 0, 0, 0.30))
    #expect(dark.hairline == TokenColor(1, 1, 1, 0.22))
    #expect(dark.hairlineBright == TokenColor(1, 1, 1, 0.35))
    #expect(light.text == TokenColor(hex: 0x1B1C20))
    #expect(dark.emberText == TokenColor(hex: 0xFF8A5B))
    #expect(light.emberMark == TokenColor(hex: 0xD9622F))
    #expect(dark.onEmber == TokenColor(hex: 0x24130B))
    #expect(light.onEmber == TokenColor(hex: 0x1B0D06))
    #expect(Tokens.cardRadius - Tokens.rimInset == Tokens.wellRadius)
}

@Test(.overlayExclusive) func reduceTransparencyMakesSurfacesOpaque() {
    let light = Tokens(.init(dark: false, reduceTransparency: true))
    let dark = Tokens(.init(dark: true, reduceTransparency: true))
    #expect(!light.usesGlass && !dark.usesGlass)
    #expect(light.opaqueSurface == TokenColor(hex: 0xF3F1ED))
    #expect(dark.opaqueSurface == TokenColor(hex: 0x1E2025))
    #expect(light.well.alpha == 1 && dark.well.alpha == 1)
}

@Test(.overlayExclusive) func increaseContrastStrengthensEdgesAndText() {
    for dark in [false, true] {
        let normal = Tokens(.init(dark: dark))
        let strong = Tokens(.init(dark: dark, increaseContrast: true))
        #expect(strong.hairline.alpha > normal.hairline.alpha)
        #expect(strong.well.alpha == 1)
        #expect(strong.secondaryText != normal.secondaryText)
        #expect(strong.usesGlass)
    }
}

// MARK: Placement

private let screen = CGRect(x: 0, y: 25, width: 1512, height: 924)  // visible frame, top-left
private let card = CGSize(width: 330, height: 200)

@Test(.overlayExclusive) func placesBelowFirst() {
    let anchor = Anchor.rect(CGRect(x: 600, y: 200, width: 120, height: 20))
    let p = Placer.place(size: card, anchor: anchor, in: screen, style: .card)
    #expect(p.edge == .below)
    #expect(p.frame.minY == 220 + Placer.gap)
    #expect(p.frame.midX == 660)
    #expect(p.tailOffset == 165)
    #expect(p.avoidsAnchor)
}

@Test(.overlayExclusive) func fallsBackToAboveThenSide() {
    // Near the bottom: no room below.
    let low = Anchor.rect(CGRect(x: 600, y: 860, width: 120, height: 20))
    #expect(Placer.place(size: card, anchor: low, in: screen, style: .card).edge == .above)
    // A tall anchor filling most of the height: no room above or below.
    let tall = Anchor.rect(CGRect(x: 300, y: 150, width: 200, height: 700))
    let side = Placer.place(size: card, anchor: tall, in: screen, style: .card)
    #expect(side.edge == .trailing)
    #expect(side.frame.minX == 500 + Placer.gap)
    // The same against the right edge: leading side.
    let tallRight = Anchor.rect(CGRect(x: 1200, y: 150, width: 200, height: 700))
    #expect(Placer.place(size: card, anchor: tallRight, in: screen, style: .card).edge == .leading)
}

@Test(.overlayExclusive) func keepsTwelvePointsFromEdges() {
    let corner = Anchor.point(CGPoint(x: 1505, y: 40))
    let p = Placer.place(size: card, anchor: corner, in: screen, style: .card)
    #expect(p.frame.maxX <= screen.maxX - Placer.edgeMargin)
    #expect(p.frame.minY >= screen.minY + Placer.edgeMargin)
    // The tail stays clear of the rounded corner even when the anchor is past the edge.
    let lo = Tokens.cardRadius + Placer.tailHalfWidth
    #expect(p.tailOffset == card.width - lo)
}

@Test(.overlayExclusive) func chipsHaveNoTailAndRichIsCentred() {
    let anchor = Anchor.point(CGPoint(x: 400, y: 300))
    #expect(Placer.place(size: card, anchor: anchor, in: screen, style: .chip).tailOffset == nil)
    let rich = Placer.place(size: CGSize(width: 540, height: 400), anchor: anchor, in: screen, style: .centered)
    #expect(rich.edge == .centered)
    #expect(abs(rich.frame.midX - screen.midX) <= 1)
    #expect(abs(rich.frame.midY - screen.midY) <= 1)
}

@Test(.overlayExclusive) func oversizedSurfaceIsClampedOntoDisplay() {
    let huge = CGSize(width: 3000, height: 3000)
    let p = Placer.place(size: huge, anchor: .point(CGPoint(x: 700, y: 400)), in: screen, style: .card)
    #expect(screen.insetBy(dx: Placer.edgeMargin, dy: Placer.edgeMargin).contains(p.frame))
    #expect(!p.avoidsAnchor)
    #expect(p.tailOffset == nil)
}

@Test(.overlayExclusive) func pillSitsRightOfPointer() {
    let f = Placer.pillFrame(size: CGSize(width: 180, height: 36), pointer: CGPoint(x: 500, y: 300), in: screen)
    #expect(f.origin == CGPoint(x: 520, y: 312))
    let edge = Placer.pillFrame(size: CGSize(width: 180, height: 36), pointer: CGPoint(x: 1500, y: 940), in: screen)
    #expect(edge.maxX <= screen.maxX - Placer.edgeMargin)
    #expect(edge.maxY <= screen.maxY - Placer.edgeMargin)
}

// MARK: Levels and dots

@Test(.overlayExclusive) func envelopeRisesFastAndFallsSlowly() {
    var mic = LevelEnvelope.mic
    // 30 ms attack: one time constant reaches ~63%.
    #expect(abs(mic.step(toward: 1, dt: 0.030) - (1 - exp(-1))) < 1e-9)
    mic.step(toward: 1, dt: 1)
    // 250 ms release: after 30 ms it has barely fallen.
    #expect(mic.step(toward: 0, dt: 0.030) > 0.88)
    var speech = LevelEnvelope.speech
    speech.step(toward: 1, dt: 1)
    #expect(speech.step(toward: 0, dt: 0.120) < 0.37)
    #expect(speech.step(toward: 5, dt: 10) <= 1)
}

@Test(.overlayExclusive) func dotsLightFromTheCentreOutward() {
    #expect(DotField.brightness(column: 2, row: 1, level: 0, breath: 0.22) == 0.22)
    let centre = DotField.brightness(column: 2, row: 1, level: 0.5, breath: 0.22)
    let end = DotField.brightness(column: 0, row: 1, level: 0.5, breath: 0.22)
    let outerRow = DotField.brightness(column: 2, row: 0, level: 0.5, breath: 0.22)
    #expect(centre > end)
    #expect(centre > outerRow)
    #expect(DotField.brightness(column: 0, row: 1, level: 1, breath: 0.22) == 1)
}

// MARK: Shapes

@Test(.overlayExclusive) func cardTailSitsInItsBand() {
    let rect = CGRect(x: 0, y: 0, width: 330, height: 207)
    let shape = CardShape(cornerRadius: 20, tailSide: .top, tailOffset: 100)
    let path = shape.path(in: rect)
    // The tip reaches the top of the frame at the offset; the body starts 7 pt down.
    #expect(path.contains(CGPoint(x: 100, y: 1.5)))
    #expect(!path.contains(CGPoint(x: 60, y: 3)))
    #expect(path.contains(CGPoint(x: 165, y: 100)))
    #expect(CardShape.body(in: rect, side: .top).minY == CardShape.tailLength)
    #expect(CardShape.side(for: .below) == .top)
    #expect(CardShape.side(for: .trailing) == .left)
    #expect(CardShape.side(for: .centered) == nil)
}

// MARK: API

private func answer(_ shape: BuddyBlock.Shape = .card, turn: Int = 1, mode: Mode = .quick) -> Answer {
    Answer(block: BuddyBlock(say: "Your filter drops last week's data.", shape: shape,
                             actions: [.init(label: "Loosen filter", prompt: "p")]),
           lane: Lane(mode: mode, model: mode == .quick ? .haiku : .opus),
           conversation: .ember, turn: turn, replyHint: "tap ⌥ to reply · click to type")
}

@Test(.overlayExclusive) func headerLabels() {
    #expect(answer(turn: 1).headerLabel == "new")
    #expect(answer(turn: 3).headerLabel == "continuing · 3")
    var long = answer(turn: 12)
    long.isLong = true
    #expect(long.headerLabel == "continuing · 12 · long")
    #expect(Lane(mode: .quick, model: .haiku).label == "Quick · Haiku 5.5")
    #expect(!Lane(mode: .quick, model: .haiku).isEmphasized)
    #expect(Lane(mode: .deep, model: .opus).isEmphasized)
}

@Test(.overlayExclusive) func fakeRecordsCallsAndEscape() async {
    let fake = FakeOverlay()
    #expect(!fake.handleEscape())
    fake.showListening(at: CGPoint(x: 10, y: 10), hint: "tap ⌥ to send")
    #expect(fake.wantsEscape)
    #expect(fake.handleEscape())
    #expect(!fake.wantsEscape)
    fake.send(.action(index: 0))
    var it = fake.events.makeAsyncIterator()
    #expect(await it.next() == .wantsEscape(true))
    #expect(await it.next() == .wantsEscape(false))
    #expect(await it.next() == .dismissed(.escape))
    #expect(await it.next() == .action(index: 0))
    #expect(fake.calls.contains(.escape))
}

@Test(.overlayExclusive) func controllerEscapeContract() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    #expect(!overlay.wantsEscape)
    #expect(!overlay.handleEscape())
    overlay.showListening(at: CGPoint(x: 200, y: 200), hint: "tap ⌥ to send")
    #expect(overlay.wantsEscape)
    overlay.showThinking(Lane(mode: .quick, model: .haiku), status: "Reading the table")
    #expect(overlay.model.surface == .thinking(Lane(mode: .quick, model: .haiku), status: "Reading the table"))
    #expect(overlay.handleEscape())
    #expect(!overlay.wantsEscape)
    // A second Esc during the fold does nothing.
    #expect(!overlay.handleEscape())
    var it = overlay.events.makeAsyncIterator()
    #expect(await it.next() == .wantsEscape(true))
    #expect(await it.next() == .dismissed(.escape))
    #expect(await it.next() == .wantsEscape(false))
}

@Test(.overlayExclusive) func controllerMeasuresCardsAtFixedWidth() {
    let overlay = BuddyOverlayController(observesSystem: false)
    let sizeCard = overlay.measureForTesting(answer(.card), style: .card)
    #expect(sizeCard.width == BuddyOverlayController.cardWidth)
    #expect(sizeCard.height > 80)
    let chip = overlay.measureForTesting(answer(.chip), style: .chip)
    #expect(chip.width <= BuddyOverlayController.chipMaxWidth)
    #expect(chip.height < sizeCard.height)
    let withWeb = overlay.measureForTesting(
        Answer(block: BuddyBlock(say: "x", shape: .card, cardHTML: "<p>x</p>"), lane: Lane(mode: .quick, model: .haiku),
               conversation: .mist, turn: 2, replyHint: "r"),
        style: .card, webHeight: 120)
    #expect(withWeb.height >= 120)
}

@Test(.overlayExclusive) func cardDocumentIsLockedDown() {
    let doc = CardWebContent.document(body: "<p>hi</p>")
    #expect(doc.contains("color-scheme"))
    #expect(doc.contains("default-src 'none'"))
    #expect(doc.contains("<p>hi</p>"))
}

/// "15.6px" → 15.6. WebKit rounds lengths to 1/64 px, so compare with a small tolerance.
private func cssPixels(_ value: String) -> Double { Double(value.replacingOccurrences(of: "px", with: "")) ?? .nan }

@Test(.overlayExclusive) func cardListsAndJumpsFollowThePrototype() async throws {
    let content = CardWebContent(width: 300)
    defer { content.tearDown() }
    let html = #"<ul><li>One <a href="buddy://jump/a">jump</a></li><li>Two</li></ul><p>After</p>"#
    try #require(await content.load(html: html, timeout: .seconds(5)) != nil, "the card loaded")
    // One JSON string back, so nothing non-Sendable crosses from WebKit.
    let js = """
    JSON.stringify((() => { const ul = document.querySelector("ul"), li = document.querySelectorAll("li"),
      a = document.querySelector("a"), s = e => getComputedStyle(e);
      return [s(ul).marginTop, s(ul).paddingLeft, s(li[1]).marginTop, s(a).textDecorationLine,
              s(a).marginLeft, [...document.styleSheets[0].cssRules].find(r => r.selectorText === "li::marker")?.style.color ?? ""]; })())
    """
    let json = try #require(try await content.webView.evaluateJavaScript(js) as? String)
    let v = try JSONDecoder().decode([String].self, from: Data(json.utf8))
    #expect(v[0] == "0px", "no browser-default gap above the list")
    #expect(abs(cssPixels(v[1]) - 15.6) < 0.05, "1.2 em indent at 13 px")
    #expect(abs(cssPixels(v[2]) - 4.55) < 0.05, "0.35 em between bullets")
    #expect(v[3] == "none", "jump isn't underlined")
    #expect(v[4] != "0px", "jump sits a little after the text")
    // WebKit doesn't expose ::marker through getComputedStyle, so check the parsed rule.
    #expect(v[5] == "var(--ember)", "markers are ember")
}

// MARK: Review regressions

@Test(.overlayExclusive) func webNavigationOnlyAllowsTheInitialLoad() {
    let blank = URL(string: "about:blank")
    #expect(CardWebContent.policy(type: .other, url: blank, isMainFrame: true, initialLoadDone: false) == .allowInitialLoad)
    // A second about:blank, a meta refresh to a remote page, or a subframe: cancelled.
    #expect(CardWebContent.policy(type: .other, url: blank, isMainFrame: true, initialLoadDone: true) == .cancel)
    let remote = URL(string: "https://example.com/?leak=secret")!
    #expect(CardWebContent.policy(type: .other, url: remote, isMainFrame: true, initialLoadDone: true) == .cancel)
    #expect(CardWebContent.policy(type: .other, url: remote, isMainFrame: true, initialLoadDone: false) == .cancel)
    #expect(CardWebContent.policy(type: .formSubmitted, url: remote, isMainFrame: true, initialLoadDone: true) == .cancel)
    // A clicked web link opens in the browser; other schemes don't.
    #expect(CardWebContent.policy(type: .linkActivated, url: remote, isMainFrame: true, initialLoadDone: true) == .openExternally(remote))
    let file = URL(string: "file:///etc/passwd")!
    #expect(CardWebContent.policy(type: .linkActivated, url: file, isMainFrame: true, initialLoadDone: true) == .cancel)
}

@Test(.overlayExclusive, arguments: [
    CGRect(x: 600, y: 200, width: 120, height: 20),    // room below
    CGRect(x: 600, y: 860, width: 120, height: 20),    // above
    CGRect(x: 300, y: 150, width: 200, height: 700),   // trailing
    CGRect(x: 1200, y: 150, width: 200, height: 700),  // leading
])
func tailTipPointsAtTheAnchor(anchorRect: CGRect) {
    let p = Placer.place(size: card, anchor: .rect(anchorRect), in: screen, style: .card)
    let outer = OverlayModel.outerFrame(p, style: .card)
    let side = OverlayModel.tailSide(p, style: .card)!
    let tip: CGPoint = switch side {
    case .top: CGPoint(x: p.frame.minX + p.tailOffset!, y: outer.minY)
    case .bottom: CGPoint(x: p.frame.minX + p.tailOffset!, y: outer.maxY)
    case .left: CGPoint(x: outer.minX, y: p.frame.minY + p.tailOffset!)
    case .right: CGPoint(x: outer.maxX, y: p.frame.minY + p.tailOffset!)
    }
    // The tip sits in the 14 pt gap, on the anchor's centre line, 7 pt from the anchor.
    switch side {
    case .top, .bottom: #expect(abs(tip.x - anchorRect.midX) < 1)
    case .left, .right: #expect(abs(tip.y - anchorRect.midY) < 1)
    }
    let a = anchorRect
    let distance = switch side {
    case .top: tip.y - a.maxY
    case .bottom: a.minY - tip.y
    case .left: tip.x - a.maxX
    case .right: a.minX - tip.x
    }
    #expect(distance == Placer.gap - CardShape.tailLength)
}

@Test(.overlayExclusive) func grownPillIsPulledBackInside() {
    let model = OverlayModel()
    model.pillBounds = screen
    model.pillOrigin = CGPoint(x: screen.maxX - 200, y: 300)
    model.pillSize = CGSize(width: 180, height: 36)
    #expect(model.pillFrame.maxX <= screen.maxX - Placer.edgeMargin)
    model.pillSize = CGSize(width: 420, height: 36)  // thinking with a long status
    #expect(model.pillFrame.maxX <= screen.maxX - Placer.edgeMargin)
    #expect(model.pillFrame.minX >= screen.minX + Placer.edgeMargin)
}

@Test(.overlayExclusive) func hitFrameIncludesTheTail() {
    let p = Placer.place(size: card, anchor: .rect(CGRect(x: 600, y: 200, width: 120, height: 20)), in: screen, style: .card)
    let model = OverlayModel()
    model.surface = .answer(answer(), p, .card)
    #expect(model.hitFrames == [CGRect(x: p.frame.minX, y: p.frame.minY - CardShape.tailLength,
                                       width: p.frame.width, height: p.frame.height + CardShape.tailLength)])
}

@Test(.overlayExclusive) func dismissDuringHTMLLoadCancelsTheAnswer() async throws {
    let overlay = BuddyOverlayController(observesSystem: false)
    let html = Answer(block: BuddyBlock(say: "x", shape: .card, cardHTML: "<p>late</p>"),
                      lane: Lane(mode: .quick, model: .haiku), conversation: .ember, turn: 1, replyHint: "r")
    overlay.showAnswer(html, anchor: .point(CGPoint(x: 300, y: 300)))
    overlay.dismiss(.requested)
    try await Task.sleep(for: .milliseconds(900))
    #expect(overlay.model.surface == .none)
}

@Test(.overlayExclusive) func lastShowAnswerWins() async throws {
    let overlay = BuddyOverlayController(observesSystem: false)
    let slow = Answer(block: BuddyBlock(say: "slow", shape: .card, cardHTML: "<p>slow</p>"),
                      lane: Lane(mode: .quick, model: .haiku), conversation: .ember, turn: 1, replyHint: "r")
    let fast = answer(.chip)
    overlay.showAnswer(slow, anchor: .point(CGPoint(x: 300, y: 300)))
    overlay.showAnswer(fast, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    guard case .answer(let shown, _, _) = overlay.model.surface else {
        Issue.record("no answer shown")
        return
    }
    #expect(shown.block.say == fast.block.say)
    overlay.dismiss(.requested)
}

// MARK: Keys in a focused card

private func key(_ chars: String, code: UInt16 = 0, _ mods: NSEvent.ModifierFlags = [], reply: Bool = true,
                 actions: Int = 2) -> KeyCommand? {
    KeyCommand.map(keyCode: code, characters: chars, modifiers: mods, plainKeysActive: reply, actionCount: actions)
}

@Test(.overlayExclusive) func focusedCardKeys() {
    #expect(key("n", .command) == .event(.newConversation))
    #expect(key("N", .command) == .event(.newConversation))
    #expect(key("y", .command) == .event(.openConversations))
    #expect(key(",", .command) == .event(.openSettings))
    #expect(key("\r", code: KeyCommand.returnKeyCode, .command) == .event(.action(index: 0)))
    #expect(key("\r", code: KeyCommand.returnKeyCode, .command, actions: 0) == nil)
    #expect(key("1") == .event(.action(index: 0)))
    #expect(key("2") == .event(.action(index: 1)))
    #expect(key("3") == nil)                       // only two actions
    #expect(key("f") == .toggleFullScreen)
    #expect(key("\u{1b}", code: KeyCommand.escapeKeyCode) == .escape)
}

@Test(.overlayExclusive) func plainKeysYieldToTypingAndModifiers() {
    #expect(key("f", reply: false) == nil)
    #expect(key("1", reply: false) == nil)
    #expect(key("n") == nil)                       // plain n is typing, not ⌘N
    #expect(key("n", [.command, .shift]) == nil)
    #expect(key("f", .option) == nil)
    #expect(key("\u{1b}", code: KeyCommand.escapeKeyCode, .command) == nil)
    #expect(key("\r", code: KeyCommand.returnKeyCode) == nil)  // ↵ sends the reply (M3)
}

@Test(.overlayExclusive) func focusOnlyWhileAnAnswerIsVisible() async throws {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showListening(at: CGPoint(x: 200, y: 200), hint: "tap ⌥ to send")
    overlay.focusAnswer()  // nothing to focus while listening
    #expect(overlay.model.surface.isPill)
    overlay.dismiss(.requested)
    let fake = FakeOverlay()
    fake.focusAnswer()
    #expect(fake.calls == [.focus])
}

@Test(.overlayExclusive) func micLevelsDoNotInvalidateObservation() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showListening(at: CGPoint(x: 200, y: 200), hint: "h")
    let changed = Flag()
    withObservationTracking { _ = overlay.model.surface; _ = overlay.model.speech } onChange: { changed.set() }
    for i in 0..<10 { overlay.setMicLevel(Double(i) / 10) }
    #expect(!changed.value)
    #expect(overlay.model.mic.value > 0)
    overlay.dismiss(.requested)
}

/// Thread-safe flag for observation callbacks, which are @Sendable.
nonisolated private final class Flag: Sendable {
    private let lock = Mutex(false)
    func set() { lock.withLock { $0 = true } }
    var value: Bool { lock.withLock { $0 } }
}


// MARK: M2 placement, full screen

@Test(.overlayExclusive) func placementModes() {
    #expect(Placer.style(for: .chip, mode: .centre) == .chip)        // chips never centre
    #expect(Placer.style(for: .card, mode: .smart) == .card)
    #expect(Placer.style(for: .rich, mode: .smart) == .centered)
    #expect(Placer.style(for: .card, mode: .centre) == .centered)
    #expect(Placer.style(for: .rich, mode: .nextToIt) == .card)
}

@Test(.overlayExclusive) func fullScreenIs94By90Centred() {
    let f = Placer.fullScreenFrame(in: screen)
    #expect(f.width == (screen.width * 0.94).rounded())
    #expect(f.height == (screen.height * 0.90).rounded())
    #expect(abs(f.midX - screen.midX) <= 1 && abs(f.midY - screen.midY) <= 1)
}

/// A gray image, with black-and-white stripes ("text") inside `busy` (image px, top-left).
private func snapshotImage(width: Int, height: Int, busy: [CGRect]) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0.95, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(gray: 0.1, alpha: 1)
    for r in busy {
        // CGContext is bottom-left; flip to top-left image rows.
        var y = r.minY
        while y < r.maxY {
            ctx.fill(CGRect(x: r.minX, y: CGFloat(height) - y - 2, width: r.width, height: 2))
            y += 4
        }
    }
    return ctx.makeImage()!
}

@Test(.overlayExclusive) func edgeDensityFindsText() throws {
    let img = snapshotImage(width: 400, height: 250, busy: [CGRect(x: 0, y: 0, width: 200, height: 250)])
    let map = try EdgeMap.make(img)
    #expect(map.density(CGRect(x: 20, y: 20, width: 150, height: 200)) > 0.3)
    #expect(map.density(CGRect(x: 230, y: 20, width: 150, height: 200)) < 0.01)
}

@Test(.overlayExclusive) func smartPlacementAvoidsContentBelow() async throws {
    // Display 1600×1000 pt at scale 0.25 → 400×250 px. Text fills the band below the anchor.
    let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let anchor = CGRect(x: 700, y: 400, width: 200, height: 20)
    let busyBelow = CGRect(x: 100, y: 108, width: 300, height: 100)  // px: y 432–832 pt
    let snap = DisplaySnapshot(image: snapshotImage(width: 400, height: 250, busy: [busyBelow]),
                               displayID: 1, frame: frame, scale: 0.25)
    let scores = await SmartPlacement.scores(for: snap, withSaliency: false)
    let p = SmartPlacement.placeNextTo(size: card, anchor: .rect(anchor), in: frame, style: .card, scores: scores)
    #expect(p.edge == .above)
    // With nothing busy, the plain order wins: below.
    let clean = DisplaySnapshot(image: snapshotImage(width: 400, height: 250, busy: []), displayID: 1, frame: frame, scale: 0.25)
    let cleanScores = await SmartPlacement.scores(for: clean, withSaliency: false)
    #expect(SmartPlacement.placeNextTo(size: card, anchor: .rect(anchor), in: frame, style: .card,
                                       scores: cleanScores).edge == .below)
}

@Test(.overlayExclusive) func wholePageAnswersTakeTheEmptiestRegion() async {
    let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    // Everything busy except the top-right corner.
    let busy = [CGRect(x: 0, y: 0, width: 250, height: 250), CGRect(x: 250, y: 80, width: 150, height: 170)]
    let snap = DisplaySnapshot(image: snapshotImage(width: 400, height: 250, busy: busy), displayID: 1, frame: frame, scale: 0.25)
    let scores = await SmartPlacement.scores(for: snap, withSaliency: false)
    let p = SmartPlacement.placeOnPage(size: card, in: frame, scores: scores)
    #expect(p.tailOffset == nil)
    #expect(p.frame.maxX == frame.maxX - Placer.edgeMargin)
    #expect(p.frame.minY == frame.minY + Placer.edgeMargin)
}

@Test(.overlayExclusive) func snapshotMustMatchTheDisplayAsItIsNow() {
    let img = snapshotImage(width: 40, height: 25, busy: [])
    let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let snap = DisplaySnapshot(image: img, displayID: 1, frame: frame, scale: 0.025)
    let inside = Anchor.point(CGPoint(x: 800, y: 500))
    #expect(BuddyOverlayController.usableSnapshot(snap, for: inside, displayID: 1, displayFrame: frame) != nil)
    // Another display, a moved or resized display, or an anchor elsewhere: no scores.
    #expect(BuddyOverlayController.usableSnapshot(snap, for: inside, displayID: 2, displayFrame: frame) == nil)
    #expect(BuddyOverlayController.usableSnapshot(snap, for: inside, displayID: 1,
                                                  displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1200)) == nil)
    #expect(BuddyOverlayController.usableSnapshot(snap, for: .point(CGPoint(x: 2000, y: 300)), displayID: 1, displayFrame: frame) == nil)
    #expect(BuddyOverlayController.usableSnapshot(nil, for: inside, displayID: 1, displayFrame: frame) == nil)
}

/// Deterministic pseudo-random numbers for property tests.
private struct LCG {
    var state: UInt64
    mutating func next(_ range: ClosedRange<Double>) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return range.lowerBound + Double(state >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}

@Test(.overlayExclusive) func smartPlacementPropertiesHold() async {
    // A display left of and above the primary (negative origin), random busy bands.
    let frame = CGRect(x: -1600, y: -400, width: 1600, height: 1000)
    var rng = LCG(state: 42)
    for _ in 0..<60 {
        let busy = (0..<3).map { _ in CGRect(x: rng.next(0...300), y: rng.next(0...200), width: rng.next(40...200), height: rng.next(20...80)) }
        let snap = DisplaySnapshot(image: snapshotImage(width: 400, height: 250, busy: busy), displayID: 7, frame: frame, scale: 0.25)
        let scores = await SmartPlacement.scores(for: snap, withSaliency: false)
        let w = rng.next(2...260), h = rng.next(2...40)
        let anchor = CGRect(x: frame.minX + rng.next(20...1500), y: frame.minY + rng.next(20...950), width: w, height: h)
        let size = CGSize(width: rng.next(200...360), height: rng.next(80...300))
        let p = SmartPlacement.placeNextTo(size: size, anchor: .rect(anchor), in: frame, style: .card, scores: scores)
        let area = frame.insetBy(dx: Placer.edgeMargin, dy: Placer.edgeMargin)
        #expect(area.contains(p.frame), "12 pt from the edges")
        guard p.avoidsAnchor else { continue }
        #expect(!p.frame.intersects(anchor), "never covers the anchor")
        let gap: CGFloat = switch p.edge {
        case .below: p.frame.minY - anchor.maxY
        case .above: anchor.minY - p.frame.maxY
        case .trailing: p.frame.minX - anchor.maxX
        case .leading: anchor.minX - p.frame.maxX
        case .centered: Placer.gap
        }
        #expect(abs(gap - Placer.gap) <= 1, "14 pt from the anchor")
        // The tail points at the anchor's centre whenever the card isn't clamped at an edge.
        if let tail = p.tailOffset {
            switch p.edge {
            case .below, .above:
                let lo = Tokens.cardRadius + Placer.tailHalfWidth
                if anchor.midX - p.frame.minX >= lo, p.frame.maxX - anchor.midX >= lo {
                    #expect(abs(p.frame.minX + tail - anchor.midX) <= 1)
                }
            default:
                break
            }
        }
    }
}

@Test(.overlayExclusive) func shiftedCandidatesKeepTheTailOnACaret() async {
    // A caret (zero-width anchor) with text right below its centre: Smart may shift the
    // card sideways, but the tail must still point at the caret.
    let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let caret = CGRect(x: 800, y: 400, width: 0, height: 18)
    let busy = [CGRect(x: 150, y: 105, width: 40, height: 80)]  // pt 600–760: under the centred candidate only
    let snap = DisplaySnapshot(image: snapshotImage(width: 400, height: 250, busy: busy), displayID: 1, frame: frame, scale: 0.25)
    let scores = await SmartPlacement.scores(for: snap, withSaliency: false)
    let p = SmartPlacement.placeNextTo(size: card, anchor: .rect(caret), in: frame, style: .card, scores: scores)
    #expect(p.edge == .below)
    #expect(abs(p.frame.minX + (p.tailOffset ?? -999) - caret.midX) <= 1)
}

@Test(.overlayExclusive) func saliencyPathRuns() async {
    let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let snap = DisplaySnapshot(image: snapshotImage(width: 400, height: 250, busy: [CGRect(x: 0, y: 0, width: 200, height: 250)]),
                               displayID: 1, frame: frame, scale: 0.25)
    let scores = await SmartPlacement.scores(for: snap, withSaliency: true)
    #expect(scores.edges != nil)
    #expect(scores.saliency != nil)
    let c = SmartPlacement.cost(CGRect(x: 100, y: 100, width: 300, height: 300), scores)
    #expect(c >= 0 && c <= 1)
}

@Test(.overlayExclusive) func nextToItIgnoresContent() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.placementMode = .nextToIt
    let screenFrame = ScreenSpace.topLeft(NSScreen.screens[0].frame)
    let anchor = Anchor.rect(CGRect(x: screenFrame.midX - 60, y: screenFrame.minY + 200, width: 120, height: 20))
    let snap = DisplaySnapshot(image: snapshotImage(width: 400, height: 250, busy: [CGRect(x: 0, y: 0, width: 400, height: 250)]),
                               displayID: NSScreen.screens[0].displayID, frame: screenFrame, scale: 400 / screenFrame.width)
    overlay.showAnswer(answer(.card), anchor: anchor, snapshot: snap)
    await overlay.presentationFinished()
    #expect(overlay.model.scores == nil)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func centredAnswersTakeClicksOnlyOnTheCard() async {
    // No scrim: a click beside a centred answer goes to the app underneath (a click-away).
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(answer(.rich), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    guard case .answer(_, let p, let style) = overlay.model.surface else { Issue.record("no answer"); return }
    #expect(style == .centered)
    #expect(overlay.model.hitFrames == [OverlayModel.outerFrame(p, style: style)])
    #expect(!overlay.model.hitFrames.contains { $0.contains(CGPoint(x: p.frame.minX - 40, y: p.frame.midY)) })
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func pageAnchorsRouteByMode() {
    let page = Anchor.page(CGPoint(x: 700, y: 400))
    // Smart and Next to it: emptiest region, no tail. Centre: centred.
    let smart = BuddyOverlayController.place(size: card, anchor: page, in: screen, style: Placer.style(for: .card, mode: .smart), scores: nil)
    #expect(smart.tailOffset == nil && smart.edge == .centered)
    #expect(smart.frame.maxX == screen.maxX - Placer.edgeMargin)  // fallback: trailing middle
    let centre = BuddyOverlayController.place(size: card, anchor: page, in: screen, style: Placer.style(for: .card, mode: .centre), scores: nil)
    #expect(abs(centre.frame.midX - screen.midX) <= 1)
}

@Test(.overlayExclusive) func newAnswerLeavesFullScreen() async throws {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(answer(.card), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    overlay.toggleFullScreen()
    #expect(overlay.model.fullScreen)
    // Full screen takes clicks on its own frame only, not the whole display.
    #expect(overlay.model.hitFrames == [overlay.model.fullScreenFrame])
    #expect(overlay.model.fullScreenFrame != overlay.model.screenFrame)
    // No card_html: no web area in full screen.
    #expect(overlay.model.fullScreenWebHeight == 0)
    overlay.showAnswer(answer(.chip), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    #expect(!overlay.model.fullScreen)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func emptyCardHTMLGetsNoFullScreenWebArea() async throws {
    let overlay = BuddyOverlayController(observesSystem: false)
    let empty = Answer(block: BuddyBlock(say: "x", shape: .card, cardHTML: ""), lane: Lane(mode: .quick, model: .haiku),
                       conversation: .ember, turn: 1, replyHint: "r")
    overlay.showAnswer(empty, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    overlay.toggleFullScreen()
    #expect(overlay.model.fullScreen)
    #expect(overlay.model.fullScreenWebHeight == 0)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func answersNeverClaimTheWholeDisplay() {
    let model = OverlayModel()
    model.screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let p = Placer.place(size: card, anchor: .point(CGPoint(x: 10, y: 10)), in: screen, style: .centered)
    model.surface = .answer(answer(.rich), p, .centered)
    #expect(model.hitFrames == [OverlayModel.outerFrame(p, style: .centered)])
    model.fullScreen = true
    model.fullScreenFrame = Placer.fullScreenFrame(in: screen)
    #expect(model.hitFrames == [model.fullScreenFrame])
    #expect(!model.hitFrames.contains(model.screenFrame))
}

@Test(.overlayExclusive) func escapeLeavesFullScreenBeforeClosing() async throws {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(answer(.card), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    overlay.toggleFullScreen()
    #expect(overlay.model.fullScreen)
    #expect(overlay.handleEscape())
    #expect(!overlay.model.fullScreen)
    #expect(overlay.model.surface.isAnswer)
    #expect(overlay.handleEscape())
    #expect(!overlay.wantsEscape)
}

@Test(.overlayExclusive) func chipsHaveNoFullScreen() async throws {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(answer(.chip), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    overlay.toggleFullScreen()
    #expect(!overlay.model.fullScreen)
    overlay.dismiss(.requested)
}

// MARK: Typed input

@Test(.overlayExclusive) func textBoxOpensAtTheFixedStatusSpot() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showTextBox(at: CGPoint(x: 400, y: 300))
    #expect(overlay.model.surface == .textBox)
    let area = overlay.model.pillBounds.insetBy(dx: Placer.edgeMargin, dy: Placer.edgeMargin)
    #expect(abs(overlay.model.pillFrame.midX - area.midX) <= 1, "centred, not at the pointer")
    #expect(overlay.model.pillOrigin.y == area.minY)
    #expect(overlay.model.typed)
    overlay.focusChanged(false)
    #expect(overlay.wantsEscape)                 // not focused: the shell's tap is on
    overlay.focusChanged(true)
    #expect(!overlay.wantsEscape)                // focused text box: Esc reaches it directly
    #expect(overlay.handleEscape())              // a captured Esc still closes it
    #expect(!overlay.wantsEscape)
}

@Test(.overlayExclusive) func submitTrimsAndIgnoresEmpty() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showTextBox(at: CGPoint(x: 400, y: 300))
    overlay.model.draft = "   "
    overlay.submit(.textBox)
    overlay.model.draft = "  why is this list empty? \n"
    overlay.submit(.textBox)
    #expect(overlay.model.draft.isEmpty)
    overlay.model.reply = "and last week?"
    overlay.submit(.reply)
    #expect(overlay.model.reply.isEmpty)
    overlay.dismiss(.requested)
    var events: [OverlayEvent] = []
    for await e in overlay.events {
        events.append(e)
        if case .dismissed = e { break }
    }
    #expect(events.contains(.submitted(text: "why is this list empty?", source: .textBox)))
    #expect(events.contains(.submitted(text: "and last week?", source: .reply)))
    #expect(events.filter { if case .submitted = $0 { true } else { false } }.count == 2)
}

@Test(.overlayExclusive) func voiceQuestionClearsTypedMode() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showTextBox(at: CGPoint(x: 400, y: 300))
    #expect(overlay.model.typed)
    overlay.showListening(at: CGPoint(x: 400, y: 300), hint: "h")
    #expect(!overlay.model.typed)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func typedThinkingStaysFocusable() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showTextBox(at: CGPoint(x: 400, y: 300))
    overlay.model.draft = "q"
    overlay.submit(.textBox)
    overlay.showThinking(Lane(mode: .quick, model: .haiku), status: nil)
    #expect(overlay.focusableForTesting)
    overlay.showListening(at: CGPoint(x: 400, y: 300), hint: "h")
    overlay.showThinking(Lane(mode: .quick, model: .haiku), status: nil)
    #expect(!overlay.focusableForTesting)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func fakeRecordsTextBox() {
    let fake = FakeOverlay()
    fake.showTextBox(at: CGPoint(x: 1, y: 2))
    #expect(fake.calls == [.textBox(CGPoint(x: 1, y: 2))])
    #expect(!fake.wantsEscape)
}

// MARK: Typed input review regressions

private func keyEvent(_ chars: String, code: UInt16 = 0, _ mods: NSEvent.ModifierFlags = [], repeat: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                     characters: chars, charactersIgnoringModifiers: chars, isARepeat: `repeat`, keyCode: code)!
}

@Test(.overlayExclusive) func autorepeatNeverRunsCommands() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(answer(.card), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    #expect(!overlay.handleKey(keyEvent("f", repeat: true)))
    #expect(!overlay.model.fullScreen)
    #expect(overlay.handleKey(keyEvent("f")))
    #expect(overlay.model.fullScreen)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func textBoxHandlesOnlyEsc() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showTextBox(at: CGPoint(x: 300, y: 300))
    #expect(!overlay.handleKey(keyEvent("f")))
    #expect(!overlay.handleKey(keyEvent("n", .command)))
    #expect(overlay.handleKey(keyEvent("\u{1b}", code: KeyCommand.escapeKeyCode)))
    #expect(overlay.model.folding)
}

@Test(.overlayExclusive) func escTapIsOffWhileTheOverlayHasFocus() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showTextBox(at: CGPoint(x: 300, y: 300))
    overlay.focusChanged(true)
    #expect(!overlay.wantsEscape)
    overlay.focusChanged(false)
    #expect(overlay.wantsEscape)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func replyTextDoesNotLeakIntoTheNextQuestion() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.model.reply = "half typed"
    overlay.showListening(at: CGPoint(x: 300, y: 300), hint: "h")
    #expect(overlay.model.reply.isEmpty)
    overlay.model.reply = "again"
    overlay.showTextBox(at: CGPoint(x: 300, y: 300))
    #expect(overlay.model.reply.isEmpty)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func textBoxFromFullScreenClosesOnEsc() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(answer(.card), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    overlay.toggleFullScreen()
    overlay.showTextBox(at: CGPoint(x: 300, y: 300))
    #expect(!overlay.model.fullScreen)
    #expect(overlay.handleEscape())
    #expect(overlay.model.folding)
}

@Test(.overlayExclusive) func submitDuringFoldIsIgnored() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showTextBox(at: CGPoint(x: 300, y: 300))
    overlay.model.draft = "late"
    overlay.dismiss(.requested)
    overlay.submit(.textBox)
    var events: [OverlayEvent] = []
    for await e in overlay.events {
        events.append(e)
        if case .wantsEscape(false) = e { break }
    }
    #expect(!events.contains(.submitted(text: "late", source: .textBox)))
}

@Test(.overlayExclusive) func escStaysCapturedDuringTypedThinking() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showTextBox(at: CGPoint(x: 300, y: 300))
    overlay.model.draft = "q"
    overlay.submit(.textBox)
    overlay.showThinking(Lane(mode: .quick, model: .haiku), status: nil)
    overlay.focusChanged(true)                   // the panel kept focus while thinking
    #expect(overlay.wantsEscape)                 // nothing in the panel handles Esc: keep the tap
    #expect(overlay.handleEscape())              // and Esc cancels
    #expect(overlay.model.folding)
}

/// An offscreen window whose first responder is a text view, optionally composing.
private func editorWindow(composing: Bool) -> (NSWindow, NSTextView) {
    let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 60), styleMask: [.borderless],
                     backing: .buffered, defer: false)
    let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
    w.contentView = tv
    w.orderFrontRegardless()
    w.makeFirstResponder(tv)
    if composing { tv.setMarkedText("ｆ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    return (w, tv)
}

private func keyEvent(_ chars: String, in window: NSWindow, code: UInt16 = 0, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: window.windowNumber,
                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
}

@Test(.overlayExclusive) func editingAndCompositionBlockCommands() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(answer(.card), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    let (typing, tv) = editorWindow(composing: false)
    #expect(tv.hasMarkedText() == false)
    #expect(!overlay.handleKey(keyEvent("f", in: typing)))            // a field is being edited: F types
    #expect(!overlay.model.fullScreen)
    #expect(overlay.handleKey(keyEvent("n", in: typing, .command)))   // ⌘ shortcuts still work
    let (composing, ctv) = editorWindow(composing: true)
    #expect(ctv.hasMarkedText())
    #expect(!overlay.handleKey(keyEvent("\u{1b}", in: composing, code: KeyCommand.escapeKeyCode)))  // Esc goes to the IME
    #expect(overlay.model.surface.isAnswer)
    typing.orderOut(nil)
    composing.orderOut(nil)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func fakeMirrorsTheRealEscBehaviour() {
    let fake = FakeOverlay()
    fake.showTextBox(at: CGPoint(x: 1, y: 2))
    #expect(!fake.wantsEscape)                   // the box has focus
    #expect(fake.handleEscape())                 // but a delivered Esc closes it
}

// MARK: Research capsule

private let jobID = UUID()
private func job(_ status: CapsuleState.Status, sources: Int = 0, reconnecting: Bool = false) -> CapsuleState {
    CapsuleState(id: jobID, topic: "Quantitative tightening", status: status, sourceCount: sources,
                 steps: ["Searching the web for “QT”", "Reading example.com"], reconnecting: reconnecting)
}

@Test(.overlayExclusive) func capsuleLinesComeFromRealState() {
    #expect(job(.running(.planning)).line == "Planning")
    #expect(job(.running(.reading), sources: 14).line == "Reading · 14 sources")
    #expect(job(.running(.reading), sources: 1).line == "Reading · 1 source")
    #expect(job(.queued).line == "Queued")  // not "Planning": it hasn't started
    #expect(job(.running(.searching), sources: 3, reconnecting: true).line == "Reconnecting…")
    #expect(job(.done).line == "Report ready · open")
    #expect(job(.failed("Claude Code stopped 7 times while researching.")).line == "Research stopped")
    #expect(job(.queued).isRunning && !job(.done).isRunning)
}

@Test(.overlayExclusive) func capsuleNudgesOnceWhenAJobFinishes() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.updateCapsule([job(.running(.reading), sources: 2)])
    #expect(overlay.model.capsuleVisible)
    #expect(overlay.model.capsuleNudge == 0)
    overlay.updateCapsule([job(.done)])
    #expect(overlay.model.capsuleNudge == 1)
    overlay.updateCapsule([job(.done)])           // still done: no second nudge
    #expect(overlay.model.capsuleNudge == 1)
    overlay.updateCapsule([])
    #expect(!overlay.model.capsuleVisible)
}

@Test(.overlayExclusive) func capsuleTapPeeksWhileRunningAndOpensTheReportWhenDone() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.updateCapsule([job(.running(.reading), sources: 2)])
    overlay.capsuleTapped()
    #expect(overlay.model.peekOpen)
    overlay.updateCapsule([job(.done)])           // finishing closes the peek
    #expect(!overlay.model.peekOpen)
    overlay.capsuleTapped()
    #expect(!overlay.model.peekOpen)
    overlay.updateCapsule([])
    let id = jobID
    #expect(await awaitEvent(overlay.events) { $0 == .openReport(id) })
}

@Test(.overlayExclusive) func reportPopsOutOfTheCapsuleCentred() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.updateCapsule([job(.done)])
    overlay.showAnswer(answer(.card), anchor: .capsule)
    await overlay.presentationFinished()
    guard case .answer(_, _, let style) = overlay.model.surface else { Issue.record("no answer"); return }
    #expect(style == .centered)
    #expect(overlay.model.source == CGPoint(x: overlay.model.capsuleFrame.midX, y: overlay.model.capsuleFrame.midY))
    overlay.dismiss(.requested)
    overlay.updateCapsule([])
}

@Test(.overlayExclusive) func capsuleHitFramesStayOnItsDisplay() {
    let model = OverlayModel()
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982), other = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    model.capsuleScreenFrame = main
    model.capsuleBounds = CGRect(x: 0, y: 33, width: 1512, height: 949)
    model.capsules = [job(.running(.reading))]
    #expect(model.hitFrames(onDisplay: main) == [model.capsuleFrame])
    #expect(model.hitFrames(onDisplay: other).isEmpty)
    #expect(abs(model.capsuleFrame.minY - 39) < 0.5)              // just under the menu bar
    #expect(abs(model.capsuleFrame.midX - 756) <= 1)               // top centre
    model.peekOpen = true
    model.peekSize = CGSize(width: 300, height: 120)
    #expect(model.hitFrames(onDisplay: main).count == 2)
    #expect(model.peekFrame.minY == model.capsuleFrame.maxY + 8)
}

@Test(.overlayExclusive) func menuBarDisplayRule() {
    let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080), main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let frames = [main, left]
    // One menu bar: always the primary display.
    #expect(ScreenSpace.menuBarScreenIndex(separateSpaces: false, screenFrames: frames, frontWindowCentre: CGPoint(x: -900, y: 500)) == 0)
    // A menu bar per display: the one holding the frontmost app's window.
    #expect(ScreenSpace.menuBarScreenIndex(separateSpaces: true, screenFrames: frames, frontWindowCentre: CGPoint(x: -900, y: 500)) == 1)
    #expect(ScreenSpace.menuBarScreenIndex(separateSpaces: true, screenFrames: frames, frontWindowCentre: nil) == 0)
    #expect(ScreenSpace.menuBarScreenIndex(separateSpaces: true, screenFrames: frames, frontWindowCentre: CGPoint(x: 9999, y: 0)) == 0)
    #expect(ScreenSpace.menuBarScreenIndex(separateSpaces: true, screenFrames: [], frontWindowCentre: nil) == nil)
    let fake = FakeOverlay()
    fake.updateCapsule([job(.queued)])
    #expect(fake.calls == [.capsule([job(.queued)])])
}

@Test(.overlayExclusive) func finishedJobsShowFirstAndPlusCountsRunningOnly() {
    let model = OverlayModel()
    let running = CapsuleState(id: UUID(), topic: "B", status: .running(.reading))
    let done = CapsuleState(id: UUID(), topic: "A", status: .done)
    let queued = CapsuleState(id: UUID(), topic: "C", status: .queued)
    model.capsules = [running, done, queued]
    #expect(model.displayedCapsule?.topic == "A")   // the finished one waits for the user
    #expect(model.otherRunningJobs == 2)            // B running and C queued
    model.capsules = [running, CapsuleState(id: UUID(), topic: "D", status: .cancelled)]
    #expect(model.displayedCapsule?.topic == "B")
    #expect(model.otherRunningJobs == 0)
}

// MARK: Capsule review regressions

@Test(.overlayExclusive) func surfacesFromIdleAreActuallyOnScreen() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showListening(at: CGPoint(x: 300, y: 300), hint: "h")
    #expect(overlay.visiblePanelCountForTesting == 1)
    overlay.dismiss(.requested)
    #expect(await eventually { overlay.visiblePanelCountForTesting == 0 })
    overlay.showThinking(Lane(mode: .quick, model: .haiku), status: nil)  // no pill first
    #expect(overlay.visiblePanelCountForTesting == 1)
    overlay.dismiss(.requested)
    #expect(await eventually { overlay.visiblePanelCountForTesting == 0 })
    overlay.showAnswer(answer(.card), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    #expect(overlay.visiblePanelCountForTesting == 1)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func peekStaysOnItsJobWhenANewOneStarts() {
    let overlay = BuddyOverlayController(observesSystem: false)
    let a = CapsuleState(id: UUID(), topic: "A", status: .running(.reading), steps: ["Reading a.com"])
    let b = CapsuleState(id: UUID(), topic: "B", status: .running(.planning))
    overlay.updateCapsule([a])
    overlay.capsuleTapped()
    #expect(overlay.model.peekJob?.topic == "A")
    overlay.updateCapsule([b, a])                      // B started and is now first
    #expect(overlay.model.peekOpen)
    #expect(overlay.model.peekJob?.topic == "A")
    var doneA = a
    doneA.status = .done
    overlay.updateCapsule([b, doneA])                  // A finished: its peek closes
    #expect(!overlay.model.peekOpen)
    overlay.updateCapsule([])
}

@Test(.overlayExclusive) func peekMonitorIsRemovedWhenTheCapsuleHides() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.updateCapsule([CapsuleState(id: UUID(), topic: "A", status: .running(.reading))])
    overlay.capsuleTapped()
    #expect(overlay.peekMonitorCountForTesting == 1)
    overlay.showListening(at: CGPoint(x: 300, y: 300), hint: "h")  // something else stays up
    overlay.updateCapsule([])
    #expect(overlay.peekMonitorCountForTesting == 0)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func capsuleReportWithoutACapsulePopsFromTheTopCentre() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(answer(.card), anchor: .capsule)
    await overlay.presentationFinished()
    let visible = ScreenSpace.topLeft((ScreenSpace.menuBarScreen ?? NSScreen.screens[0]).visibleFrame)
    #expect(abs(overlay.model.source.x - visible.midX) <= 1)
    #expect(abs(overlay.model.source.y - (visible.minY + 19)) <= 1)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func peekStaysClickableWhileAnAnswerFolds() {
    let model = OverlayModel()
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    model.capsuleScreenFrame = display
    model.capsuleBounds = CGRect(x: 0, y: 33, width: 1512, height: 949)
    model.capsules = [CapsuleState(id: UUID(), topic: "A", status: .running(.reading))]
    model.peekOpen = true
    model.peekSize = CGSize(width: 300, height: 100)
    #expect(model.capsuleHitFrames(onDisplay: display) == [model.capsuleFrame, model.peekFrame])
    #expect(model.capsuleHitFrames(onDisplay: CGRect(x: 1512, y: 0, width: 100, height: 100)).isEmpty)
}

/// Waits for the first event matching `match`, giving up after `timeout`.
private func awaitEvent(_ events: AsyncStream<OverlayEvent>, timeout: Duration = .seconds(10),
                        _ match: @escaping @Sendable (OverlayEvent) -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { for await e in events where match(e) { return true }; return false }
        group.addTask { try? await Task.sleep(for: timeout); return false }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

// MARK: Rings

@Test(.overlayExclusive) func jumpLinksBecomeJumpEvents() {
    let jump = URL(string: "buddy://jump/2")!
    #expect(CardWebContent.policy(type: .linkActivated, url: jump, isMainFrame: true, initialLoadDone: true) == .jump("2"))
    let spaced = URL(string: "buddy://jump/clause%204")!
    #expect(CardWebContent.policy(type: .linkActivated, url: spaced, isMainFrame: true, initialLoadDone: true) == .jump("clause 4"))
    #expect(CardWebContent.policy(type: .linkActivated, url: URL(string: "buddy://jump/")!, isMainFrame: true, initialLoadDone: true) == .cancel)
    // Only clicks: a meta refresh to buddy:// does nothing.
    #expect(CardWebContent.policy(type: .other, url: jump, isMainFrame: true, initialLoadDone: true) == .cancel)
}

@Test(.overlayExclusive) func ringsAppearAndExpire() async throws {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.ringDuration = .milliseconds(100)
    let screen = ScreenSpace.topLeft(NSScreen.screens[0].frame)
    overlay.showRings([Ring(rect: CGRect(x: screen.minX + 200, y: screen.minY + 200, width: 120, height: 18), label: "1"),
                       Ring(rect: CGRect(x: screen.minX + 400, y: screen.minY + 300, width: 0, height: 18))])  // caret
    #expect(overlay.model.rings.count == 2)
    #expect(overlay.model.shows(onDisplay: screen))
    #expect(overlay.model.hitFrames(onDisplay: screen).isEmpty)  // rings never take clicks
    #expect(await eventually { overlay.model.rings.isEmpty })
    overlay.showRings([])  // nothing found: nothing shown
    #expect(overlay.model.rings.isEmpty)
}

@Test(.overlayExclusive) func fakeRecordsRings() {
    let fake = FakeOverlay()
    fake.showRings([Ring(rect: CGRect(x: 1, y: 2, width: 3, height: 4), label: "1")])
    #expect(fake.calls == [.rings([Ring(rect: CGRect(x: 1, y: 2, width: 3, height: 4), label: "1")])])
}

/// Polls a condition on the main actor until it holds or `timeout` passes.
private func eventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Test(.overlayExclusive) func ringsAloneNeverBlockClicks() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.ringDuration = .seconds(10)
    let screen = ScreenSpace.topLeft(NSScreen.screens[0].frame)
    overlay.showAnswer(answer(.card), anchor: .point(CGPoint(x: screen.midX, y: screen.midY)))
    await overlay.presentationFinished()
    overlay.showRings([Ring(rect: CGRect(x: screen.minX + 100, y: screen.minY + 100, width: 80, height: 18))])
    overlay.dismiss(.closeButton)                          // the card closes; only the ring remains
    #expect(await eventually { overlay.model.surface == .none })
    #expect(overlay.visiblePanelCountForTesting == 1)      // the ring's panel stays up
    #expect(overlay.allVisiblePanelsClickThroughForTesting) // but takes no clicks
}

// MARK: Effects and edge strengthening

@Test(.overlayExclusive) func brightnessGateHasHysteresisAndDwell() {
    var gate = BrightnessGate()
    let t0 = ContinuousClock.now
    func step(_ lum: Double, _ ms: Int) -> Bool { gate.update(luminance: lum, at: t0 + .milliseconds(ms)) }
    var r = step(0.65, 0); #expect(!r)
    r = step(0.75, 0); #expect(r)            // rises at once above 0.70
    r = step(0.60, 10); #expect(r)           // stays between 0.55 and 0.70
    r = step(0.40, 20); #expect(r)           // below 0.55: dwell starts
    r = step(0.40, 200); #expect(r)          // still within 300 ms
    r = step(0.62, 250); #expect(r)          // back up: dwell resets
    r = step(0.40, 300); #expect(r)
    r = step(0.40, 620); #expect(!r)         // 320 ms below: falls
}

/// A gray snapshot: `outside` everywhere, `inside` within `rect` (image px, top-left).
private func lumImage(width: Int, height: Int, outside: CGFloat, inside: CGFloat, rect: CGRect) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: outside, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(gray: inside, alpha: 1)
    ctx.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
    return ctx.makeImage()!
}

@Test(.overlayExclusive) func ringLuminanceIgnoresTheSurfaceItself() throws {
    let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let card = CGRect(x: 600, y: 400, width: 300, height: 200)  // pt → px at 0.25: 150,100 75×50
    let bright = DisplaySnapshot(image: lumImage(width: 400, height: 250, outside: 1, inside: 0,
                                                 rect: CGRect(x: 150, y: 100, width: 75, height: 50)),
                                 displayID: 1, frame: frame, scale: 0.25)
    let map = try LuminanceMap.make(bright.image)
    #expect(try #require(map.ringLuminance(around: card, snapshot: bright)) > 0.95)
    let dark = DisplaySnapshot(image: lumImage(width: 400, height: 250, outside: 0.1, inside: 1,
                                               rect: CGRect(x: 150, y: 100, width: 75, height: 50)),
                               displayID: 1, frame: frame, scale: 0.25)
    #expect(try #require(try LuminanceMap.make(dark.image).ringLuminance(around: card, snapshot: dark)) < 0.05)
}

@Test(.overlayExclusive) func inkInTimingMatchesTheDesign() {
    #expect(InkRenderer.progress(word: 0, elapsed: 0) == 0)
    #expect(InkRenderer.progress(word: 0, elapsed: 0.55) == 1)
    #expect(InkRenderer.progress(word: 10, elapsed: 0.34) == 0)            // word 10 starts at 340 ms
    #expect(abs(InkRenderer.progress(word: 10, elapsed: 0.34 + 0.275) - 0.5) < 1e-9)
}

@Test(.overlayExclusive) func levelBarsMoveMostInTheMiddle() {
    #expect(LevelBars.height(bar: 2, level: 0) == 0.2)
    #expect(LevelBars.height(bar: 2, level: 0.6) > LevelBars.height(bar: 0, level: 0.6))
    #expect(LevelBars.height(bar: 3, level: 1) <= 1)
}

@Test(.overlayExclusive) func settingsDrivePlacementMode() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.settings = OverlaySettings(glow: false, dotField: false, inkIn: false, placement: .centre)
    #expect(overlay.placementMode == .centre)
    overlay.placementMode = .nextToIt
    #expect(overlay.settings.placement == .nextToIt)
    #expect(!overlay.model.settings.glow && !overlay.model.settings.dotField)
    let fake = FakeOverlay()
    fake.placementMode = .centre
    #expect(fake.settings.placement == .centre)
}

@Test(.overlayExclusive) func brightBackdropStrengthensEdges() async {
    guard !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else { return }
    let overlay = BuddyOverlayController(observesSystem: false)
    let screenFrame = ScreenSpace.topLeft(NSScreen.screens[0].frame)
    overlay.showAnswer(answer(.card), anchor: .point(CGPoint(x: screenFrame.midX, y: screenFrame.midY)))
    await overlay.presentationFinished()
    let white = DisplaySnapshot(image: lumImage(width: 400, height: 260, outside: 1, inside: 1, rect: .zero),
                                displayID: NSScreen.screens[0].displayID, frame: screenFrame, scale: 400 / screenFrame.width)
    overlay.updateBackdrop(white)
    #expect(overlay.model.brightBackdrop)
    overlay.dismiss(.requested)
}

// MARK: Effects review regressions

@Test(.overlayExclusive) func eachAnswerDecidesBrightnessAfresh() async {
    guard !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else { return }
    let overlay = BuddyOverlayController(observesSystem: false)
    let screenFrame = ScreenSpace.topLeft(NSScreen.screens[0].frame)
    let id = NSScreen.screens[0].displayID, scale = 400 / screenFrame.width
    let white = DisplaySnapshot(image: lumImage(width: 400, height: 260, outside: 1, inside: 1, rect: .zero),
                                displayID: id, frame: screenFrame, scale: scale)
    let black = DisplaySnapshot(image: lumImage(width: 400, height: 260, outside: 0, inside: 0, rect: .zero),
                                displayID: id, frame: screenFrame, scale: scale)
    let centre = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
    overlay.showAnswer(answer(.card), anchor: .point(centre), snapshot: white)
    await overlay.presentationFinished()
    #expect(overlay.model.brightBackdrop)
    overlay.showAnswer(answer(.card), anchor: .point(centre), snapshot: black)   // follow-up, no fold
    await overlay.presentationFinished()
    #expect(!overlay.model.brightBackdrop)       // not stuck bright from the last answer
    overlay.showAnswer(answer(.rich), anchor: .point(centre), snapshot: white)   // centred, no scrim
    await overlay.presentationFinished()
    #expect(overlay.model.brightBackdrop)        // sits on the real backdrop, so it's sampled too
    overlay.showListening(at: centre, hint: "h")
    // The bright card folds into the pill first; the pill then starts fresh.
    #expect(await eventually {
        if case .listening = overlay.model.surface { !overlay.model.folding } else { false }
    })
    #expect(!overlay.model.brightBackdrop)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func inkInDurationCoversEveryWord() {
    #expect(InkText.duration(wordCount: 1) == InkRenderer.wordDuration)
    #expect(abs(InkText.duration(wordCount: 10) - (9 * 0.034 + 0.55)) < 1e-9)
}

// MARK: Ink details and toggles

@Test(.overlayExclusive) func inkTrackingClosesAsWordsSharpen() {
    #expect(InkRenderer.trackingOffset(glyph: 0, progress: 0, em: 19) == 0)
    #expect(abs(InkRenderer.trackingOffset(glyph: 5, progress: 0, em: 19) - 5 * 0.06 * 19) < 1e-9)  // +0.06 em per glyph
    #expect(InkRenderer.trackingOffset(glyph: 5, progress: 1, em: 19) == 0)
    #expect(InkRenderer.caretOn(elapsed: 0.1) && !InkRenderer.caretOn(elapsed: 0.6) && InkRenderer.caretOn(elapsed: 1.1))
}

@Test(.overlayExclusive) func togglesThatAreOffDoNoWork() {
    // Ink-in: off, measuring or Reduce Motion means plain text (no timeline).
    #expect(AnswerContent.inksIn(setting: true, sizing: false, reduceMotion: false))
    #expect(!AnswerContent.inksIn(setting: false, sizing: false, reduceMotion: false))
    #expect(!AnswerContent.inksIn(setting: true, sizing: true, reduceMotion: false))
    #expect(!AnswerContent.inksIn(setting: true, sizing: false, reduceMotion: true))
    // Glow: off means level 0, so no stroke or shadow is drawn.
    #expect(OverlayRootView.glowLevel(speaking: true, glow: false, speech: 0.8) == 0)
    #expect(OverlayRootView.glowLevel(speaking: true, glow: true, speech: 0.8) == 0.8)
    #expect(OverlayRootView.glowLevel(speaking: false, glow: true, speech: 0.8) == 0)
}
// MARK: Toasts, conversation chips, fold into listening

@Test(.overlayExclusive) func toastsAppearNearThePointerAndExpire() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.toastDuration = .milliseconds(100)
    let screen = ScreenSpace.topLeft(NSScreen.screens[0].visibleFrame)
    let pointer = CGPoint(x: screen.midX, y: screen.midY)
    overlay.showToast("Discarded", at: pointer)
    #expect(overlay.model.toast?.text == "Discarded")
    #expect(overlay.model.toast?.origin == CGPoint(x: pointer.x + 18, y: pointer.y - 30))
    #expect(await eventually { overlay.model.toast == nil })
}

@Test(.overlayExclusive) func backChipTimesOutAndHidesWhenClicked() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.backChipDuration = .milliseconds(150)
    let screen = ScreenSpace.topLeft(NSScreen.screens[0].visibleFrame)
    let pointer = CGPoint(x: screen.midX, y: screen.midY)
    overlay.showBackChip(title: "The empty list", at: pointer)
    #expect(overlay.model.conversationChip?.label == "↩ Back to ‘The empty list’")
    #expect(overlay.model.conversationChip?.origin == CGPoint(x: pointer.x + 18, y: pointer.y + 8))
    let display = ScreenSpace.topLeft(NSScreen.screens[0].frame)
    #expect(overlay.model.hitFrames(onDisplay: display).count == 1)   // the chip takes clicks
    #expect(await eventually { overlay.model.conversationChip == nil })
    overlay.backChipDuration = .seconds(30)
    overlay.showBackChip(title: "x", at: pointer)
    overlay.chipClickedForTesting(.backToPrevious)
    #expect(overlay.model.conversationChip == nil)
}

@Test(.overlayExclusive) func resumeChipStaysUntilTheNextSummon() async throws {
    let overlay = BuddyOverlayController(observesSystem: false)
    let pointer = CGPoint(x: 400, y: 400)
    overlay.showResumeChip(title: "QT research", detail: nil, at: pointer)
    #expect(overlay.model.conversationChip?.label == "Resume ‘QT research’")
    try await Task.sleep(for: .milliseconds(300))
    #expect(overlay.model.conversationChip != nil)
    overlay.showListening(at: pointer, hint: "h")
    #expect(overlay.model.conversationChip == nil)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func listeningFoldsAnOpenCardFirst() async {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(answer(.card), anchor: .point(CGPoint(x: 400, y: 400)))
    await overlay.presentationFinished()
    overlay.showListening(at: CGPoint(x: 400, y: 400), hint: "h")
    #expect(overlay.model.folding)                       // the card folds away first
    #expect(overlay.model.surface.isAnswer)
    #expect(await eventually {
        if case .listening = overlay.model.surface { !overlay.model.folding } else { false }
    })
    #expect(overlay.model.web == nil)
    overlay.dismiss(.requested)
    // The first dismissal is this one: the fold into listening wasn't a dismissal.
    #expect(await awaitEvent(overlay.events) { if case .dismissed(let r) = $0 { r == .requested } else { false } })
}

@Test(.overlayExclusive) func fakeRecordsToastsAndChips() {
    let fake = FakeOverlay()
    fake.showToast("Cancelled", at: .zero)
    fake.showBackChip(title: "a", at: .zero)
    fake.showResumeChip(title: "b", detail: nil, at: .zero)
    fake.hideConversationChip()
    #expect(fake.calls == [.toast("Cancelled"), .backChip("a"), .resumeChip("b"), .hideChip])
}

// MARK: Toasts review regressions

@Test(.overlayExclusive) func escDuringTheListeningFoldDiscards() async {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(answer(.card), anchor: .point(CGPoint(x: 400, y: 400)))
    await overlay.presentationFinished()
    overlay.showListening(at: CGPoint(x: 400, y: 400), hint: "h")
    #expect(overlay.wantsEscape)                          // Esc is still captured during the fold
    #expect(overlay.handleEscape())
    #expect(await eventually { overlay.model.surface == .none })  // listening never started
}

@Test(.overlayExclusive) func dismissHidesTheResumeChip() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(answer(.card), anchor: .point(CGPoint(x: 400, y: 400)))
    await overlay.presentationFinished()
    overlay.showResumeChip(title: "QT", detail: nil, at: CGPoint(x: 400, y: 500))
    overlay.dismiss(.escape)
    #expect(overlay.model.conversationChip == nil)
    #expect(await eventually { overlay.visiblePanelCountForTesting == 0 })
}

@Test(.overlayExclusive) func chipNearTheRightEdgeIsPulledBackInside() {
    let model = OverlayModel()
    let bounds = CGRect(x: 0, y: 33, width: 1512, height: 949)
    model.conversationChipBounds = bounds
    model.conversationChip = OverlayModel.ConversationChip(kind: .back, title: "x", origin: CGPoint(x: 1400, y: 500))
    model.conversationChipSize = CGSize(width: 340, height: 32)
    #expect((model.conversationChipFrame?.maxX ?? .infinity) <= bounds.maxX - Placer.edgeMargin)
}
// MARK: Listening hint

@Test(.overlayExclusive) func listeningHintUpdatesInPlace() async throws {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showListening(at: CGPoint(x: 300, y: 300), hint: "tap ⌥ to send")
    #expect(!overlay.model.showsListeningHint)  // "Listening" first
    overlay.updateListeningHint("release to send")
    #expect(overlay.model.surface == .listening(hint: "release to send"))
    #expect(!overlay.model.showsListeningHint)  // still within the first 2 s
    overlay.updateListeningHint("x")
    overlay.showThinking(Lane(mode: .quick, model: .haiku), status: nil)
    overlay.updateListeningHint("ignored")      // not listening: no effect
    #expect(overlay.model.surface == .thinking(Lane(mode: .quick, model: .haiku), status: nil))
    overlay.dismiss(.requested)
    let fake = FakeOverlay()
    fake.updateListeningHint("release to send")
    #expect(fake.calls == [.hint("release to send")])
}

@Test(.overlayExclusive) func hintAppearsAfterItsDelay() async throws {
    #expect(BuddyOverlayController(observesSystem: false).listeningHintDelay == .seconds(2), "Listening for 2 s")
    let slow = BuddyOverlayController(observesSystem: false)
    slow.listeningHintDelay = .seconds(60)
    slow.showListening(at: CGPoint(x: 300, y: 300), hint: "tap ⌥ to send")
    try await Task.sleep(for: .milliseconds(200))
    #expect(!slow.model.showsListeningHint)           // still "Listening" before the delay
    slow.dismiss(.requested)
    let fast = BuddyOverlayController(observesSystem: false)
    fast.listeningHintDelay = .milliseconds(20)
    fast.showListening(at: CGPoint(x: 300, y: 300), hint: "tap ⌥ to send")
    #expect(await eventually { fast.model.showsListeningHint })
    fast.dismiss(.requested)
}

@Test(.overlayExclusive) func cardTablesAndCodeFollowThePrototype() async throws {
    let content = CardWebContent(width: 300)
    defer { content.tearDown() }
    let html = #"<div><table><tr><th>Plan</th></tr><tr><td>A</td></tr></table><pre>x = 1</pre><p>After</p><div id="g" style="display:grid;grid-template-columns:1fr 1fr"><div>before</div><div id="after">after</div></div><figure>f</figure></div>"#
    try #require(await content.load(html: html, timeout: .seconds(5)) != nil, "the card loaded")
    let js = """
    JSON.stringify((() => { const s = e => getComputedStyle(document.querySelector(e));
      return [s("th").textAlign, s("th").fontWeight, s("td").borderBottomStyle, s("pre").backgroundColor,
              s("pre").borderRadius, s("pre").marginTop, s("p").marginTop, s("table").marginTop,
              s("#after").marginTop, s("figure").marginLeft, s("body").fontSize, s("pre").fontSize]; })())
    """
    let json = try #require(try await content.webView.evaluateJavaScript(js) as? String)
    let v = try JSONDecoder().decode([String].self, from: Data(json.utf8))
    #expect(v[0] == "left", "header cells aren't centred")
    #expect(v[1] == "500")
    #expect(v[2] == "solid", "rows have a hairline rule")
    #expect(v[3] != "rgba(0, 0, 0, 0)", "code sits on a panel")
    #expect(v[4] == "9px")
    #expect(abs(cssPixels(v[5]) - 7.15) < 0.05 && abs(cssPixels(v[6]) - 7.15) < 0.05, "a .55 em gap between blocks")
    #expect(v[7] == "0px", "none above the first block")
    #expect(v[8] == "0px", "grid columns stay level: no gap inside a grid")
    #expect(v[9] == "0px", "no browser indent on figures")
    #expect(v[10] == "13px" && v[11] == "12px", "macOS sizes: 13 pt body, 12 pt code")
}

@Test func answerTypeFollowsTheMacScale() {
    // Headline 15, chip line 14, body 13, buttons 12, labels 11.
    let sizes: [(Font, CGFloat)] = [(Typeface.headline, 15), (Typeface.chipHeadline, 14), (Typeface.detail, 13),
                                    (Typeface.button, 12), (Typeface.label, 11), (Typeface.labelStrong, 11)]
    for (font, size) in sizes {
        let measured = NSHostingView(rootView: Text("Hg").font(font).fixedSize()).fittingSize.height
        let reference = NSHostingView(rootView: Text("Hg").font(.system(size: size)).fixedSize()).fittingSize.height
        #expect(abs(measured - reference) < 0.5, "\(font) should be \(size) pt")
    }
}

@Test func fullScreenWebAreaFitsItsContentUpToTheSpaceLeft() {
    #expect(BuddyOverlayController.fullScreenWebHeight(available: 700, content: 240) == 240, "no hole above the actions")
    #expect(BuddyOverlayController.fullScreenWebHeight(available: 700, content: 2_000) == 700, "taller content scrolls")
    #expect(BuddyOverlayController.fullScreenWebHeight(available: 700, content: 20) == 80)
}

@Test(.overlayExclusive) func fullScreenWebAreaFollowsReportedContentAndTheCardComesBack() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    let block = BuddyBlock(say: "Short.", shape: .rich, cardHTML: "<p>One short line.</p>")
    overlay.showAnswer(Answer(block: block, lane: Lane(mode: .quick, model: .haiku), conversation: .ember, turn: 1, replyHint: "r"),
                       anchor: .point(CGPoint(x: 400, y: 400)))
    await overlay.presentationFinished()
    // The card's own report, however late it comes under load: one short line.
    #expect(await eventually { (overlay.model.web?.contentHeight ?? 0) > 0 && overlay.model.webHeight > 0 })
    #expect((overlay.model.web?.contentHeight ?? .infinity) < 200)
    let cardWeb = overlay.model.webHeight
    overlay.toggleFullScreen()
    #expect(overlay.model.fullScreen)
    #expect(overlay.model.fullScreenWebHeight < 200, "a short card doesn't stretch to the full height")
    overlay.model.web?.onHeightChange?(300)             // reflowed at the full width
    #expect(overlay.model.fullScreenWebHeight == 300)
    #expect(overlay.model.webHeight == cardWeb, "full-width reports don't change the card")
    overlay.toggleFullScreen()
    #expect(!overlay.model.fullScreen)
    overlay.dismiss(.requested)
}

@Test func cardWebHostNeverSizesTheWebViewToNothing() {
    let web = CardWebContent(width: 300)
    let host = CardWebHost()
    host.adopt(web.webView)
    #expect(web.webView.frame.width == 300, "a zero-sized host would reflow the card one word per line")
    host.setFrameSize(NSSize(width: 420, height: 120))
    #expect(web.webView.frame == host.bounds)
    host.setFrameSize(.zero)
    #expect(web.webView.frame.width == 420, "collapsing the host keeps the last real size")
    let other = CardWebHost(frame: NSRect(x: 0, y: 0, width: 500, height: 90))
    other.adopt(web.webView)
    #expect(web.webView.superview === other && web.webView.frame == other.bounds)
    web.tearDown()
}

// MARK: Recall

private func recallable(_ say: String, shape: BuddyBlock.Shape = .card) -> Answer {
    Answer(block: BuddyBlock(say: say, shape: shape), lane: Lane(mode: .quick, model: .haiku),
           conversation: .ember, turn: 2, replyHint: "r")
}

private func shownFrame(_ overlay: BuddyOverlayController) -> CGRect? {
    if case .answer(_, let p, _) = overlay.model.surface { p.frame } else { nil }
}

@Test(.overlayExclusive) func recallBringsAClosedAnswerBackWhereItWas() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    let card = recallable("The loop reads one past the end.")
    overlay.showAnswer(card, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    guard let before = shownFrame(overlay) else { Issue.record("no answer"); return }
    overlay.dismiss(.clickAway)
    #expect(await eventually { overlay.model.surface == .none })
    // Recalled from somewhere else entirely (e.g. the menu bar): it still returns to its spot.
    overlay.recallAnswer(card, anchor: .point(CGPoint(x: 900, y: 600)))
    await overlay.presentationFinished()
    #expect(shownFrame(overlay)?.origin == before.origin)
    #expect(overlay.model.headlineAlreadyShown)  // read once already: no ink-in
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func recallSurvivesAChipShownInBetween() async {
    // A setup or Fix chip may replace the answer before it's recalled.
    let overlay = BuddyOverlayController(observesSystem: false)
    let card = recallable("Three things changed since Monday.")
    overlay.showAnswer(card, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    guard let before = shownFrame(overlay) else { Issue.record("no answer"); return }
    overlay.showAnswer(recallable("Fix", shape: .chip), anchor: .point(CGPoint(x: 900, y: 600)))
    await overlay.presentationFinished()
    overlay.dismiss(.requested)
    #expect(await eventually { overlay.model.surface == .none })
    overlay.recallAnswer(card, anchor: .point(CGPoint(x: 900, y: 600)))
    await overlay.presentationFinished()
    #expect(shownFrame(overlay)?.origin == before.origin)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func recallingAnUnknownAnswerPlacesItLikeANewOne() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    let anchor = Anchor.point(CGPoint(x: 500, y: 400))
    overlay.showAnswer(recallable("Fresh answer."), anchor: anchor)
    await overlay.presentationFinished()
    let fresh = shownFrame(overlay)
    overlay.dismiss(.requested)
    #expect(await eventually { overlay.model.surface == .none })
    overlay.recallAnswer(recallable("Never shown here."), anchor: anchor)
    await overlay.presentationFinished()
    #expect(shownFrame(overlay)?.origin == fresh?.origin)  // same anchor, same rules
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func recallRightAfterClosingStillFindsItsSpot() async {
    // Recalled while the card is still folding away (within 200 ms of Esc).
    let overlay = BuddyOverlayController(observesSystem: false)
    let card = recallable("Recalled mid-fold.")
    overlay.showAnswer(card, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    guard let before = shownFrame(overlay) else { Issue.record("no answer"); return }
    overlay.dismiss(.escape)
    overlay.recallAnswer(card, anchor: .point(CGPoint(x: 900, y: 600)))
    await overlay.presentationFinished()
    #expect(shownFrame(overlay)?.origin == before.origin)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func aCardFoldedByTheBuddyKeyCanBeRecalledToItsSpot() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    let card = recallable("Folded into listening.")
    overlay.showAnswer(card, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    guard let before = shownFrame(overlay) else { Issue.record("no answer"); return }
    overlay.showListening(at: CGPoint(x: 300, y: 300), hint: "h")
    #expect(await eventually { if case .listening = overlay.model.surface { true } else { false } })
    overlay.dismiss(.escape)  // the listen is discarded
    #expect(await eventually { overlay.model.surface == .none })
    overlay.recallAnswer(card, anchor: .point(CGPoint(x: 900, y: 600)))
    await overlay.presentationFinished()
    #expect(shownFrame(overlay)?.origin == before.origin)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func aRecalledSpotNeverCarriesOverToTheNextAnswer() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    let next = recallable("The next question's answer.")
    let there = Anchor.point(CGPoint(x: 900, y: 600))
    overlay.showAnswer(next, anchor: there)
    await overlay.presentationFinished()
    let usual = shownFrame(overlay)
    let card = recallable("Recalled first.")
    overlay.showAnswer(card, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    overlay.dismiss(.clickAway)
    overlay.recallAnswer(card, anchor: there)
    await overlay.presentationFinished()
    overlay.showAnswer(next, anchor: there)  // an ordinary answer, placed by the usual rules
    await overlay.presentationFinished()
    #expect(shownFrame(overlay)?.origin == usual?.origin)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func fakeRecordsRecall() {
    let fake = FakeOverlay()
    let card = recallable("x")
    fake.recallAnswer(card, anchor: .point(.zero))
    #expect(fake.calls == [.recall(card, .point(.zero))])
}

@Test(.overlayExclusive) func systemChipsDontPushARecallableAnswerOut() async {
    // More app chips than the overlay remembers spots for, shown between an answer and its recall.
    let overlay = BuddyOverlayController(observesSystem: false)
    let card = recallable("Kept through the chips.")
    overlay.showAnswer(card, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    guard let before = shownFrame(overlay) else { Issue.record("no answer"); return }
    for i in 0...BuddyOverlayController.recentPlacementLimit {
        var chip = recallable("Setup step \(i)", shape: .chip)
        chip.keepsPlacement = false
        overlay.showAnswer(chip, anchor: .point(CGPoint(x: 900, y: 600)))
        await overlay.presentationFinished()
    }
    overlay.dismiss(.requested)
    #expect(await eventually { overlay.model.surface == .none })
    overlay.recallAnswer(card, anchor: .point(CGPoint(x: 900, y: 600)))
    await overlay.presentationFinished()
    #expect(shownFrame(overlay)?.origin == before.origin)
    overlay.dismiss(.requested)
}

@Test func fakeKeepsTheFoldTarget() {
    let fake = FakeOverlay()
    #expect(fake.foldTarget == nil)
    fake.foldTarget = { CGRect(x: 1, y: 2, width: 3, height: 4) }
    #expect(fake.foldTarget?() == CGRect(x: 1, y: 2, width: 3, height: 4))
}

// MARK: Tuck into the menu-bar orb

/// A status item near the right end of the main display's menu bar, in AppKit coordinates.
@MainActor private func orbFrame() -> CGRect {
    let s = NSScreen.screens[0].frame
    return CGRect(x: s.maxX - 220, y: s.maxY - 24, width: 24, height: 24)
}
@MainActor private func orbCentre() -> CGPoint {
    let r = ScreenSpace.topLeft(orbFrame())
    return CGPoint(x: r.midX, y: r.midY)
}

@Test(.overlayExclusive) func aClickAwayTucksTheAnswerIntoTheOrb() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.foldTarget = { orbFrame() }
    var caught = 0
    overlay.onFoldedIntoTarget = { caught += 1 }
    overlay.showAnswer(recallable("Tucked into the orb."), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    overlay.dismiss(.clickAway)
    #expect(overlay.model.folding)
    #expect(overlay.model.source == orbCentre())                 // folds toward the orb
    #expect(overlay.model.foldScale == Motion.tuckScale)
    #expect(await eventually { overlay.model.surface == .none })
    #expect(caught == 1, "the orb is told once, after the fold")
}

@Test(.overlayExclusive) func onlyRealAnswersClosedByTheUserTuck() async {
    for (answer, reason, orb) in [(recallable("Replaced by the app."), DismissReason.requested, true),
                                   (recallable("No menu-bar item visible."), .escape, false)] {
        let overlay = BuddyOverlayController(observesSystem: false)
        overlay.foldTarget = { orb ? orbFrame() : nil }
        var caught = 0
        overlay.onFoldedIntoTarget = { caught += 1 }
        overlay.showAnswer(answer, anchor: .point(CGPoint(x: 300, y: 300)))
        await overlay.presentationFinished()
        overlay.dismiss(reason)
        #expect(overlay.model.foldScale == Motion.foldScale, "\(reason): the usual fold")
        #expect(await eventually { overlay.model.surface == .none })
        #expect(caught == 0)
    }
    // An app chip (setup, Fix) is never recalled, so it never tucks.
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.foldTarget = { orbFrame() }
    var chip = recallable("Accessibility is off.", shape: .chip)
    chip.keepsPlacement = false
    overlay.showAnswer(chip, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    overlay.dismiss(.clickAway)
    #expect(overlay.model.foldScale == Motion.foldScale)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func aRecalledAnswerPopsOutOfTheOrb() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.foldTarget = { orbFrame() }
    let card = recallable("Back from the orb.")
    overlay.showAnswer(card, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    #expect(overlay.model.source != orbCentre())
    overlay.dismiss(.clickAway)
    #expect(await eventually { overlay.model.surface == .none })
    overlay.recallAnswer(card, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    #expect(overlay.model.source == orbCentre())
    overlay.showAnswer(recallable("A new answer."), anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    #expect(overlay.model.source != orbCentre(), "only the recall comes from the orb")
    overlay.dismiss(.requested)
}

@Test func fakeKeepsTheFoldedHook() {
    let fake = FakeOverlay()
    var called = false
    fake.onFoldedIntoTarget = { called = true }
    fake.onFoldedIntoTarget?()
    #expect(called)
}

@Test(.overlayExclusive) func aTuckNeverShrinksTheNextFoldToASpeck() async {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.foldTarget = { orbFrame() }
    let card = recallable("Tucked, then folded by the Lumi key.")
    overlay.showAnswer(card, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    overlay.dismiss(.escape)                                   // tucks: .06
    #expect(await eventually { overlay.model.surface == .none })
    overlay.recallAnswer(card, anchor: .point(CGPoint(x: 300, y: 300)))
    await overlay.presentationFinished()
    overlay.showListening(at: CGPoint(x: 300, y: 300), hint: "h")   // folds toward the pill
    #expect(overlay.model.folding)
    #expect(overlay.model.foldScale == Motion.foldScale)
    overlay.dismiss(.requested)
}

// MARK: Glass edge (wants Liquid Glass; our outline doubled the system's edge)

@Test func overGlassOnlyTheEdgesGlassCantDrawAreAdded() {
    let glass = Tokens(.init(dark: false))
    #expect(SurfaceChrome<Capsule>.edge(glass, bright: false, border: nil) == nil)                    // glass draws its own
    #expect(SurfaceChrome<Capsule>.edge(glass, bright: true, border: nil) == glass.hairlineBright)     // bright backdrop
    #expect(SurfaceChrome<Capsule>.edge(glass, bright: false, border: Tokens.amberBorder) == Tokens.amberBorder)
    #expect(!SurfaceChrome<Capsule>.drawsHighlight(glass))
    let opaque = Tokens(.init(dark: false, reduceTransparency: true))
    #expect(SurfaceChrome<Capsule>.edge(opaque, bright: false, border: nil) == opaque.hairline)
    #expect(SurfaceChrome<Capsule>.drawsHighlight(opaque))
    let contrast = Tokens(.init(dark: true, increaseContrast: true))
    #expect(SurfaceChrome<Capsule>.edge(contrast, bright: false, border: nil) == contrast.hairline)
}

@Test func cardAndChipCornersStayConcentric() {
    #expect(Tokens.cardRadius == 18 && Tokens.chipRadius == 14)
    #expect(Tokens.chipRadius - Tokens.rimInset == Tokens.chipWellRadius)
}
