import AppKit
import BuddyCore
import Foundation
import Testing
@testable import BuddyOverlay

/// The composer's rules (61-COMPOSER): paste chips, tokens, `@path`, the `/` and `@` menus and
/// their ranking, ↑/↓ history, and what a paste or a drop brings in.
@MainActor
struct ComposerTests {
    @Test("⌘⇧↩ in the field sends to a new session where the host offers it, and does nothing at Home")
    func commandShiftReturn() {
        func press(offered: Bool) -> (Bool, Int) {
            var sent = 0
            let field = ComposerField(state: ComposerState(), placeholder: "", font: .systemFont(ofSize: 13), lineHeight: 18,
                                      textColor: .black, tokenColor: .orange, chipFill: .gray, placeholderColor: .gray,
                                      onSubmit: {}, onSubmitToNewSession: offered ? { sent += 1 } : nil)
            let coordinator = field.makeCoordinator()
            let view = ComposerTextView(usingTextLayoutManager: false)
            view.coordinator = coordinator
            let window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: 300, height: 100), styleMask: .borderless,
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.makeFirstResponder(view)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: "\r",
                                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            let handled = view.performKeyEquivalent(with: event)
            window.close()
            return (handled, sent)
        }
        #expect(press(offered: true) == (true, 1))
        #expect(press(offered: false).1 == 0)
    }

    @Test("The field counts its lines at the width it's offered: empty, a new line, and wrapping")
    func fieldLines() {
        let font = NSFont.systemFont(ofSize: 13)
        func lines(_ s: String, _ width: CGFloat = 400) -> Int {
            ComposerField.lines(in: NSAttributedString(string: s, attributes: [.font: font]), width: width)
        }
        #expect(lines("") == 1)
        #expect(lines("Hi") == 1)
        #expect(lines("Hi\n") == 2, "the caret's empty line after ⇧↩ counts")
        #expect(lines("a\nb\nc") == 3)
        let long = String(repeating: "words that wrap ", count: 20)
        #expect(lines(long, 200) > lines(long, 600))
    }

    // MARK: Long paste

    @Test func longPasteCollapsesAndExpandsOnSend() {
        let long = (1...40).map { "line \($0)" }.joined(separator: "\n")
        #expect(ComposerText.shouldCollapse(long))
        #expect(!ComposerText.shouldCollapse("a\nb\nc"))
        #expect(ComposerText.shouldCollapse(String(repeating: "x", count: 2_000)), "one huge line too")

        let state = ComposerState()
        let chip = state.collapse(long)
        #expect(chip == "[Pasted text #1 +40 lines]")
        state.text = "Why does this fail? \(chip) and \(state.collapse("a\nb"))"
        #expect(state.expandedText == "Why does this fail? \(long) and a\nb")
        #expect(state.text.contains("[Pasted text #2 +2 lines]"))
    }

    @Test func aChipWithoutItsPasteStaysAsTyped() {
        #expect(ComposerText.expand("see [Pasted text #3 +2 lines]", pastes: [1: "x"]) == "see [Pasted text #3 +2 lines]")
    }

    @Test func backspaceDeletesAChipWhole() throws {
        let text = "fix [Pasted text #1 +12 lines] now"
        let chip = try #require(ComposerText.chip(endingAt: 30, in: text))
        #expect((text as NSString).substring(with: chip) == "[Pasted text #1 +12 lines]")
        #expect(ComposerText.chip(endingAt: 3, in: text) == nil, "plain text deletes a character")
        #expect(ComposerText.chip(endingAt: 31, in: text) == nil, "after the space, it's plain again")
    }

    // MARK: Tokens and mentions

    @Test func tokensAreACommandAtTheStartMentionsAndChips() {
        let text = "/review @Sources/App.swift and @\"Q3 plan.pdf\" [Pasted text #1 +20 lines] mail@me.com"
        let tokens = ComposerText.tokens(in: text).map { ($0.kind, (text as NSString).substring(with: $0.range)) }
        #expect(tokens.map(\.0) == [.command, .mention, .mention, .paste])
        #expect(tokens.map(\.1) == ["/review", "@Sources/App.swift", "@\"Q3 plan.pdf\"", "[Pasted text #1 +20 lines]"])
        #expect(ComposerText.tokens(in: "see /review").isEmpty, "a command only counts at the start")
    }

    @Test func mentionIsRelativeToTheSessionFolderAndQuotedWithSpaces() {
        let folder = URL(filePath: "/Users/me/app", directoryHint: .isDirectory)
        #expect(ComposerText.mention(URL(filePath: "/Users/me/app/Sources/A.swift"), folders: [folder]) == "@Sources/A.swift")
        #expect(ComposerText.mention(URL(filePath: "/tmp/Q3 plan.pdf"), folders: [folder]) == "@\"/tmp/Q3 plan.pdf\"")
        #expect(ComposerText.mention(URL(filePath: "/Users/me/app/Docs"), isFolder: true, folders: [folder]) == "@Docs/")
        #expect(ComposerText.mention(URL(filePath: "/Users/me/application.txt"), folders: [folder]) == "@/Users/me/application.txt",
                "a sibling with the same prefix isn't inside")
    }

    // MARK: Menus

    @Test func queryOpensOnSlashAtTheStartAndAtAfterSpace() {
        #expect(CompletionQuery.at(4, in: "/rev") == CompletionQuery(trigger: .command, range: NSRange(location: 0, length: 4), text: "rev"))
        #expect(CompletionQuery.at(1, in: "/")?.text == "")
        #expect(CompletionQuery.at(9, in: "see /rev x") == nil, "not mid-message")
        #expect(CompletionQuery.at(7, in: "/Users/") == nil, "a path isn't a command")
        #expect(CompletionQuery.at(8, in: "fix @Sou") == CompletionQuery(trigger: .mention, range: NSRange(location: 4, length: 4), text: "Sou"))
        #expect(CompletionQuery.at(11, in: "mail me@x.c") == nil, "an address isn't a mention")
        #expect(CompletionQuery.at(4, in: "@Sou now") != nil, "the caret's token, not the line's end")
        #expect(CompletionQuery.at(5, in: "@Sou now") == nil, "a space ends it")
    }

    @Test func fuzzyRankingPrefersNamesWordStartsAndRuns() {
        let files = ["Tests/BuddyOverlayTests/ComposerTests.swift", "Sources/BuddyOverlay/Conversation/ComposerView.swift",
                     "Sources/BuddyOverlay/Composer/ComposerField.swift", "docs/compose-notes.md", "Package.swift"]
            .map { CompletionItem(kind: .file, title: $0, insert: "@\($0) ") }
        #expect(Fuzzy.rank(files, query: "cview").first?.title == "Sources/BuddyOverlay/Conversation/ComposerView.swift")
        #expect(Fuzzy.rank(files, query: "package").first?.title == "Package.swift", "an exact name wins")
        #expect(Fuzzy.rank(files, query: "cfield").first?.title.hasSuffix("ComposerField.swift") == true)
        #expect(Fuzzy.rank(files, query: "zzz").isEmpty)
        #expect(Fuzzy.rank(files, query: "", limit: 2).map(\.title) == Array(files.prefix(2).map(\.title)), "no query keeps the order")
        #expect(Fuzzy.score("abc", "a-b-c") != nil && Fuzzy.score("abc", "acb") == nil, "in order only")
    }

    @Test func mentionMenuListsTeammatesFirst() {
        let state = ComposerState()
        state.teammates = { ["Writer", "Researcher"] }
        state.text = "@wr"
        state.caretChanged(3)
        #expect(state.menu?.items.first?.title == "Writer")
        #expect(state.menu?.items.first?.insert == "@Writer ")
        state.text = "hello"
        state.caretChanged(5)
        #expect(state.menu == nil)
    }

    @Test func commandMenuMovesWrapsAndAccepts() throws {
        let state = ComposerState()
        state.text = "/"
        state.caretChanged(1)
        let menu = try #require(state.menu)
        #expect(menu.items.map(\.title).prefix(2) == ["compact", "model"], "the built-ins before the catalog loads")
        state.moveSelection(-1)
        #expect(state.menu?.selected == menu.items.count - 1, "↑ from the top wraps")
        state.moveSelection(1)
        let accepted = try #require(state.acceptMenu())
        #expect(accepted.insert == "/compact ")
        #expect(accepted.range == NSRange(location: 0, length: 1))
        #expect(state.menu == nil)
    }

    @Test func aLiveSessionsCommandsDecideTheSlashMenu() {
        let known = CommandCatalog.builtIns + [
            CompletionItem(kind: .command, title: "review-pr", detail: "Review a pull request.", source: "Skill", insert: "/review-pr "),
            CompletionItem(kind: .command, title: "not-loaded", source: "Skill", insert: "/not-loaded "),
        ]
        let rows = CommandCatalog.live(["review-pr", "compact", "init", "compact"], known: known)
        #expect(rows.map(\.title) == ["compact", "review-pr", "init"], "built-ins, then known, then the rest")
        #expect(rows[1].detail == "Review a pull request.", "the scan's description")
        #expect(rows[2].source == "Claude Code")

        let m = ConversationPageModel(snapshot: SessionSnapshot(id: SessionID(rawValue: "s"), title: "T", color: .ember,
                                                                harness: .open, lastUsed: .now))
        m.apply(.initialized(InitSummary(commands: ["init", "compact"])))
        m.draft = "/"
        m.composer.caretChanged(1)
        #expect(m.composer.menu?.items.map(\.title) == ["compact", "init"], "only what the session runs")
    }

    // MARK: History

    @Test func historyWalksBackAndRestoresTheDraft() {
        var h = ComposerHistory(["first", "second", "second", " "])
        #expect(h.entries == ["first", "second"], "repeats and blanks skipped")
        #expect(h.back(from: "half typed") == "second")
        #expect(h.back(from: "second") == "first")
        #expect(h.back(from: "first") == nil, "stops at the oldest")
        #expect(h.forward() == "second")
        #expect(h.forward() == "half typed", "past the newest: the user's own draft")
        #expect(h.forward() == nil, "not walking any more")
        h.add("third")
        #expect(h.back(from: "") == "third")
    }

    @Test func pageHistoryIsTheSessionsQuestionsAndGrowsOnSend() {
        let m = ConversationPageModel(snapshot: SessionSnapshot(id: SessionID(rawValue: "s"), title: "T", color: .ember,
                                                                harness: .open, lastUsed: .now))
        m.load(history: [TranscriptTurn(id: "u1", question: "why is it red?", block: BuddyBlock(say: "A token bug.", shape: .chip),
                                        mode: .quick, model: .haiku)])
        m.draft = "and now?"
        m.submit()
        #expect(m.composer.history.entries == ["why is it red?", "and now?"])
        #expect(m.composer.historyBack() == "and now?")
    }

    // MARK: Sending

    @Test func submitSendsExpandedPastesAndAnAnswerKeepsTheFiles() {
        let m = ConversationPageModel(snapshot: SessionSnapshot(id: SessionID(rawValue: "s"), title: "T", color: .ember,
                                                                harness: .open, lastUsed: .now))
        var sent: [PageAction] = []
        m.onAction = { sent.append($0) }
        m.attach([URL(filePath: "/tmp/shot.png")])
        m.draft = "look: " + m.composer.collapse("a\nb")
        m.submit()
        guard case .submit(let s)? = sent.last else { Issue.record("no submit"); return }
        #expect(s.text == "look: a\nb")
        #expect(s.attachments.map(\.kind) == [.image])
        #expect(m.composer.pastes.isEmpty && m.attachments.isEmpty)

        m.attach([URL(filePath: "/tmp/b.md")])
        m.answerInComposer("q1", questions: ["Which one?"])
        m.draft = "the second"
        m.submit()
        #expect(m.attachments.map(\.name) == ["b.md"], "an answer is text only: the file waits")
    }

    @Test func draftRoundTripsAttachmentsAndPastes() {
        let state = ComposerState()
        state.text = state.collapse("x\ny")
        state.attach([URL(filePath: "/tmp/a.png")])
        let kept = state.draft
        state.clear()
        #expect(state.draft.isEmpty)
        state.draft = kept
        #expect(state.expandedText == "x\ny")
        #expect(state.attachments.map(\.name) == ["a.png"])
        #expect(state.collapse("z") == "[Pasted text #2 +1 lines]", "numbering carries on")
    }

    @Test func filesSplitIntoPicturesAndMentions() {
        let state = ComposerState()
        let mentions = state.take([URL(filePath: "/tmp/shot.PNG"), URL(filePath: "/tmp/notes.md"),
                                   URL(filePath: "/tmp/My Folder", directoryHint: .isDirectory)])
        #expect(state.attachments.map(\.name) == ["shot.PNG"])
        #expect(mentions == "@/tmp/notes.md @\"/tmp/My Folder/\"")
        state.text = "see"
        state.append(mentions)
        #expect(state.text == "see @/tmp/notes.md @\"/tmp/My Folder/\" ")
    }

    // MARK: Pasteboard

    @Test func pasteboardPicturesTextAndFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "paste-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pb = NSPasteboard(name: NSPasteboard.Name("lumi.composer.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        // A screenshot copied with ⌃⇧⌘4: TIFF data only → a PNG file, attached.
        let image = NSImage(size: NSSize(width: 8, height: 6))
        image.lockFocus(); NSColor.orange.setFill(); NSRect(x: 0, y: 0, width: 8, height: 6).fill(); image.unlockFocus()
        pb.clearContents()
        pb.setData(image.tiffRepresentation, forType: .tiff)
        guard case .images(let urls) = ComposerPasteboard.read(pb, into: dir), let url = urls.first else {
            Issue.record("no picture"); return
        }
        #expect(url.pathExtension == "png" && url.path.hasPrefix(dir.path))
        #expect(try Data(contentsOf: url).starts(with: [0x89, 0x50, 0x4E, 0x47]))

        // "Copy Image" in a browser: the picture and its address → the picture.
        pb.clearContents()
        pb.setData(image.tiffRepresentation, forType: .tiff)
        pb.setString("https://example.com/a.png", forType: .string)
        guard case .images = ComposerPasteboard.read(pb, into: dir) else { Issue.record("link + picture"); return }

        // Rich text with a picture rendition (Pages, Excel) → the text.
        pb.clearContents()
        pb.setData(image.tiffRepresentation, forType: .tiff)
        pb.setString("Revenue up 4%", forType: .string)
        #expect(ComposerPasteboard.read(pb, into: dir) == .text("Revenue up 4%"))

        // Copied files in Finder → files.
        pb.clearContents()
        pb.writeObjects([URL(filePath: "/tmp/a.md") as NSURL])
        #expect(ComposerPasteboard.read(pb, into: dir) == .files([URL(filePath: "/tmp/a.md")]))
    }

    // MARK: Catalog

    @Test func catalogReadsSkillsCommandsAndEnabledPlugins() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("home/skills/review-pr/SKILL.md", "---\nname: review-pr\ndescription: \"Review a pull request. Long tail.\"\n---\nbody")
        try write("home/skills/hidden/SKILL.md", "---\nname: hidden\nuser-invocable: false\n---\n")
        try write("home/skills/synced/abc/SKILL.md", "---\nname: morning\ndescription: Brief me\n---\n")
        try write("home/commands/frontend/component.md", "---\ndescription: Make a component\n---\n")
        try write("project/.claude/skills/ship/SKILL.md", "---\nname: ship\ndescription: Ship it\n---\n")
        try write("plug/skills/slides/SKILL.md", "---\nname: slides\ndescription: Make slides\n---\n")
        try write("plug2/skills/off/SKILL.md", "---\nname: off\n---\n")
        try write("home/settings.json", #"{"enabledPlugins": {"deck@market": true, "other@market": false}}"#)
        try write("home/plugins/installed_plugins.json", """
            {"plugins": {"deck@market": [{"installPath": "\(root.path)/plug"}], "other@market": [{"installPath": "\(root.path)/plug2"}]}}
            """)

        let items = await CommandCatalog.load(claudeHome: root.appending(path: "home"), folders: [root.appending(path: "project")])
        let byName = Dictionary(items.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byName["review-pr"]?.detail == "Review a pull request.", "first sentence")
        #expect(byName["review-pr"]?.source == "Skill")
        #expect(byName["morning"] != nil, "synced skills")
        #expect(byName["hidden"] == nil, "user-invocable: false")
        #expect(byName["frontend:component"]?.source == "Command")
        #expect(byName["ship"]?.source == "Project")
        #expect(byName["deck:slides"]?.insert == "/deck:slides ")
        #expect(byName["other:off"] == nil, "a disabled plugin")
        #expect(items.prefix(4).map(\.title) == ["compact", "model", "effort", "mcp"])
    }

    @Test func fileIndexIsShallowFirstAndSkipsNoise() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "files-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["README.md", "Sources/App/main.swift", "node_modules/x/index.js", ".git/HEAD", "Sources/A b.swift"] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let items = await FileIndex.load([root])
        #expect(items.map(\.title) == ["README.md", "Sources/", "Sources/A b.swift", "Sources/App/", "Sources/App/main.swift"])
        #expect(items.first { $0.title == "Sources/A b.swift" }?.insert == "@\"Sources/A b.swift\" ")
        #expect(items.first { $0.title == "Sources/" }?.kind == .folder)
        #expect(await FileIndex.load([root], cap: 2).count == 2)
    }
}
