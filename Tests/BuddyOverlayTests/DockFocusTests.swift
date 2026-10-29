import AppKit
import SwiftUI
import Testing
@testable import BuddyOverlay

/// Lumi in the Dock is a regular app, so these keep summoning from ever activating it (no Lumi menu
/// bar over the user's app) and keep an overlay showing while Lumi is hidden.
@MainActor
struct DockFocusTests {
    @Test(.overlayExclusive) func overlaysNeverActivateLumiAndSurviveHide() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let glance = OverlayPanel(screen: screen, displayID: 0, root: Color.clear)
        let panel = ConversationPanel(root: Color.clear)
        let switcher = SwitcherPanel(Color.clear)
        defer { [glance, panel, switcher].forEach { $0.close() } }
        for window in [glance, panel, switcher] as [NSPanel] {
            #expect(window.styleMask.contains(.nonactivatingPanel), "becoming key never activates Lumi")
            #expect(!window.canHide, "Hide (⌘H, the Dock's) leaves overlays able to show")
            #expect(!window.hidesOnDeactivate)
        }
        #expect(!switcher.canBecomeKey, "the strip never takes keys")
        #expect(!glance.canBecomeKey, "the Glance takes keys only while it accepts focus")
        glance.acceptsFocus = true
        #expect(glance.canBecomeKey)
        #expect(panel.becomesKeyOnlyIfNeeded, "the Panel is key only when its composer is clicked or focused")
    }
}
