import CoreGraphics
import Testing
@testable import BuddyOverlay

// Lead re-verification of #49: the pure display rules behind the capsule.

@Test(.overlayExclusive) func frontWindowSkipsOurOwnProcess() {
    let window: [String: Any] = [
        kCGWindowOwnerPID as String: Int32(42), kCGWindowLayer as String: 0,
        kCGWindowBounds as String: ["X": CGFloat(100), "Y": CGFloat(50), "Width": CGFloat(200), "Height": CGFloat(100)],
    ]
    let menu: [String: Any] = [
        kCGWindowOwnerPID as String: Int32(42), kCGWindowLayer as String: 25,
        kCGWindowBounds as String: ["X": CGFloat(0), "Y": CGFloat(0), "Width": CGFloat(10), "Height": CGFloat(10)],
    ]
    #expect(ScreenSpace.frontWindowCentre(in: [menu, window], frontmostPID: 42, ownPID: 7) == CGPoint(x: 200, y: 100))
    // We are frontmost (our panel is key): never pick our own window.
    #expect(ScreenSpace.frontWindowCentre(in: [window], frontmostPID: 42, ownPID: 42) == nil)
    // Only another app's windows: none of the frontmost app's.
    #expect(ScreenSpace.frontWindowCentre(in: [window], frontmostPID: 9, ownPID: 7) == nil)
}

@Test(.overlayExclusive) func reportOpensOnTheCapsulesDisplay() {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    let frames = [main, external]
    // The capsule is on the external display: the report opens there, whatever the menu bar says now.
    #expect(ScreenSpace.reportScreenIndex(capsuleFrame: external, capsuleVisible: true, screenFrames: frames, menuBarIndex: 0) == 1)
    // No capsule (or its display is gone): the menu-bar display.
    #expect(ScreenSpace.reportScreenIndex(capsuleFrame: external, capsuleVisible: false, screenFrames: frames, menuBarIndex: 0) == 0)
    #expect(ScreenSpace.reportScreenIndex(capsuleFrame: CGRect(x: 9, y: 9, width: 1, height: 1), capsuleVisible: true,
                                          screenFrames: frames, menuBarIndex: 0) == 0)
}
