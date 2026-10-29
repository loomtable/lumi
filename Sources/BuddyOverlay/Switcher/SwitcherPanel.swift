import AppKit
import SwiftUI

/// A borderless, non-activating, never-key panel for one switcher surface (the strip, the
/// peek), sized to that surface so clicks around it reach
/// the user's app. It never takes focus: the buddy key's tap owns the keys.
final class SwitcherPanel: NSPanel {
    let host: NSHostingView<AnyView>

    init(_ root: some View, level: NSWindow.Level = .statusBar) {
        host = SwitcherHostingView(rootView: AnyView(root.lumiTheme()))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Floating first: setting `isFloatingPanel` resets the level to `.floating` (OverlayPanel).
        isFloatingPanel = true
        // Above the overlay's panels (also .statusBar, ordered earlier), unless told otherwise.
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        // Lumi in the Dock can be hidden (⌘H, the Dock's Hide): an overlay still shows when summoned.
        canHide = false
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
        alphaValue = 0
        host.sizingOptions = []
        host.wantsLayer = true
        contentView = host
    }

    /// The strip's level: one under the overlay's, so the live pill stays on top as its header.
    static let stripLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The surface's natural size, padding included.
    var fittingSize: CGSize { host.fittingSize }

    func place(_ frame: CGRect) {
        guard frame != self.frame else { return }
        setFrame(frame, display: false)
        host.frame = NSRect(origin: .zero, size: frame.size)
    }

    /// Visible and clickable now; ordered in first if needed.
    func reveal(clickable: Bool = true) {
        if !isVisible { orderFrontRegardless() }
        alphaValue = 1
        ignoresMouseEvents = !clickable
    }

    /// Ordered in but invisible and click-through: built, so showing it later is one flip.
    func stage() {
        alphaValue = 0
        ignoresMouseEvents = true
        if !isVisible { orderFrontRegardless() }
        warm()
    }

    /// Lays out and draws pending changes now, so the frame that shows it carries none (U65).
    func warm() {
        host.layoutSubtreeIfNeeded()
        displayIfNeeded()
    }

    func conceal() {
        ignoresMouseEvents = true
        alphaValue = 0
        orderOut(nil)
    }
}

/// Buttons on a never-key panel must work on the first click.
private final class SwitcherHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
