import AppKit
import SwiftUI

/// One borderless, non-activating, never-key panel per display, covering the whole screen
/// and passing clicks through except over the visible surfaces (Show).
final class OverlayPanel: NSPanel {
    let displayID: CGDirectDisplayID

    init(screen: NSScreen, displayID: CGDirectDisplayID, root: some View) {
        self.displayID = displayID
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isFloatingPanel = true
        // A click on a visible answer should focus it, not only clicks on text fields.
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        contentView = host
    }

    /// The panel never takes focus on its own. While an answer is visible, a click on
    /// it (or `focusAnswer()`) makes it key; the app itself is never activated. Key status
    /// goes back to the user's app when the panel orders out after the fold.
    var acceptsFocus = false
    /// Local key handling while key. Returns true when the key was used. Runs before the
    /// focused text field sees the key, so ⌘ shortcuts, Esc and (with an empty reply)
    /// 1–3 and F work while typing.
    var onKey: (NSEvent) -> Bool = { _ in false }
    /// Key status changes (the card or text box gained or lost keyboard focus).
    var onFocusChange: (Bool) -> Void = { _ in }

    override var canBecomeKey: Bool { acceptsFocus }
    override var canBecomeMain: Bool { false }

    /// ⌘ shortcuts arrive here before the app's main menu (SwiftUI installs "Settings… ⌘,"),
    /// so ⌘, reaches the overlay while it has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKey(event) || super.performKeyEquivalent(with: event)
    }

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

    func fit(to screen: NSScreen) {
        setFrame(screen.frame, display: false)
        contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
    }
}

/// Buttons on a never-key panel must work on the first click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        cgDirectDisplayID ?? (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
