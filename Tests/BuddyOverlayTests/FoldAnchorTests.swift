import AppKit
import SwiftUI
import Testing
@testable import BuddyOverlay

// Bug, Oct 17: a closed answer "goes and vanishes while going to the centre-top", not into
// the menu-bar orb. The fold scaled around a box only as big as its content.

@MainActor private final class FrameBox { var frame: CGRect = .zero }

/// Where a card at `card` ends up when its stage folds toward `source` (panel coordinates).
@MainActor private func foldedFrame(card: CGRect, source: CGPoint, panel: CGSize, scale: CGFloat) async -> CGRect {
    let box = FrameBox()
    let stage = SurfaceStage(size: panel, popTrigger: 0, folding: true, foldScale: scale,
                             anchor: unitPoint(source, in: CGRect(origin: .zero, size: panel)), reduceMotion: false) {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: card.width, height: card.height)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel")) } action: { box.frame = $0 }
                .padding(.leading, card.minX)
                .padding(.top, card.minY)
        }
    }
    .coordinateSpace(.named("panel"))
    let host = NSHostingView(rootView: stage)
    host.frame = CGRect(origin: .zero, size: panel)
    for _ in 0..<20 where box.frame == .zero {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(10))
    }
    return box.frame
}

@Test(.overlayExclusive) func aTuckedCardFoldsIntoTheOrbAtTheTopRight() async {
    // A 1512 × 982 display (a 14" MacBook Pro); the Lumi item near the right end of the menu bar,
    // in AppKit coordinates as the status item reports it.
    let item = NSRect(x: 1290, y: 958, width: 24, height: 24)
    let orb = ScreenSpace.topLeft(item, primaryMaxY: 982)
    let centre = CGPoint(x: orb.midX, y: orb.midY)
    #expect(centre == CGPoint(x: 1302, y: 12), "top right, in the panel's top-left points")
    let folded = await foldedFrame(card: CGRect(x: 591, y: 300, width: 330, height: 260), source: centre,
                                   panel: CGSize(width: 1512, height: 982), scale: Motion.tuckScale)
    // At scale .06 the card is a speck a few points from the orb.
    #expect(abs(folded.midX - centre.x) < 50 && abs(folded.midY - centre.y) < 30, "folded to \(folded), orb at \(centre)")
}

@Test(.overlayExclusive) func aCardFoldsTowardItsSourceAnywhereOnThePanel() async {
    // The plain fold (.55) toward a source on the far left: the card moves left, not right.
    let folded = await foldedFrame(card: CGRect(x: 900, y: 500, width: 330, height: 260), source: CGPoint(x: 40, y: 900),
                                   panel: CGSize(width: 1512, height: 982), scale: Motion.foldScale)
    let expected = CGPoint(x: 40 + 0.55 * (1065 - 40), y: 900 + 0.55 * (630 - 900))
    #expect(abs(folded.midX - expected.x) < 2 && abs(folded.midY - expected.y) < 2, "folded to \(folded), expected \(expected)")
}
