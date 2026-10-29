import Testing
@testable import BuddyOverlay

/// The Lumi window's surfaces (polish, round 3; every theme, 67-THEMES.md): every text token reads
/// on the window background, on a card and on the inspector's tabs, in light, dark and Increase
/// Contrast; the quiet card outline turns into the full hairline with Increase Contrast. Computed,
/// not eyeballed.
struct WindowSurfaceTokenTests {
    nonisolated static let variants: [Tokens.Variant] = Theme.allCases.flatMap { theme in
        [false, true].flatMap { dark in
            [Tokens.Variant(dark: dark, theme: theme), .init(dark: dark, theme: theme, reduceTransparency: true),
             .init(dark: dark, theme: theme, increaseContrast: true)]
        }
    }

    /// What a translucent (Liquid Glass) surface sits on: `Material.regular` or Regular glass,
    /// estimated conservatively as the appearance's material base covering 60% of a pure white or
    /// pure black backdrop. Opaque surfaces don't need one.
    static func materials(_ t: Tokens) -> [TokenColor] {
        let base = t.variant.dark ? TokenColor(hex: 0x1E1E1E, alpha: 0.6) : TokenColor(hex: 0xF2F2F2, alpha: 0.6)
        return [TokenColor(1, 1, 1), TokenColor(0, 0, 0)].map { SwitcherSurface.over(base, $0) }
    }

    /// Where overlay text sits, over the worst backdrops: the glass's veil (its tint) over the
    /// material in Liquid Glass, else the opaque well.
    static func readingSurfaces(_ t: Tokens) -> [TokenColor] {
        t.onGlass ? materials(t).map { SwitcherSurface.over(t.glassTint, $0) } : [t.well.opacity(1)]
    }

    static func texts(_ t: Tokens) -> [(String, TokenColor)] {
        [("text", t.text), ("secondary", t.secondaryText), ("emberText", t.emberText), ("sage", t.sage),
         ("amber", t.amber), ("rose", t.rose), ("mist", t.mist)]
    }

    /// Every surface holds 4.5:1; glass ones over the material's worst case (the window over the
    /// material, a card over the window).
    @Test(arguments: variants)
    func textReadsOnTheWindowAndCards(_ v: Tokens.Variant) {
        let t = Tokens(v)
        let glass = t.windowBackground.alpha < 1
        #expect(glass == (v.theme.isGlass && !v.reduceTransparency && !v.increaseContrast), "only Liquid Glass is translucent, \(v)")
        #expect((t.panel.alpha < 1) == glass)
        for material in glass ? Self.materials(t) : [TokenColor(0, 0, 0)] {
            let window = SwitcherSurface.over(t.windowBackground, material)
            let panel = SwitcherSurface.over(t.panel, window)
            for (sName, s) in [("windowBackground", window), ("panel", panel)] {
                for (name, c) in Self.texts(t) {
                    #expect(SwitcherSurface.contrast(c, s) >= 4.5, "\(name) on \(sName), \(v)")
                }
            }
        }
    }

    /// Liquid Glass: the overlay's text sits straight on the glass (clear wells), legible through
    /// the glass's veil alone, plain text and the faint neutral pill alike. Every other theme and
    /// Reduce Transparency or Increase Contrast keep a well.
    @Test(arguments: variants)
    func textReadsStraightOnGlass(_ v: Tokens.Variant) {
        let t = Tokens(v)
        #expect(t.onGlass == (v.theme.isGlass && !v.reduceTransparency && !v.increaseContrast), "\(v)")
        #expect((t.well.alpha == 0) == t.onGlass, "\(v)")
        for surface in Self.readingSurfaces(t) {
            let pill = SwitcherSurface.over(t.text.opacity(0.07), surface)
            for (name, c) in Self.texts(t) {
                #expect(SwitcherSurface.contrast(c, surface) >= 4.5, "\(name) on the glass, \(v)")
            }
            #expect(SwitcherSurface.contrast(t.text, pill) >= 4.5 && SwitcherSurface.contrast(t.secondaryText, pill) >= 4.5, "\(v)")
        }
    }

    /// The inspector's tabs (on the opaque well; the window's veil in Liquid Glass): the selected
    /// one's faint fill under text, the others in secondary.
    @Test(arguments: variants)
    func inspectorTabsRead(_ v: Tokens.Variant) {
        let t = Tokens(v)
        let surfaces = t.onGlass ? Self.materials(t).map { SwitcherSurface.over(t.windowBackground, $0) } : [t.well.opacity(1)]
        for well in surfaces {
            #expect(SwitcherSurface.contrast(t.text, SwitcherSurface.over(t.text.opacity(0.08), well)) >= 4.5)
            #expect(SwitcherSurface.contrast(t.secondaryText, well) >= 4.5)
        }
    }

    /// Text on the ember pill (Allow, Start, Continue), and on the faint plain pill over a card.
    @Test(arguments: variants)
    func pillsKeepTheirTextReadable(_ v: Tokens.Variant) {
        let t = Tokens(v)
        #expect(SwitcherSurface.contrast(t.onEmber, t.emberMark) >= 4.5)
        let plain = SwitcherSurface.over(t.text.opacity(0.11), t.panel)
        #expect(SwitcherSurface.contrast(t.text, plain) >= 4.5)
    }

    /// The sidebar's selected row: the system's white text on the deep ember.
    @Test(arguments: Theme.allCases)
    func whiteReadsOnTheDeepEmberSelection(_ theme: Theme) {
        for dark in [false, true] {
            #expect(SwitcherSurface.contrast(TokenColor(1, 1, 1), Tokens(.init(dark: dark, theme: theme)).emberDeep) >= 4.5)
        }
    }

    @Test(arguments: Theme.allCases)
    func increaseContrastUsesTheFullHairline(_ theme: Theme) {
        for dark in [false, true] {
            let ic = Tokens(.init(dark: dark, theme: theme, increaseContrast: true))
            #expect(ic.cardHairline == ic.hairline)
            let plain = Tokens(.init(dark: dark, theme: theme))
            #expect(plain.cardHairline.alpha < plain.hairline.alpha)
            // Increase Contrast outlines hold 3:1 against the window (non-text contrast).
            let edge = SwitcherSurface.over(ic.hairline, ic.windowBackground)
            #expect(SwitcherSurface.contrast(edge, ic.windowBackground) >= 3, "\(theme) \(dark)")
        }
    }
}
