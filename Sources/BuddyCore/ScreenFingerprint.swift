import CoreGraphics
import Foundation

/// A copy of a screenshot at the size the model sees it, to tell whether the screen changed since
/// the last image a session got. Compared pixel for pixel in colour, so one changed digit in a
/// dense table, or a status dot turning from red to green, counts as a change. Only a change
/// inside the text caret's own rectangle (a blink) doesn't. In memory only, never sent.
public struct ScreenFingerprint: Sendable, Equatable {
    public let displayID: UInt32
    /// The display in global points, top-left origin, to place the caret.
    public let frame: CGRect
    public let width: Int
    public let height: Int
    /// Row-major RGBA, four bytes per pixel.
    public let pixels: [UInt8]

    public init(displayID: UInt32, frame: CGRect, width: Int, height: Int, pixels: [UInt8]) {
        self.displayID = displayID
        self.frame = frame
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A channel differing by more than this (of 255) is a change; identical content renders
    /// identically, so this only absorbs dithering.
    public static let threshold = 12
    /// Slack around the caret's rectangle, in fingerprint pixels.
    public static let caretSlack = 3

    /// True only when nothing changed, except inside `caret` (global points: the text caret, from
    /// the packet's selection bounds when nothing is selected).
    public func isSameScreen(as other: ScreenFingerprint, caret: CGRect? = nil) -> Bool {
        guard displayID == other.displayID, frame == other.frame, width == other.width, height == other.height,
              pixels.count == other.pixels.count, pixels.count == width * height * 4 else { return false }
        let allowed = caret.flatMap(pixelRect)
        var same = true
        pixels.withUnsafeBufferPointer { a in
            other.pixels.withUnsafeBufferPointer { b in
                var i = 0
                while i < a.count {
                    if abs(Int(a[i]) - Int(b[i])) > Self.threshold || abs(Int(a[i + 1]) - Int(b[i + 1])) > Self.threshold
                        || abs(Int(a[i + 2]) - Int(b[i + 2])) > Self.threshold {
                        let p = i / 4
                        guard let allowed, allowed.contains(x: p % width, y: p / width) else {
                            same = false
                            return
                        }
                    }
                    i += 4
                }
            }
        }
        return same
    }

    struct PixelRect: Equatable {
        var minX, maxX, minY, maxY: Int
        func contains(x: Int, y: Int) -> Bool { x >= minX && x <= maxX && y >= minY && y <= maxY }
    }

    /// `rect` (global points) in this fingerprint's pixels, widened by the slack.
    func pixelRect(_ rect: CGRect) -> PixelRect? {
        guard frame.width > 0, frame.height > 0, !rect.isNull else { return nil }
        let sx = Double(width) / frame.width, sy = Double(height) / frame.height
        let s = Self.caretSlack
        let r = PixelRect(minX: Int(((rect.minX - frame.minX) * sx).rounded(.down)) - s,
                          maxX: Int(((rect.maxX - frame.minX) * sx).rounded(.up)) + s,
                          minY: Int(((rect.minY - frame.minY) * sy).rounded(.down)) - s,
                          maxY: Int(((rect.maxY - frame.minY) * sy).rounded(.up)) + s)
        return r.maxX < 0 || r.maxY < 0 || r.minX >= width || r.minY >= height ? nil : r
    }
}
