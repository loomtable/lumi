import AppKit
import Observation
import SwiftUI

/// Settings › Appearance › Theme (67-THEMES.md): a full set of the tokens plus a look (light, dark
/// or the Mac's) and a material. Views never branch on it; `Tokens` picks the palette.
nonisolated public enum Theme: String, Codable, Sendable, CaseIterable {
    /// Follows the Mac's light or dark appearance (the default).
    case system
    case light
    case dark
    /// Follows the Mac; every floating surface is one piece of Regular glass with text on it, and
    /// the Lumi window's content sits on a thin veil over the system material.
    case glass
    /// Dark future: black-violet, cyan accent, magenta identity.
    case neonNoir
    /// Dark future: deep indigo, sunset-pink accent, violet identity.
    case synthwave

    /// Light or dark regardless of the Mac, or nil to follow it.
    public var forcedDark: Bool? {
        switch self {
        case .system, .glass: nil
        case .light: false
        case .dark, .neonNoir, .synthwave: true
        }
    }

    /// The app-wide appearance this theme sets (system controls, menus, forms and web views follow it).
    public var appearanceName: NSAppearance.Name? {
        forcedDark.map { $0 ? .darkAqua : .aqua }
    }

    /// This theme on a surface that is always dark (the research capsule by the notch).
    public var alwaysDark: Theme { self == .light ? .dark : self }

    /// Surfaces with text are translucent over the system material instead of opaque.
    public var isGlass: Bool { self == .glass }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .glass: "Liquid Glass"
        case .neonNoir: "Neon Noir"
        case .synthwave: "Synthwave"
        }
    }
}

/// The theme in force, process-wide. The shell copies Settings › Appearance into it; the root of
/// every window reads it through `.lumiTheme()`.
@MainActor @Observable
public final class ThemeSelection {
    public static let shared = ThemeSelection()

    public var theme: Theme = .system {
        didSet {
            guard theme != oldValue else { return }
            NSApp?.appearance = theme.appearanceName.flatMap { NSAppearance(named: $0) }
        }
    }

    init() {}
}

extension Tokens {
    /// The theme's wash: its colour at the top, clear by the middle. Drawn over the Lumi window's
    /// background and the answer card's well; clear in every theme but the futures.
    public var washGradient: LinearGradient {
        LinearGradient(colors: [wash.color, wash.opacity(0).color], startPoint: .top, endPoint: .center)
    }
}

nonisolated extension EnvironmentValues {
    /// The theme `TokensReader` and `TokenStyle` resolve with. Set once per window by `.lumiTheme()`.
    @Entry public var lumiTheme: Theme = .system
}

extension View {
    /// Puts the selected theme into this window's environment. Once at every SwiftUI root.
    public func lumiTheme() -> some View { modifier(ThemeRoot()) }
}

private struct ThemeRoot: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.lumiTheme, ThemeSelection.shared.theme)
    }
}
