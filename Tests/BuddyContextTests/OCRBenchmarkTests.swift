import AppKit
import CoreText
import Foundation
import Testing
import Vision
@testable import BuddyContext

/// OCR timings behind the locator's prepare/deadline design, on a dense full-Retina screen
/// drawn in-process (no Screen Recording needed). Opt-in: BUDDYCONTEXT_BENCH=1.
@Suite("OCR benchmark", .enabled(if: ProcessInfo.processInfo.environment["BUDDYCONTEXT_BENCH"] == "1"))
struct OCRBenchmarkTests {
    /// A 1470×956 pt display at 2× (a 15" MacBook Air), filled edge to edge with 13 pt text.
    static func denseScreen() -> Screenshot {
        let scale: CGFloat = 2, size = CGSize(width: 1470, height: 956)
        let ctx = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        let font = CTFontCreateWithName("Helvetica" as CFString, 13 * scale, nil)
        let sentence = "The supplier shall deliver the goods within thirty days of the order and invoice the customer monthly. "
        var y: CGFloat = 20
        var n = 0
        while y < size.height - 20 {
            let text = "\(n). " + String(repeating: sentence, count: 3)
            let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
            ctx.textPosition = CGPoint(x: 20 * scale, y: (size.height - y - 13) * scale)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
            y += 17
            n += 1
        }
        return Screenshot(
            file: URL(fileURLWithPath: "/dev/null"), fileData: Data(), fileWidth: 1, fileHeight: 1, full: ctx.makeImage()!,
            displayID: 9, scale: Double(scale), displayFrame: CGRect(origin: .zero, size: size))
    }

    @Test("accurate and fast OCR, whole display vs an 800×500 pt window")
    func timings() async {
        let shot = Self.denseScreen()
        let cases: [(String, CGRect, RecognizeTextRequest.RecognitionLevel)] = [
            ("whole display, accurate", shot.displayFrame, .accurate),
            ("whole display, fast", shot.displayFrame, .fast),
            ("800×500 pt window, accurate", CGRect(x: 300, y: 200, width: 800, height: 500), .accurate),
            ("800×500 pt window, fast", CGRect(x: 300, y: 200, width: 800, height: 500), .fast),
        ]
        _ = await OCRText.recognize(shot, within: cases[3].1, level: .fast)  // warm up Vision
        for (name, window, level) in cases {
            var ms: [Double] = []
            var lines = 0, found = 0
            for _ in 0..<5 {
                let t = ContinuousClock.now
                let text = await OCRText.recognize(shot, within: window, level: level)
                ms.append((ContinuousClock.now - t).milliseconds)
                lines = text?.lines.count ?? 0
                found = text?.find(["invoice the customer monthly"], within: window).count ?? 0
            }
            ms.sort()
            print(String(format: "OCR %@: p50 %.0f ms, min %.0f, max %.0f (n=5); %d lines, quote %@",
                         name, ms[2], ms[0], ms[4], lines, found == 1 ? "found" : "NOT found"))
        }
    }
}
