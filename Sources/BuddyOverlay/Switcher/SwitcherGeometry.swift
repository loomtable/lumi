import CoreGraphics

/// Where the switcher's pieces go, in AppKit screen coordinates (origin bottom-left). Pure, so
/// placement is tested without windows.
///
/// The strip grows out of the listening pill (63-SWITCHER-UX, owner Oct 29): the pill's row is
/// its header, then a grid of agent chips, three across, in strip order with "New session" in the
/// cell after the last (up to 8 sessions, so never more than 3 rows and never a "+N"), then a
/// footer with the keys and the count line. With the pill at the bottom the header goes under.
/// The peek opens beside its chip.
nonisolated enum SwitcherGeometry {
    // Strip (agentlook, Oct 29: denser chips that show each title in full).
    static let columns = 3
    static let chipWidth: CGFloat = 196
    static let chipHeight: CGFloat = 48
    static let chipRadius: CGFloat = 13
    static let gap: CGFloat = 4
    static let paddingX: CGFloat = 10
    static let paddingY: CGFloat = 8
    /// The footer under the chips: the key hints and the count line.
    static let footerHeight: CGFloat = 30
    /// The agent mark on a chip, and how much the selected one grows.
    static let markSize: CGFloat = 34
    static let selectedScale: CGFloat = 1.08
    static let stripRadius: CGFloat = 24
    /// The origin app's icon, at the mark's 4:30.
    static let badgeSize: CGFloat = 14
    static let screenMargin: CGFloat = 16
    /// The header row around the pill: the pill's own height plus this above and below.
    static let headerInset: CGFloat = 6
    /// The listening pill's height (`PillContent`: 28 + its 4 pt rim, twice).
    static let pillHeight: CGFloat = 36
    static let headerHeight: CGFloat = pillHeight + 2 * headerInset
    // Peek.
    static let peekWidth: CGFloat = 300
    static let peekGap: CGFloat = 12

    // MARK: Strip

    /// Every strip is three chips wide, so it never jumps as sessions come and go.
    static let stripWidth: CGFloat = 2 * paddingX + CGFloat(columns) * chipWidth + CGFloat(columns - 1) * gap

    /// Rows for `sessions` chips plus "New session".
    static func rows(sessions: Int) -> Int { (sessions + 1 + columns - 1) / columns }

    /// The chips and the footer, without the header.
    static func stripHeight(sessions: Int) -> CGFloat {
        let r = CGFloat(rows(sessions: sessions))
        return paddingY + r * chipHeight + (r - 1) * gap + footerHeight
    }

    /// The tallest strip (8 sessions and New: 3 rows), which cards keep clear of.
    static let maxStripHeight = stripHeight(sessions: 8)

    /// Without a pill: centred at the top of `screen` (the visible frame), no header.
    static func stripFrame(sessions: Int, in screen: CGRect) -> CGRect {
        let w = min(stripWidth, screen.width - 2 * screenMargin)
        let h = stripHeight(sessions: sessions)
        return CGRect(x: (screen.midX - w / 2).rounded(), y: screen.maxY - screenMargin - h, width: w, height: h)
    }

    /// The plate around the pill (AppKit screen coordinates): centred on it, as wide as the chips
    /// (or the pill, if wider), with the pill's row as its header, on top (the chips grow down)
    /// or, for a pill at the bottom, underneath (the chips grow up).
    static func plateFrame(around pill: CGRect, sessions: Int, atBottom: Bool, in screen: CGRect) -> CGRect {
        let header = pill.height + 2 * headerInset
        let w = min(max(stripWidth, pill.width + 2 * paddingX), screen.width - 2 * screenMargin)
        let h = header + stripHeight(sessions: sessions)
        let x = clamp(pill.midX - w / 2, screen.minX + screenMargin, screen.maxX - screenMargin - w)
        let y = atBottom ? pill.minY - headerInset : pill.maxY + headerInset - h
        return CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }

    /// The `index`-th cell inside the strip (top-left origin, as SwiftUI lays it out): sessions in
    /// strip order, then "New session" at `index == count`.
    static func tileFrame(_ index: Int) -> CGRect {
        let col = CGFloat(index % columns), row = CGFloat(index / columns)
        return CGRect(x: paddingX + col * (chipWidth + gap), y: paddingY + row * (chipHeight + gap),
                      width: chipWidth, height: chipHeight)
    }

    // MARK: Peek

    /// Above `anchor` (a tile, screen coordinates), centred on it; below it when there
    /// is no room above. Clamped to `screen` with the margin.
    static func peekFrame(size: CGSize, anchor: CGRect, screen: CGRect) -> CGRect {
        var y = anchor.maxY + peekGap
        if y + size.height > screen.maxY - screenMargin { y = anchor.minY - peekGap - size.height }
        let x = clamp(anchor.midX - size.width / 2, screen.minX + screenMargin, screen.maxX - screenMargin - size.width)
        y = clamp(y, screen.minY + screenMargin, screen.maxY - screenMargin - size.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(v, max(lo, hi))) }
}
