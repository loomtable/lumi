import AppKit

extension BuddyOverlayController {
    /// The listening or thinking pill's frame in AppKit screen coordinates (bottom-left
    /// origin), nil while no pill shows. Read-only: the switcher's strip grows out of it.
    public var pillScreenFrame: CGRect? {
        guard model.surface.isPill, !model.folding else { return nil }
        return Self.appKitFrame(model.pillFrame, primaryHeight: NSScreen.screens.first?.frame.height)
    }

    /// A global top-left frame (the overlay's space) in AppKit's bottom-left space, flipped
    /// about the primary display.
    nonisolated static func appKitFrame(_ topLeft: CGRect, primaryHeight: CGFloat?) -> CGRect? {
        guard let primaryHeight, topLeft.width > 0, topLeft.height > 0 else { return nil }
        return CGRect(x: topLeft.minX, y: primaryHeight - topLeft.maxY, width: topLeft.width, height: topLeft.height)
    }
}
