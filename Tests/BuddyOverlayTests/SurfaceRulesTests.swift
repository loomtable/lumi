import AppKit
import BuddyCore
import Foundation
import SwiftUI
import Testing
@testable import BuddyOverlay

// The rules in docs/v2-sessions/65-SURFACE-RULES.md that the overlay holds on its own.

private let bounds = CGRect(x: 0, y: 33, width: 1512, height: 916)

private func card(turn: Int) -> Answer {
    Answer(block: BuddyBlock(say: "Hi.", shape: .card), lane: Lane(mode: .quick, model: .haiku),
           conversation: .ember, turn: turn, replyHint: "r")
}

// MARK: Rule 3: answers keep out of the top column

@Test func aRememberedSpotInTheTopColumnStepsOutOfIt() throws {
    let zones = Placer.reservedZones(in: bounds)
    let size = CGSize(width: 330, height: 200)
    let inside = CGPoint(x: bounds.midX - 100, y: bounds.minY + 20)
    let kept = try #require(Placer.keep(inside, size: size, in: bounds, reserved: zones))
    #expect(!zones.contains { $0.intersects(kept) }, "never over the pill, strip or capsules")
    #expect(bounds.insetBy(dx: Placer.edgeMargin, dy: Placer.edgeMargin).contains(kept))
    #expect(kept.size == size)

    let clear = CGPoint(x: bounds.minX + 40, y: bounds.midY)
    #expect(Placer.keep(clear, size: size, in: bounds, reserved: zones)?.origin == clear, "a clear spot holds")
    for statusAtBottom in [false, true] {
        let zones = Placer.reservedZones(in: bounds, statusAtBottom: statusAtBottom)
        let low = CGPoint(x: bounds.midX - 100, y: bounds.maxY - 120)
        if let r = Placer.keep(low, size: size, in: bounds, reserved: zones) {
            #expect(!zones.contains { $0.intersects(r) })
        }
    }
}

/// Live: a card dragged up to the top centre made every later answer of the conversation open
/// over the pill and the capsules there.
@Test(.overlayExclusive) func aCardDraggedOntoTheColumnDoesntBringLaterAnswersThere() async throws {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(card(turn: 1), anchor: .point(CGPoint(x: 400, y: 500)))
    await overlay.presentationFinished()
    guard case .answer(_, let before, _) = overlay.model.surface else { Issue.record("no answer"); return }
    let screen = try #require(NSScreen.screens.first { ScreenSpace.topLeft($0.frame) == overlay.model.screenFrame })
    let visible = ScreenSpace.topLeft(screen.visibleFrame)
    // Drag its top-left corner just under the menu bar, centred.
    let target = CGPoint(x: visible.midX - before.frame.width / 2, y: visible.minY + Placer.edgeMargin)
    let move = CGSize(width: target.x - before.frame.minX, height: target.y - before.frame.minY)
    overlay.drag(.answer, .changed, translation: move)
    overlay.drag(.answer, .ended, translation: move)

    overlay.showAnswer(card(turn: 2), anchor: .point(CGPoint(x: 900, y: 300)))
    await overlay.presentationFinished()
    guard case .answer(_, let next, _) = overlay.model.surface else { Issue.record("no answer"); return }
    let zones = Placer.reservedZones(in: visible)
    #expect(!zones.contains { $0.intersects(next.frame) }, "\(next.frame) is in the top column \(zones)")
    overlay.dismiss(.requested)
}

// MARK: Rule 2: one column, nothing in it overlaps

@MainActor private func rowFrames(_ rows: [ProgressItem], more: Int) -> [CGRect] {
    final class Box { var frames: [Int: CGRect] = [:] }
    let box = Box()
    let view = TokensReader { t in
        ProgressColumn(shown: .init(rows: rows, more: more), t: t, reduceMotion: true,
                       onRowFrame: { id, frame in box.frames[id] = frame })
    }
    let host = NSHostingView(rootView: view.fixedSize())
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    return rows.compactMap { box.frames[$0.id] }
}

@Test(.overlayExclusive) func capsulesStackWithoutOverlapping() {
    let rows = (1...3).map { ProgressItem(id: $0, title: "Query \($0)", line: "Searching the web for things") }
    for (shown, more) in [(1, 0), (2, 0), (3, 0), (2, 4)] {
        let frames = rowFrames(Array(rows.prefix(shown)), more: more)
        #expect(frames.count == shown)
        for (a, b) in zip(frames, frames.dropFirst()) {
            #expect(b.minY >= a.maxY, "row \(b) starts under row \(a)")
            #expect(!a.intersects(b))
        }
    }
}

/// The whole column at its tallest (research capsule, a two-line headline pill, three rows) fits
/// the zone cards keep out of, so a card placed clear of the zone never meets a capsule.
@Test(.overlayExclusive) func theTallestColumnFitsTheReservedZone() {
    let rows = (1...3).map { ProgressItem(id: $0, title: "Query \($0)", line: "Thinking") }
    let stack = NSHostingView(rootView: TokensReader { t in
        ProgressColumn(shown: .init(rows: rows, more: 0), t: t, reduceMotion: true)
    }.fixedSize()).fittingSize
    // The research capsule sits 6 pt under the menu bar, 26 pt tall; the pill 8 pt under it,
    // else at the margin (OverlayModel.statusPillOrigin).
    let pillTop = max(Placer.edgeMargin, 6 + 26 + 8)
    // The headline pill (PillContent): two lines of the headline, 6 pt above and below, in its rim.
    let twoLines = NSHostingView(rootView: HugWrap(maxWidth: PillContent.headlineWidth) {
        Text(String(repeating: "New Delhi is 27°C now, with a high of 28 ", count: 4)).font(Typeface.labelStrong).lineLimit(2)
    }.fixedSize()).fittingSize.height
    let headlinePill = twoLines + 12 + 2 * Tokens.pillWellInset
    let column = pillTop + headlinePill + OverlayModel.progressGap + stack.height
    let zone = Placer.reservedZones(in: bounds)[0]
    #expect(column <= zone.height, "column \(column) pt (pill \(headlinePill)), zone \(zone.height) pt")
    #expect(max(stack.width, ProgressCapsule.maxWidth) <= zone.width)
}

/// Live: a pill nudged a few points (a drag starts at 3 pt) left the stack at the top of the
/// screen, so the capsules drew over the pill.
@Test(.overlayExclusive) func aNudgedPillStillHasTheStackUnderIt() {
    let overlay = BuddyOverlayController(observesSystem: false)
    let model = overlay.model
    overlay.updateProgress(.init(rows: [ProgressItem(id: 1, title: "Trip", line: "Thinking"),
                                        ProgressItem(id: 2, title: "Budget", line: "Thinking")], more: 0))
    model.progressSize = CGSize(width: 300, height: 78)
    overlay.showListening(at: CGPoint(x: 300, y: 300), hint: "h")
    overlay.drag(.pill, .changed, translation: CGSize(width: 4, height: 3))
    overlay.drag(.pill, .ended, translation: CGSize(width: 4, height: 3))
    #expect(model.pillDrag != .zero)
    #expect(!model.progressFrame.intersects(model.pillFrame), "stack \(model.progressFrame), pill \(model.pillFrame)")
    #expect(model.progressFrame.minY >= model.pillFrame.maxY)
    // Dragged well away, the stack has the top again.
    overlay.drag(.pill, .changed, translation: CGSize(width: 0, height: 400), startedAt: CGPoint(x: 1, y: 1))
    overlay.drag(.pill, .ended, translation: CGSize(width: 0, height: 400), startedAt: CGPoint(x: 1, y: 1))
    #expect(model.progressOrigin.y == model.progressBounds.minY + Placer.edgeMargin)
    overlay.resetPositions()
    overlay.dismiss(.requested)
    overlay.updateProgress(.empty)
}

@Test(.overlayExclusive) func aNudgedResearchCapsuleStillHasThePillAndStackUnderIt() {
    let overlay = BuddyOverlayController(observesSystem: false)
    let model = overlay.model
    overlay.updateCapsule([CapsuleState(id: UUID(), topic: "QT", status: .running(.reading))])
    overlay.updateProgress(.init(rows: [ProgressItem(id: 1, title: "Trip", line: "Thinking")], more: 0))
    model.progressSize = CGSize(width: 300, height: 36)
    overlay.drag(.capsule, .changed, translation: CGSize(width: 5, height: 4), startedAt: CGPoint(x: 8, y: 8))
    overlay.drag(.capsule, .ended, translation: CGSize(width: 5, height: 4), startedAt: CGPoint(x: 8, y: 8))
    #expect(model.capsuleDrag != .zero)
    overlay.showListening(at: CGPoint(x: 300, y: 300), hint: "h")
    let column = [model.capsuleFrame, model.pillFrame, model.progressFrame]
    for (a, b) in zip(column, column.dropFirst()) {
        #expect(!a.intersects(b), "\(a) and \(b) overlap")
        #expect(b.minY >= a.maxY)
    }
    overlay.dismiss(.requested)
    overlay.updateProgress(.empty)
    overlay.updateCapsule([])
}

// MARK: Rule 1, in the trace: every card that shows is closed before the next one shows

@Test(.overlayExclusive) func everyCardReportsItsFrameAndWhyItLeft() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    var changes: [BuddyOverlayController.CardChange] = []
    overlay.onCard = { changes.append($0) }
    overlay.showAnswer(card(turn: 1), anchor: .point(CGPoint(x: 400, y: 500)))
    await overlay.presentationFinished()
    guard case .answer(_, let first, _) = overlay.model.surface else { Issue.record("no answer"); return }
    overlay.showAnswer(card(turn: 2), anchor: .point(CGPoint(x: 400, y: 500)))
    await overlay.presentationFinished()
    overlay.dismiss(.escape)
    overlay.showAnswer(card(turn: 3), anchor: .point(CGPoint(x: 400, y: 500)))
    await overlay.presentationFinished()
    overlay.showListening(at: CGPoint(x: 300, y: 300), hint: "h")
    #expect(changes.count == 6)
    #expect(changes.first == .shown(OverlayModel.outerFrame(first, style: .card)))
    let closes: [BuddyOverlayController.CardClose?] = changes.map { if case .closed(let why) = $0 { why } else { nil } }
    #expect(closes == [nil, .replaced, nil, .dismissed(.escape), nil, .summon], "shown and closed take turns")
    overlay.dismiss(.requested)
}
