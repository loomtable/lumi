import AppKit
import BuddyCore
import Foundation
import SwiftUI
import Testing
@testable import BuddyOverlay

private func item(_ id: Int, _ title: String = "Trip", line: String = "Thinking") -> ProgressItem {
    ProgressItem(id: id, title: title, line: line)
}

// MARK: Model

@Test func queriesStackInTheOrderTheyWereAsked() {
    var stack = ProgressStack()
    stack.begin(item(1, "Trip"))
    stack.begin(item(2, "Budget"))
    stack.begin(item(3, "Repo"))
    #expect(stack.items.map(\.id) == [1, 2, 3])
    // Beginning a running query again keeps its place.
    stack.begin(item(1, "Trip to Lisbon"))
    #expect(stack.items.map(\.id) == [1, 2, 3])
    #expect(stack.items.first?.title == "Trip to Lisbon")
}

@Test func aLiveLineUpdatesOnlyItsOwnQuery() {
    var stack = ProgressStack([item(1), item(2)])
    let changed = stack.update(2, line: "Searching the web for “QT”")
    #expect(changed)
    #expect(stack.items.map(\.line) == ["Thinking", "Searching the web for “QT”"])
    let same = stack.update(2, line: "Searching the web for “QT”")
    #expect(!same, "the same line changes nothing")
    let unknown = stack.update(9, line: "Reading a.md")
    #expect(!unknown, "an unknown query changes nothing")
    let empty = stack.update(1, line: "  ")
    #expect(!empty, "an empty line keeps the last one")
}

@Test func endingAQueryRemovesItsCapsule() {
    var stack = ProgressStack([item(1), item(2), item(3)])
    stack.end(2)
    #expect(stack.items.map(\.id) == [1, 3])
    stack.end(2)
    #expect(stack.items.map(\.id) == [1, 3])
}

@Test func oneTwoAndThreeRunningShowThatManyThenItCapsWithMore() {
    var stack = ProgressStack()
    stack.begin(item(1))
    #expect(stack.shown() == .init(rows: [item(1)], more: 0))
    stack.begin(item(2))
    #expect(stack.shown().rows.count == 2)
    stack.begin(item(3))
    #expect(stack.shown().rows.count == 3)
    #expect(stack.shown().moreLabel == nil)
    stack.begin(item(4))
    stack.begin(item(5))
    let shown = stack.shown()
    #expect(shown.rows.map(\.id) == [1, 2], "the cap counts the +N row")
    #expect(shown.more == 3)
    #expect(shown.moreLabel == "+3 more")
}

@Test func queriesShownElsewhereAreLeftOut() {
    let stack = ProgressStack([item(1), item(2), item(3), item(4)])
    let shown = stack.shown(hiding: [1])
    #expect(shown.rows.map(\.id) == [2, 3, 4])
    #expect(shown.more == 0)
    #expect(stack.shown(hiding: [1, 2, 3, 4]).isEmpty)
}

@Test func titlesAndLinesStayOneShortLine() {
    var stack = ProgressStack()
    stack.begin(ProgressItem(id: 1, title: "A very long session title that keeps going", line: "Reading\nnotes.md"))
    let shown = stack.items[0]
    #expect(shown.title.count == ProgressStack.titleLimit)
    #expect(shown.title.hasSuffix("…"))
    #expect(shown.line == "Reading notes.md")
    stack.update(1, line: String(repeating: "x", count: 200))
    #expect(stack.items[0].line.count == ProgressStack.lineLimit)
    stack.begin(ProgressItem(id: 2, title: " ", line: "Thinking"))
    #expect(stack.items[1].title == "New session")
}

@Test func renameReportsChanges() {
    var stack = ProgressStack([item(1, "New words")])
    let renamed = stack.rename(1, title: "Budget", symbol: "chart.bar", color: .sage)
    #expect(renamed)
    let again = stack.rename(1, title: "Budget", symbol: "chart.bar", color: .sage)
    #expect(!again)
    #expect(stack.items[0] == ProgressItem(id: 1, title: "Budget", symbol: "chart.bar", color: .sage, line: "Thinking"))
    #expect(ProgressItem(id: 1, title: "budget", line: "").monogram == "B")
}

// MARK: Overlay

private let lane = Lane(mode: .quick, model: .haiku)

@Test(.overlayExclusive) func theStackShowsOnTheActiveDisplayAndNeverTakesClicks() throws {
    let overlay = BuddyOverlayController(observesSystem: false)
    overlay.updateProgress(.init(rows: [item(1)], more: 0))
    #expect(overlay.model.progressVisible)
    #expect(overlay.model.progressScreenFrame != .zero)
    #expect(overlay.model.shows(onDisplay: overlay.model.progressScreenFrame))
    #expect(overlay.visiblePanelCountForTesting == 1)
    #expect(overlay.model.hitFrames(onDisplay: overlay.model.progressScreenFrame).isEmpty, "capsules are click-through")
    #expect(!overlay.focusableForTesting)
    overlay.updateProgress(.empty)
    #expect(!overlay.model.progressVisible)
    #expect(overlay.visiblePanelCountForTesting == 0)
}

@Test(.overlayExclusive) func theStackSitsUnderThePillAtTheTopElseAtTheTopOfTheScreen() {
    let overlay = BuddyOverlayController(observesSystem: false)
    let model = overlay.model
    overlay.updateProgress(.init(rows: [item(1)], more: 0))
    let top = model.progressBounds.minY + Placer.edgeMargin
    #expect(model.progressOrigin.y == top)
    overlay.showThinking(lane, status: "Reading the page")
    #expect(model.progressScreenFrame == model.screenFrame, "the stack follows the pill's display")
    #expect(model.progressOrigin.y == model.pillFrame.maxY + OverlayModel.progressGap)
    #expect(!model.progressFrame.intersects(model.pillFrame))
    model.settings.statusPosition = .bottom
    #expect(model.progressOrigin.y == top, "a pill at the bottom leaves the top to the stack")
    overlay.dismiss(.escape)
    overlay.updateProgress(.empty)
}

@Test(.overlayExclusive) func onlyANeedsYouCapsuleTakesClicks() {
    let overlay = BuddyOverlayController(observesSystem: false)
    let model = overlay.model
    var waiting = item(2, "Budget", line: "Needs your OK")
    waiting.needsYou = true
    waiting.session = SessionID(rawValue: "s_b")
    overlay.updateProgress(.init(rows: [item(1), waiting], more: 0))
    let display = model.progressScreenFrame
    model.progressRowFrames = [1: CGRect(x: 10, y: 10, width: 200, height: 36), 2: CGRect(x: 10, y: 52, width: 200, height: 36)]
    #expect(model.progressTakesClicks)
    #expect(model.hitFrames(onDisplay: display) == [CGRect(x: 10, y: 52, width: 200, height: 36)])
    overlay.updateProgress(.init(rows: [item(1)], more: 0))
    #expect(!model.progressTakesClicks)
    #expect(model.hitFrames(onDisplay: display).isEmpty)
    overlay.updateProgress(.empty)
}

@Test func setNeedsYouChangesStateAndLine() {
    var stack = ProgressStack([item(1)])
    let set = stack.setNeedsYou(1, true, line: "Needs your OK")
    #expect(set)
    #expect(stack.items[0].needsYou && stack.items[0].line == "Needs your OK")
    let cleared = stack.setNeedsYou(1, false)
    #expect(cleared)
    #expect(!stack.items[0].needsYou && stack.items[0].line == "Needs your OK", "the line stays until the next step")
    let unknown = stack.setNeedsYou(7, true)
    #expect(!unknown)
}

@Test func theFakeKeepsProgressApartFromItsCalls() {
    let fake = FakeOverlay()
    fake.updateProgress(.init(rows: [item(1)], more: 0))
    #expect(fake.progress.rows.map(\.id) == [1])
    #expect(fake.calls.isEmpty)
}

// MARK: Render

@MainActor private func fitting<V: View>(_ view: V) -> CGSize {
    NSHostingView(rootView: view.fixedSize()).fittingSize
}

@MainActor private func column(_ rows: [ProgressItem], more: Int = 0) -> some View {
    TokensReader { t in ProgressColumn(shown: .init(rows: rows, more: more), t: t, reduceMotion: true) }
}

@Test(.overlayExclusive) func eachRunningQueryAddsOneCapsuleRow() {
    let one = fitting(column([item(1)]))
    let two = fitting(column([item(1), item(2, "Budget")]))
    let three = fitting(column([item(1), item(2), item(3)]))
    let capped = fitting(column([item(1), item(2)], more: 3))
    #expect(one.height >= 28)
    #expect(two.height > one.height + 20)
    #expect(three.height > two.height + 20)
    #expect(capped.height > two.height, "the +N row adds height")
    #expect(capped.height < three.height, "and is smaller than a capsule")
}

@Test(.overlayExclusive) func aLongLineIsCutAtThePillWidth() {
    let short = fitting(column([item(1, line: "Reading a.md")]))
    let long = fitting(column([item(1, line: String(repeating: "Searching the web for things ", count: 6))]))
    #expect(short.width < ProgressCapsule.maxWidth)
    #expect(long.width <= ProgressCapsule.maxWidth + 1)
    #expect(long.height == short.height, "one line, never wrapped")
}

// MARK: Research capsule bar

@Test(.overlayExclusive) func theResearchBarHoldsStillWithReduceMotion() {
    let bar = IndeterminateBar.BarView(frame: NSRect(x: 0, y: 0, width: 50, height: 4))
    bar.setRunning(true)
    #expect(bar.fillLayer.animation(forKey: "slide") != nil)
    bar.still = true
    bar.setRunning(true)
    bar.layout()
    #expect(bar.fillLayer.animation(forKey: "slide") == nil, "no slide with Reduce Motion")
    #expect(bar.fillLayer.position.x == 0, "a static 35% fill shows instead")
}
