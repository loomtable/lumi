import BuddyCore
import CoreGraphics

/// What an answer is placed next to. Global points, top-left origin (the same space as
/// `ContextPacket` selection bounds and cursor).
nonisolated public enum Anchor: Sendable, Equatable {
    /// Selection or element bounds.
    case rect(CGRect)
    /// Pointer or text caret.
    case point(CGPoint)
    /// A whole-page answer with nothing specific to point at (e.g. a summary of what's
    /// visible). The point picks the display; Smart placement takes its emptiest region.
    case page(CGPoint)
    /// The research report: centred on the capsule's display, popping out of the capsule.
    case capsule

    public var rect: CGRect {
        switch self {
        case .rect(let r): r.standardized
        case .point(let p), .page(let p): CGRect(origin: p, size: .zero)
        case .capsule: .zero
        }
    }

    public var isPage: Bool { if case .page = self { true } else { false } }
}

nonisolated public enum PlacementEdge: String, Sendable, Equatable {
    /// The surface sits below the anchor, above it, or to its trailing/leading side.
    case below, above, trailing, leading
    /// Centred on the display (rich answers).
    case centered
}

nonisolated public struct Placement: Sendable, Equatable {
    /// Global points, top-left origin.
    public var frame: CGRect
    public var edge: PlacementEdge
    /// Where the tail meets the surface edge facing the anchor, measured along that edge
    /// from the frame's leading (or top) corner. Nil for chips and centred surfaces.
    public var tailOffset: CGFloat?
    /// False when no candidate fitted and the surface was clamped onto the anchor.
    public var avoidsAnchor: Bool
}

/// Placement rules: below, then above, then to the side; 14 pt from
/// the anchor; 12 pt from the display edges. Pure, so it is unit-tested.
nonisolated public enum Placer {
    public static let gap: CGFloat = 14
    public static let edgeMargin: CGFloat = 12
    /// Tail geometry, used to keep the tail clear of the rounded corners.
    public static let tailHalfWidth: CGFloat = 7
    /// Pill and toast offsets from the pointer.
    public static let pillOffset = CGSize(width: 20, height: 12)
    public static let textBoxOffset = CGSize(width: 16, height: 14)
    /// Toasts at +18, −30; the ↩ Back chip at +18, +8.
    public static let toastOffset = CGSize(width: 18, height: -30)
    public static let backChipOffset = CGSize(width: 18, height: 8)

    /// Settings › Appearance › Placement.
    public enum Mode: String, Sendable, Equatable, CaseIterable {
        /// Chips and cards next to the anchor, rich answers centred.
        case smart
        /// Everything next to the anchor.
        case nextToIt
        /// Cards and rich answers centred. Chips always stay next to the anchor.
        case centre
    }

    /// How an answer of `shape` is placed under `mode`.
    public static func style(for shape: BuddyBlock.Shape, mode: Mode) -> Style {
        switch (shape, mode) {
        case (.chip, _): .chip
        case (.card, .centre), (.rich, .smart), (.rich, .centre): .centered
        case (.card, _), (.rich, .nextToIt): .card
        }
    }

    /// Full screen: about 94% × 90% of the display, centred. Measured from the
    /// visible frame (below the menu bar and clear of the Dock), so it never sits under them.
    public static func fullScreenFrame(in bounds: CGRect) -> CGRect {
        let size = CGSize(width: (bounds.width * 0.94).rounded(), height: (bounds.height * 0.90).rounded())
        return CGRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    public enum Style: Sendable, Equatable {
        /// Card: next to the anchor, with a tail.
        case card
        /// Chip: next to the anchor, no tail.
        case chip
        /// Rich: centred on the display.
        case centered
    }

    /// - Parameters:
    ///   - bounds: the usable area of the anchor's display (visible frame), global top-left.
    public static func place(size: CGSize, anchor: Anchor, in bounds: CGRect, style: Style,
                             cornerRadius: CGFloat = Tokens.cardRadius) -> Placement {
        let area = bounds.insetBy(dx: edgeMargin, dy: edgeMargin)
        let size = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
        if style == .centered {
            let frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height).integral
            return Placement(frame: frame, edge: .centered, tailOffset: nil, avoidsAnchor: !frame.intersects(anchor.rect))
        }
        let a = anchor.rect
        let candidates: [(PlacementEdge, CGRect)] = [
            (.below, CGRect(x: a.midX - size.width / 2, y: a.maxY + gap, width: size.width, height: size.height)),
            (.above, CGRect(x: a.midX - size.width / 2, y: a.minY - gap - size.height, width: size.width, height: size.height)),
            (.trailing, CGRect(x: a.maxX + gap, y: a.midY - size.height / 2, width: size.width, height: size.height)),
            (.leading, CGRect(x: a.minX - gap - size.width, y: a.midY - size.height / 2, width: size.width, height: size.height)),
        ]
        for (edge, raw) in candidates {
            let slid = slideAlongEdge(raw, edge: edge, in: area)
            if area.contains(slid) {
                return finish(slid, edge: edge, anchor: a, style: style, cornerRadius: cornerRadius, avoids: true)
            }
        }
        // Nothing fits cleanly: take the side with the most room and clamp into the display.
        let room: [(PlacementEdge, CGFloat)] = [
            (.below, area.maxY - a.maxY), (.above, a.minY - area.minY),
            (.trailing, area.maxX - a.maxX), (.leading, a.minX - area.minX),
        ]
        let edge = room.max { $0.1 < $1.1 }!.0
        let raw = candidates.first { $0.0 == edge }!.1
        let clamped = clamp(raw, in: area)
        return finish(clamped, edge: edge, anchor: a, style: style, cornerRadius: cornerRadius,
                      avoids: !clamped.intersects(a))
    }

    /// The pill's frame: pointer + (20, 12), kept on the display.
    public static func pillFrame(size: CGSize, pointer: CGPoint, in bounds: CGRect,
                                 offset: CGSize = pillOffset) -> CGRect {
        let raw = CGRect(x: pointer.x + offset.width, y: pointer.y + offset.height,
                         width: size.width, height: size.height)
        return clamp(raw, in: bounds.insetBy(dx: edgeMargin, dy: edgeMargin))
    }

    static func slideAlongEdge(_ r: CGRect, edge: PlacementEdge, in area: CGRect) -> CGRect {
        var r = r
        switch edge {
        case .below, .above:
            r.origin.x = min(max(r.minX, area.minX), area.maxX - r.width)
        case .trailing, .leading:
            r.origin.y = min(max(r.minY, area.minY), area.maxY - r.height)
        case .centered:
            break
        }
        return r
    }

    static func clamp(_ r: CGRect, in area: CGRect) -> CGRect {
        var r = r
        r.origin.x = min(max(r.minX, area.minX), max(area.minX, area.maxX - r.width))
        r.origin.y = min(max(r.minY, area.minY), max(area.minY, area.maxY - r.height))
        return r
    }

    static func finish(_ frame: CGRect, edge: PlacementEdge, anchor a: CGRect, style: Style,
                       cornerRadius: CGFloat, avoids: Bool) -> Placement {
        let frame = frame.integral
        var tail: CGFloat?
        if style == .card {
            let lo = cornerRadius + tailHalfWidth
            switch edge {
            case .below, .above:
                tail = min(max(a.midX - frame.minX, lo), frame.width - lo)
            case .trailing, .leading:
                tail = min(max(a.midY - frame.minY, lo), frame.height - lo)
            case .centered:
                tail = nil
            }
            // A tail only makes sense when the surface really sits beside the anchor.
            if !avoids { tail = nil }
        }
        return Placement(frame: frame, edge: edge, tailOffset: tail, avoidsAnchor: avoids)
    }
}
