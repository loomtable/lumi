import AppKit
import SwiftUI

/// The floating conversation Panel's window: borderless, non-activating, on all Spaces and
/// auxiliary in full screen. It becomes key only when a click lands on something that needs
/// the keyboard (the composer), so the app underneath keeps its focus otherwise (04 §3.2).
final class ConversationPanel: NSPanel {
    /// Local keys while key (Esc on an empty composer). True when used.
    var onKey: (NSEvent) -> Bool = { _ in false }
    var onFocusChange: (Bool) -> Void = { _ in }
    /// The user dragged the panel: its new top-left corner and display.
    var onMoved: (CGPoint, CGDirectDisplayID) -> Void = { _, _ in }
    private var programmaticMove = false

    init(root: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PanelDocking.defaultWidth, height: PanelDocking.minHeight),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // The SwiftUI shell draws the shadow (04 §7.2: 0 8 24).
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        // Lumi in the Dock can be hidden (⌘H, the Dock's Hide): an overlay still shows when summoned.
        canHide = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        minSize = NSSize(width: PanelDocking.widthRange.lowerBound, height: PanelDocking.minHeight)
        maxSize = NSSize(width: PanelDocking.widthRange.upperBound, height: .greatestFiniteMagnitude)
        setRoot(root)
        NotificationCenter.default.addObserver(self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: self)
    }

    /// Replaces the SwiftUI content (another session's page).
    func setRoot(_ root: some View) {
        let host = PanelHostingView(rootView: AnyView(root.lumiTheme()))
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc reaches `onKey` before the focused field sees it.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey(event) { return }
        super.sendEvent(event)
    }

    override func becomeKey() {
        super.becomeKey()
        onFocusChange(true)
    }

    override func resignKey() {
        super.resignKey()
        onFocusChange(false)
    }

    /// Moves without counting as the user's drag.
    func place(_ frame: NSRect, animate: Bool) {
        programmaticMove = true
        setFrame(frame, display: true, animate: animate)
        programmaticMove = false
    }

    @objc private func didMove() {
        guard !programmaticMove, let screen else { return }
        onMoved(CGPoint(x: frame.minX, y: frame.maxY), screen.displayID)
    }
}

/// Buttons work on the first click, without the panel taking focus.
private final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
