import CoreGraphics

/// Where the Panel sits (04 §3.2). Pure geometry in AppKit screen coordinates (origin bottom
/// left): it docks 12 pt outside the origin window's trailing edge, or 12 pt inside the
/// screen's trailing edge when there's no room; its vertical centre follows the anchor,
/// clamped to a 16 pt margin. A position the user dragged to wins, per display.
nonisolated public enum PanelDocking {
    public static let defaultWidth: CGFloat = 400
    public static let widthRange: ClosedRange<CGFloat> = 340...560
    public static let minHeight: CGFloat = 220
    /// Of the visible screen height.
    public static let maxHeightFraction: CGFloat = 0.72
    public static let gap: CGFloat = 12
    public static let margin: CGFloat = 16

    public struct Input: Sendable, Equatable {
        /// The screen's visible frame (no menu bar or Dock).
        public var visible: CGRect
        public var originWindow: CGRect?
        /// The point Lumi read from, when there was one.
        public var anchor: CGPoint?
        public var width: CGFloat
        /// The page's content height (header, thread and composer).
        public var contentHeight: CGFloat
        /// The panel's top-left corner the user dragged it to on this display (the height
        /// changes with content, so the top edge stays put).
        public var remembered: CGPoint?

        public init(visible: CGRect, originWindow: CGRect? = nil, anchor: CGPoint? = nil, width: CGFloat = PanelDocking.defaultWidth,
                    contentHeight: CGFloat = PanelDocking.minHeight, remembered: CGPoint? = nil) {
            self.visible = visible
            self.originWindow = originWindow
            self.anchor = anchor
            self.width = width
            self.contentHeight = contentHeight
            self.remembered = remembered
        }
    }

    public static func height(content: CGFloat, visible: CGRect) -> CGFloat {
        let maxH = max(minHeight, visible.height * maxHeightFraction)
        return min(max(content, minHeight), maxH)
    }

    public static func frame(_ i: Input) -> CGRect {
        let w = min(max(i.width, widthRange.lowerBound), min(widthRange.upperBound, i.visible.width - 2 * gap))
        let h = height(content: i.contentHeight, visible: i.visible)
        if let r = i.remembered { return clamp(CGRect(x: r.x, y: r.y - h, width: w, height: h), to: i.visible) }

        var x = i.visible.maxX - gap - w
        if let win = i.originWindow, win.maxX + gap + w <= i.visible.maxX - gap {
            x = win.maxX + gap
        }
        let centreY = i.anchor?.y ?? i.originWindow?.midY ?? i.visible.midY
        return clamp(CGRect(x: x, y: centreY - h / 2, width: w, height: h), to: i.visible)
    }

    /// Keeps the frame inside the visible screen: 12 pt from the sides, 16 pt from top and bottom.
    public static func clamp(_ f: CGRect, to visible: CGRect) -> CGRect {
        var r = f
        r.origin.x = min(max(r.minX, visible.minX + gap), visible.maxX - gap - r.width)
        r.origin.y = min(max(r.minY, visible.minY + margin), visible.maxY - margin - r.height)
        return r
    }
}
