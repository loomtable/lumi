import BuddyCore
import CoreGraphics

/// What an answer is placed next to. Global points, top-left origin (the same space as
/// `ContextPacket` selection bounds and cursor).
nonisolated public enum Anchor: Sendable, Equatable {
    /// Selection or element bounds.
    case rect(CGRect)
    /// Pointer or text caret.
    case point(CGPoint)
    /// The research report: centred on the capsule's display, popping out of the capsule.
    case capsule

    public var rect: CGRect {
        switch self {
        case .rect(let r): r.standardized
        case .point(let p): CGRect(origin: p, size: .zero)
        case .capsule: .zero
        }
    }
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

/// Where answers go. One rule, pure, so it is unit-tested:
///
/// 1. **Display:** the one under the anchor, the selection when there is one, else the pointer
///    at the key press; only the anchor's part on that display counts. Everything stays
///    `edgeMargin` inside its visible frame.
/// 2. **Beside the anchor,** `gap` away: below it, else above, else to its trailing side, else
///    its leading side. Along that side the card centres on the anchor, sliding only as far as
///    keeps it on screen.
/// 3. **Reserved zones** (`reservedZones`) are never covered: the top centre (the pill, the
///    switcher strip that grows out of it, and the progress capsules), plus the bottom centre
///    when "Listening and status" is set to Bottom (the pill and its strip sit there). A spot
///    that would overlap one steps sideways past it, on the same side of the anchor.
/// 4. **Nothing fits:** the side with the most room, clamped onto the display and stepped out
///    of the zones (it may then cover the anchor; the height cap, `clearHeight`, always leaves
///    a spot clear of the zones).
/// 5. **Stable:** a conversation's later answers pass the first one's anchor and side as
///    `prefer`, so they appear where the first did (the controller keeps that spot; a drag
///    replaces it).
/// 6. **Centred** answers (rich answers, Centre mode, the research report) sit in the middle
///    of the band between the zones.
///
/// Heights are capped by the controller (`BuddyOverlayController.maxHeight`, within
/// `clearHeight`, so a spot clear of the zones always exists); content past the cap scrolls
/// inside the card.
nonisolated public enum Placer {
    public static let gap: CGFloat = 14
    public static let edgeMargin: CGFloat = 12
    /// Tail geometry, used to keep the tail clear of the rounded corners.
    public static let tailHalfWidth: CGFloat = 7
    /// Pill and toast offsets from the pointer.
    public static let pillOffset = CGSize(width: 20, height: 12)
    public static let textBoxOffset = CGSize(width: 16, height: 14)
    /// Toasts at +18, −30.
    public static let toastOffset = CGSize(width: 18, height: -30)

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

    // MARK: Reserved zones

    /// The top-centre zone: the research capsule, the status pill (up to its two-line headline
    /// width) and the progress stack under it (≤ 360 × ~120 pt, 3 rows), with room around them.
    public static let topZoneSize = CGSize(width: 520, height: 220)
    /// The pill's zone with its switcher strip open: the strip at its tallest (8 chips and New)
    /// with the pill's row as its header, from the display's edge.
    public static var switcherZoneSize: CGSize {
        CGSize(width: SwitcherGeometry.stripWidth + 2 * gap,
               height: edgeMargin + SwitcherGeometry.headerHeight + SwitcherGeometry.maxStripHeight + gap)
    }

    /// The zones answers keep clear of on a display whose visible frame is `bounds`, each centred
    /// and no wider than the display: the top centre (capsules, and the pill with its strip),
    /// and with `statusAtBottom` the pill and its strip at the bottom centre instead.
    public static func reservedZones(in bounds: CGRect, statusAtBottom: Bool = false) -> [CGRect] {
        func zone(_ size: CGSize, y: CGFloat) -> CGRect {
            let w = min(size.width, bounds.width)
            return CGRect(x: (bounds.midX - w / 2).rounded(), y: y, width: w, height: min(size.height, bounds.height / 2))
        }
        let strip = switcherZoneSize
        guard statusAtBottom else {
            let top = CGSize(width: max(topZoneSize.width, strip.width), height: max(topZoneSize.height, strip.height))
            return [zone(top, y: bounds.minY)]
        }
        return [zone(topZoneSize, y: bounds.minY), zone(strip, y: bounds.maxY - min(strip.height, bounds.height / 2))]
    }

    // MARK: Placing

    /// - Parameters:
    ///   - bounds: the usable area of the anchor's display (visible frame), global top-left.
    ///   - reserved: areas to keep clear of (`reservedZones(in:)`).
    ///   - prefer: the side to try first, so a conversation's answers stay on one side.
    public static func place(size: CGSize, anchor: Anchor, in bounds: CGRect, style: Style,
                             reserved: [CGRect] = [], prefer: PlacementEdge? = nil,
                             cornerRadius: CGFloat = Tokens.cardRadius) -> Placement {
        let area = bounds.insetBy(dx: edgeMargin, dy: edgeMargin)
        let size = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
        // Only the part of the anchor on this display counts: a selection scrolled partly out of
        // view points at what still shows.
        let a = anchor.rect.intersects(bounds) ? anchor.rect.intersection(bounds) : anchor.rect
        func clear(_ r: CGRect) -> Bool { area.contains(r) && !reserved.contains { $0.intersects(r) } }

        if style == .centered {
            let band = centredBand(area, reserved: reserved, height: size.height)
            let frame = CGRect(x: band.midX - size.width / 2, y: band.midY - size.height / 2,
                               width: size.width, height: size.height).integral
            return Placement(frame: frame, edge: .centered, tailOffset: nil, avoidsAnchor: !frame.intersects(a))
        }
        let order: [PlacementEdge] = [.below, .above, .trailing, .leading]
        let edges = prefer.map { p in [p] + order.filter { $0 != p } } ?? order
        for edge in edges {
            let slid = slideAlongEdge(candidate(edge, size: size, anchor: a), edge: edge, in: area)
            let along: Axis = edge == .below || edge == .above ? .horizontal : .vertical
            if let spot = ([slid] + stepsOut(of: reserved, from: slid, along: [along])).first(where: clear) {
                return finish(spot, edge: edge, anchor: a, style: style, cornerRadius: cornerRadius, avoids: true)
            }
        }
        // Nothing fits cleanly: take the side with the most room, clamp into the display, and
        // step out of the zones on either axis.
        let room: [(PlacementEdge, CGFloat)] = [
            (.below, area.maxY - a.maxY), (.above, a.minY - area.minY),
            (.trailing, area.maxX - a.maxX), (.leading, a.minX - area.minX),
        ]
        let edge = room.max { $0.1 < $1.1 }!.0
        let clamped = clamp(candidate(edge, size: size, anchor: a), in: area)
        let spot = ([clamped] + stepsOut(of: reserved, from: clamped, along: [.horizontal, .vertical])).first(where: clear)
            ?? clamped
        return finish(spot, edge: edge, anchor: a, style: style, cornerRadius: cornerRadius, avoids: !spot.intersects(a))
    }

    /// The frame on `edge` of the anchor, centred on it along that edge.
    static func candidate(_ edge: PlacementEdge, size: CGSize, anchor a: CGRect) -> CGRect {
        switch edge {
        case .below: CGRect(x: a.midX - size.width / 2, y: a.maxY + gap, width: size.width, height: size.height)
        case .above: CGRect(x: a.midX - size.width / 2, y: a.minY - gap - size.height, width: size.width, height: size.height)
        case .trailing: CGRect(x: a.maxX + gap, y: a.midY - size.height / 2, width: size.width, height: size.height)
        case .leading: CGRect(x: a.minX - gap - size.width, y: a.midY - size.height / 2, width: size.width, height: size.height)
        case .centered: CGRect(x: a.midX - size.width / 2, y: a.midY - size.height / 2, width: size.width, height: size.height)
        }
    }

    enum Axis { case horizontal, vertical }

    /// `r` moved just past each zone it overlaps (`gap` clear), along `axes`, nearest first.
    static func stepsOut(of zones: [CGRect], from r: CGRect, along axes: [Axis]) -> [CGRect] {
        var out: [CGRect] = []
        for z in zones where z.intersects(r) {
            if axes.contains(.horizontal) {
                out.append(r.offsetBy(dx: z.minX - gap - r.maxX, dy: 0))
                out.append(r.offsetBy(dx: z.maxX + gap - r.minX, dy: 0))
            }
            if axes.contains(.vertical) {
                out.append(r.offsetBy(dx: 0, dy: z.minY - gap - r.maxY))
                out.append(r.offsetBy(dx: 0, dy: z.maxY + gap - r.minY))
            }
        }
        func shift(_ c: CGRect) -> CGFloat { abs(c.minX - r.minX) + abs(c.minY - r.minY) }
        return out.sorted { shift($0) < shift($1) }
    }

    /// The part of `area` between the zones that span its centre, for centred answers; the
    /// whole area when an answer of `height` wouldn't fit between them.
    static func centredBand(_ area: CGRect, reserved: [CGRect], height: CGFloat) -> CGRect {
        let top = reserved.filter { $0.midY < area.midY && $0.minX < area.midX && $0.maxX > area.midX }
            .map { $0.maxY + gap }.max() ?? area.minY
        let bottom = reserved.filter { $0.midY >= area.midY && $0.minX < area.midX && $0.maxX > area.midX }
            .map { $0.minY - gap }.min() ?? area.maxY
        let band = CGRect(x: area.minX, y: max(area.minY, top), width: area.width, height: min(area.maxY, bottom) - max(area.minY, top))
        return band.height >= height ? band : area
    }

    /// The tallest an answer `width` wide can be and still have a spot clear of the zones: the
    /// display's height when it fits in the margin beside them, else the band between them.
    public static func clearHeight(width: CGFloat, in bounds: CGRect, statusAtBottom: Bool = false) -> CGFloat {
        let area = bounds.insetBy(dx: edgeMargin, dy: edgeMargin)
        let zones = reservedZones(in: bounds, statusAtBottom: statusAtBottom)
        let beside = (area.width - (zones.map(\.width).max() ?? 0)) / 2
        return width + gap <= beside ? area.height : centredBand(area, reserved: zones, height: 0).height
    }

    /// The pill's frame: pointer + (20, 12), kept on the display.
    public static func pillFrame(size: CGSize, pointer: CGPoint, in bounds: CGRect,
                                 offset: CGSize = pillOffset) -> CGRect {
        let raw = CGRect(x: pointer.x + offset.width, y: pointer.y + offset.height,
                         width: size.width, height: size.height)
        return clamp(raw, in: bounds.insetBy(dx: edgeMargin, dy: edgeMargin))
    }

    /// A remembered spot (a recalled answer's, or where the user dragged one) for an answer of
    /// `size`: kept on the display and stepped out of the zones, as every placement is
    /// (65-SURFACE-RULES, rule 3). Nil when no clear spot is near it: it's placed afresh.
    public static func keep(_ origin: CGPoint, size: CGSize, in bounds: CGRect, reserved: [CGRect]) -> CGRect? {
        let area = bounds.insetBy(dx: edgeMargin, dy: edgeMargin)
        let r = clamp(CGRect(origin: origin, size: size), in: area)
        return ([r] + stepsOut(of: reserved, from: r, along: [.horizontal, .vertical]))
            .first { area.contains($0) && !reserved.contains(where: $0.intersects) }
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
        if style == .card, avoids {
            // The tail points at the anchor's centre, kept clear of the rounded corners. Only
            // when that centre faces the card's edge (or the margin a slide along a display edge
            // leaves): a card stepped aside from a zone has no tail.
            let lo = cornerRadius + tailHalfWidth
            let (offset, length): (CGFloat, CGFloat) = switch edge {
            case .below, .above: (a.midX - frame.minX, frame.width)
            case .trailing, .leading: (a.midY - frame.minY, frame.height)
            case .centered: (-.infinity, 0)
            }
            if offset >= -gap, offset <= length + gap { tail = min(max(offset, lo), length - lo) }
        }
        return Placement(frame: frame, edge: edge, tailOffset: tail, avoidsAnchor: avoids)
    }
}
