import AppKit
import CoreText
import Foundation
import Synchronization
import Testing
@testable import BuddyContext

@Suite("TextMatch")
struct TextMatchTests {
    @Test("case, whitespace, quotes and dashes don't matter")
    func lenient() {
        let text = "The  Termination clause — it says “either party”\nmay end it."
        #expect(TextMatch.range(of: "termination clause", in: text) != nil)
        #expect(TextMatch.range(of: "clause - it says \"either party\" may", in: text) != nil)
        #expect(TextMatch.range(of: "it’s", in: "it's here") != nil)
        #expect(TextMatch.range(of: "missing words", in: text) == nil)
        #expect(TextMatch.range(of: "   ", in: text) == nil)
    }

    @Test("regex characters in the quote are literal")
    func literal() {
        #expect(TextMatch.range(of: "a+b (c)", in: "x a+b (c) y") != nil)
        #expect(TextMatch.range(of: "a.b", in: "axb") == nil)
    }

    @Test("UTF-16 ranges count emoji and combining marks as AX does")
    func utf16() {
        let text = "👋 café — naïve résumé"
        let range = TextMatch.range(of: "naïve", in: text)!
        let r = TextMatch.utf16Range(range, in: text)
        #expect(r.length == 5)
        #expect(r.location == (text as NSString).range(of: "naïve").location)
    }

    @Test("whole words only: a quote never matches inside a longer word")
    func wordBoundaries() {
        #expect(TextMatch.range(of: "art", in: "Insert Chart") == nil)
        #expect(TextMatch.range(of: "pay", in: "early repayment") == nil)
        #expect(TextMatch.range(of: "art", in: "modern art.") != nil)
        #expect(TextMatch.range(of: "Chart", in: "Insert Chart") != nil)
    }

    @Test("edge punctuation, internal punctuation and diacritics are lenient")
    func fuzzy() {
        #expect(TextMatch.range(of: "“Export as PDF…”", in: "choose Export as PDF from") != nil)
        #expect(TextMatch.range(of: "Save, then export", in: "Save then export") != nil)
        #expect(TextMatch.range(of: "Save then export", in: "Save; then export") != nil)
        #expect(TextMatch.range(of: "e-mail", in: "your email address") != nil)
        #expect(TextMatch.range(of: "resume", in: "your résumé here") != nil)
        let text = "Ça coûte 3 €, café inclus"
        let r = TextMatch.range(of: "cafe inclus", in: text)!
        #expect(String(text[r]) == "café inclus")
    }

    @Test("prefix gives the opening words only when the quote is longer")
    func prefix() {
        #expect(TextMatch.prefix(of: "one two three", words: 6) == nil)
        #expect(TextMatch.prefix(of: "1 2 3 4 5 6 7 8", words: 6) == "1 2 3 4 5 6")
    }
}

@Suite("OCR locate")
struct OCRLocateTests {
    /// A 2× "display" at global origin (100, 50), 800×400 pt, with lines of text drawn at known
    /// positions (top-left points).
    static func screenshot(lines: [(String, CGPoint)]) -> Screenshot {
        let scale: CGFloat = 2, size = CGSize(width: 800, height: 400)
        let ctx = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        let font = CTFontCreateWithName("Helvetica" as CFString, 15 * scale, nil)
        for (text, point) in lines {
            let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
            let line = CTLineCreateWithAttributedString(attributed)
            // CG draws bottom-up: baseline at (height - y - ascent).
            ctx.textPosition = CGPoint(x: point.x * scale, y: (size.height - point.y - 15) * scale)
            CTLineDraw(line, ctx)
        }
        return Screenshot(
            file: URL(fileURLWithPath: "/dev/null"), fileData: Data(), fileWidth: 1, fileHeight: 1, full: ctx.makeImage()!,
            displayID: 9, scale: Double(scale), displayFrame: CGRect(x: 100, y: 50, width: size.width, height: size.height))
    }

    /// The display the helper draws.
    static let display = CGRect(x: 100, y: 50, width: 800, height: 400)

    /// A locator that sees app `com.example.test` with `window` focused and no AX text.
    static func locator(window: CGRect? = display, bundleID: String? = "com.example.test", ocrWait: Duration = .seconds(5)) -> ScreenPointLocator {
        ScreenPointLocator(system: LocatorSystem(
            bundleID: { _ in bundleID }, windowFrame: { _ in window },
            findText: { _, _, _, partial in partial.window.withLock { $0 = window } }), ocrWait: ocrWait)
    }

    @Test("finds a quote inside a line and returns its rect in global points")
    func findsInLine() async throws {
        let shot = Self.screenshot(lines: [
            ("Section 4. Either party may terminate this agreement with notice.", CGPoint(x: 40, y: 60)),
            ("Payment is due within thirty days of the invoice date.", CGPoint(x: 40, y: 200)),
        ])
        let locator = Self.locator()
        await locator.prepare(shot, pid: 1)  // accurate OCR while the user speaks
        let found = await locator.locate(["terminate this agreement", "thirty days", "not on screen"], pid: 1, screenshot: shot)
        #expect(found.map(\.quote) == ["terminate this agreement", "thirty days"])
        let first = try #require(found.first)
        #expect(first.source == .ocr)
        // Line 1 sits 60 pt from the display's top, i.e. y ≈ 50 + 60 in global points.
        #expect(abs(first.rect.minY - 110) < 12)
        #expect(first.rect.minX > 100 + 40 && first.rect.maxX < 100 + 800)
        #expect(first.rect.width > 60 && first.rect.width < 400)
        let second = try #require(found.last)
        #expect(abs(second.rect.minY - 250) < 12)
    }

    @Test("without prepare, accurate OCR of the window still finds a quote")
    func fallback() async {
        let shot = Self.screenshot(lines: [("Payment is due within thirty days of the invoice date.", CGPoint(x: 40, y: 80))])
        let found = await Self.locator().locate(["thirty days"], pid: 1, screenshot: shot)
        #expect(found.first?.source == .ocr)
        #expect(found.first.map { abs($0.rect.minY - 130) < 12 } == true)
    }

    @Test("locate uses the text prepared for the same capture once, then forgets it")
    func usesPreparedTextOnce() async {
        let prepared = Self.screenshot(lines: [("Only the prepared capture says apricot.", CGPoint(x: 40, y: 80))])
        // Same file URL (both /dev/null), different pixels: a fresh OCR would not find "apricot".
        let other = Self.screenshot(lines: [("This capture says something else entirely.", CGPoint(x: 40, y: 80))])
        let locator = Self.locator()
        await locator.prepare(prepared, pid: 1)
        #expect(await locator.locate(["apricot"], pid: 1, screenshot: other).count == 1)
        #expect(await locator.preparedTask == nil)
        #expect(await locator.locate(["apricot"], pid: 1, screenshot: other).isEmpty)
    }

    @Test("a new prepare cancels the earlier one")
    func prepareCancels() async throws {
        let shot = Self.screenshot(lines: [("Some text", CGPoint(x: 40, y: 80))])
        let locator = Self.locator()
        await locator.prepare(shot, pid: 1)
        let first = try #require(await locator.preparedTask)
        await locator.prepare(shot, pid: 1)
        #expect(first.isCancelled)
        #expect(await locator.preparedTask?.isCancelled == false)
    }

    @Test("OCR that isn't ready by the deadline gives no rings")
    func deadline() async {
        let shot = Self.screenshot(lines: [("Payment is due within thirty days of the invoice date.", CGPoint(x: 40, y: 80))])
        let locator = Self.locator(ocrWait: .milliseconds(1))
        await locator.prepare(shot, pid: 1)
        #expect(await locator.locate(["thirty days"], pid: 1, screenshot: shot).isEmpty)
        #expect(await Self.locator(ocrWait: .milliseconds(1)).locate(["thirty days"], pid: 1, screenshot: shot).isEmpty)
    }

    @Test("a quote that wraps is found across the lines, and its ring covers both pieces")
    func wrapped() async throws {
        let shot = Self.screenshot(lines: [
            ("The supplier shall indemnify the customer against all claims", CGPoint(x: 40, y: 100)),
            ("arising from defects in the delivered goods.", CGPoint(x: 40, y: 122)),
        ])
        let found = await Self.locator().locate(["against all claims arising from defects"], pid: 1, screenshot: shot)
        let rect = try #require(found.first?.rect)
        #expect(abs(rect.minY - 150) < 12)
        #expect(abs(rect.maxY - 172 - 15) < 12)  // down to the second line
    }

    @Test("a hyphen that breaks a word across lines is dropped")
    func dehyphenated() async {
        let shot = Self.screenshot(lines: [
            ("The supplier shall indem-", CGPoint(x: 40, y: 100)),
            ("nify the customer against claims.", CGPoint(x: 40, y: 122)),
        ])
        #expect(await Self.locator().locate(["shall indemnify the customer"], pid: 1, screenshot: shot).count == 1)
    }

    @Test("text outside the focused window is never ringed")
    func insideWindowOnly() async {
        let shot = Self.screenshot(lines: [
            ("left side words", CGPoint(x: 40, y: 80)),
            ("right side apricot", CGPoint(x: 500, y: 80)),
        ])
        let leftHalf = CGRect(x: 100, y: 50, width: 380, height: 400)
        let locator = Self.locator(window: leftHalf)
        await locator.prepare(shot, pid: 1)
        #expect(await locator.locate(["apricot"], pid: 1, screenshot: shot).isEmpty)
        #expect(await locator.locate(["left side"], pid: 1, screenshot: shot).count == 1)
    }

    @Test("a window on another display gives no OCR rings, prepared or not")
    func offDisplay() async {
        let shot = Self.screenshot(lines: [("visible text here", CGPoint(x: 40, y: 80))])
        let elsewhere = CGRect(x: 3_000, y: 0, width: 400, height: 300)
        let locator = Self.locator(window: elsewhere)
        await locator.prepare(shot, pid: 1)
        #expect(await locator.locate(["visible text"], pid: 1, screenshot: shot).isEmpty)
        #expect(await Self.locator(window: elsewhere).locate(["visible text"], pid: 1, screenshot: shot).isEmpty)
    }

    @Test("an unknown or blocked app gives nothing, even though the capture shows the text")
    func blockedOrUnknown() async {
        let shot = Self.screenshot(lines: [("visible text here", CGPoint(x: 40, y: 80))])
        #expect(await Self.locator(bundleID: nil).locate(["visible text"], pid: 1, screenshot: shot).isEmpty)
        #expect(await Self.locator().locate(["visible text"], pid: nil, screenshot: shot).isEmpty)
        let blocked = Blocklist(userBundleIDs: ["com.example.test"])
        let locator = Self.locator()
        await locator.prepare(shot, pid: 1, blocklist: blocked)
        #expect(await locator.preparedTask == nil)
        #expect(await locator.locate(["visible text"], pid: 1, screenshot: shot, blocklist: blocked).isEmpty)
    }

    @Test("no quotes, blank quotes, or no screenshot give nothing")
    func nothing() async {
        #expect(await Self.locator().locate([], pid: 1, screenshot: nil).isEmpty)
        #expect(await Self.locator().locate(["  "], pid: 1, screenshot: nil).isEmpty)
        #expect(await Self.locator().locate(["x"], pid: 1, screenshot: nil).isEmpty)
    }
}

@Suite("AX locate rules")
struct AXLocateRuleTests {
    @Test("a rect is ringable only inside the window (AX reports scrolled-out text too)")
    func visibility() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(AXTextSearch.visible(CGRect(x: 120, y: 150, width: 50, height: 14), in: window))
        #expect(!AXTextSearch.visible(CGRect(x: 120, y: 2_400, width: 50, height: 14), in: window))
        #expect(AXTextSearch.visible(CGRect(x: 5, y: 5, width: 5, height: 5), in: nil))
    }

    @Test("prose and whole-element hits rank above buttons, links and cells")
    func ranking() {
        #expect(AXTextSearch.tier(role: "AXStaticText", coverage: 0.1) == 0)
        #expect(AXTextSearch.tier(role: "AXHeading", coverage: 0.1) == 0)
        #expect(AXTextSearch.tier(role: "AXButton", coverage: 1) == 0)
        #expect(AXTextSearch.tier(role: "AXButton", coverage: 0.5) == 1)
        #expect(AXTextSearch.tier(role: "AXLink", coverage: 0.3) == 1)
        #expect(AXTextSearch.tier(role: "AXCell", coverage: 0.3) == 1)
    }

    @Test("OCR lines join only when one sits directly below the other")
    func wraps() {
        let a = CGRect(x: 0.1, y: 0.80, width: 0.6, height: 0.04)
        #expect(OCRText.wraps(from: a, to: CGRect(x: 0.1, y: 0.75, width: 0.4, height: 0.04)))
        #expect(!OCRText.wraps(from: a, to: CGRect(x: 0.1, y: 0.50, width: 0.4, height: 0.04)))  // far below
        #expect(!OCRText.wraps(from: a, to: CGRect(x: 0.75, y: 0.75, width: 0.2, height: 0.04)))  // another column
    }
}
