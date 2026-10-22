import CoreGraphics
import Testing
@testable import BuddyOverlay

private let a = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let b = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

@Test func theChosenDisplayStillThereAsItWasIsKept() {
    #expect(BuddyOverlayController.recheckDisplay(captured: 2, capturedFrame: b, live: [(1, a), (2, b)], main: 1) == .unchanged)
}

@Test func aRearrangedOrResizedDisplayIsRelaidOutWhereItIs() {
    let moved = b.offsetBy(dx: -1512, dy: 982)
    #expect(BuddyOverlayController.recheckDisplay(captured: 2, capturedFrame: b, live: [(1, a), (2, moved)], main: 1)
            == .changed(id: 2, gone: false))
}

@Test func anAnswerForAnUnpluggedDisplayGoesToTheMainOneRecentred() {
    #expect(BuddyOverlayController.recheckDisplay(captured: 2, capturedFrame: b, live: [(1, a)], main: 1)
            == .changed(id: 1, gone: true), "never a panel for a display that's gone")
    #expect(BuddyOverlayController.recheckDisplay(captured: 2, capturedFrame: b, live: [(3, a)], main: nil)
            == .changed(id: 3, gone: true), "no main reported: the first live display")
}

@Test func noDisplayAtAllShowsNothing() {
    #expect(BuddyOverlayController.recheckDisplay(captured: 2, capturedFrame: b, live: [], main: nil) == .noScreens)
}
