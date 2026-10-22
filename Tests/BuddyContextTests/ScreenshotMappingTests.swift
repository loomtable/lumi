import BuddyCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import BuddyContext

@Suite("Screenshot mapping")
struct ScreenshotMappingTests {
    static func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// A 100×50 pt display at (100, 50) in global points, captured at 2× (200×100 px), with a
    /// file downscaled to 100×50 px.
    static let shot = Screenshot(
        file: URL(fileURLWithPath: "/dev/null"), fileData: Data(), fileWidth: 100, fileHeight: 50, full: image(200, 100),
        displayID: 2, scale: 2, displayFrame: CGRect(x: 100, y: 50, width: 100, height: 50))

    @Test("global points map to file and full pixels")
    func mapping() {
        let r = CGRect(x: 110, y: 60, width: 20, height: 10)
        #expect(Self.shot.filePixels(ofGlobal: r) == CGRect(x: 10, y: 10, width: 20, height: 10))
        #expect(Self.shot.fullPixels(ofGlobal: r) == CGRect(x: 20, y: 20, width: 40, height: 20))
    }

    @Test("rects are clipped to the image; off-display gives nil")
    func clipping() {
        #expect(Self.shot.filePixels(ofGlobal: CGRect(x: 190, y: 90, width: 50, height: 50))
            == CGRect(x: 90, y: 40, width: 10, height: 10))
        #expect(Self.shot.filePixels(ofGlobal: CGRect(x: 0, y: 0, width: 20, height: 20)) == nil)
    }

    @Test("a display left of the primary (negative origin) maps correctly")
    func negativeOrigin() {
        let left = Screenshot(
            file: URL(fileURLWithPath: "/dev/null"), fileData: Data(), fileWidth: 100, fileHeight: 50, full: Self.image(100, 50),
            displayID: 3, scale: 1, displayFrame: CGRect(x: -100, y: 0, width: 100, height: 50))
        #expect(left.filePixels(ofGlobal: CGRect(x: -90, y: 5, width: 10, height: 5))
            == CGRect(x: 10, y: 5, width: 10, height: 5))
    }

    @Test("crop around a selection encodes the padded region at the requested size")
    func crop() throws {
        let data = try #require(try Self.shot.crop(
            aroundGlobal: CGRect(x: 140, y: 70, width: 10, height: 5), padding: 10,
            options: ScreenshotOptions(maxLongEdge: nil, format: .jpeg(quality: 0.7))))
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        // 30×25 pt padded region at 2× = 60×50 px.
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 60)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 50)
        #expect(try Self.shot.crop(aroundGlobal: CGRect(x: 0, y: 0, width: 5, height: 5), padding: 0, options: .model) == nil)
    }

    @Test("backdrop is a quarter of the display's points, made from the full image")
    func backdrop() throws {
        // 100×50 pt display captured at 2×: a 0.25 backdrop is 25×13 px (12.5 rounds up).
        let image = try #require(Self.shot.backdrop())
        #expect(image.width == 25)
        #expect(image.height == 13)
        #expect(Self.shot.backdrop(pointScale: 1)?.width == 100)
        let snap = try #require(Self.shot.displaySnapshot())
        #expect(snap.frame == Self.shot.displayFrame)
        #expect(snap.displayID == 2)
        #expect(snap.scale == 0.25)
        #expect(snap.image.width == 25)
    }
}
