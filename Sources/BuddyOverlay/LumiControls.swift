import SwiftUI

/// The canvas's buttons on content and cards (04 §4.3, Home's running cards): 28 pt capsules,
/// 12 pt semibold. `.prominent` is the one ember action (Allow, Start, Continue); `.plain` is a faint
/// fill with a hairline (Deny, Always this session). Flat, so there's no glass on glass inside the
/// Panel or a card.
public struct PillButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case prominent, plain }
    let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(kind: kind, configuration: configuration)
    }
}

private struct PillButtonBody: View {
    let kind: PillButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        TokensReader { t in
            let prominent = kind == .prominent
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle((prominent ? t.onEmber : t.text).color)
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background {
                    Capsule().fill(prominent ? t.emberMark.color : t.text.opacity(hovering ? 0.11 : 0.07).color)
                }
                .overlay {
                    if !prominent { Capsule().strokeBorder(controlOutline(t, 0.14).color, lineWidth: Tokens.hairlineWidth) }
                }
                .brightness(prominent && hovering ? 0.04 : 0)
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(Motion.crossfade, value: hovering)
        }
    }
}

/// The canvas's round icon buttons in a header (Open as Panel, Inspector, More; the Panel's pin,
/// expand and minimise): a 28 pt circle, a faint fill and hairline, the glyph in text colour.
public struct RoundIconButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        RoundIconBody(configuration: configuration)
    }
}

private struct RoundIconBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        TokensReader { t in
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(t.text.color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(t.text.opacity(hovering ? 0.10 : 0.05).color))
                .overlay { Circle().strokeBorder(controlOutline(t, 0.10).color, lineWidth: Tokens.hairlineWidth) }
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(Motion.crossfade, value: hovering)
        }
    }
}

/// A control's outline: faint, or the full hairline with Increase Contrast.
private func controlOutline(_ t: Tokens, _ alpha: Double) -> TokenColor {
    t.variant.increaseContrast ? t.hairline : t.text.opacity(alpha)
}

extension ButtonStyle where Self == PillButtonStyle {
    /// The one ember action on a card or in the page.
    public static var pillProminent: PillButtonStyle { PillButtonStyle(.prominent) }
    /// A quiet capsule beside it.
    public static var pill: PillButtonStyle { PillButtonStyle(.plain) }
}

extension ButtonStyle where Self == RoundIconButtonStyle {
    /// A header's round icon button.
    public static var roundIcon: RoundIconButtonStyle { RoundIconButtonStyle() }
}

extension View {
    /// Ember as the one accent (04 §7.1): links, toggles, sliders, radio and segmented selections,
    /// focus rings. Set once at a window's root (the Lumi window, onboarding); read it with `.tint`,
    /// never `Color.accentColor`, which ignores it.
    public func emberTint() -> some View {
        TokensReader { t in self.tint(t.emberMark.color) }
    }
}

/// A token colour as a ShapeStyle that resolves for the view's appearance, so plain SwiftUI code
/// says `.foregroundStyle(.lumiAmber)` instead of the system `.orange` (04 §7.1: amber needs you,
/// sage is done, rose failed).
public struct TokenStyle: ShapeStyle {
    public enum Role: Sendable { case sage, amber, rose, ember, emberText, secondary }
    let role: Role

    public func resolve(in environment: EnvironmentValues) -> Color {
        let t = Tokens(.init(dark: environment.colorScheme == .dark, theme: environment.lumiTheme,
                             reduceTransparency: environment.accessibilityReduceTransparency,
                             increaseContrast: environment.colorSchemeContrast == .increased))
        return switch role {
        case .sage: t.sage.color
        case .amber: t.amber.color
        case .rose: t.rose.color
        case .ember: t.emberMark.color
        case .emberText: t.emberText.color
        case .secondary: t.secondaryText.color
        }
    }
}

extension ShapeStyle where Self == TokenStyle {
    /// Done, granted, ready.
    public static var lumiSage: TokenStyle { TokenStyle(role: .sage) }
    /// Needs you, a warning.
    public static var lumiAmber: TokenStyle { TokenStyle(role: .amber) }
    /// Failed, an error.
    public static var lumiRose: TokenStyle { TokenStyle(role: .rose) }
    /// Secondary text.
    public static var lumiSecondary: TokenStyle { TokenStyle(role: .secondary) }
}

/// A text link in ember text (04 §6.4: "Links use ember text"), underlined while hovered. The system
/// `.link` style ignores the tint and stays blue.
public struct LumiLinkButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        LumiLinkBody(configuration: configuration)
    }
}

private struct LumiLinkBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        TokensReader { t in
            configuration.label
                .foregroundStyle(t.emberText.color)
                .underline(hovering && enabled)
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .pointerStyle(.link)
        }
    }
}

extension ButtonStyle where Self == LumiLinkButtonStyle {
    /// An ember text link.
    public static var lumiLink: LumiLinkButtonStyle { LumiLinkButtonStyle() }
}
