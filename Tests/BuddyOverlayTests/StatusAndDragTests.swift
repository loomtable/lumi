import AppKit
import BuddyCore
import Foundation
import Testing
@testable import BuddyOverlay

private let bounds = CGRect(x: 0, y: 33, width: 1512, height: 916)

private func model(_ position: OverlaySettings.StatusPosition = .top) -> OverlayModel {
    let m = OverlayModel()
    m.settings.statusPosition = position
    m.pillBounds = bounds
    m.screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    return m
}

@Test(.overlayExclusive) func statusPillSitsAtTopOrBottomCentreWhateverThePointer() {
    let size = CGSize(width: 200, height: 36)
    let area = bounds.insetBy(dx: Placer.edgeMargin, dy: Placer.edgeMargin)
    let top = model(.top).statusPillOrigin(size: size, in: bounds)
    #expect(top == CGPoint(x: (area.midX - 100).rounded(), y: area.minY))
    let bottom = model(.bottom).statusPillOrigin(size: size, in: bounds)
    #expect(bottom == CGPoint(x: (area.midX - 100).rounded(), y: area.maxY - 36))
}

@Test(.overlayExclusive) func atTheTopThePillClearsTheResearchCapsule() {
    let m = model(.top)
    m.capsuleScreenFrame = m.screenFrame
    m.capsuleBounds = bounds
    m.capsules = [CapsuleState(id: UUID(), topic: "QT", status: .running(.reading))]
    let origin = m.statusPillOrigin(size: CGSize(width: 200, height: 36), in: bounds)
    #expect(origin.y >= m.capsuleFrame.maxY + 8)
}

@Test(.overlayExclusive) func theGrowingPillStaysCentred() {
    let m = model()
    m.placeStatusPill()
    m.pillSize = CGSize(width: 400, height: 36)  // thinking is wider than listening
    #expect(abs(m.pillFrame.midX - bounds.insetBy(dx: Placer.edgeMargin, dy: 0).midX) <= 1)
}

@Test(.overlayExclusive) func aDraggedPillKeepsItsSpotUntilANewConversation() {
    let overlay = BuddyOverlayController(observesSystem: false)
    /// The pill's offset from its centred fixed spot (its size changes once the view measures it).
    func offset() -> CGSize {
        let m = overlay.model, area = m.pillBounds.insetBy(dx: Placer.edgeMargin, dy: Placer.edgeMargin)
        return CGSize(width: m.pillFrame.midX - area.midX, height: m.pillOrigin.y - area.minY)
    }
    overlay.showListening(at: CGPoint(x: 300, y: 300), hint: "h")
    #expect(abs(offset().width) <= 1 && offset().height == 0)
    overlay.drag(.pill, .changed, translation: CGSize(width: 50, height: 120))
    overlay.drag(.pill, .ended, translation: CGSize(width: 60, height: 140))
    #expect(abs(offset().width - 60) <= 1 && offset().height == 140)
    overlay.dismiss(.requested)
    overlay.showListening(at: CGPoint(x: 900, y: 700), hint: "h")      // next turn, same conversation
    #expect(abs(offset().width - 60) <= 1 && offset().height == 140, "kept for the conversation")
    overlay.resetPositions()
    #expect(abs(offset().width) <= 1 && offset().height == 0, "a new conversation starts at the fixed spot")
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func aDraggedAnswerLosesItsTailAndLaterAnswersOpenThere() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    func answer(turn: Int) -> Answer {
        Answer(block: BuddyBlock(say: "Hi.", shape: .card), lane: Lane(mode: .quick, model: .haiku),
               conversation: .ember, turn: turn, replyHint: "r")
    }
    overlay.showAnswer(answer(turn: 1), anchor: .point(CGPoint(x: 400, y: 400)))
    await overlay.presentationFinished()
    guard case .answer(_, let before, _) = overlay.model.surface else { Issue.record("no answer"); return }
    overlay.drag(.answer, .changed, translation: CGSize(width: 200, height: 100))
    overlay.drag(.answer, .ended, translation: CGSize(width: 200, height: 100))
    guard case .answer(_, let after, _) = overlay.model.surface else { Issue.record("no answer"); return }
    #expect(after.frame.origin == CGPoint(x: before.frame.minX + 200, y: before.frame.minY + 100))
    #expect(after.tailOffset == nil, "moved off its anchor: no tail")
    overlay.showAnswer(answer(turn: 2), anchor: .point(CGPoint(x: 900, y: 200)))
    await overlay.presentationFinished()
    guard case .answer(_, let next, _) = overlay.model.surface else { Issue.record("no answer"); return }
    #expect(next.frame.origin == after.frame.origin, "the conversation's answers open where it was dragged")
    overlay.showAnswer(answer(turn: 1), anchor: .point(CGPoint(x: 900, y: 200)))  // a new conversation
    await overlay.presentationFinished()
    guard case .answer(_, let fresh, _) = overlay.model.surface else { Issue.record("no answer"); return }
    #expect(fresh.frame.origin != after.frame.origin)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func aDraggedCapsuleStaysWhileItShows() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.updateCapsule([CapsuleState(id: UUID(), topic: "QT", status: .running(.reading))])
    let home = overlay.model.capsuleFrame
    overlay.drag(.capsule, .changed, translation: CGSize(width: -300, height: 200))
    overlay.drag(.capsule, .ended, translation: CGSize(width: -300, height: 200))
    #expect(overlay.model.capsuleFrame.origin == CGPoint(x: home.minX - 300, y: home.minY + 200))
    overlay.updateCapsule([])
    #expect(overlay.model.capsuleDrag == .zero)
}

@Test(.overlayExclusive) func fullScreenAnswersDontDrag() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showAnswer(Answer(block: BuddyBlock(say: "Hi.", shape: .card), lane: Lane(mode: .quick, model: .haiku),
                              conversation: .ember, turn: 1, replyHint: "r"), anchor: .point(CGPoint(x: 400, y: 400)))
    await overlay.presentationFinished()
    overlay.toggleFullScreen()
    overlay.drag(.answer, .changed, translation: CGSize(width: 200, height: 100))
    overlay.drag(.answer, .ended, translation: CGSize(width: 200, height: 100))
    #expect(overlay.model.answerOrigin == nil)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func aDragCutOffMidwayDoesntLeakIntoTheNext() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showListening(at: CGPoint(x: 300, y: 300), hint: "h")
    overlay.drag(.pill, .changed, translation: CGSize(width: 80, height: 80), startedAt: CGPoint(x: 1, y: 1))
    // The pill's view went away before .ended (e.g. it became the card); a new gesture starts.
    let afterFirst = overlay.model.pillDrag
    overlay.drag(.pill, .changed, translation: CGSize(width: 10, height: 0), startedAt: CGPoint(x: 2, y: 2))
    #expect(overlay.model.pillDrag == CGSize(width: afterFirst.width + 10, height: afterFirst.height),
            "the new gesture starts from where the pill is, not from the old gesture's start")
    overlay.drag(.pill, .ended, translation: CGSize(width: 10, height: 0), startedAt: CGPoint(x: 2, y: 2))
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func draggingPastAnEdgeLeavesNoDeadZone() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.showListening(at: CGPoint(x: 300, y: 300), hint: "h")
    let home = overlay.model.pillOrigin
    overlay.drag(.pill, .changed, translation: CGSize(width: 0, height: -5_000), startedAt: CGPoint(x: 5, y: 5))
    overlay.drag(.pill, .ended, translation: CGSize(width: 0, height: -5_000), startedAt: CGPoint(x: 5, y: 5))
    #expect(overlay.model.pillOrigin.y == home.y, "clamped at the top")
    overlay.drag(.pill, .changed, translation: CGSize(width: 0, height: 40), startedAt: CGPoint(x: 6, y: 6))
    #expect(overlay.model.pillOrigin.y == home.y + 40, "moves straight back down")
    overlay.drag(.pill, .ended, translation: CGSize(width: 0, height: 40), startedAt: CGPoint(x: 6, y: 6))
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func chipsStayNextToTheAnchorEvenAfterADrag() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    func answer(_ shape: BuddyBlock.Shape, turn: Int) -> Answer {
        Answer(block: BuddyBlock(say: "Hi.", shape: shape), lane: Lane(mode: .quick, model: .haiku),
               conversation: .ember, turn: turn, replyHint: "r")
    }
    overlay.showAnswer(answer(.card, turn: 1), anchor: .point(CGPoint(x: 400, y: 400)))
    await overlay.presentationFinished()
    overlay.drag(.answer, .changed, translation: CGSize(width: 300, height: 200), startedAt: CGPoint(x: 7, y: 7))
    overlay.drag(.answer, .ended, translation: CGSize(width: 300, height: 200), startedAt: CGPoint(x: 7, y: 7))
    let dragged = overlay.model.answerOrigin
    #expect(dragged != nil)
    overlay.showAnswer(answer(.chip, turn: 2), anchor: .point(CGPoint(x: 400, y: 400)))
    await overlay.presentationFinished()
    guard case .answer(_, let chip, _) = overlay.model.surface else { Issue.record("no chip"); return }
    #expect(chip.frame.origin != dragged, "chips ignore the dragged spot")
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func draggingTheCapsuleAwayLetsThePillMoveUp() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.updateCapsule([CapsuleState(id: UUID(), topic: "QT", status: .running(.reading))])
    overlay.showListening(at: CGPoint(x: 300, y: 300), hint: "h")
    let belowCapsule = overlay.model.pillOrigin.y
    overlay.drag(.capsule, .changed, translation: CGSize(width: 0, height: 300), startedAt: CGPoint(x: 8, y: 8))
    overlay.drag(.capsule, .ended, translation: CGSize(width: 0, height: 300), startedAt: CGPoint(x: 8, y: 8))
    #expect(overlay.model.pillOrigin.y < belowCapsule)
    overlay.updateCapsule([])
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func ringsOffDrawsNoRingsEvenIfAsked() {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.settings.rings = false
    overlay.showRings([Ring(rect: CGRect(x: 100, y: 100, width: 80, height: 20), label: "1")])
    #expect(overlay.model.rings.isEmpty)
    overlay.settings.rings = true
    overlay.showRings([Ring(rect: CGRect(x: 100, y: 100, width: 80, height: 20), label: "1")])
    #expect(overlay.model.rings.count == 1)
    #expect(OverlaySettings().rings, "on by default")
    overlay.settings.rings = false
    #expect(overlay.model.rings.isEmpty, "turning it off clears rings already on screen")
}

@Test func withRingsOffCardsHideJumpLinks() {
    #expect(CardWebContent.document(body: "<p>x</p>", jumps: false).contains(#"a[href^="buddy://jump/"] { display: none; }"#))
    #expect(!CardWebContent.document(body: "<p>x</p>").contains("display: none"))
}
