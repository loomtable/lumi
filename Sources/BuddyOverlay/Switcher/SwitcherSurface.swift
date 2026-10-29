import BuddyCore
import SwiftUI

/// The colours the switcher's text and rings sit on and use, in one place so views and the
/// contrast test agree (QA U4, 04 §7.1: text over glass sits on a reading well).
///
/// The strip, its hint row, the peek and the "+N" capsule put their text on the
/// `well` token drawn fully opaque, glass only on the rim. At the token's 94%, light-mode sage
/// over a black backdrop computes to 4.45:1; opaque, every pair below is ≥ 4.5:1 for text and
/// ≥ 3:1 for rings in light and dark, over any backdrop. In Liquid Glass the text sits on the
/// glass itself (`Tokens.onGlass`), whose tint is the veil.
nonisolated enum SwitcherSurface {
    /// The reading well under every switcher text: opaque, or clear in Liquid Glass.
    static func well(_ t: Tokens) -> TokenColor { t.onGlass ? t.well : t.well.opacity(1) }

    /// Neutral fills and strokes (selection, keycaps, tracks): the text colour, faint.
    static func neutral(_ t: Tokens, _ alpha: Double) -> TokenColor { t.text.opacity(alpha) }

    /// The selected tile's fill: ember, faint. Light mode stays fainter than the shared
    /// `selection` token, which would take light sage under 4.5:1. On glass any ember fill takes
    /// text under 4.5:1 over the thin veil, so the tile is a denser patch of the veil instead and
    /// the ember edge marks it.
    static func selection(_ t: Tokens) -> TokenColor {
        if t.onGlass { return t.well.opacity(0.3) }
        return t.variant.dark ? t.selection : t.emberMark.opacity(0.07)
    }

    /// The selected tile's ember edge (full with Increase Contrast) and its glow.
    static func selectionEdge(_ t: Tokens) -> TokenColor { t.emberMark.opacity(t.variant.increaseContrast ? 1 : 0.75) }
    static func selectionGlow(_ t: Tokens) -> TokenColor { t.emberMark.opacity(t.variant.dark ? 0.35 : 0.25) }

    static func mix(_ a: TokenColor, _ b: TokenColor, _ t: Double) -> TokenColor {
        TokenColor(a.red + (b.red - a.red) * t, a.green + (b.green - a.green) * t, a.blue + (b.blue - a.blue) * t, a.alpha)
    }

    /// Every colour switcher text is drawn in (titles, status words, hints, "+N").
    static func textColors(_ t: Tokens) -> [(name: String, color: TokenColor)] {
        [("text", t.text), ("secondary", t.secondaryText), ("ember", t.emberText), ("sage", t.sage),
         ("amber", t.amber), ("rose", t.rose)]
    }

    /// The state rings and the unread dot.
    static func ringColors(_ t: Tokens) -> [(name: String, color: TokenColor)] {
        [("ember", t.emberMark), ("amber", t.amber), ("rose", t.rose)]
    }

    // MARK: Contrast (WCAG 2)

    /// `fg` composited over `bg` (both sRGB, `bg` opaque).
    static func over(_ fg: TokenColor, _ bg: TokenColor) -> TokenColor {
        let a = fg.alpha
        return TokenColor(fg.red * a + bg.red * (1 - a), fg.green * a + bg.green * (1 - a), fg.blue * a + bg.blue * (1 - a))
    }

    static func luminance(_ c: TokenColor) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
    }

    static func contrast(_ a: TokenColor, _ b: TokenColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

extension View {
    /// The switcher's reading well inside `shape`'s glass rim.
    func switcherWell<S: InsettableShape>(_ shape: S, t: Tokens) -> some View {
        background(shape.inset(by: Tokens.rimInset).fill(SwitcherSurface.well(t).color))
    }
}
