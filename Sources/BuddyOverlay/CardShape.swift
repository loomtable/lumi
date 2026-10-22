import SwiftUI

/// A rounded rectangle with an optional tail pointing at the anchor (cards have a
/// tail, chips don't). The tail sits in a band of `tailLength` on the facing side, so the
/// view's frame includes it.
nonisolated struct CardShape: InsettableShape {
    enum Side: Equatable { case top, bottom, left, right }

    var cornerRadius: CGFloat
    var tailSide: Side?
    /// Along the facing edge, from the body's top-left corner.
    var tailOffset: CGFloat = 0
    var inset: CGFloat = 0

    static let tailLength: CGFloat = 7
    static let tailHalfWidth: CGFloat = Placer.tailHalfWidth

    /// The tail goes on the side of the card that faces the anchor.
    static func side(for edge: PlacementEdge) -> Side? {
        switch edge {
        case .below: .top
        case .above: .bottom
        case .trailing: .left
        case .leading: .right
        case .centered: nil
        }
    }

    /// The card body inside a frame that includes the tail band.
    static func body(in rect: CGRect, side: Side?) -> CGRect {
        var r = rect
        switch side {
        case .top: r.origin.y += tailLength; r.size.height -= tailLength
        case .bottom: r.size.height -= tailLength
        case .left: r.origin.x += tailLength; r.size.width -= tailLength
        case .right: r.size.width -= tailLength
        case nil: break
        }
        return r
    }

    func path(in rect: CGRect) -> Path {
        let body = Self.body(in: rect, side: tailSide).insetBy(dx: inset, dy: inset)
        var path = Path(roundedRect: body, cornerRadius: max(0, cornerRadius - inset), style: .continuous)
        guard let side = tailSide else { return path }
        let half = max(0, Self.tailHalfWidth - inset)
        let reach = Self.tailLength
        var tail = Path()
        switch side {
        case .top, .bottom:
            let x = body.minX - inset + tailOffset
            let base = side == .top ? body.minY : body.maxY
            let tip = side == .top ? base - reach : base + reach
            // Overlap the body by 1 pt so the union has no seam.
            let baseIn = side == .top ? base + 1 : base - 1
            tail.move(to: CGPoint(x: x - half, y: baseIn))
            tail.addLine(to: CGPoint(x: x, y: tip))
            tail.addLine(to: CGPoint(x: x + half, y: baseIn))
        case .left, .right:
            let y = body.minY - inset + tailOffset
            let base = side == .left ? body.minX : body.maxX
            let tip = side == .left ? base - reach : base + reach
            let baseIn = side == .left ? base + 1 : base - 1
            tail.move(to: CGPoint(x: baseIn, y: y - half))
            tail.addLine(to: CGPoint(x: tip, y: y))
            tail.addLine(to: CGPoint(x: baseIn, y: y + half))
        }
        tail.closeSubpath()
        path = path.union(tail)
        return path
    }

    func inset(by amount: CGFloat) -> CardShape {
        var s = self
        s.inset += amount
        return s
    }
}
