import CoreGraphics

/// Plausibility checks for a selection rect in AX global coordinates. Chromium
/// and Electron often answer `AXBoundsForRange` with the whole element's frame or a zero-origin
/// rect instead of failing, so success with a CGRect is not enough.
enum BoundsCheck {
    static let equalTolerance: CGFloat = 1
    static let containmentSlack: CGFloat = 2

    /// Nil if `rect` can anchor UI next to the selection, otherwise why not.
    static func rejectionReason(_ rect: CGRect, elementFrame: CGRect?) -> String? {
        let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
        guard values.allSatisfy(\.isFinite) else { return "non-finite" }
        if rect.size.width <= 0 || rect.size.height <= 0 { return "empty" }
        if rect.origin == .zero { return "at origin" }
        guard let el = elementFrame, el.width > 0, el.height > 0 else { return nil }
        if abs(rect.minX - el.minX) <= equalTolerance, abs(rect.minY - el.minY) <= equalTolerance,
           abs(rect.maxX - el.maxX) <= equalTolerance, abs(rect.maxY - el.maxY) <= equalTolerance {
            return "whole element"
        }
        let s = containmentSlack
        let inside = rect.minX >= el.minX - s && rect.maxX <= el.maxX + s
            && rect.minY >= el.minY - s && rect.maxY <= el.maxY + s
        return inside ? nil : "outside element"
    }
}
