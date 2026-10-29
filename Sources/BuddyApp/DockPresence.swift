import AppKit

/// Lumi's Dock icon, following Settings › General › "Show in Dock". The app always launches as an
/// agent (`LSUIElement`), so "off" never flashes an icon at launch; "on" turns it into a regular
/// app. Overlays are unaffected: the Glance, the switcher and the Panel are non-activating panels,
/// so summoning never activates Lumi or brings its menu bar forward, with or without the icon.
@MainActor
public final class DockPresence {
    private let apply: @MainActor (NSApplication.ActivationPolicy) -> Void
    private let isActive: @MainActor () -> Bool
    private let activate: @MainActor () -> Void
    /// The policy last applied; nil before the first.
    public private(set) var policy: NSApplication.ActivationPolicy?

    public init(apply: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void,
                isActive: @escaping @MainActor () -> Bool,
                activate: @escaping @MainActor () -> Void) {
        self.apply = apply
        self.isActive = isActive
        self.activate = activate
    }

    public static func live() -> DockPresence {
        DockPresence(apply: { NSApp.setActivationPolicy($0) }, isActive: { NSApp.isActive }, activate: { NSApp.activate() })
    }

    public static func policy(showInDock: Bool) -> NSApplication.ActivationPolicy { showInDock ? .regular : .accessory }

    /// Applies `showInDock` when it changed. Leaving the Dock deactivates the app, and the switch
    /// was just flipped in the Lumi window, so an app that was active is activated again (never one
    /// that wasn't: this never takes focus from the user's app).
    public func show(inDock showInDock: Bool) {
        let wanted = Self.policy(showInDock: showInDock)
        guard wanted != policy else { return }
        let first = policy == nil
        let wasActive = isActive()
        apply(wanted)
        policy = wanted
        if !first, wasActive, wanted == .accessory { activate() }
    }
}
