import AppKit
import BuddyCore
import SwiftUI

/// An sRGB colour with alpha, kept as plain numbers so tokens are comparable in tests.
nonisolated public struct TokenColor: Sendable, Equatable, CustomStringConvertible {
    public var red, green, blue, alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
    }

    /// `0xRRGGBB` plus alpha.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double(hex >> 16 & 0xFF) / 255, Double(hex >> 8 & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    public func opacity(_ alpha: Double) -> TokenColor { TokenColor(red, green, blue, alpha) }

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    public var description: String {
        let hex = [red, green, blue].map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
        return "#\(hex)@\(alpha)"
    }
}

/// Lantern Ink tokens (are the source of truth). One value per surface
/// and colour, resolved for the theme, the Mac's appearance and accessibility display options.
nonisolated public struct Tokens: Sendable, Equatable {
    public struct Variant: Sendable, Equatable {
        /// The Mac's (or the glass's) appearance; a theme with a fixed look overrides it in `Tokens`.
        public var dark: Bool
        public var theme: Theme
        public var reduceTransparency: Bool
        public var increaseContrast: Bool

        public init(dark: Bool, theme: Theme = .system, reduceTransparency: Bool = false, increaseContrast: Bool = false) {
            self.dark = dark
            self.theme = theme
            self.reduceTransparency = reduceTransparency
            self.increaseContrast = increaseContrast
        }

        /// The current system settings. `dark` comes from the given appearance.
        public static func current(appearance: NSAppearance, theme: Theme = .system) -> Variant {
            let ws = NSWorkspace.shared
            return Variant(
                dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, theme: theme,
                reduceTransparency: ws.accessibilityDisplayShouldReduceTransparency,
                increaseContrast: ws.accessibilityDisplayShouldIncreaseContrast)
        }
    }

    public let variant: Variant

    /// The reading well under all text: 94% opaque, clear in Liquid Glass (`onGlass`), fully
    /// opaque with Reduce Transparency or Increase Contrast.
    public let well: TokenColor
    /// Tint for Regular glass. In Liquid Glass it is the legibility veil (the well's colour, 36%
    /// light, 48% dark). With Reduce Transparency, surfaces are opaque instead.
    public let glassTint: TokenColor
    /// Opaque surface used instead of glass when Reduce Transparency is on.
    public let opaqueSurface: TokenColor
    public let innerHighlight: TokenColor
    /// Outer hairline over a normal backdrop, and over a bright one (above 0.70 luminance).
    public let hairline: TokenColor
    public let hairlineBright: TokenColor
    public let text: TokenColor
    public let secondaryText: TokenColor
    public let emberText: TokenColor
    public let emberMark: TokenColor
    public let sage: TokenColor
    public let amber: TokenColor
    public let rose: TokenColor
    public let mist: TokenColor
    /// Text on solid ember buttons and the Deep/Research mode chip.
    public let onEmber: TokenColor
    /// Glow and halo shadow colour (ember).
    public let shadow: TokenColor

    // The Lumi window's content (04 §7.1, the canvas boards): opaque, never glass.
    /// The window's content background: Home, a session's column, Settings pages.
    public let windowBackground: TokenColor
    /// Cards and grouped sections on the window background (Home's cards, Settings sections, the inspector).
    public let panel: TokenColor
    /// The quiet outline of a card or section on the window background. Full hairline with Increase Contrast.
    public let cardHairline: TokenColor
    /// Solid ember behind white text (the sidebar's selected row, which the system draws with
    /// white text): deep enough for 4.5:1, unlike the bright mark.
    public let emberDeep: TokenColor
    /// A soft top-down tint on the window background and the card (the future themes); clear elsewhere.
    public let wash: TokenColor

    /// Glass is replaced by `opaqueSurface` when this is false.
    public var usesGlass: Bool { !variant.reduceTransparency }
    /// Liquid Glass (67-THEMES.md): text sits straight on Regular glass. The reading wells are clear
    /// and the glass's tint is the veil, so each surface is one piece of glass, edge to edge.
    /// False with Reduce Transparency or Increase Contrast, where every surface is solid.
    public let onGlass: Bool

    public init(_ v: Variant) {
        let p = Palette(v.theme, dark: v.theme.forcedDark ?? v.dark)
        var resolved = v
        resolved.dark = p.dark
        variant = resolved
        let ic = v.increaseContrast
        // Solid with Reduce Transparency or Increase Contrast; Liquid Glass clears what can stay legible.
        let solid = v.reduceTransparency || ic
        let glass = v.theme.isGlass && !solid
        onGlass = glass
        // Liquid Glass's veil over the material: the least that keeps every text 4.5:1 over a
        // pure white or black backdrop (WindowSurfaceTokenTests models the material).
        let veil = p.dark ? 0.48 : 0.36
        well = p.well.opacity(solid ? 1 : glass ? 0 : 0.94)
        glassTint = glass ? p.well.opacity(veil) : p.glassTint
        opaqueSurface = p.opaqueSurface
        innerHighlight = TokenColor(1, 1, 1, p.dark ? (ic ? 0.24 : 0.14) : 0.55)
        hairline = p.ink.opacity(ic ? p.hairline.ic : p.hairline.normal)
        hairlineBright = p.ink.opacity(ic ? p.hairline.ic + 0.10 : p.hairline.bright)
        text = p.text
        secondaryText = ic ? p.secondaryIC : p.secondary
        emberText = p.emberText
        emberMark = p.emberMark
        emberDeep = p.emberDeep
        sage = p.sage
        amber = p.amber
        rose = p.rose
        mist = p.mist
        onEmber = p.onEmber
        shadow = p.shadow
        windowBackground = p.windowBackground.opacity(glass ? veil : 1)
        panel = p.panel.opacity(glass ? (p.dark ? 0.4 : 0.5) : 1)
        cardHairline = p.ink.opacity(ic ? p.hairline.ic : p.cardHairline)
        wash = p.wash
    }

    public func conversationColor(_ c: ConversationColor) -> TokenColor {
        // Per theme: the futures' mist and sage are their neon identity colours.
        switch c {
        case .ember: emberMark
        case .mist: mist
        case .sage: sage
        case .amber: amber
        }
    }

    // Geometry (Shapes). Corners stay concentric: well = card - inset.
    // Card 18 and chip 14 (the macOS 26 panel and control radii).
    public static let cardRadius: CGFloat = 18
    public static let wellRadius: CGFloat = 13
    public static let rimInset: CGFloat = cardRadius - wellRadius
    public static let chipRadius: CGFloat = 14
    public static let chipWellRadius: CGFloat = chipRadius - rimInset
    /// Cards and grouped sections in the Lumi window (the canvas's 14–16).
    public static let windowCardRadius: CGFloat = 14
    /// Sidebar rows and Settings icon tiles: rows 8, icon tiles 6.
    public static let rowRadius: CGFloat = 8
    /// The pill's capsule reading well sits 4 pt inside the glass (decided after S2).
    public static let pillWellInset: CGFloat = 4
    public static let hairlineWidth: CGFloat = 1
    /// The "Needs your OK" card's outline, in both appearances (More tokens).
    public static let amberBorder = TokenColor(245 / 255, 192 / 255, 96 / 255, 0.6)
    /// The soft shadow under floating surfaces, and the deeper one over bright backdrops.
    public static let outlineShadow = TokenColor(0, 0, 0, 0.12)
    public static let outlineShadowDeep = TokenColor(0, 0, 0, 0.22)
    /// Glyphs on solid colour tiles (the Settings icons), white in both appearances.
    public static let onTile = TokenColor(1, 1, 1)

    /// A selected chip, option or row: ember, faint (the canvas's 13–14 %).
    public var selection: TokenColor { emberMark.opacity(0.14) }
}

/// One theme's raw colours (67-THEMES.md). `Tokens.init` adds the display options and the glass
/// alphas on top. Lantern Ink is System, Light, Dark and Liquid Glass; the futures are their own.
nonisolated private struct Palette {
    let dark: Bool
    var well, glassTint, opaqueSurface, windowBackground, panel: TokenColor
    /// The hue of hairlines and card outlines, at the alphas below.
    var ink: TokenColor
    var hairline: (normal: Double, bright: Double, ic: Double)
    var cardHairline: Double
    var text, secondary, secondaryIC, emberText, emberMark, emberDeep, onEmber: TokenColor
    var sage, amber, rose, mist, shadow: TokenColor
    var wash = TokenColor(0, 0, 0, 0)

    init(_ theme: Theme, dark: Bool) {
        self.dark = dark
        if dark {
            well = TokenColor(hex: 0x16181D)
            glassTint = TokenColor(18 / 255, 20 / 255, 24 / 255, 0.45)
            opaqueSurface = TokenColor(hex: 0x1E2025)
            windowBackground = TokenColor(hex: 0x111317)
            panel = TokenColor(hex: 0x1A1C21)
            ink = TokenColor(1, 1, 1)
            hairline = (0.22, 0.35, 0.50)
            cardHairline = 0.08
            text = TokenColor(hex: 0xF2EFEA)
            secondary = TokenColor(hex: 0xA9AEB8)
            secondaryIC = TokenColor(hex: 0xCDD1D8)
            emberText = TokenColor(hex: 0xFF8A5B)
            emberMark = TokenColor(hex: 0xFF8A5B)
            emberDeep = TokenColor(hex: 0xB4451F)
            onEmber = TokenColor(hex: 0x24130B)
            sage = TokenColor(hex: 0x7FD1A8)
            amber = TokenColor(hex: 0xF5C060)
            rose = TokenColor(hex: 0xFF7B7B)
            mist = TokenColor(hex: 0x8FB8D8)
            shadow = TokenColor(0, 0, 0, 0.35)
        } else {
            well = TokenColor(hex: 0xFBFAF7)
            glassTint = TokenColor(251 / 255, 250 / 255, 247 / 255, 0.40)
            opaqueSurface = TokenColor(hex: 0xF3F1ED)
            windowBackground = TokenColor(hex: 0xF6F4F0)
            panel = TokenColor(hex: 0xFFFFFF)
            ink = TokenColor(0, 0, 0)
            hairline = (0.16, 0.30, 0.45)
            cardHairline = 0.08
            text = TokenColor(hex: 0x1B1C20)
            secondary = TokenColor(hex: 0x5A606B)
            secondaryIC = TokenColor(hex: 0x3A3F48)
            emberText = TokenColor(hex: 0xB4451F)
            emberMark = TokenColor(hex: 0xD9622F)
            emberDeep = TokenColor(hex: 0xB4451F)
            onEmber = TokenColor(hex: 0x1B0D06)
            sage = TokenColor(hex: 0x1F7A4F)
            amber = TokenColor(hex: 0x8A5A00)
            rose = TokenColor(hex: 0xB42318)
            mist = TokenColor(hex: 0x2F6488)
            shadow = TokenColor(0, 0, 0, 0.16)
        }
        switch theme {
        case .system, .light, .dark:
            break
        case .glass where !dark:
            // Text straight on glass: a step deeper (light) or brighter (dark) than Lantern, so a
            // thin veil holds 4.5:1 over the material.
            secondary = TokenColor(hex: 0x3A3F48)
            secondaryIC = TokenColor(hex: 0x2E3239)
            emberText = TokenColor(hex: 0x7A2C11)
            sage = TokenColor(hex: 0x124F33)
            amber = TokenColor(hex: 0x5C3B00)
            rose = TokenColor(hex: 0x8A1B12)
            mist = TokenColor(hex: 0x1F4A67)
        case .glass:
            secondary = TokenColor(hex: 0xC9CDD4)
            emberText = TokenColor(hex: 0xFFAA85)
            sage = TokenColor(hex: 0xA6E6C6)
            rose = TokenColor(hex: 0xFFA3A3)
            mist = TokenColor(hex: 0xB4D0E6)
        case .neonNoir:
            well = TokenColor(hex: 0x110F19)
            glassTint = TokenColor(hex: 0x0A0910, alpha: 0.5)
            opaqueSurface = TokenColor(hex: 0x17141F)
            windowBackground = TokenColor(hex: 0x0A0910)
            panel = TokenColor(hex: 0x14121D)
            ink = TokenColor(hex: 0x2DE2FF)
            hairline = (0.30, 0.45, 0.70)
            cardHairline = 0.14
            text = TokenColor(hex: 0xF1EEFF)
            secondary = TokenColor(hex: 0xA9A4C4)
            secondaryIC = TokenColor(hex: 0xD0CCE6)
            emberText = TokenColor(hex: 0x5CEBFF)
            emberMark = TokenColor(hex: 0x2DE2FF)
            emberDeep = TokenColor(hex: 0x0E7C90)
            onEmber = TokenColor(hex: 0x031418)
            sage = TokenColor(hex: 0x4DF5B0)
            amber = TokenColor(hex: 0xFFD24D)
            rose = TokenColor(hex: 0xFF5C7A)
            mist = TokenColor(hex: 0xFF4FB3)
            shadow = TokenColor(hex: 0x2DE2FF, alpha: 0.35)
            wash = TokenColor(hex: 0x2DE2FF, alpha: 0.08)
        case .synthwave:
            well = TokenColor(hex: 0x1A1030)
            glassTint = TokenColor(hex: 0x140B26, alpha: 0.5)
            opaqueSurface = TokenColor(hex: 0x221639)
            windowBackground = TokenColor(hex: 0x140B26)
            panel = TokenColor(hex: 0x1E1336)
            ink = TokenColor(hex: 0xFF6F91)
            hairline = (0.28, 0.42, 0.70)
            cardHairline = 0.16
            text = TokenColor(hex: 0xFBEFFF)
            secondary = TokenColor(hex: 0xB8A6D9)
            secondaryIC = TokenColor(hex: 0xDCCFF2)
            emberText = TokenColor(hex: 0xFF8FAB)
            emberMark = TokenColor(hex: 0xFF6F91)
            emberDeep = TokenColor(hex: 0xB8325A)
            onEmber = TokenColor(hex: 0x1A0610)
            sage = TokenColor(hex: 0x5EF2C2)
            amber = TokenColor(hex: 0xFFC85C)
            rose = TokenColor(hex: 0xFF6B6B)
            mist = TokenColor(hex: 0xA98BFF)
            shadow = TokenColor(hex: 0xFF6F91, alpha: 0.35)
            wash = TokenColor(hex: 0xFF6F91, alpha: 0.12)
        }
    }
}
