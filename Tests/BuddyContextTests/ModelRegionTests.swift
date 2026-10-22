import BuddyCore
import CoreGraphics
import Foundation
import Testing
@testable import BuddyContext

/// The model's image is the front window, so text stays legible on a large display, and the whole
/// display whenever the window wouldn't show what was asked about.
struct ModelRegionTests {
    static let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    static let window = CGRect(x: 300, y: 200, width: 1600, height: 1000)

    @Test func theFrontWindowIsTheRegion() {
        #expect(ModelRegion.choose(window: Self.window, cursor: CGPoint(x: 800, y: 600), display: Self.display) == Self.window)
        #expect(ModelRegion.choose(window: Self.window, cursor: nil, display: Self.display) == Self.window)
    }

    @Test func thePointerOutsideTheWindowMeansTheWholeDisplay() {
        // "What's this?" pointing at a background window.
        #expect(ModelRegion.choose(window: Self.window, cursor: CGPoint(x: 2200, y: 300), display: Self.display) == nil)
    }

    @Test func noWindowATinyOneOrOneMostlyOffTheDisplayMeansTheWholeDisplay() {
        #expect(ModelRegion.choose(window: nil, cursor: nil, display: Self.display) == nil)
        #expect(ModelRegion.choose(window: CGRect(x: 10, y: 10, width: 300, height: 150), cursor: nil, display: Self.display) == nil)
        let mostlyOff = CGRect(x: 2400, y: 200, width: 1000, height: 800)   // 160 of 1000 pt on this display
        #expect(ModelRegion.choose(window: mostlyOff, cursor: nil, display: Self.display) == nil)
    }

    @Test func aWindowPartlyOffTheDisplayIsClippedToIt() {
        let partly = CGRect(x: 1960, y: 200, width: 1000, height: 800)   // 600 of 1000 pt on it
        #expect(ModelRegion.choose(window: partly, cursor: nil, display: Self.display)
            == CGRect(x: 1960, y: 200, width: 600, height: 800))
    }

    /// A 200×100 pt display at (100, 50), captured at 2×: the left half is black, the right white.
    static let halves: Screenshot = {
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        return Screenshot(file: URL(fileURLWithPath: "/dev/null"), fileData: Data(), fileWidth: 400, fileHeight: 200,
                          full: ctx.makeImage()!, displayID: 2, scale: 2, displayFrame: CGRect(x: 100, y: 50, width: 200, height: 100))
    }()

    @Test func theModelAreaIsTheRegionsPixelsAndTheRectTheyShow() {
        let shot = Self.halves
        let area = Screenshot.modelArea(of: shot.full, displayFrame: shot.displayFrame,
                                        region: CGRect(x: 210, y: 60, width: 50.25, height: 30))
        #expect((area.image.width, area.image.height) == (101, 60))   // snapped outward to whole pixels
        #expect(area.rect == CGRect(x: 210, y: 60, width: 50.5, height: 30))
        let none = Screenshot.modelArea(of: shot.full, displayFrame: shot.displayFrame, region: nil)
        #expect(none.rect == shot.displayFrame && none.image.width == 400)
        let offDisplay = Screenshot.modelArea(of: shot.full, displayFrame: shot.displayFrame,
                                              region: CGRect(x: 0, y: 0, width: 50, height: 40))
        #expect(offDisplay.rect == shot.displayFrame, "a region not on this display falls back to all of it")
    }

    @Test func filePixelsMapThroughWhatTheFileShows() {
        let shot = Self.halves
        let window = Screenshot(file: shot.file, fileData: Data(), fileWidth: 100, fileHeight: 50, full: shot.full,
                                displayID: 2, scale: 2, displayFrame: shot.displayFrame,
                                fileRect: CGRect(x: 200, y: 50, width: 100, height: 50))
        #expect(window.filePixels(ofGlobal: CGRect(x: 210, y: 60, width: 20, height: 10)) == CGRect(x: 10, y: 10, width: 20, height: 10))
        #expect(window.filePixels(ofGlobal: CGRect(x: 110, y: 60, width: 20, height: 10)) == nil, "outside the window")
        #expect(window.fullPixels(ofGlobal: CGRect(x: 110, y: 60, width: 20, height: 10)) == CGRect(x: 20, y: 20, width: 40, height: 20),
                "full stays the whole display, for rings and OCR")
    }

    @Test func theFingerprintCoversWhatWasSentAndNamesIt() throws {
        let shot = Self.halves
        func sent(_ rect: CGRect) -> Screenshot {
            Screenshot(file: shot.file, fileData: Data(), fileWidth: 1, fileHeight: 1, full: shot.full, displayID: 2, scale: 2,
                       displayFrame: shot.displayFrame, fileRect: rect)
        }
        let whiteHalf = try #require(sent(CGRect(x: 200, y: 50, width: 100, height: 50)).fingerprint())
        #expect(whiteHalf.frame == CGRect(x: 200, y: 50, width: 100, height: 50))
        #expect((whiteHalf.width, whiteHalf.height) == (200, 100))
        #expect(whiteHalf.pixels.allSatisfy { $0 == 255 }, "only the window's pixels")
        let whole = try #require(shot.fingerprint())
        #expect(whole.frame == shot.displayFrame)
        #expect(!whiteHalf.isSameScreen(as: whole) && !whole.isSameScreen(as: whiteHalf))
        let blackHalf = try #require(sent(CGRect(x: 100, y: 50, width: 100, height: 50)).fingerprint())
        #expect(!whiteHalf.isSameScreen(as: blackHalf), "another window is a change")
    }

    /// Review: at a scaled mode (non-integer pixels per point, display not at the origin) the rect
    /// shown maps back to exactly the pixels encoded, not one column more.
    @Test func theFingerprintCoversExactlyTheEncodedPixelsAtAScaledMode() throws {
        let frame = CGRect(x: 3440, y: -200, width: 1714, height: 1080)   // 3000×1890 px: 1.7503 px/pt
        let ctx = CGContext(data: nil, width: 3000, height: 1890, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let full = ctx.makeImage()!
        for x in stride(from: 3441.0, to: 4000, by: 7.3) {
            let region = CGRect(x: x, y: -150.4, width: 900.7, height: 601.3)
            let area = Screenshot.modelArea(of: full, displayFrame: frame, region: region)
            let shot = Screenshot(file: URL(fileURLWithPath: "/dev/null"), fileData: Data(), fileWidth: 1, fileHeight: 1, full: full,
                                  displayID: 1, scale: 1.75, displayFrame: frame, fileRect: area.rect)
            let image = try #require(shot.fileArea())
            #expect((image.width, image.height) == (area.image.width, area.image.height), "at x \(x)")
        }
    }

    @Test func theFocusIsThePacketsWindowAndPointer() {
        var packet = ContextPacket(askedAt: Date(timeIntervalSince1970: 0), utterance: "")
        #expect(ModelRegion.focus(in: packet) == nil)
        packet.cursor = .init(x: 5, y: 6)
        packet.window = .init(title: "No frame")
        #expect(ModelRegion.focus(in: packet) == nil, "a window without bounds is no focus")
        packet.window?.bounds = .init(x: 1, y: 2, width: 300, height: 400)
        #expect(ModelRegion.focus(in: packet) == .init(window: CGRect(x: 1, y: 2, width: 300, height: 400), cursor: CGPoint(x: 5, y: 6)))
    }

    @Test func theCloseUpCentreIsAnAXSelectionInTheWindow() {
        var packet = ContextPacket(askedAt: Date(timeIntervalSince1970: 0), utterance: "")
        packet.window = .init(title: "W", bounds: .init(x: 0, y: 0, width: 1000, height: 800))
        packet.selection = .init(text: "x", bounds: .init(x: 100, y: 100, width: 50, height: 16), boundsSource: .axRange)
        #expect(ModelRegion.focus(in: packet)?.detail == CGRect(x: 100, y: 100, width: 50, height: 16))
        packet.selection?.boundsSource = .axTextMarker
        #expect(ModelRegion.focus(in: packet)?.detail != nil)
        packet.selection?.boundsSource = .ocr
        #expect(ModelRegion.focus(in: packet)?.detail == nil, "never a guess")
        packet.selection?.boundsSource = nil
        #expect(ModelRegion.focus(in: packet)?.detail == nil)
        packet.selection = .init(text: "x", bounds: .init(x: 1200, y: 100, width: 50, height: 16), boundsSource: .axRange)
        #expect(ModelRegion.focus(in: packet)?.detail == nil, "outside the window")
    }

    /// A 1000×500 pt display at 2× whose file is a 400×200 pt window downscaled to 200 px wide (4×).
    static func windowShot(fileWidth: Int = 200) -> Screenshot {
        let ctx = CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return Screenshot(file: URL(fileURLWithPath: "/dev/null"), fileData: Data(), fileWidth: fileWidth, fileHeight: fileWidth / 2,
                          full: ctx.makeImage()!, displayID: 1, scale: 2, displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 500),
                          fileRect: CGRect(x: 100, y: 50, width: 400, height: 200))
    }

    @Test func theCloseUpIs512FullPixelsCentredOnTheSelection() throws {
        let d = try #require(Self.windowShot().detail(around: CGRect(x: 290, y: 140, width: 20, height: 20)))
        #expect((d.width, d.height) == (512, 400), "the window is only 400 px tall")
        #expect(d.rect == CGRect(x: 172, y: 50, width: 256, height: 200), "centred on x 300, the window's full height")
    }

    @Test func theCloseUpStaysInsideTheWindow() throws {
        // A caret at the window's left edge: the box slides right rather than show the window beside it.
        let d = try #require(Self.windowShot().detail(around: CGRect(x: 101, y: 60, width: 2, height: 16)))
        #expect(d.rect.minX == 100 && d.rect.maxX <= 500 && d.rect.minY >= 50 && d.rect.maxY <= 250)
        #expect(Self.windowShot().detail(around: CGRect(x: 700, y: 60, width: 2, height: 16)) == nil, "not in the window")
    }

    @Test func noCloseUpWhenTheImageIsAlmostFullResolution() {
        #expect(Self.windowShot(fileWidth: 700).detail(around: CGRect(x: 290, y: 140, width: 20, height: 20)) == nil)
    }

    @Test func theFakeRecordsTheRegion() async throws {
        let fake = FakeScreenshotter(result: .success(URL(fileURLWithPath: "/tmp/x.jpg")))
        _ = try await fake.capture(displayID: 1, blocklist: Blocklist(), options: .model, region: Self.window)
        #expect(fake.lastRegion == Self.window)
        _ = try await fake.capture(displayID: 1, blocklist: Blocklist(), options: .model)
        #expect(fake.lastRegion == nil)
    }
}
