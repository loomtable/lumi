import AppKit
import BuddyCore
import Foundation
import SwiftUI
import Testing
@testable import BuddyOverlay

// MARK: Past cards as text

@Test func cardTextKeepsParagraphsListsAndTablesReadable() {
    let html = """
    <h3>Why it fails</h3><p>The list is <b>empty</b>
       when the page loads.</p>
    <ul><li>Fetch runs late</li><li>State resets</li></ul>
    <table><tr><th>Plan</th><th>Cost</th></tr><tr><td>Basic</td><td>$4</td></tr></table>
    """
    #expect(CardText.plainText(fromHTML: html) == """
    Why it fails
    The list is empty when the page loads.
    • Fetch runs late
    • State resets
    Plan · Cost
    Basic · $4
    """)
}

@Test func cardTextKeepsCodeLinesAndDecodesEntities() {
    let html = "<pre>if a &lt; b {\n    return &quot;x&quot;\n}</pre><p>A&amp;B&nbsp;&#8594; &#x2713; &bogus; 5 & 6</p>"
    #expect(CardText.plainText(fromHTML: html) == "if a < b {\n    return \"x\"\n}\nA&B → ✓ &bogus; 5 & 6")
    #expect(CardText.plainText(fromHTML: "<p>a&#0;b&#7;c</p>") == "a&#0;b&#7;c", "no control characters")
}

@Test func cardTextKeepsAStrayLessThanAsText() {
    #expect(CardText.plainText(fromHTML: "<p>if a < b then</p><p>x</p>") == "if a < b then\nx")
    #expect(CardText.plainText(fromHTML: "<p>5 <6 and 7 < 8") == "5 <6 and 7 < 8", "never closes: kept, not dropped")
    #expect(CardText.plainText(fromHTML: "<p>a <b class=\"x>y\">bold</b> c</p>") == "a bold c", "a quoted > stays in its tag")
}

@Test func cardTextScriptsEndOnlyAtTheirEndTag() {
    let html = "<script>if(a<b){x('</p>')}</SCRIPT ><p>Hi</p><style>p>b{}</style><p>There</p>"
    #expect(CardText.plainText(fromHTML: html) == "Hi\nThere")
    #expect(CardText.plainText(fromHTML: "<p>Before</p><script>never closed <p>x</p>") == "Before")
}

@Test func cardTextKeepsATableRowOnOneLine() {
    let html = "<table><tr><td><p>Basic</p></td><td><div>$4</div><br>monthly</td></tr><tr><td>Pro</td><td>$9</td></tr></table>"
    #expect(CardText.plainText(fromHTML: html) == "Basic · $4 monthly\nPro · $9")
}

@Test func cardTextLeavesOutStylesScriptsDiagramsAndComments() {
    let html = """
    <style>p { color: var(--ember) }</style><!-- note <p>hidden</p> -->
    <svg viewBox="0 0 10 10"><g><text>Node A</text></g><svg><text>inner</text></svg></svg>
    <p>After the diagram.</p><img src="data:image/png;base64,AAAA"><script>alert(1)</script>
    """
    #expect(CardText.plainText(fromHTML: html) == "After the diagram.")
}

@Test func pastAnswerShowsTextOnlyWhenTheCardHasSome() {
    #expect(PastAnswer.cardText(BuddyBlock(say: "s", shape: .card)) == nil)
    #expect(PastAnswer.cardText(BuddyBlock(say: "s", shape: .rich, cardHTML: "<svg></svg>")) == nil)
    #expect(PastAnswer.cardText(BuddyBlock(say: "s", shape: .rich, cardHTML: "<p>Hi</p>")) == "Hi")
}

// MARK: Transcript mode

private func turn(_ i: Int, html: String? = nil) -> TranscriptTurn {
    TranscriptTurn(id: "t\(i)", question: "Question \(i)?",
                   block: BuddyBlock(say: "Answer \(i).", shape: .card, cardHTML: html,
                                     actions: [BuddyBlock.Action(label: "Do \(i)", prompt: "p")]),
                   mode: .quick, model: .haiku)
}

private func answer(earlier: [TranscriptTurn], shape: BuddyBlock.Shape = .card, html: String? = nil) -> Answer {
    Answer(block: BuddyBlock(say: "The latest answer.", shape: shape, cardHTML: html,
                             actions: [BuddyBlock.Action(label: "Open", prompt: "p")]),
           lane: Lane(mode: .deep, model: .opus), conversation: .sage, turn: earlier.count + 1, replyHint: "reply",
           question: "And now?", earlier: earlier)
}

@Test func transcriptShowsOnlyInFullScreenWithEarlierTurns() {
    let t = Tokens(.init(dark: false))
    func shows(_ a: Answer, style: Placer.Style, full: Bool) -> Bool {
        AnswerContent(answer: a, style: style, t: t, web: nil, webHeight: 0, fullScreen: full).showsTranscript
    }
    #expect(shows(answer(earlier: [turn(1)]), style: .card, full: true))
    #expect(!shows(answer(earlier: [turn(1)]), style: .card, full: false), "a normal card stays a card")
    #expect(!shows(answer(earlier: []), style: .card, full: true), "a first answer is the card, larger")
    #expect(!shows(answer(earlier: [turn(1)], shape: .chip), style: .chip, full: true))
}

/// The scroll view inside a hosting view, once SwiftUI has laid it out.
private func scrollView(in view: NSView) -> NSScrollView? {
    if let s = view as? NSScrollView { return s }
    for sub in view.subviews { if let s = scrollView(in: sub) { return s } }
    return nil
}

/// Lays out full screen's transcript in an offscreen window (so SwiftUI lays out and scrolls
/// as on screen) and waits until `opened` holds for its scroll view's document and visible rect.
private func transcriptOpens(_ a: Answer, webHeight: CGFloat = 0,
                             _ opened: @escaping (_ document: CGRect, _ visible: CGRect) -> Bool) async -> Bool {
    let content = AnswerContent(answer: a, style: .centered, t: Tokens(.init(dark: true)),
                                web: nil, webHeight: webHeight, fullScreen: true)
    let host = NSHostingView(rootView: content.frame(width: 900, height: 700))
    let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 900, height: 700),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    return await waitUntil {
        host.layoutSubtreeIfNeeded()
        guard let s = scrollView(in: host), let doc = s.documentView else { return false }
        return opened(doc.frame, s.contentView.documentVisibleRect)
    }
}

@Test(.overlayExclusive) func longTranscriptOpensOnTheLatestAnswer() async {
    let earlier = (1...300).map { turn($0, html: "<p>Card \($0) with a few words of detail.</p>") }
    let opened = await transcriptOpens(answer(earlier: earlier)) { doc, visible in
        // Laid out lazily from the bottom: the visible part is the end of a long document.
        doc.height > visible.height * 3 && doc.height - visible.maxY < 2
    }
    #expect(opened, "full screen lands on the newest answer, with history above it")
}

@Test(.overlayExclusive) func aLongLatestAnswerOpensAtItsTop() async {
    // The live card is 2,000 pt tall: the view opens at its start, not its end.
    let opened = await transcriptOpens(answer(earlier: (1...20).map { turn($0) }, shape: .rich, html: "<p>x</p>"),
                                       webHeight: 2_000) { doc, visible in
        visible.minY > 0 && doc.height - visible.maxY > 1_500
    }
    #expect(opened)
}

@Test(.overlayExclusive) func transcriptGivesTheLiveCardItsWholeFullWidthHeight() async {
    for earlier in [[turn(1), turn(2)], []] {
        let overlay = BuddyOverlayController()
        overlay.showAnswer(answer(earlier: earlier, shape: .rich, html: "<p>Card</p>"),
                           anchor: .point(CGPoint(x: 400, y: 400)))
        await overlay.presentationFinished()
        overlay.toggleFullScreen()
        #expect(overlay.model.fullScreen)
        overlay.model.web?.onHeightChange?(5_000)  // reflowed at the full width, taller than any display
        if earlier.isEmpty {
            #expect(overlay.model.fullScreenWebHeight < 5_000, "without history the card fits the space and scrolls")
        } else {
            #expect(overlay.model.fullScreenWebHeight == 5_000, "the transcript scrolls, so the card isn't clipped")
        }
        overlay.toggleFullScreen()
        overlay.dismiss(.requested)
    }
}

@Test func transcriptWebHeightIsTheContentWithAFloor() {
    #expect(BuddyOverlayController.transcriptWebHeight(content: 2_400) == 2_400)
    #expect(BuddyOverlayController.transcriptWebHeight(content: 10) == 80)
}

private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now + timeout
    while clock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

// MARK: Wheel scrolling over the card

private final class WheelRecorder: NSResponder {
    var wheels = 0
    override func scrollWheel(with event: NSEvent) { wheels += 1 }
}

@Test func cardWebViewPassesWheelScrollsOnOnlyInTheTranscript() throws {
    let web = CardWebContent(width: 300)
    let view = try #require(web.webView as? CardWKWebView)
    let recorder = WheelRecorder()
    view.nextResponder = recorder
    let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -20, wheel2: 0, wheel3: 0))
    let event = try #require(NSEvent(cgEvent: cg))
    view.forwardsScrollWheel = true
    view.scrollWheel(with: event)
    #expect(recorder.wheels == 1)
    view.forwardsScrollWheel = false
    view.scrollWheel(with: event)
    #expect(recorder.wheels == 1, "on a normal card the web view scrolls itself")
    web.tearDown()
}

@Test func cardWebViewMovesBetweenHostsWithoutGettingLost() {
    let web = CardWebContent(width: 300)
    let frame = CGRect(x: 0, y: 0, width: 300, height: 100)
    let card = NSHostingView(rootView: AnyView(CardWebView(content: web, dark: false).frame(width: 300, height: 100)))
    card.frame = frame
    card.layoutSubtreeIfNeeded()
    let first = web.webView.superview
    #expect(first != nil)
    let transcript = NSHostingView(rootView: CardWebView(content: web, dark: true, forwardsScrollWheel: true)
        .frame(width: 300, height: 100))
    transcript.frame = frame
    transcript.layoutSubtreeIfNeeded()
    let second = web.webView.superview
    #expect(second != nil && second !== first)
    #expect((web.webView as? CardWKWebView)?.forwardsScrollWheel == true)
    // The old host going away removes only its own container, not the web view's new home.
    card.rootView = AnyView(EmptyView())
    card.layoutSubtreeIfNeeded()
    #expect(web.webView.superview === second)
    #expect(second?.isDescendant(of: transcript) == true)
    web.tearDown()
}

@Test(.overlayExclusive) func theWebViewFollowsTheCardIntoTheTranscriptAndBack() async {
    let web = CardWebContent(width: 300)
    _ = await web.load(html: "<p>Card</p>")
    let a = answer(earlier: [turn(1)], shape: .rich, html: "<p>Card</p>")
    func content(_ full: Bool) -> AnswerContent {
        AnswerContent(answer: a, style: .centered, t: Tokens(.init(dark: false)), web: web, webHeight: 120,
                      inkIn: true, fullScreen: full)
    }
    let host = NSHostingView(rootView: content(false))
    let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 700, height: 600),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    #expect(web.webView.window === window)
    // One view, two branches: into the transcript and back out again.
    host.rootView = content(true)
    host.layoutSubtreeIfNeeded()
    #expect(await waitUntil { web.webView.window === window && (web.webView as? CardWKWebView)?.forwardsScrollWheel == true })
    host.rootView = content(false)
    host.layoutSubtreeIfNeeded()
    #expect(await waitUntil { web.webView.window === window && (web.webView as? CardWKWebView)?.forwardsScrollWheel == false })
    web.tearDown()
}

// MARK: Conversations window transcript

@Test(.overlayExclusive) func conversationTranscriptOpensOnTheNewestTurn() async {
    let turns = (1...200).map { turn($0, html: "<p>Card \($0) with a few words of detail.</p>") }
    let host = NSHostingView(rootView: TranscriptView(turns: turns).frame(width: 520, height: 600))
    let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 520, height: 600),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    let opened = await waitUntil {
        host.layoutSubtreeIfNeeded()
        guard let s = scrollView(in: host), let doc = s.documentView else { return false }
        let visible = s.contentView.documentVisibleRect
        return doc.frame.height > visible.height * 3 && doc.frame.height - visible.maxY < 2
    }
    #expect(opened, "a long conversation opens at its newest turn, with history above it")
}

@Test(.overlayExclusive) func aShortConversationSitsAtTheTop() async {
    let host = NSHostingView(rootView: TranscriptView(turns: [turn(1)]).frame(width: 520, height: 600))
    let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 520, height: 600),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    // Drawn pixels in the top and bottom thirds of the pane.
    func inked() -> (top: Int, bottom: Int) {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return (0, 0) }
        host.cacheDisplay(in: host.bounds, to: rep)
        var top = 0, bottom = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                if y < rep.pixelsHigh / 3 { top += 1 } else if y > rep.pixelsHigh * 2 / 3 { bottom += 1 }
            }
        }
        return (top, bottom)
    }
    let atTop = await waitUntil { let i = inked(); return i.top > 0 && i.bottom == 0 }
    #expect(atTop, "one turn shows at the top of the pane, with no gap above it")
}
