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
/// and colour, resolved for the Mac's appearance and accessibility display options.
nonisolated public struct Tokens: Sendable, Equatable {
    public struct Variant: Sendable, Equatable {
        public var dark: Bool
        public var reduceTransparency: Bool
        public var increaseContrast: Bool

        public init(dark: Bool, reduceTransparency: Bool = false, increaseContrast: Bool = false) {
            self.dark = dark
            self.reduceTransparency = reduceTransparency
            self.increaseContrast = increaseContrast
        }

        /// The current system settings. `dark` comes from the given appearance.
        public static func current(appearance: NSAppearance) -> Variant {
            let ws = NSWorkspace.shared
            return Variant(
                dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                reduceTransparency: ws.accessibilityDisplayShouldReduceTransparency,
                increaseContrast: ws.accessibilityDisplayShouldIncreaseContrast)
        }
    }

    public let variant: Variant

    /// The reading well under all text: 94% opaque, fully opaque with Reduce Transparency
    /// or Increase Contrast.
    public let well: TokenColor
    /// Tint for Regular glass. With Reduce Transparency, surfaces are opaque instead.
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
    public let onSage: TokenColor
    /// Glow and halo shadow colour (ember).
    public let shadow: TokenColor

    /// Glass is replaced by `opaqueSurface` when this is false.
    public var usesGlass: Bool { !variant.reduceTransparency }

    public init(_ v: Variant) {
        variant = v
        let solid = v.reduceTransparency || v.increaseContrast
        if v.dark {
            well = TokenColor(hex: 0x16181D, alpha: solid ? 1 : 0.94)
            glassTint = TokenColor(18 / 255, 20 / 255, 24 / 255, 0.45)
            opaqueSurface = TokenColor(hex: 0x1E2025)
            innerHighlight = TokenColor(1, 1, 1, v.increaseContrast ? 0.24 : 0.14)
            hairline = TokenColor(1, 1, 1, v.increaseContrast ? 0.50 : 0.22)
            hairlineBright = TokenColor(1, 1, 1, v.increaseContrast ? 0.60 : 0.35)
            text = TokenColor(hex: 0xF2EFEA)
            secondaryText = v.increaseContrast ? TokenColor(hex: 0xCDD1D8) : TokenColor(hex: 0xA9AEB8)
            emberText = TokenColor(hex: 0xFF8A5B)
            emberMark = TokenColor(hex: 0xFF8A5B)
            sage = TokenColor(hex: 0x7FD1A8)
            amber = TokenColor(hex: 0xF5C060)
            rose = TokenColor(hex: 0xFF7B7B)
            mist = TokenColor(hex: 0x8FB8D8)
            onEmber = TokenColor(hex: 0x24130B)
            onSage = TokenColor(hex: 0x0F2A1D)
            shadow = TokenColor(0, 0, 0, 0.35)
        } else {
            well = TokenColor(hex: 0xFBFAF7, alpha: solid ? 1 : 0.94)
            glassTint = TokenColor(251 / 255, 250 / 255, 247 / 255, 0.40)
            opaqueSurface = TokenColor(hex: 0xF3F1ED)
            innerHighlight = TokenColor(1, 1, 1, 0.55)
            hairline = TokenColor(0, 0, 0, v.increaseContrast ? 0.45 : 0.16)
            hairlineBright = TokenColor(0, 0, 0, v.increaseContrast ? 0.55 : 0.30)
            text = TokenColor(hex: 0x1B1C20)
            secondaryText = v.increaseContrast ? TokenColor(hex: 0x3A3F48) : TokenColor(hex: 0x5A606B)
            emberText = TokenColor(hex: 0xB4451F)
            emberMark = TokenColor(hex: 0xD9622F)
            sage = TokenColor(hex: 0x1F7A4F)
            amber = TokenColor(hex: 0x8A5A00)
            rose = TokenColor(hex: 0xB42318)
            mist = TokenColor(hex: 0x2F6488)
            onEmber = TokenColor(hex: 0x1B0D06)
            onSage = TokenColor(hex: 0x1B0D06)
            shadow = TokenColor(0, 0, 0, 0.16)
        }
    }

    public func conversationColor(_ c: ConversationColor) -> TokenColor {
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
    /// The pill's capsule reading well sits 4 pt inside the glass (decided after S2).
    public static let pillWellInset: CGFloat = 4
    public static let hairlineWidth: CGFloat = 1
    /// The "Needs your OK" card's outline, in both appearances (More tokens).
    public static let amberBorder = TokenColor(245 / 255, 192 / 255, 96 / 255, 0.6)
}
