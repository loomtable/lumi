import BuddyCore
import Foundation
import Testing
import WebKit
@testable import BuddyOverlay

@Test(.overlayExclusive) func aHungWebProcessDoesntKeepTheCardFromAppearing() async {
    let overlay = BuddyOverlayController(observesSystem: false)
    var asked = false
    // Enabling scrolling never comes back, as if the web process hung.
    overlay.scrollingEnabler = { _ in asked = true; try? await Task.sleep(for: .seconds(3600)) }
    let tall = #"<div style="height:5000px">long</div>"#
    overlay.showAnswer(Answer(block: BuddyBlock(say: "Long.", shape: .card, cardHTML: tall),
                              lane: Lane(mode: .quick, model: .haiku), conversation: .ember, turn: 1, replyHint: "r"),
                       anchor: .point(CGPoint(x: 400, y: 400)))
    let done = Task { await overlay.presentationFinished(); return true }
    let finished = await withTaskGroup(of: Bool.self) { group in
        group.addTask { await done.value }
        group.addTask { try? await Task.sleep(for: .seconds(10)); return false }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    #expect(finished, "presentation must not wait on scrolling")
    guard case .answer = overlay.model.surface else { Issue.record("the card never appeared"); return }
    // Over-tall HTML shows at its full height and the card's body scrolls; only when its height
    // didn't arrive in time does the web view scroll itself instead.
    #expect(overlay.model.answerScrolls || asked)
    overlay.dismiss(.requested)
}

@Test(.overlayExclusive) func aCrashedWebProcessReloadsTheCard() async throws {
    let content = CardWebContent(width: 300)
    try #require(await content.load(html: "<p>Hello</p>", timeout: .seconds(5)) != nil)
    content.webViewWebContentProcessDidTerminate(content.webView)
    #expect(content.reloads == 1)
    // The reload is allowed (it's the card's own about:blank load) and renders the same card.
    let deadline = ContinuousClock.now + .seconds(10)
    var text: String?
    while ContinuousClock.now < deadline {
        text = try? await content.webView.evaluateJavaScript("document.body ? document.body.innerText : ''", in: nil,
                                                             contentWorld: .world(name: "buddy-card")) as? String
        if text == "Hello" { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(text == "Hello")
    content.tearDown()
    content.webViewWebContentProcessDidTerminate(content.webView)
    #expect(content.reloads == 1, "a card that's gone isn't reloaded")
}

@Test(.overlayExclusive) func aReloadedScrollingCardStillScrollsAndReloadsAreCapped() async throws {
    let content = CardWebContent(width: 300)
    defer { content.tearDown() }
    try #require(await content.load(html: #"<div style="height:3000px">tall</div>"#, timeout: .seconds(5)) != nil)
    await content.allowScrolling()
    content.webViewWebContentProcessDidTerminate(content.webView)
    let deadline = ContinuousClock.now + .seconds(10)
    var overflow: String?
    while ContinuousClock.now < deadline {
        overflow = try? await content.webView.evaluateJavaScript(
            "document.body && document.body.innerText === 'tall' ? getComputedStyle(document.body).overflowY : ''",
            in: nil, contentWorld: .world(name: "buddy-card")) as? String
        if overflow == "auto" { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(overflow == "auto", "a card that scrolled before the crash scrolls after the reload")
    content.webViewWebContentProcessDidTerminate(content.webView)
    content.webViewWebContentProcessDidTerminate(content.webView)
    #expect(content.reloads == CardWebContent.maxReloads, "HTML that keeps crashing isn't reloaded forever")
}
