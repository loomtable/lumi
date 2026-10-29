import CoreGraphics
import Testing
@testable import BuddyOverlay

struct PanelDockingTests {
    /// A 1440 × 875 visible frame above a 25 pt menu bar.
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func docksOutsideTheOriginWindowsTrailingEdge() {
        let win = CGRect(x: 56, y: 56, width: 880, height: 788)
        let f = PanelDocking.frame(.init(visible: visible, originWindow: win, anchor: CGPoint(x: 500, y: 450), contentHeight: 600))
        #expect(f.minX == win.maxX + 12)
        #expect(f.width == 400)
        #expect(f.height == 600)
        #expect(f.midY == 450)
    }

    @Test func docksInsideTheScreenEdgeWhenThereIsNoRoom() {
        let win = CGRect(x: 100, y: 100, width: 1200, height: 600)
        let f = PanelDocking.frame(.init(visible: visible, originWindow: win))
        #expect(f.maxX == visible.maxX - 12)
        #expect(f.midY == win.midY)
    }

    @Test func heightGrowsFrom220To72Percent() {
        #expect(PanelDocking.height(content: 50, visible: visible) == 220)
        #expect(PanelDocking.height(content: 400, visible: visible) == 400)
        #expect(PanelDocking.height(content: 5000, visible: visible) == 875 * 0.72)
    }

    @Test func clampsTheAnchorToA16ptMargin() {
        let f = PanelDocking.frame(.init(visible: visible, anchor: CGPoint(x: 10, y: 870), contentHeight: 300))
        #expect(f.maxY == visible.maxY - 16)
        let low = PanelDocking.frame(.init(visible: visible, anchor: CGPoint(x: 10, y: 0), contentHeight: 300))
        #expect(low.minY == 16)
    }

    @Test func aRememberedCornerWinsAndStaysOnScreen() {
        let f = PanelDocking.frame(.init(visible: visible, originWindow: CGRect(x: 0, y: 0, width: 300, height: 300),
                                         contentHeight: 300, remembered: CGPoint(x: 200, y: 700)))
        #expect(f.minX == 200)
        #expect(f.maxY == 700)
        let off = PanelDocking.frame(.init(visible: visible, contentHeight: 300, remembered: CGPoint(x: 5000, y: 5000)))
        #expect(visible.contains(off))
    }

    @Test func widthStaysIn340To560() {
        #expect(PanelDocking.frame(.init(visible: visible, width: 100)).width == 340)
        #expect(PanelDocking.frame(.init(visible: visible, width: 900)).width == 560)
    }
}
