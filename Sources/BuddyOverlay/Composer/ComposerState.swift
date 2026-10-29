import AppKit
import BuddyCore
import Foundation
import Observation

/// Everything a composer holds before it's sent: kept per session when the user switches away
/// (S-04) and restored when they come back.
nonisolated public struct ComposerDraft: Sendable, Equatable {
    public var text: String
    public var attachments: [PageAttachment]
    /// Collapsed pastes by chip number.
    public var pastes: [Int: String]

    public init(text: String = "", attachments: [PageAttachment] = [], pastes: [Int: String] = [:]) {
        self.text = text
        self.attachments = attachments
        self.pastes = pastes
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }
}

/// One composer's live state (Panel, Studio column, Studio Home): the text, attachments, collapsed
/// pastes, the `/` and `@` menu and the ↑/↓ history. `ComposerField` edits it.
@MainActor @Observable
public final class ComposerState {
    public var text = ""
    public var attachments: [PageAttachment] = []
    public private(set) var pastes: [Int: String] = [:]
    /// The open `/` or `@` menu.
    public private(set) var menu: Menu?
    /// Image thumbnails by file, made off the main actor once per attachment.
    public private(set) var thumbnails: [URL: NSImage] = [:]
    /// Bumped by a click on a menu row.
    public private(set) var pickRequests = 0

    public struct Menu: Equatable {
        public var query: CompletionQuery
        public var items: [CompletionItem]
        public var selected = 0
    }

    /// This session's teammates, for `@` (first in the menu).
    @ObservationIgnored public var teammates: @MainActor () -> [String] = { [] }
    /// The session's folders, for `@` files and project skills. Read once, the first time a menu opens.
    @ObservationIgnored public var folders: @MainActor () async -> [URL] = { [] }
    @ObservationIgnored public var claudeHome = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    @ObservationIgnored public var history = ComposerHistory()
    /// What the live session says `/` can run (its `system/init`), when one has started; else the
    /// menu lists what the `~/.claude` scan finds.
    @ObservationIgnored public var liveCommands: [String]?

    @ObservationIgnored private var nextPaste = 1
    @ObservationIgnored private var loaded: (folders: [URL], commands: [CompletionItem], files: [CompletionItem])?
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// The caret's last token query, re-run when the catalog arrives.
    @ObservationIgnored private var lastQuery: CompletionQuery?

    public init() {}

    public var draft: ComposerDraft {
        get { ComposerDraft(text: text, attachments: attachments, pastes: pastes) }
        set {
            text = newValue.text
            attachments = []
            pastes = newValue.pastes
            nextPaste = (newValue.pastes.keys.max() ?? 0) + 1
            add(newValue.attachments)
        }
    }

    /// The text with paste chips expanded: what's sent.
    public var expandedText: String { ComposerText.expand(text, pastes: pastes) }

    /// After a send: empties the composer and remembers the message for ↑.
    public func clear(sent: String? = nil, keepAttachments: Bool = false) {
        if let sent { history.add(sent) }
        text = ""
        if !keepAttachments { attachments = []; thumbnails = [:] }
        pastes = [:]
        nextPaste = 1
        menu = nil
        history.stopWalking()
    }

    // MARK: Attachments

    public func attach(_ urls: [URL]) { add(urls.map(PageAttachment.file)) }

    /// Dropped or pasted files: pictures attach (they go to Claude as images); the rest come back
    /// as `@path` text for the caret ("" when there are none).
    public func take(_ urls: [URL]) -> String {
        let isFolder = { (url: URL) in (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath }
        let pictures = urls.filter { PageAttachment.file($0).kind == .image && !isFolder($0) }
        attach(pictures)
        return urls.filter { !pictures.contains($0) }
            .map { ComposerText.mention($0, isFolder: isFolder($0), folders: mentionFolders) }
            .joined(separator: " ")
    }

    /// `@path` text appended at the end, spaced (a drop outside the text).
    public func append(_ mentions: String) {
        guard !mentions.isEmpty else { return }
        let gap = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
        text += gap + mentions + " "
    }

    public func add(_ new: [PageAttachment]) {
        for a in new where !attachments.contains(where: { $0.url == a.url }) {
            attachments.append(a)
            guard a.kind != .file, thumbnails[a.url] == nil else { continue }
            let url = a.url
            Task {
                guard let data = await ComposerImages.thumbnail(url) else { return }
                if attachments.contains(where: { $0.url == url }) { thumbnails[url] = NSImage(data: data) }
            }
        }
    }

    public func detach(_ attachment: PageAttachment) {
        attachments.removeAll { $0 == attachment }
        thumbnails[attachment.url] = nil
    }

    /// A long paste: stored, and its chip returned to insert in its place.
    public func collapse(_ pasted: String) -> String {
        let number = nextPaste
        nextPaste += 1
        pastes[number] = pasted
        return ComposerText.placeholder(number, for: pasted)
    }

    // MARK: Menu

    /// The caret moved or the text changed: opens, narrows or closes the menu.
    public func caretChanged(_ caret: Int) {
        guard let query = CompletionQuery.at(caret, in: text) else {
            lastQuery = nil
            menu = nil
            return
        }
        lastQuery = query
        if loaded == nil { loadCatalog() }
        let items = candidates(for: query)
        guard !items.isEmpty else { menu = nil; return }
        let keep = menu.flatMap { old in old.query.trigger == query.trigger ? items.firstIndex(of: old.items[old.selected]) : nil }
        menu = Menu(query: query, items: items, selected: keep ?? 0)
    }

    func candidates(for query: CompletionQuery) -> [CompletionItem] {
        switch query.trigger {
        case .command:
            let known = loaded?.commands ?? CommandCatalog.builtIns
            return Fuzzy.rank(liveCommands.map { CommandCatalog.live($0, known: known) } ?? known, query: query.text)
        case .mention:
            let mates = teammates().map {
                CompletionItem(kind: .teammate, title: $0, source: "Teammate", insert: "@\($0) ")
            }
            // Teammates first while they match; files fill the rest.
            let ranked = Fuzzy.rank(mates, query: query.text, limit: 4)
            return ranked + Fuzzy.rank(loaded?.files ?? [], query: query.text, limit: 8 - ranked.count)
        }
    }

    public func moveSelection(_ delta: Int) {
        guard var m = menu, !m.items.isEmpty else { return }
        m.selected = (m.selected + delta + m.items.count) % m.items.count
        menu = m
    }

    public func select(_ index: Int) {
        guard var m = menu, m.items.indices.contains(index) else { return }
        m.selected = index
        menu = m
    }

    /// The chosen row's text, and the token it replaces; the menu closes.
    public func acceptMenu() -> (range: NSRange, insert: String)? {
        guard let m = menu, m.items.indices.contains(m.selected) else { return nil }
        menu = nil
        lastQuery = nil
        return (m.query.range, m.items[m.selected].insert)
    }

    public func dismissMenu() { menu = nil }

    /// A click on a menu row: the field takes it on its next update.
    public func pick(_ index: Int) {
        select(index)
        pickRequests += 1
    }

    /// Reads skills, commands and files once, off the main actor; the folders' list is refreshed
    /// when the composer is next opened for another session (a new state).
    private func loadCatalog() {
        guard loading == nil else { return }
        let home = claudeHome
        loading = Task {
            let folders = await folders()
            async let commands = CommandCatalog.load(claudeHome: home, folders: folders)
            async let files = FileIndex.load(folders)
            loaded = (folders, await commands, await files)
            if let q = lastQuery, CompletionQuery.at(NSMaxRange(q.range), in: text) == q { caretChanged(NSMaxRange(q.range)) }
        }
    }

    /// The folders `@path` mentions are relative to, once read.
    public var mentionFolders: [URL] { loaded?.folders ?? [] }

    // MARK: History

    /// ↑ on the first line: the older message, or nil.
    public func historyBack() -> String? { history.back(from: text) }
    /// ↓ on the last line: the newer message or the saved draft, or nil when not walking.
    public func historyForward() -> String? { history.forward() }
}
