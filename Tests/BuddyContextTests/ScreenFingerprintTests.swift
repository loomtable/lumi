import BuddyCore
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import BuddyContext

/// The screen check behind "send the screenshot only when it changed": a missed change means the
/// model answers "what about now?" from a stale image, so any real change must count.
struct ScreenFingerprintTests {
    /// A 1512×982 pt display at 2×: a dense table of 6-digit numbers in 13 pt Menlo.
    static func table(changing cell: (row: Int, column: Int)? = nil, caretAt caret: CGPoint? = nil) -> CGImage {
        let (width, height) = (3024, 1964)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 26, nil)
        for row in 0..<60 {
            for column in 0..<16 {
                var value = 100_000 + row * 1_013 + column * 37
                if let cell, cell == (row, column) { value += 1 } // one digit differs
                let text = NSAttributedString(string: String(value), attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
                ])
                ctx.textPosition = CGPoint(x: 40 + column * 180, y: height - 60 - row * 30)
                CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
            }
        }
        if let caret {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: caret.x, y: caret.y, width: 2, height: 34))
        }
        return ctx.makeImage()!
    }

    static func shot(_ image: CGImage) -> Screenshot {
        Screenshot(file: URL(fileURLWithPath: "/dev/null"), fileData: Data(), fileWidth: 1568, fileHeight: 1018, full: image,
                   displayID: 1, scale: 2, displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    @Test func theSameScreenMatches() throws {
        let a = try #require(Self.shot(Self.table()).fingerprint())
        let b = try #require(Self.shot(Self.table()).fingerprint())
        #expect(a.width == 1568)
        #expect(a.isSameScreen(as: b))
    }

    @Test func oneChangedDigitInADenseTableIsAChange() throws {
        let before = try #require(Self.shot(Self.table()).fingerprint())
        let after = try #require(Self.shot(Self.table(changing: (row: 31, column: 9))).fingerprint())
        #expect(!before.isSameScreen(as: after))
    }

    /// The caret drawn at (1500, 900) px from the bottom-left of the 2× image: in global points,
    /// top-left origin, that's x 750, y (1964 − 900 − 34) / 2 = 515, 1×17 pt.
    static let caretRect = CGRect(x: 750, y: 515, width: 1, height: 17)

    @Test func aBlinkingCaretIsNotAChange() throws {
        let before = try #require(Self.shot(Self.table()).fingerprint())
        let after = try #require(Self.shot(Self.table(caretAt: CGPoint(x: 1500, y: 900))).fingerprint())
        #expect(before.isSameScreen(as: after, caret: Self.caretRect))
    }

    @Test func aCaretSizedChangeAwayFromTheCaretCounts() throws {
        // "v1" becoming "v11" in another pane is a sliver as narrow as a caret.
        let before = try #require(Self.shot(Self.table()).fingerprint())
        let after = try #require(Self.shot(Self.table(caretAt: CGPoint(x: 1500, y: 900))).fingerprint())
        #expect(!before.isSameScreen(as: after))
        #expect(!before.isSameScreen(as: after, caret: Self.caretRect.offsetBy(dx: 200, dy: 0)))
    }

    static func flat(_ rgb: (UInt8, UInt8, UInt8), display: UInt32 = 1) -> ScreenFingerprint {
        ScreenFingerprint(displayID: display, frame: CGRect(x: 0, y: 0, width: 10, height: 10), width: 10, height: 10,
                          pixels: Array(repeating: [rgb.0, rgb.1, rgb.2, 255], count: 100).flatMap { $0 })
    }

    @Test func anotherDisplayIsAChange() {
        #expect(!Self.flat((0, 0, 0)).isSameScreen(as: Self.flat((0, 0, 0), display: 2)))
    }

    @Test func aColourOnlyChangeCounts() {
        // GitHub's success green and danger red have nearly the same brightness.
        var pixels = Self.flat((0x1a, 0x7f, 0x37)).pixels
        pixels[0] = 0xd1; pixels[1] = 0x24; pixels[2] = 0x2f
        let after = ScreenFingerprint(displayID: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10), width: 10, height: 10, pixels: pixels)
        #expect(!Self.flat((0x1a, 0x7f, 0x37)).isSameScreen(as: after))
    }

    /// CPU time on this thread, not wall time: a loaded machine (load ~60 while peers build) can
    /// keep the thread off a core for longer than the work itself takes.
    static func threadCPUTime() -> Duration {
        .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
    }

    @Test func fingerprintAndCompareCostMilliseconds() throws {
        let image = Self.table()
        let (start, cpuStart) = (ContinuousClock.now, Self.threadCPUTime())
        let a = try #require(Self.shot(image).fingerprint())
        let made = Self.threadCPUTime() - cpuStart
        _ = a.isSameScreen(as: a)
        let total = Self.threadCPUTime() - cpuStart
        print("fingerprint \(made) CPU, with compare \(total) CPU (\(ContinuousClock.now - start) wall)")
        #expect(total < .milliseconds(500), "debug build; release is far faster")
    }
}
