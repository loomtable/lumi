import AppKit
import SwiftUI
import Testing
@testable import BuddyOverlay

/// The `/` and `@` menu floats above the composer, never over the field (qa-ui, adca650).
@MainActor
struct FloatingAboveTests {
    @MainActor final class Frames {
        var field: CGRect?
        var menu: CGRect?
    }

    /// Conditional content, as the composer shows the menu: an alignment guide inside an `if` in a
    /// top overlay is ignored, and the menu drew from the field's top down over it.
    @Test func floatingContentEndsSixPointsAboveItsView() async throws {
        let frames = Frames()
        let open: Bool? = true
        let root = VStack(spacing: 0) {
            Color.clear.frame(height: 300)
            Color.clear.frame(width: 400, height: 44)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("root")) }) { frames.field = $0 }
                .floatingAbove {
                    if open != nil {
                        Color.clear.frame(width: 200, height: 120)
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("root")) }) { frames.menu = $0 }
                            .transition(.opacity)
                    }
                }
            Text("hint")
        }
        .coordinateSpace(.named("root"))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 344), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.contentView?.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while frames.menu == nil || frames.field == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let field = try #require(frames.field), menu = try #require(frames.menu)
        #expect(abs(menu.maxY - (field.minY - 6)) < 0.5, "the menu's bottom sits 6 pt above the field")
        #expect(menu.height == 120, "full height, not squeezed")
        #expect(menu.minX == field.minX, "leading-aligned")
        window.close()
    }
}
