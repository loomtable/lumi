import AppKit
import BuddyCore
import SwiftUI
import Testing
@testable import BuddyCompanion
@testable import BuddyOverlay

// Owner, Oct 29: in the Studio window the answer ran past the right edge and the composer was
// cut off. These lay the real views out in real windows (a titled one for Studio, as the
// Window scene makes, a borderless one for the Panel) and read the AppKit views SwiftUI makes
// for text: every line must sit inside the window and the reading column, and the composer's
// field inside the window. Nothing is ordered on screen.

@MainActor
private enum Probe {
    static let answer = """
        There's no single "best." It depends on whether you want a big night out or a casual meal. Here are my picks for each.

        **Casual / classic Munich (what "food joint" usually means)**

        - **Augustiner Bräustuben** (Landsberger Str.): a beer hall next to the Augustiner brewery. It's cheap and the Schweinshaxe (roast pork knuckle) is excellent for a casual meal.
        - **Viktualienmarkt**: an open-air market where you can graze from stall to stall. Wurstimbiss Teltschik is a well-known sausage stand there.

        1. Book well ahead, and check opening dates. Some of these close for summer breaks, and rankings differ between guides.

        > Rankings differ between guides, so check two before you book a table for a big group on a weekend night.

        A long link: https://www.example.com/guides/munich/restaurants/2026/the-complete-list-of-every-beer-hall-and-market-stall-worth-a-visit?ref=lumi&utm_source=answer
        and a long word: Donaudampfschifffahrtsgesellschaftskapitänswitwenrentenversicherungsanstaltsangestellter.

        | Place | Area | Price | Best for | Booking | Notes |
        |---|---|---|---|---|---|
        | Augustiner Bräustuben | Landsberger Straße, Schwanthalerhöhe | € | Pork knuckle and a big group | Walk in, or call a day ahead | Cash only at some tables |
        | Tantris | Schwabing, north of the Englischer Garten | €€€€ | A long tasting menu | Weeks ahead | Jackets welcome |

        ```swift
        let picks = restaurants.filter { $0.city == "Munich" && $0.rating >= 4.5 }.sorted { $0.price < $1.price }.map(\\.name).joined(separator: ", ")
        ```

        Sources:

        - [The Tour Guy: Best restaurants in Munich](https://example.com/a)
        """

    static let question = "What is the best food joint in Munich? I want somewhere locals actually go, not a tourist trap, ideally near the old town."

    static let sid = SessionID(rawValue: "s1")

    /// A session whose page has one finished typed turn, as the engine sends it.
    static func studio(inspector: Bool = false) -> (StudioModel, FakeStudioSource) {
        let snap = SessionSnapshot(id: sid, title: "Munich food", color: .ember, harness: .open, lastUsed: Date())
        let source = FakeStudioSource([snap])
        source.turns = [sid: [TranscriptTurn(id: "h1", question: question, block: BuddyBlock(say: "", shape: .rich),
                                             mode: .deep, model: ModelID(rawValue: "claude-opus-5-5"), kind: .typed,
                                             markdown: answer)]]
        let model = StudioModel(source: source)
        model.selection = .session(sid)
        model.windowVisible = true
        model.inspectorShown = inspector
        return (model, source)
    }

    /// The same turn, live: started, streamed and ended on the page.
    static func page(running: Bool = false) -> ConversationPageModel {
        var p = ConversationPage(session: sid, title: "Munich food")
        let t0 = Date().addingTimeInterval(-30)
        _ = p.send(question, kind: .typed, context: nil, at: t0)
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0)
        if running {
            p.apply(.text(answer, subagent: nil), at: t0.addingTimeInterval(10))
        } else {
            p.apply(.turnEnded(TurnEnd(kind: .typed, markdown: answer)), at: t0.addingTimeInterval(20))
        }
        return ConversationPageModel(page: p)
    }

    /// A long page: `count` finished turns of mixed Markdown, the last one still streaming if `running`.
    static func long(_ count: Int, running: Bool = false) -> ConversationPageModel {
        var p = ConversationPage(session: sid, title: "Long session")
        var t0 = Date().addingTimeInterval(-10_000)
        for i in 0..<count {
            _ = p.send("Question \(i): " + String(repeating: "and a few more words ", count: i % 4 * 4 + 1), kind: .typed, context: nil, at: t0)
            p.apply(.turnStarted(userUUID: "u\(i)", kind: .typed), at: t0)
            var md = "Answer \(i). " + String(repeating: "A sentence that wraps across the column. ", count: i % 5 * 3 + 2)
            if i % 3 == 0 { md += "\n\n- one\n- two, a longer item that wraps a little\n- three" }
            if i % 4 == 1 { md += "\n\n```\nlet x = \(i)\nprint(x)\n```" }
            if i % 5 == 2 { md += "\n\n| a | b |\n|---|---|\n| 1 | 2 |" }
            if running, i == count - 1 {
                p.apply(.text(md, subagent: nil), at: t0.addingTimeInterval(5))
            } else {
                p.apply(.turnEnded(TurnEnd(kind: .typed, markdown: md)), at: t0.addingTimeInterval(20))
            }
            t0 = t0.addingTimeInterval(60)
        }
        return ConversationPageModel(page: p)
    }

    /// The page's own scroll view (not a code block's, not the sidebar's).
    static func thread(in root: NSView) -> NSScrollView? {
        all(NSScrollView.self, in: root).first {
            $0.enclosingScrollView == nil && !($0.documentView is ComposerTextView)
                && !String(describing: type(of: $0)).contains("List")
        }
    }

    static func scroll(_ scroll: NSScrollView, to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func settle(_ view: NSView, passes: Int = 4) async {
        for _ in 0..<passes {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// The line nearest the middle of the visible part of `scroll`, and where it is in the window.
    static func middleLine(of scroll: NSScrollView) -> (NSTextField, CGFloat)? {
        let clip = scroll.contentView
        let mid = clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil).y
        guard let doc = scroll.documentView else { return nil }
        return all(NSTextField.self, in: doc)
            .map { ($0, $0.convert($0.bounds, to: nil).midY) }
            .min { abs($0.1 - mid) < abs($1.1 - mid) }
    }

    /// Lays `root` out in a window of `size` (titled with a full-size content view, as the
    /// Window scene makes it, or borderless as the Panel is) until `ready` holds.
    static func window(_ root: some View, size: CGSize, titled: Bool, ready: (NSView) -> Bool) async -> NSWindow {
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = titled ? .all : []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        // Closed inside async tests: no close animation, and the test keeps the window alive.
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.setFrame(CGRect(x: -30_000, y: -30_000, width: size.width, height: size.height), display: false)
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            controller.view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        } while !ready(controller.view) && ContinuousClock.now < deadline
        // A few more passes: the page measures itself once and lays out again.
        for _ in 0..<5 {
            controller.view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return window
    }

    /// Takes the window off screen, then closes it (it isn't released on close).
    static func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }

    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { sub in [sub as? T].compactMap { $0 } + all(type, in: sub) }
    }

    /// The text SwiftUI drew for the page: every text field below `root` that isn't the
    /// window's title, the sidebar's, or an editable field.
    static func lines(in root: NSView, excluding sidebar: NSView?) -> [NSTextField] {
        all(NSTextField.self, in: root).filter { field in
            !field.isEditable && !field.isHidden && !(sidebar.map { field.isDescendant(of: $0) } ?? false)
                && !field.stringValue.isEmpty && field.window != nil
        }
    }

    /// Where a line can be seen: its frame in the window, or, inside a block that scrolls
    /// sideways (code, a wide table), that block's frame.
    static func visibleFrame(_ view: NSView) -> CGRect {
        var frame = view.convert(view.bounds, to: nil)
        var node: NSView? = view.superview
        while let current = node {
            if let scroll = current as? NSScrollView, let doc = scroll.documentView,
               doc.frame.width > scroll.contentView.bounds.width + 1, scroll.enclosingScrollView != nil {
                frame = scroll.convert(scroll.bounds, to: nil)
            }
            node = current.superview
        }
        return frame
    }

    /// The composer's text view: the box it shows in.
    static func composer(in root: NSView) -> NSView? {
        all(ComposerTextView.self, in: root).first.map { $0.enclosingScrollView ?? $0 }
    }

    /// What's wrong with the page in `window`: lines past the window's or the column's edge, a
    /// column wider than `maxWidth`, a composer outside the window.
    static func problems(in window: NSWindow, maxWidth: CGFloat?, sidebar: NSView? = nil) -> [String] {
        guard let root = window.contentView else { return ["no content"] }
        let bounds = window.contentLayoutRect
        var out: [String] = []
        let texts = lines(in: root, excluding: sidebar)
        if texts.isEmpty { out.append("no text laid out") }
        for line in texts {
            let f = visibleFrame(line)
            let what = "\"\(line.stringValue.prefix(40))\" at \(f.integral)"
            if f.minX < bounds.minX - 0.5 || f.maxX > bounds.maxX + 0.5 { out.append("past the window's edge: \(what)") }
            if let maxWidth, f.width > maxWidth + 0.5 { out.append("wider than the column (\(maxWidth)): \(what)") }
        }
        if let field = composer(in: root) {
            let f = field.convert(field.bounds, to: nil)
            if !bounds.insetBy(dx: -0.5, dy: -0.5).contains(f) { out.append("composer outside the window: \(f.integral) in \(bounds.integral)") }
        } else {
            out.append("no composer")
        }
        return out
    }
}

@Suite(.serialized)
@MainActor
struct PageLayoutTests {
    /// Studio's widest text column: the widest reading width less its insets.
    static let column = PageDensity.widestColumn - 2 * PageDensity.comfortable.inset

    func studio(_ size: CGSize, inspector: Bool = false) async -> [String] {
        let (model, _) = Probe.studio(inspector: inspector)
        let store = SettingsStore(defaults: TestDefaults().defaults)
        let window = await Probe.window(StudioView(model: model, store: store), size: size, titled: true) {
            Probe.composer(in: $0) != nil && Probe.lines(in: $0, excluding: nil).count > 10
        }
        defer { Probe.close(window) }
        let sidebar = Probe.all(NSScrollView.self, in: window.contentView!).first { String(describing: type(of: $0)).contains("List") }
        return Probe.problems(in: window, maxWidth: Self.column, sidebar: sidebar)
    }

    @Test("Studio: the answer wraps inside the reading column and the composer shows, at every window size",
          arguments: [CGSize(width: 820, height: 560), CGSize(width: 1100, height: 700),
                      CGSize(width: 1512, height: 884), CGSize(width: 2560, height: 1415)])
    func studioWindow(size: CGSize) async {
        let problems = await studio(size)
        #expect(problems.isEmpty, Comment(rawValue: "\(Int(size.width))×\(Int(size.height)):\n" + problems.joined(separator: "\n")))
    }

    @Test("Studio: with the inspector open at the smallest window, the column narrows and still wraps")
    func studioNarrowWithInspector() async {
        let problems = await studio(CGSize(width: 820, height: 560), inspector: true)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test("Studio column outside the split view: a finished and a streaming turn both fit",
          arguments: [false, true])
    func studioPage(running: Bool) async {
        let model = Probe.page(running: running)
        for width in [360.0, 700, 1300] {
            let window = await Probe.window(ConversationPageView(model: model, density: .comfortable),
                                            size: CGSize(width: width, height: 640), titled: false) {
                Probe.composer(in: $0) != nil
            }
            let problems = Probe.problems(in: window, maxWidth: Self.column)
            Probe.close(window)
            #expect(problems.isEmpty, Comment(rawValue: "\(Int(width)) wide:\n" + problems.joined(separator: "\n")))
        }
    }

    @Test("Panel: the answer wraps and the composer shows at every Panel width",
          arguments: [PanelDocking.widthRange.lowerBound, PanelDocking.defaultWidth, PanelDocking.widthRange.upperBound])
    func panel(width: CGFloat) async {
        let model = Probe.page()
        let root = PanelRootView(model: model, chrome: PanelChrome(), onPin: {}, onExpand: {}, onMinimise: {}, onClose: {},
                                 onComposerFocus: { _ in }, onContentHeight: { _ in })
        let window = await Probe.window(root, size: CGSize(width: width, height: 620), titled: false) {
            Probe.composer(in: $0) != nil
        }
        defer { Probe.close(window) }
        let problems = Probe.problems(in: window, maxWidth: nil)
        #expect(problems.isEmpty, Comment(rawValue: "\(Int(width)) wide:\n" + problems.joined(separator: "\n")))
    }

    // MARK: Spacing (owner, Oct 29: "so much space on the borders")

    @Test("The reading column is 720 pt, grows with the page to 820 pt, and the Panel has none")
    func readingWidthRule() {
        let d = PageDensity.comfortable
        #expect(d.readingWidth(in: 600) == 720)
        #expect(d.readingWidth(in: 1100) == 720)
        #expect(d.readingWidth(in: 1200) == 780)
        #expect(d.readingWidth(in: 1300) == 820)
        #expect(d.readingWidth(in: 2560) == 820)
        let widths = stride(from: 400.0, through: 3000, by: 10).compactMap { d.readingWidth(in: $0) }
        #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 }, "the column never narrows as the page widens")
        #expect(PageDensity.compact.readingWidth(in: 1300) == nil)
    }

    /// The page's widest answer line, its question bubble's trailing edge and its composer, in a
    /// Studio window of `size`, against the column the rule gives for the page's width.
    func studioColumn(_ size: CGSize) async -> [String] {
        let (model, _) = Probe.studio()
        let store = SettingsStore(defaults: TestDefaults().defaults)
        let window = await Probe.window(StudioView(model: model, store: store), size: size, titled: true) {
            Probe.composer(in: $0) != nil && Probe.lines(in: $0, excluding: nil).count > 10
        }
        defer { Probe.close(window) }
        let root = window.contentView!
        guard let thread = Probe.all(NSTextField.self, in: root).first(where: { $0.stringValue == Probe.question })?.enclosingScrollView,
              let doc = thread.documentView, let field = Probe.composer(in: root)
        else { return ["no thread or composer"] }
        let sidebar = Probe.all(NSScrollView.self, in: root).first { String(describing: type(of: $0)).contains("List") }
        let threadFrame = thread.convert(thread.bounds, to: nil)
        let left = sidebar.map { $0.convert($0.bounds, to: nil).maxX } ?? threadFrame.minX
        let page = threadFrame.maxX - left
        let d = PageDensity.comfortable
        let text = min(page, d.readingWidth(in: page)!) - 2 * d.inset
        let lines = Probe.all(NSTextField.self, in: doc).filter { !$0.isEditable && Probe.visibleFrame($0) == $0.convert($0.bounds, to: nil) }
        let widest = lines.map { $0.convert($0.bounds, to: nil).width }.max() ?? 0
        let composer = field.convert(field.bounds, to: nil)
        var out: [String] = []
        if widest > text + 0.5 || widest < text - 40 { out.append("the widest line is \(widest) pt, the text column \(text) (page \(page))") }
        // The composer's field sits inside the column's text edges, its insets in from each.
        let inner = text - 2 * ComposerView.textInset
        if abs(composer.width - inner) > 1 { out.append("the composer's field is \(composer.width) pt, expected \(inner)") }
        let centre = left + page / 2
        if abs(composer.midX - centre) > 1 { out.append("the composer is off centre: \(composer.midX) vs \(centre)") }
        return out
    }

    @Test("Studio: the text column and the composer follow the reading-width rule, centred, at every window size",
          arguments: [CGSize(width: 820, height: 560), CGSize(width: 1100, height: 700),
                      CGSize(width: 1512, height: 884), CGSize(width: 2560, height: 1415)])
    func studioColumnFollowsTheRule(size: CGSize) async {
        let problems = await studioColumn(size)
        #expect(problems.isEmpty, Comment(rawValue: "\(Int(size.width))×\(Int(size.height)):\n" + problems.joined(separator: "\n")))
    }

    // Owner, Oct 29: the session's title and buttons sit in the window's toolbar, with no header
    // band between it and the page. Narrow (inspector open), Open as Panel and the Inspector fold into ⋯.
    @Test("Studio: the title and actions are toolbar items, the page starts right under the toolbar, and narrow columns fold",
          arguments: [(CGSize(width: 1512, height: 884), false), (CGSize(width: 820, height: 560), true)])
    func headerInToolbar(size: CGSize, inspector: Bool) async {
        let (model, _) = Probe.studio(inspector: inspector)
        let store = SettingsStore(defaults: TestDefaults().defaults)
        let window = await Probe.window(StudioView(model: model, store: store), size: size, titled: true) {
            Probe.composer(in: $0) != nil && Probe.lines(in: $0, excluding: nil).count > 10
        }
        defer { Probe.close(window) }
        let items = window.toolbar?.items ?? []
        let labels = items.map(\.label)
        // 820 pt with the inspector open leaves the session column under the fold width.
        let folded = inspector
        #expect(labels.contains("More"))
        #expect(labels.contains("Open as Panel") == !folded, "\(labels)")
        #expect(labels.contains("Inspector") == !folded, "\(labels)")
        // The title: an unlabelled item on the detail's leading side, inside the window.
        let root = window.contentView!
        let sidebar = Probe.all(NSScrollView.self, in: root).first { String(describing: type(of: $0)).contains("List") }
        let title = items.first { $0.label.isEmpty }?.view.map { $0.convert($0.bounds, to: nil) }
        #expect(title.map { $0.width > 40 && $0.minX >= (sidebar.map { $0.convert($0.bounds, to: nil).maxX } ?? 0) - 1 } == true,
                "title item at \(String(describing: title))")
        // The actions on the trailing edge (with the inspector open, its own column sits beyond them).
        let more = items.first { $0.label == "More" }?.view.map { $0.convert($0.bounds, to: nil) }
        let page = Probe.all(NSTextField.self, in: root).first(where: { $0.stringValue == Probe.question })?.enclosingScrollView
            .map { $0.convert($0.bounds, to: nil).maxX } ?? window.contentLayoutRect.maxX
        #expect(more.map { page - $0.maxX < 40 } == true, "⋯ at \(String(describing: more)), the page ends at \(page)")
        // No header band: the thread starts at the toolbar's bottom edge (one hairline below it).
        guard let thread = Probe.all(NSTextField.self, in: root).first(where: { $0.stringValue == Probe.question })?.enclosingScrollView
        else { Issue.record("no thread"); return }
        let gap = window.contentLayoutRect.maxY - thread.convert(thread.bounds, to: nil).maxY
        #expect(gap >= 0 && gap <= 2, "the page starts \(gap) pt below the toolbar")
    }

    // MARK: Scrolling (owner, Oct 29: "scrolling up and down is glitchy")

    func longPage(_ density: PageDensity, model: ConversationPageModel) async -> (NSWindow, NSScrollView)? {
        let size = density == .compact ? CGSize(width: 400, height: 620) : CGSize(width: 1000, height: 700)
        let window = await Probe.window(ConversationPageView(model: model, density: density), size: size, titled: false) {
            Probe.thread(in: $0)?.documentView != nil
        }
        guard let scroll = Probe.thread(in: window.contentView!), let doc = scroll.documentView else { return nil }
        Probe.scroll(scroll, to: doc.frame.height - scroll.contentView.bounds.height)
        await Probe.settle(window.contentView!, passes: 8)
        return (window, scroll)
    }

    @Test("Scrolling a long page moves it by exactly the scroll, and its height never changes",
          arguments: PageDensity.allCases)
    func scrollingIsSteady(density: PageDensity) async {
        guard let (window, scroll) = await longPage(density, model: Probe.long(30)) else { Issue.record("no thread"); return }
        defer { Probe.close(window) }
        let clip = scroll.contentView
        let height = scroll.documentView!.frame.height
        var problems: [String] = []
        // Up from the bottom to the top in 120 pt steps, as a trackpad flick would.
        while clip.bounds.minY > 0, problems.count < 5 {
            let before = clip.bounds.minY
            let target = max(0, before - 120)
            Probe.scroll(scroll, to: target)
            await Probe.settle(window.contentView!, passes: 2)
            if abs(clip.bounds.minY - target) > 0.5 { problems.append("asked for \(target), landed at \(clip.bounds.minY)") }
            let now = scroll.documentView!.frame.height
            if abs(now - height) > 0.5 { problems.append("the page's height changed from \(height) to \(now) at \(before)") }
        }
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test("Streaming text: scrolled up, the page holds still; at the bottom, it follows the answer",
          arguments: PageDensity.allCases)
    func streamingFollowsOnlyAtTheBottom(density: PageDensity) async {
        let model = Probe.long(12, running: true)
        guard let (window, scroll) = await longPage(density, model: model) else { Issue.record("no thread"); return }
        defer { Probe.close(window) }
        let root = window.contentView!
        func stream(_ n: Int) async {
            for i in 0..<n {
                model.apply(.text("More words \(i). " + String(repeating: "wrap ", count: 60) + "\n\n", subagent: nil))
                model.flushText()
                await Probe.settle(root)
            }
        }
        // Scrolled up: what the user is reading stays put.
        Probe.scroll(scroll, to: scroll.contentView.bounds.minY - 900)
        await Probe.settle(root, passes: 8)
        guard let (line, y0) = Probe.middleLine(of: scroll) else { Issue.record("no line in view"); return }
        await stream(4)
        #expect(abs(line.convert(line.bounds, to: nil).midY - y0) < 0.5, "a line the user was reading moved")
        // Back at the bottom: the newest words stay in view.
        let doc = scroll.documentView!
        Probe.scroll(scroll, to: doc.frame.height - scroll.contentView.bounds.height)
        await Probe.settle(root, passes: 8)
        await stream(4)
        #expect(doc.frame.height - scroll.contentView.bounds.maxY < 1, "the page stopped following the answer")
    }

    // Owner, Oct 29: "the last message jumps around a little", even when only hovering. The copy
    // row showed only on the latest turn or a hovered one, so hovering an earlier turn grew it, the
    // bottom-anchored page shifted, and the pointer landed on another turn. Offscreen windows get
    // no hover tracking, so this holds the turn's chrome to one layout in every state it has.
    @Test("A finished turn has the same height whether or not it's the latest", arguments: PageDensity.allCases)
    func turnChromeIsSteady(density: PageDensity) {
        let model = Probe.long(3)
        let turn = model.page.turns[1]
        func height(latest: Bool) -> CGFloat {
            NSHostingController(rootView: TurnView(turn: turn, model: model, density: density, t: Tokens(.init(dark: false)), isLatest: latest))
                .sizeThatFits(in: CGSize(width: 600, height: 10_000)).height
        }
        #expect(height(latest: false) == height(latest: true))
    }

    // Owner, Oct 29: typed text wrapped at about a third of the composer's width. SwiftUI's size
    // probes set the text view's own container to the probed width and nothing set it back, and
    // in the Panel the buttons sat beside every line (U59). The text now has its own row.

    /// Types a sentence word by word into the composer in `window`, as the owner did, and returns
    /// what's wrong with how it wraps: the field must span the capsule less its insets, where the
    /// capsule is the page's reading column less the composer's margins (in Studio, the text's).
    func composerProblems(in window: NSWindow, density: PageDensity) async -> [String] {
        let root = window.contentView!
        guard let text = Probe.all(ComposerTextView.self, in: root).first, let tc = text.textContainer,
              let lm = text.layoutManager,
              // The page's thread: the scroll view the question sits in (Studio has others).
              let thread = Probe.all(NSTextField.self, in: root).first(where: { $0.stringValue == Probe.question })?.enclosingScrollView
        else { return ["no composer or thread"] }
        for word in "Hi! Your screenshot shows the fine-dining part of my Munich list. What would you like to know about it? I can:".split(separator: " ") {
            text.insertText(String(word) + " ", replacementRange: text.selectedRange())
            await Probe.settle(root, passes: 1)
        }
        await Probe.settle(root)
        lm.ensureLayout(for: tc)
        let field = text.enclosingScrollView!.contentSize.width
        // Studio's thread runs under the floating sidebar: the page starts at the sidebar's edge.
        let threadFrame = thread.convert(thread.bounds, to: nil)
        let sidebar = Probe.all(NSScrollView.self, in: root).first { String(describing: type(of: $0)).contains("List") }
        let left = sidebar.map { $0.convert($0.bounds, to: nil).maxX } ?? threadFrame.minX
        let page = threadFrame.maxX - left
        let column = min(page, density.readingWidth(in: page) ?? page)
        let expected = column - 2 * density.composerInset - 2 * ComposerView.textInset
        let firstLine = lm.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil).width
        var out: [String] = []
        if abs(field - expected) > 1 { out.append("the field is \(field) pt, expected \(expected) (page \(page))") }
        if abs(tc.size.width - text.bounds.width) > 0.5 { out.append("the text wraps at \(tc.size.width) in a \(text.bounds.width) pt view") }
        if firstLine < field - 80 { out.append("the first line is \(firstLine) pt in a \(field) pt field") }
        return out
    }

    @Test("Composer in Studio: typed text spans the field",
          arguments: [CGSize(width: 820, height: 560), CGSize(width: 1512, height: 884), CGSize(width: 2560, height: 1415)])
    func studioComposerTextFillsTheField(size: CGSize) async {
        let (model, _) = Probe.studio()
        let store = SettingsStore(defaults: TestDefaults().defaults)
        let window = await Probe.window(StudioView(model: model, store: store), size: size, titled: true) {
            Probe.composer(in: $0) != nil && Probe.lines(in: $0, excluding: nil).count > 10
        }
        defer { Probe.close(window) }
        let problems = await composerProblems(in: window, density: .comfortable)
        #expect(problems.isEmpty, Comment(rawValue: "\(Int(size.width)) wide:\n" + problems.joined(separator: "\n")))
    }

    @Test("Composer in the Panel: typed text spans the field, the ▣ chip on the row below",
          arguments: [PanelDocking.widthRange.lowerBound, PanelDocking.defaultWidth, PanelDocking.widthRange.upperBound])
    func panelComposerTextFillsTheField(width: CGFloat) async {
        let model = Probe.page()
        model.screenAppName = "Numbers"
        let root = PanelRootView(model: model, chrome: PanelChrome(), onPin: {}, onExpand: {}, onMinimise: {}, onClose: {},
                                 onComposerFocus: { _ in }, onContentHeight: { _ in })
        let window = await Probe.window(root, size: CGSize(width: width, height: 620), titled: false) {
            Probe.composer(in: $0) != nil
        }
        defer { Probe.close(window) }
        let problems = await composerProblems(in: window, density: .compact)
        #expect(problems.isEmpty, Comment(rawValue: "\(Int(width)) wide:\n" + problems.joined(separator: "\n")))
    }

    // qa-ui: the "Started in a new session" toast floated over the thread and covered the last
    // copy button. It now takes the hint row's place, the same height: no line of the thread and
    // not the composer moves. (Text outside the scroll view draws without AppKit views, so the
    // note itself can't be found here; qa-ui checks it renders.)
    @Test("The ⌘⇧↩ note moves nothing on the page", arguments: PageDensity.allCases)
    func startedNoteMovesNothing(density: PageDensity) async {
        let model = Probe.long(6)
        guard let (window, scroll) = await longPage(density, model: model) else { Issue.record("no thread"); return }
        defer { Probe.close(window) }
        let root = window.contentView!
        func frames() -> [CGRect] {
            (Probe.all(NSTextField.self, in: scroll.documentView!) as [NSView] + Probe.all(ComposerTextView.self, in: root))
                .map { $0.convert($0.bounds, to: nil) }
        }
        let before = frames()
        model.startedSession = Date()
        await Probe.settle(root)
        #expect(model.startedSession != nil)
        #expect(frames() == before)
    }

    @Test("A 500-turn session opens on its latest turns only", arguments: PageDensity.allCases)
    func longSessionOpensOnLatestTurns(density: PageDensity) async {
        guard let (window, scroll) = await longPage(density, model: Probe.long(500)) else { Issue.record("no thread"); return }
        defer { Probe.close(window) }
        let questions = Probe.all(NSTextField.self, in: scroll.documentView!).map(\.stringValue).filter { $0.hasPrefix("Question ") }
        let first = 500 - ConversationPageView.turnsPerPage
        #expect(questions.count == ConversationPageView.turnsPerPage)
        #expect(questions.first?.hasPrefix("Question \(first):") == true && questions.last?.hasPrefix("Question 499:") == true)
    }
}
