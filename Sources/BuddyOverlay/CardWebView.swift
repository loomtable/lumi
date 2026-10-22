import AppKit
import SwiftUI
import WebKit

/// Renders a `buddy` block's `card_html` in a locked-down, transparent WKWebView and
/// reports its content height so the card can be sized before it pops.
///
/// WebKit's view, navigation delegate and script message handler are all main-actor
/// (`WK_SWIFT_UI_ACTOR`), so the main-actor callbacks here are called on the main thread.
final class CardWebContent: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private(set) var contentHeight: CGFloat?
    private var initialLoadDone = false
    /// What was loaded, so a crashed content process can be reloaded.
    private var loaded: (html: String, jumps: Bool)?
    /// Times the content process died and the card was reloaded (tests).
    private(set) var reloads = 0
    /// HTML that keeps killing the process isn't reloaded again and again.
    static let maxReloads = 2
    /// Scrolling was turned on, so a reload must come back scrollable.
    private var scrolls = false
    /// Called with every height change after the first, so the card can be re-sized when
    /// late content (data: images, fonts) changes the layout.
    var onHeightChange: ((CGFloat) -> Void)?
    /// A "jump" link in the card (`buddy://jump/<label>`): ring that point (Jump).
    var onJump: ((String) -> Void)?
    /// A code or draft block's own Copy button, with that block's text.
    var onCopy: ((String) -> Void)?
    private var waiters: [CheckedContinuation<CGFloat?, Never>] = []
    private static let handlerName = "buddyHeight"
    private static let copyHandlerName = "buddyCopy"
    private static let world = WKContentWorld.world(name: "buddy-card")

    init(width: CGFloat) {
        let config = WKWebViewConfiguration()
        // The card is model output: no page scripts, no network, no persistence.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.heightScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: Self.world))
        controller.addUserScript(WKUserScript(source: Self.copyButtonsScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: Self.world))
        config.userContentController = controller
        webView = CardWKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1), configuration: config)
        super.init()
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
        controller.add(self, contentWorld: Self.world, name: Self.copyHandlerName)
        webView.navigationDelegate = self
        // No public transparency API for WKWebView on macOS; this KVC key is what WebKit
        // itself honours for transparent embedding.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        // Loaded before it is in a window, so it can't inherit the panel's appearance yet;
        // CardWebView keeps it in sync once shown.
        webView.appearance = NSApp.effectiveAppearance
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setAccessibilityRole(.group)
    }

    /// Loads the HTML and waits for the first height report, at most `timeout` seconds.
    /// `jumps: false` ("Rings on screen" off) hides "jump" links, which would ring nothing.
    func load(html: String, timeout: Duration = BuddyOverlayController.cardLoadBudget, jumps: Bool = true) async -> CGFloat? {
        loaded = (html, jumps)
        webView.loadHTMLString(Self.document(body: html, jumps: jumps), baseURL: nil)
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resume(with: nil)
            }
        }
    }

    /// For content taller than the card can be: let the web view scroll.
    func allowScrolling() async {
        scrolls = true
        _ = try? await webView.evaluateJavaScript(
            "document.documentElement.style.overflow='auto';document.body.style.overflow='auto';",
            in: nil, contentWorld: Self.world)
    }

    func tearDown() {
        loaded = nil  // nothing to reload once the card is gone
        onHeightChange = nil
        onJump = nil
        onCopy = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        resume(with: nil)
    }

    private func resume(with height: CGFloat?) {
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.resume(returning: height ?? contentHeight) }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == Self.copyHandlerName {
            if let text = message.body as? String, !text.isEmpty { onCopy?(text) }
            return
        }
        guard message.name == Self.handlerName, let h = (message.body as? NSNumber)?.doubleValue, h > 0 else { return }
        let height = ceil(h)
        // The first report counts too: after a load that timed out, it is the card's real height.
        let changed = contentHeight != height
        contentHeight = height
        resume(with: height)
        if changed { onHeightChange?(height) }
    }

    // MARK: WKNavigationDelegate

    /// WebKit killed the card's content process (memory pressure, sleep): the HTML area would
    /// stay blank. Load the same card again; its height report re-sizes the card if needed.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let loaded, reloads < Self.maxReloads else { return }
        reloads += 1
        initialLoadDone = false  // the reload is the card's own about:blank load again
        webView.loadHTMLString(Self.document(body: loaded.html, jumps: loaded.jumps, scrolls: scrolls), baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let decision = Self.policy(type: action.navigationType, url: action.request.url,
                                   isMainFrame: action.targetFrame?.isMainFrame ?? false, initialLoadDone: initialLoadDone)
        switch decision {
        case .allowInitialLoad:
            initialLoadDone = true
            return .allow
        case .openExternally(let url):
            NSWorkspace.shared.open(url)
            return .cancel
        case .jump(let label):
            onJump?(label)
            return .cancel
        case .cancel:
            return .cancel
        }
    }

    enum NavigationDecision: Equatable {
        case allowInitialLoad
        case openExternally(URL)
        /// `buddy://jump/<label>`: a point label from the buddy block.
        case jump(String)
        case cancel
    }

    /// Only our own `loadHTMLString` (about:blank, once) may load. A clicked web link opens
    /// in the default browser. Everything else is cancelled, including meta refresh and
    /// any other navigation the model's HTML could trigger.
    nonisolated static func policy(type: WKNavigationType, url: URL?, isMainFrame: Bool,
                                   initialLoadDone: Bool) -> NavigationDecision {
        if type == .linkActivated, let url, url.scheme?.lowercased() == "buddy", url.host?.lowercased() == "jump" {
            // URL.path is already percent-decoded.
            let label = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return label.isEmpty ? .cancel : .jump(label)
        }
        if type == .linkActivated, let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            return .openExternally(url)
        }
        if !initialLoadDone, type == .other, isMainFrame, url?.absoluteString == "about:blank" {
            return .allowInitialLoad
        }
        return .cancel
    }

    // MARK: Document

    /// A small Copy on every code block and every block the model marks `data-copy` (a draft).
    /// Runs in the card's own content world (the page itself can't script), and
    /// takes each block's text before adding the button, so "Copy" isn't copied.
    private static let copyButtonsScript = """
    (() => {
      document.querySelectorAll('pre, [data-copy]').forEach(block => {
        const text = block.innerText.trim();
        if (!text) return;
        const button = document.createElement('button');
        button.className = 'buddy-copy';
        button.textContent = 'Copy';
        button.setAttribute('aria-label', 'Copy this block');
        button.addEventListener('click', () => window.webkit.messageHandlers.\(copyHandlerName).postMessage(text));
        block.classList.add('buddy-copyable');
        block.appendChild(button);
      });
    })();
    """

    private static let heightScript = """
    (() => {
      const post = () => window.webkit.messageHandlers.\(handlerName).postMessage(
        Math.ceil(document.documentElement.getBoundingClientRect().height));
      new ResizeObserver(post).observe(document.documentElement);
      post();
    })();
    """

    /// Wraps the model's fragment: both appearances, transparent, our type scale, no
    /// scrolling (the card is sized to the content). Lists follow the prototype: ember markers,
    /// a 1.2 em indent, 0.35 em between bullets, and no browser-default gap above them. Tables,
    /// code panels and the gap between blocks follow the prototype's `.tbl`, `.codeb` and `.cbd`. Bullets
    /// keep the 15 pt detail size (Type) rather than the prototype's smaller .86 em.
    static func document(body: String, jumps: Bool = true, scrolls: Bool = false) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:">
        <style>
        :root { color-scheme: light dark; --text:#1B1C20; --secondary:#5A606B; --ember:#B4451F; --sage:#1F7A4F;
                --amber:#8A5A00; --rose:#B42318; --mist:#2F6488; --hair:rgba(0,0,0,.12); --panel:rgba(0,0,0,.05); }
        @media (prefers-color-scheme: dark) { :root { --text:#F2EFEA; --secondary:#A9AEB8; --ember:#FF8A5B;
                --sage:#7FD1A8; --amber:#F5C060; --rose:#FF7B7B; --mist:#8FB8D8;
                --hair:rgba(255,255,255,.13); --panel:rgba(0,0,0,.4); } }
        html, body { margin:0; padding:0; background:transparent; overflow:\(scrolls ? "auto" : "hidden"); overscroll-behavior:none; }
        body { font: 13px/1.4 -apple-system, "SF Pro Text", system-ui; color: var(--text);
               -webkit-font-smoothing: antialiased; word-wrap: break-word; }
        code, pre { font: 12px/1.45 ui-monospace, "SF Mono", monospace; }
        pre { white-space: pre-wrap; background: var(--panel); border-radius: 9px; padding: .55em .7em; line-height: 1.6; }
        img, svg { max-width: 100%; height: auto; }
        a { color: var(--mist); }
        p, ul, ol, table, pre, figure { margin: 0; }
        ul, ol { padding-left: 1.2em; }
        /* One gap between blocks (.55 em of the 13 px body), as the prototype's card body has. */
        /* Top-level flow only (the body and the model's wrapper div): never inside a grid or flex row. */
        :is(body, body > div) > :is(p, ul, ol, table, pre, div, figure) + :is(p, ul, ol, table, pre, div, figure) { margin-top: 7.15px; }
        table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
        th, td { text-align: left; vertical-align: top; padding: .3em .4em; border-bottom: 1px solid var(--hair); }
        th { font-weight: 500; color: var(--secondary); }
        li + li { margin-top: .35em; }
        li::marker { color: var(--ember); }
        /* Jump: a small rounded "jump" after a bullet, mist, no underline until hovered. */
        a[href^="buddy://jump/"] { font: 500 .85em ui-rounded, "SF Pro Rounded", -apple-system, system-ui;
               text-decoration: none; margin-left: .3em; }
        a[href^="buddy://jump/"]:hover { text-decoration: underline; }
        /* code and draft blocks each get their own small Copy. */
        .buddy-copyable { position: relative; }
        pre.buddy-copyable { padding-right: 52px; }  /* clears the fixed-size Copy and its 5 px inset (about 49 px) */
        .buddy-copy { position: absolute; top: 5px; right: 5px; font: 500 11px ui-rounded, "SF Pro Rounded", -apple-system, system-ui;
               color: var(--secondary); background: var(--panel); border: 1px solid var(--hair); border-radius: 6px;
               padding: 1px 7px; cursor: pointer; opacity: .75; }
        .buddy-copy:hover { opacity: 1; color: var(--text); }
        \(jumps ? "" : #"a[href^="buddy://jump/"] { display: none; }"#)
        </style></head><body>\(body)</body></html>
        """
    }
}

/// The card's web view. In full screen's transcript the card is shown at its full height and
/// the transcript scrolls, so wheel events go on to the enclosing scroll view instead of
/// being swallowed by the web view.
final class CardWKWebView: WKWebView {
    var forwardsScrollWheel = false

    override func scrollWheel(with event: NSEvent) {
        if forwardsScrollWheel, let next = nextResponder {
            next.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The web view's own container. It sizes the web view to its bounds only once they are
/// real: at zero width the card would reflow one word per line and report that height.
final class CardWebHost: NSView {
    func adopt(_ view: WKWebView) {
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.autoresizingMask = []
        if !bounds.isEmpty { view.frame = bounds }  // otherwise it keeps its size until layout
        addSubview(view)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard !bounds.isEmpty else { return }
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }
}

/// Hosts an already-loaded `CardWebContent` in SwiftUI.
///
/// The web view sits in a container of its own, so it can move between the card and full
/// screen's transcript: whichever host goes away last only removes its own container.
///
/// `dark` comes from the resolved tokens (the Mac's appearance). Don't read
/// `\.colorScheme` here: inside a glass effect it reflects the glass's adaptive look over
/// the backdrop (light over a white page, even in dark mode), not the Mac's appearance.
struct CardWebView: NSViewRepresentable {
    let content: CardWebContent
    let dark: Bool
    /// In the transcript: wheel scrolling scrolls the transcript, not the card.
    var forwardsScrollWheel = false

    func makeNSView(context: Context) -> CardWebHost {
        let host = CardWebHost()
        sync(host)
        return host
    }

    func updateNSView(_ host: CardWebHost, context: Context) { sync(host) }

    private func sync(_ host: CardWebHost) {
        let view = content.webView
        host.adopt(view)
        (view as? CardWKWebView)?.forwardsScrollWheel = forwardsScrollWheel
        // `prefers-color-scheme` in the card follows the web view's appearance.
        let name: NSAppearance.Name = dark ? .darkAqua : .aqua
        if view.appearance?.name != name { view.appearance = NSAppearance(named: name) }
    }
}
