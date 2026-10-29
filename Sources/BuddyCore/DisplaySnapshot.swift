import CoreGraphics

/// A downscaled image of one display, for the overlay's backdrop brightness (outlines, rings).
/// BuddyContext produces it from its ScreenCaptureKit capture; BuddyOverlay consumes it;
/// the shell passes it through, so neither module depends on the other.
public struct DisplaySnapshot: Sendable {
    /// The display at `scale` pixels per point (default 0.25 → 378×246 for 1512×982 pt),
    /// sRGB, without Lumi's or any blocked app's windows.
    public let image: CGImage
    public let displayID: UInt32
    /// The display in global points, top-left origin (CGDisplayBounds): the same space as
    /// AX rects, packet.selection.bounds and packet.cursor.
    public let frame: CGRect
    /// Image pixels per point (so image px = (globalPoint - frame.origin) * scale).
    public let scale: Double

    public init(image: CGImage, displayID: UInt32, frame: CGRect, scale: Double) {
        self.image = image
        self.displayID = displayID
        self.frame = frame
        self.scale = scale
    }
}
