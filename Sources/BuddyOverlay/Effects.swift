import Accelerate
import BuddyCore
import CoreGraphics
import Foundation

/// Effects and placement the user controls in Settings › Appearance (Effects).
nonisolated public struct OverlaySettings: Sendable, Equatable {
    /// Speaking glow follows the reply's loudness.
    public var glow = true
    /// Dot field while you talk; otherwise 6 plain level bars.
    public var dotField = true
    /// Answer headlines ink in word by word.
    public var inkIn = true
    public var placement: Placer.Mode = .smart
    /// Where the listening pill and every status line sit: one fixed spot.
    public var statusPosition: StatusPosition = .top
    /// Settings › Appearance › "Rings on screen". Off: no ring is drawn, even if one is asked for.
    public var rings = true

    public nonisolated enum StatusPosition: String, Sendable, Equatable, CaseIterable {
        /// Centred under the menu bar, below the research capsule when one is showing.
        case top
        /// Centred above the bottom of the visible frame (clear of the Dock).
        case bottom
    }

    public init(glow: Bool = true, dotField: Bool = true, inkIn: Bool = true, placement: Placer.Mode = .smart,
                statusPosition: StatusPosition = .top, rings: Bool = true) {
        self.rings = rings
        self.glow = glow
        self.dotField = dotField
        self.inkIn = inkIn
        self.placement = placement
        self.statusPosition = statusPosition
    }
}

/// Edge strengthening over bright backdrops (Light and dark): above 0.70 luminance in a
/// 24 pt ring around a surface the outer hairline strengthens and the shadow deepens; it
/// returns only below 0.55, after 300 ms there. Pure, so the hysteresis is unit-tested.
nonisolated struct BrightnessGate: Sendable, Equatable {
    static let rise = 0.70
    static let fall = 0.55
    static let dwell: Duration = .milliseconds(300)

    private(set) var bright = false
    private var belowSince: ContinuousClock.Instant?

    mutating func update(luminance: Double, at now: ContinuousClock.Instant) -> Bool {
        if luminance > Self.rise {
            bright = true
            belowSince = nil
        } else if bright, luminance < Self.fall {
            if let since = belowSince {
                if now - since >= Self.dwell { bright = false; belowSince = nil }
            } else {
                belowSince = now
            }
        } else {
            belowSince = nil
        }
        return bright
    }

    mutating func reset() { self = BrightnessGate() }
}

/// Relative luminance of a snapshot, with O(1) rect means, for the 24 pt ring.
nonisolated struct LuminanceMap: Sendable {
    let width: Int
    let height: Int
    /// (width+1) × (height+1) integral image of linear luminance, row 0 = top.
    let integral: [Double]

    static let ringWidth: CGFloat = 24

    static func make(_ image: CGImage) throws -> LuminanceMap {
        var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 8,
                                          colorSpace: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))!
        let gray = try vImage.PixelBuffer(cgImage: image, cgImageFormat: &format, pixelFormat: vImage.Planar8.self)
        let w = gray.width, h = gray.height, stride = gray.rowStride, iw = w + 1
        // sRGB-encoded gray to linear luminance, once per level.
        let linear: [Double] = (0..<256).map { v in
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        var ii = [Double](repeating: 0, count: iw * (h + 1))
        gray.withUnsafeBufferPointer { g in
            for y in 0..<h {
                var run = 0.0
                for x in 0..<w {
                    run += linear[Int(g[y * stride + x])]
                    ii[(y + 1) * iw + x + 1] = ii[y * iw + x + 1] + run
                }
            }
        }
        return LuminanceMap(width: w, height: h, integral: ii)
    }

    private func sum(_ r: CGRect) -> (Double, Int) {
        let x0 = max(0, min(width, Int(r.minX.rounded(.down)))), x1 = max(0, min(width, Int(r.maxX.rounded(.up))))
        let y0 = max(0, min(height, Int(r.minY.rounded(.down)))), y1 = max(0, min(height, Int(r.maxY.rounded(.up))))
        guard x1 > x0, y1 > y0 else { return (0, 0) }
        let w = width + 1
        let s = integral[y1 * w + x1] - integral[y0 * w + x1] - integral[y1 * w + x0] + integral[y0 * w + x0]
        return (s, (x1 - x0) * (y1 - y0))
    }

    /// Mean luminance of the ring of `ringWidth` points around `globalRect`.
    func ringLuminance(around globalRect: CGRect, snapshot: DisplaySnapshot) -> Double? {
        let s = snapshot.scale
        func px(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - snapshot.frame.minX) * s, y: (r.minY - snapshot.frame.minY) * s,
                   width: r.width * s, height: r.height * s)
        }
        let outer = sum(px(globalRect.insetBy(dx: -Self.ringWidth, dy: -Self.ringWidth)))
        let inner = sum(px(globalRect))
        let n = outer.1 - inner.1
        guard n > 0 else { return nil }
        return (outer.0 - inner.0) / Double(n)
    }
}
