import AppKit
import BuddyCore
import Foundation
import Testing
import WebKit
@testable import BuddyOverlay

private final class RecordingClipboard: ClipboardWriting {
    var written: [ClipboardContents] = []
    func write(_ contents: ClipboardContents) { written.append(contents) }
}

private func answer(_ block: BuddyBlock, main: MainAction? = nil) -> Answer {
    Answer(block: block, lane: Lane(mode: .quick, model: .haiku), conversation: .ember, turn: 1, replyHint: "r", mainAction: main)
}

@Test func copyTakesThePasteTextNeverTheHeadline() {
    let draft = BuddyBlock(say: "Here's a warmer version.", shape: .card, cardHTML: "<p>Hi Sam, Friday works.</p>",
                           insert: "Hi Sam, Friday works.")
    #expect(AnswerClipboard.contents(for: draft) == ClipboardContents(plain: "Hi Sam, Friday works.", html: nil))
}

@Test func copyOfAFormattedAnswerIsPlainAndRich() {
    let block = BuddyBlock(say: "South grew fastest.", shape: .card,
                           cardHTML: "<table><tr><th>Region</th><th>Growth</th></tr><tr><td>South &amp; East</td><td>21%</td></tr></table><ul><li>One</li><li>Two</li></ul>")
    let c = AnswerClipboard.contents(for: block)
    #expect(c.plain.hasPrefix("South grew fastest.\n\n"))
    #expect(c.plain.contains("Region\tGrowth"))
    #expect(c.plain.contains("South & East\t21%"))
    #expect(c.plain.contains("• One\n• Two"))
    #expect(!c.plain.contains("<"))
    #expect(c.html?.hasPrefix("<p><strong>South grew fastest.</strong></p>") == true)
    #expect(AnswerClipboard.contents(for: BuddyBlock(say: "Just this.", shape: .chip)) == ClipboardContents(plain: "Just this.", html: nil))
}

@Test func plainTextDropsScriptsAndDecodesEntities() {
    let text = AnswerClipboard.plainText(fromHTML: "<style>p{}</style><script>x()</script><p>a &lt;b&gt;</p><br><p>c</p>")
    #expect(text == "a <b>\n\nc", "one blank line between paragraphs at most")
}

@Test func commandCCopiesUnlessAFieldIsBeingEdited() {
    #expect(KeyCommand.map(keyCode: 8, characters: "c", modifiers: .command, plainKeysActive: true, actionCount: 0) == .copy)
    #expect(KeyCommand.map(keyCode: 8, characters: "c", modifiers: .command, plainKeysActive: false, actionCount: 0) == nil,
            "the reply field keeps ⌘C for its own selection")
}

@Test func commandReturnRunsTheMainButtonWhenThereIsOne() {
    let ret = KeyCommand.returnKeyCode
    #expect(KeyCommand.map(keyCode: ret, characters: "\r", modifiers: .command, plainKeysActive: true, actionCount: 2,
                           mainAction: .insert) == .event(.mainAction(.insert)))
    #expect(KeyCommand.map(keyCode: ret, characters: "\r", modifiers: .command, plainKeysActive: true, actionCount: 2)
            == .event(.action(index: 0)), "no main button: the first model action, as before")
}

@Test func theMainButtonTakesOneOfTheThreeSlots() {
    let three = BuddyBlock(say: "x", shape: .card, actions: (1...3).map { .init(label: "A\($0)", prompt: "p") })
    #expect(AnswerContent.shownActions(three, isChip: false, mainAction: .copy).count == 2)
    #expect(AnswerContent.shownActions(three, isChip: true, mainAction: .copy).isEmpty, "a chip shows just the main button")
    #expect(AnswerContent.shownActions(three, isChip: false).count == 3)
    #expect(AnswerContent.kind(ofAction: 0, block: three, isChip: false, mainAction: .insert) == .quiet,
            "the model's first action steps down when there's a main button")
    #expect(MainAction.allCases.map(\.label) == ["Insert", "Replace", "Copy"])
}

@Test(.overlayExclusive) func copyAnswerWritesTheClipboardAndSaysCopied() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    let clipboard = RecordingClipboard()
    overlay.clipboard = clipboard
    overlay.copyAnswer()                                            // nothing shown: nothing copied
    #expect(clipboard.written.isEmpty)
    overlay.showAnswer(answer(BuddyBlock(say: "Hi.", shape: .card, insert: "Hello there")), anchor: .point(CGPoint(x: 400, y: 400)))
    await overlay.presentationFinished()
    overlay.copyAnswer()
    #expect(clipboard.written == [ClipboardContents(plain: "Hello there", html: nil)])
    #expect(overlay.model.toast?.text == "Copied")
    overlay.copyBlock("let x = 1")
    #expect(clipboard.written.last == ClipboardContents(plain: "let x = 1", html: nil))
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func codeBlocksGetTheirOwnCopy() async throws {
    let content = CardWebContent(width: 300)
    defer { content.tearDown() }
    var copied: String?
    content.onCopy = { copied = $0 }
    try #require(await content.load(html: "<p>Run:</p><pre>swift test</pre><div data-copy>Hi Sam</div>", timeout: .seconds(5)) != nil)
    let count = try await content.webView.evaluateJavaScript("String(document.querySelectorAll('.buddy-copy').length)",
                                                             in: nil, contentWorld: .world(name: "buddy-card")) as? String
    #expect(count == "2", "one per code block and per data-copy block")
    _ = try await content.webView.evaluateJavaScript("document.querySelector('pre .buddy-copy').click(); 'ok'",
                                                     in: nil, contentWorld: .world(name: "buddy-card"))
    let deadline = ContinuousClock.now + .seconds(10)
    while copied == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(copied == "swift test", "the block's text, without the button's own label")
}

@Test func copiedCodeKeepsItsIndentation() {
    let text = AnswerClipboard.plainText(fromHTML: "<p>Fix:</p><pre><code>func f() {\n    return 1   \n}</code></pre>")
    #expect(text == "Fix:\n\nfunc f() {\n    return 1\n}", "a blank line before the code; its indentation kept")
}

@Test func prettyPrintedHTMLDoesntSplitRowsOrSentences() {
    let html = """
    <p>The rate rose
       sharply.</p>
    <table>
      <tr>
        <td>South</td>
        <td>21%</td>
      </tr>
    </table>
    """
    let t = AnswerClipboard.plainText(fromHTML: html)
    #expect(t == "The rate rose sharply.\nSouth\t21%")
}

@Test func everyEntityFormIsDecoded() {
    #expect(AnswerClipboard.decodeEntities("it&#8217;s &#x27;ok&#x27; &mdash; 5&nbsp;&lt;&amp;&gt; &amp;lt;") == "it’s 'ok' — 5 <&> &lt;")
}

@Test func unclosedScriptsAreLinearAndRemoved() {
    let hostile = String(repeating: "<script>x", count: 20_000)
    let start = ContinuousClock.now
    #expect(AnswerClipboard.plainText(fromHTML: "<p>keep</p>" + hostile) == "keep")
    #expect(ContinuousClock.now - start < .seconds(2))
}

@Test func theRichCopyLeavesTheCardsInternalsBehind() {
    let html = AnswerClipboard.richHTML(#"<style>p{color:var(--ember)}</style><p>See <a href="buddy://jump/1">jump</a> and <a href="https://example.com">site</a></p>"#)
    #expect(!html.contains("<style") && !html.contains("buddy:"))
    #expect(html.contains(#"href="https://example.com""#))
}

@Test func aDraftsLinkGetsAButtonAndASlot() throws {
    let link = try #require(BuddyBlock.Link(label: "Open draft", url: URL(string: "https://www.mail.google.com/x")!))
    let three = BuddyBlock(say: "Drafted.", shape: .card, actions: (1...3).map { .init(label: "A\($0)", prompt: "p") }, link: link)
    #expect(AnswerContent.showsLink(three, isChip: false))
    #expect(AnswerContent.shownActions(three, isChip: false).count == 2, "the link takes one of the three slots")
    #expect(AnswerContent.shownActions(three, isChip: false, mainAction: .copy).count == 1)
    #expect(!AnswerContent.showsLink(three, isChip: true), "a chip's one slot isn't the link")
    #expect(AnswerContent.linkTitle(link) == "Open draft · mail.google.com")
    let long = try #require(BuddyBlock.Link(label: "Open the reply draft to Sarah about Friday", url: URL(string: "https://mail.google.com")!))
    #expect(AnswerContent.linkTitle(long) == "Open the reply draft to… · mail.google.com", "the domain always shows")
    #expect(BuddyBlock.Link(label: "x", url: URL(string: "http://example.com")!) == nil, "https only (BuddyCore)")
}

@Test(.overlayExclusive) func codeNeverRunsUnderItsCopyButton() async throws {
    let content = CardWebContent(width: 300)
    defer { content.tearDown() }
    try #require(await content.load(html: "<pre>let total = items.reduce(0) { $0 + $1.price }</pre>", timeout: .seconds(5)) != nil)
    // The text box's right edge (inside the padding) stays left of the button.
    let js = """
    (() => { const pre = document.querySelector('pre'), b = pre.querySelector('.buddy-copy');
      const r = pre.getBoundingClientRect(), pad = parseFloat(getComputedStyle(pre).paddingRight);
      return String(b.getBoundingClientRect().left - (r.right - pad)); })()
    """
    let gap = try await content.webView.evaluateJavaScript(js, in: nil, contentWorld: .world(name: "buddy-card")) as? String
    #expect((Double(gap ?? "") ?? -1) >= 0, "code text clears the Copy button")
}
