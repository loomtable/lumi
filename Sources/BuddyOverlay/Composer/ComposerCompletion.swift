import Foundation

/// One row of the composer's `/` or `@` menu (04 §4.5): a command or skill, a teammate, or a file
/// or folder in the session's folders.
nonisolated public struct CompletionItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case command, teammate, file, folder }

    public var kind: Kind
    /// What the row shows and the fuzzy match runs on: "review", "Writer", "Sources/App.swift".
    public var title: String
    /// One line under or beside the title: a skill's description.
    public var detail: String?
    /// "Skill", "Command", "Project", a plugin's name, "Teammate".
    public var source: String?
    /// What replaces the typed token, trigger included ("/review ", "@Sources/App.swift ").
    public var insert: String
    public var id: String { "\(kind)·\(source ?? "")·\(title)" }

    public init(kind: Kind, title: String, detail: String? = nil, source: String? = nil, insert: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.source = source
        self.insert = insert
    }
}

/// The `/` or `@` token the caret is in, if it opens a menu.
nonisolated public struct CompletionQuery: Sendable, Equatable {
    public enum Trigger: Sendable, Equatable { case command, mention }
    public var trigger: Trigger
    /// The token, trigger included, in UTF-16 (NSTextView's units).
    public var range: NSRange
    /// What follows the trigger up to the caret.
    public var text: String

    /// `/` at the very start of the message (Claude Code runs a command only there), or `@` at the
    /// start or after whitespace. The token runs from there to the caret with no whitespace in it.
    public static func at(_ caret: Int, in text: String) -> CompletionQuery? {
        let ns = text as NSString
        guard caret > 0, caret <= ns.length else { return nil }
        var start = caret
        while start > 0, let scalar = UnicodeScalar(ns.character(at: start - 1)),
              !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            start -= 1
        }
        let token = ns.substring(with: NSRange(location: start, length: caret - start))
        if token.hasPrefix("/"), start == 0 {
            let name = token.dropFirst()
            guard !name.contains("/") else { return nil } // a path, not a command
            return CompletionQuery(trigger: .command, range: NSRange(location: 0, length: caret), text: String(name))
        }
        if token.hasPrefix("@"), !token.hasPrefix("@\"") {
            return CompletionQuery(trigger: .mention, range: NSRange(location: start, length: caret - start),
                                   text: String(token.dropFirst()))
        }
        return nil
    }
}

/// Fuzzy ranking for the menus: the query's characters in order (case-insensitive), scored up for
/// runs, word starts and the file name, as fzf does. An empty query keeps the given order.
nonisolated public enum Fuzzy {
    /// Higher is better; nil when `query` isn't a subsequence of `candidate`. A match inside the
    /// last path component is tried first and counts more, so "cview" finds `…/ComposerView.swift`.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let q = Array(query.lowercased()), c = Array(candidate)
        let nameStart = (c.lastIndex(of: "/").map { $0 + 1 }) ?? 0
        let inName = nameStart > 0 ? align(q, c, from: nameStart).map { $0 + 30 } : nil
        guard let best = [inName, align(q, c, from: 0)].compactMap(\.self).max() else { return nil }
        // An exact name or a name prefix wins; shorter candidates break ties.
        let name = String(c[nameStart...]).lowercased()
        let bonus = name == query.lowercased() ? 40 : name.hasPrefix(query.lowercased()) ? 20 : 0
        return (best + bonus) * 100 - min(c.count, 99)
    }

    /// Greedy left-to-right match of `q` in `c` from `start`: runs, word starts (after `/_-. ` or a
    /// lower-to-upper case change) and the name's first letter score up.
    private static func align(_ q: [Character], _ c: [Character], from start: Int) -> Int? {
        let nameStart = (c.lastIndex(of: "/").map { $0 + 1 }) ?? 0
        var score = 0, qi = 0, run = 0, last = -2
        for i in start..<c.count where qi < q.count {
            guard Character(c[i].lowercased()) == q[qi] else { run = 0; continue }
            var s = 1
            if i == last + 1 { run += 1; s += 4 * run } else { run = 0 }
            if i == 0 || "/_-. ".contains(c[i - 1]) || (c[i].isUppercase && c[i - 1].isLowercase) { s += 6 }
            if i == nameStart, qi == 0 { s += 10 }
            score += s
            last = i
            qi += 1
        }
        return qi == q.count ? score : nil
    }

    /// `items` that match `query`, best first, at most `limit`. Stable for equal scores.
    public static func rank(_ items: [CompletionItem], query: String, limit: Int = 8) -> [CompletionItem] {
        guard limit > 0 else { return [] }
        guard !query.isEmpty else { return Array(items.prefix(limit)) }
        var scored: [(offset: Int, score: Int)] = []
        for (offset, item) in items.enumerated() {
            if let s = score(query, item.title) { scored.append((offset, s)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.offset < b.offset }
        return scored.prefix(limit).map { items[$0.offset] }
    }
}

/// ↑/↓ through the session's earlier messages, as in Claude Code: ↑ on the first line goes back,
/// ↓ on the last line comes forward, and coming past the newest restores what was being typed.
nonisolated public struct ComposerHistory: Sendable, Equatable {
    /// Oldest first.
    public private(set) var entries: [String]
    /// The entry shown, or nil while the user's own draft is.
    public private(set) var index: Int?
    private var saved = ""

    public init(_ entries: [String] = []) {
        self.entries = []
        for e in entries { add(e) }
    }

    /// A sent message: becomes the newest entry (repeats of the newest are skipped), and the walk
    /// starts over.
    public mutating func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        index = nil
        guard !t.isEmpty, entries.last != t else { return }
        entries.append(t)
    }

    /// The older entry to show, or nil at the oldest (or with none).
    public mutating func back(from current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        let next: Int
        if let index { guard index > 0 else { return nil }; next = index - 1 } else { saved = current; next = entries.count - 1 }
        index = next
        return entries[next]
    }

    /// The newer entry to show, or the saved draft past the newest; nil when not walking.
    public mutating func forward() -> String? {
        guard let index else { return nil }
        if index + 1 < entries.count {
            self.index = index + 1
            return entries[index + 1]
        }
        self.index = nil
        return saved
    }

    /// The user edited the text: the walk ends where it is.
    public mutating func stopWalking() { index = nil }
}
