import Foundation

/// One top-level Markdown block of an answer. Finished blocks are frozen with stable ids, so
/// a streaming answer re-renders only its live tail.
nonisolated public struct MarkdownBlock: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case paragraph
        case heading(level: Int)
        /// A fenced code block; `text` is the body without the fences.
        case code(language: String?)
        case list(ordered: Bool)
        case quote
        case table
        case rule
    }

    public var id: Int
    public var kind: Kind
    /// The block's source (inline Markdown), or the code body.
    public var text: String

    public init(id: Int, kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// Splits Markdown into top-level blocks at blank lines outside code fences (``` and ~~~).
/// Headings, rules and fences are blocks of their own. Pure and line-based: no full parser.
nonisolated public enum MarkdownSplitter {
    public struct Result: Sendable, Equatable {
        public var blocks: [MarkdownBlock]
        /// How many leading blocks can't change however the text goes on.
        public var complete: Int
        /// The UTF-8 offset just after the complete blocks: where the live tail starts.
        public var consumed: Int
    }

    /// `final`: the text won't grow, so every block is complete.
    public static func split(_ text: String, firstID: Int = 0, final: Bool = true) -> Result {
        var p = Parser(firstID: firstID)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var offset = 0
        for (i, line) in lines.enumerated() {
            let terminated = i < lines.count - 1
            let start = offset
            offset += line.utf8.count + (terminated ? 1 : 0)
            if !terminated, line.isEmpty { break }
            p.feed(String(line), start: start, end: offset, terminated: terminated || final)
        }
        p.flush(at: offset, complete: final)
        return Result(blocks: p.blocks, complete: final ? p.blocks.count : p.complete, consumed: final ? offset : p.consumed)
    }

    private struct Parser {
        enum LineKind: Equatable { case paragraph, list(ordered: Bool), quote, table }

        let firstID: Int
        var blocks: [MarkdownBlock] = []
        var complete = 0
        var consumed = 0
        var current: (kind: MarkdownBlock.Kind, lines: [String])?
        var fence: (marker: Character, length: Int, language: String?, lines: [String])?

        init(firstID: Int) { self.firstID = firstID }

        mutating func feed(_ line: String, start: Int, end: Int, terminated: Bool) {
            let trimmed = Self.leadingTrimmed(line)
            if let f = fence {
                if Self.closesFence(trimmed, f.marker, f.length) {
                    fence = nil
                    emit(.code(language: f.language), f.lines.joined(separator: "\n"))
                    if terminated { mark(end) }
                } else {
                    fence?.lines.append(line)
                }
                return
            }
            if trimmed.isEmpty {
                emitCurrent()
                if terminated { mark(end) }
                return
            }
            if let opened = Self.opensFence(trimmed) {
                if emitCurrent(), terminated { mark(start) }
                fence = (opened.marker, opened.length, opened.language, [])
                return
            }
            if let level = Self.headingLevel(trimmed) {
                if emitCurrent(), terminated { mark(start) }
                emit(.heading(level: level), String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces))
                if terminated { mark(end) }
                return
            }
            if Self.isRule(trimmed) {
                if emitCurrent(), terminated { mark(start) }
                emit(.rule, "")
                if terminated { mark(end) }
                return
            }
            let kind = Self.lineKind(trimmed)
            guard let c = current else {
                current = (Self.blockKind(kind), [line])
                return
            }
            if Self.continues(c.kind, with: kind, line: line) {
                current?.lines.append(line)
            } else {
                if emitCurrent(), terminated { mark(start) }
                current = (Self.blockKind(kind), [line])
            }
        }

        mutating func flush(at end: Int, complete: Bool) {
            if let f = fence {
                // An open fence renders as code while it streams.
                emit(.code(language: f.language), f.lines.joined(separator: "\n"))
                fence = nil
            }
            emitCurrent()
            if complete { mark(end) }
        }

        @discardableResult
        mutating func emitCurrent() -> Bool {
            guard let c = current else { return false }
            current = nil
            emit(c.kind, c.lines.joined(separator: "\n"))
            return true
        }

        mutating func emit(_ kind: MarkdownBlock.Kind, _ text: String) {
            blocks.append(MarkdownBlock(id: firstID + blocks.count, kind: kind, text: text))
        }

        /// Everything emitted so far is final, and the tail starts at `offset`.
        mutating func mark(_ offset: Int) {
            complete = blocks.count
            consumed = offset
        }

        static func leadingTrimmed(_ line: String) -> Substring {
            let spaces = line.prefix { $0 == " " }.count
            return spaces <= 3 ? line.dropFirst(spaces) : Substring(line)
        }

        static func opensFence(_ s: Substring) -> (marker: Character, length: Int, language: String?)? {
            guard let c = s.first, c == "`" || c == "~" else { return nil }
            let n = s.prefix { $0 == c }.count
            guard n >= 3 else { return nil }
            let info = s.dropFirst(n).trimmingCharacters(in: .whitespaces)
            if c == "`", info.contains("`") { return nil }
            let lang = info.split(separator: " ").first.map(String.init)
            return (c, n, lang?.isEmpty == false ? lang : nil)
        }

        static func closesFence(_ s: Substring, _ marker: Character, _ length: Int) -> Bool {
            let n = s.prefix { $0 == marker }.count
            return n >= length && s.dropFirst(n).allSatisfy(\.isWhitespace)
        }

        static func headingLevel(_ s: Substring) -> Int? {
            let n = s.prefix { $0 == "#" }.count
            guard (1...6).contains(n) else { return nil }
            let rest = s.dropFirst(n)
            return rest.isEmpty || rest.first == " " ? n : nil
        }

        static func isRule(_ s: Substring) -> Bool {
            let chars = s.filter { !$0.isWhitespace }
            guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
            return chars.allSatisfy { $0 == c }
        }

        static func lineKind(_ s: Substring) -> LineKind {
            if s.hasPrefix(">") { return .quote }
            if s.hasPrefix("|") { return .table }
            if let c = s.first, "-*+".contains(c), s.dropFirst().first == " " { return .list(ordered: false) }
            let digits = s.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 9 {
                let rest = s.dropFirst(digits.count)
                if let d = rest.first, d == "." || d == ")", rest.dropFirst().first == " " { return .list(ordered: true) }
            }
            return .paragraph
        }

        static func blockKind(_ k: LineKind) -> MarkdownBlock.Kind {
            switch k {
            case .paragraph: .paragraph
            case .list(let ordered): .list(ordered: ordered)
            case .quote: .quote
            case .table: .table
            }
        }

        /// Whether `line` joins the open block: list items and indented continuations stay in a
        /// list, lazy lines stay in a quote, and a list, quote or table after a paragraph
        /// starts a new block.
        static func continues(_ kind: MarkdownBlock.Kind, with line: LineKind, line raw: String) -> Bool {
            switch (kind, line) {
            case (.paragraph, .paragraph): true
            // An indented item of either kind is a nested list: it stays in the open one (QA S-11).
            case (.list(let a), .list(let b)): a == b || raw.first == " " || raw.first == "\t"
            case (.list, .paragraph): raw.first == " " || raw.first == "\t"
            case (.quote, .quote), (.quote, .paragraph): true
            case (.table, .table): true
            default: false
            }
        }
    }
}

/// One item of a list block: its marker ("•", "◦", "3.", "☐"), its inline text, and how deeply it's
/// nested (0 at the top).
nonisolated struct MarkdownListItem: Sendable, Equatable {
    var marker: String
    var text: String
    var depth: Int
}

nonisolated enum MarkdownList {
    /// A list block's items. Each marker line starts an item, nested by its indent against the
    /// open levels; other lines continue the item before them.
    static func items(_ s: String) -> [MarkdownListItem] {
        var out: [MarkdownListItem] = []
        var levels: [Int] = []   // the indents of the open levels
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard let (marker, rest) = marker(trimmed) else {
                if out.isEmpty { out.append(MarkdownListItem(marker: "•", text: String(trimmed), depth: 0)) } else {
                    out[out.count - 1].text += " " + trimmed
                }
                continue
            }
            while let last = levels.last, indent < last { levels.removeLast() }
            if levels.last.map({ indent > $0 }) ?? true { levels.append(indent) }
            let depth = levels.count - 1
            let (shown, text) = task(rest).map { ($0.done ? "☑" : "☐", $0.text) }
                ?? (marker == "•" ? (depth == 0 ? "•" : "◦") : marker, String(rest))
            out.append(MarkdownListItem(marker: shown, text: text, depth: depth))
        }
        return out
    }

    /// "- x" / "* x" / "+ x" → ("•", "x"); "3. x" or "3) x" → ("3.", "x").
    static func marker(_ s: Substring) -> (String, Substring)? {
        if let c = s.first, "-*+".contains(c), s.dropFirst().first == " " { return ("•", s.dropFirst(2)) }
        let digits = s.prefix { $0.isNumber }
        let rest = s.dropFirst(digits.count)
        if !digits.isEmpty, let d = rest.first, d == "." || d == ")", rest.dropFirst().first == " " {
            return (digits + ".", rest.dropFirst(2))
        }
        return nil
    }

    /// A task item: "[ ] todo" or "[x] done".
    static func task(_ s: Substring) -> (done: Bool, text: String)? {
        guard s.count >= 4, s.first == "[", s.dropFirst(2).first == "]", s.dropFirst(3).first == " " else { return nil }
        let mark = s.dropFirst().first
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        return (mark != " ", String(s.dropFirst(4)))
    }
}

/// A streaming answer: frozen finished blocks plus the live tail, the only part re-parsed as
/// text arrives.
nonisolated public struct StreamingMarkdown: Sendable, Equatable {
    public private(set) var frozen: [MarkdownBlock] = []
    /// The unfinished source after the frozen blocks.
    public private(set) var tail = ""
    public private(set) var isFinished = false
    private var source = ""

    public init() {}

    /// A finished answer (history).
    public init(finished markdown: String) {
        finish(markdown)
    }

    /// All the text so far.
    public var text: String { source }
    public var isEmpty: Bool { source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public mutating func append(_ delta: String) {
        guard !isFinished, !delta.isEmpty else { return }
        source += delta
        tail += delta
        let r = MarkdownSplitter.split(tail, firstID: frozen.count, final: false)
        guard r.complete > 0 else { return }
        frozen += r.blocks.prefix(r.complete)
        tail = String(decoding: tail.utf8.dropFirst(r.consumed), as: UTF8.self)
    }

    /// The turn ended. `final` is `result.text`, the last message only: the streamed text
    /// (which also holds the words between tool calls) is kept when it ends with it.
    public mutating func finish(_ final: String? = nil) {
        guard !isFinished else { return }
        if let final, !final.isEmpty, !source.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix(final.trimmingCharacters(in: .whitespacesAndNewlines)) {
            source = final
            frozen = []
            tail = final
        }
        frozen += MarkdownSplitter.split(tail, firstID: frozen.count, final: true).blocks
        tail = ""
        isFinished = true
    }

    /// The live tail as blocks, speculatively closed (an unclosed `**` or `` ` ``) so it
    /// doesn't flip between styles as it streams. Its ids continue the frozen ones, so a block
    /// keeps its identity when it freezes.
    public var liveBlocks: [MarkdownBlock] {
        guard !tail.isEmpty else { return [] }
        var blocks = MarkdownSplitter.split(tail, firstID: frozen.count, final: true).blocks
        if let last = blocks.indices.last, Self.closesInline(blocks[last].kind) {
            blocks[last].text = Self.speculativelyClosed(blocks[last].text)
        }
        return blocks
    }

    public var blocks: [MarkdownBlock] { frozen + liveBlocks }

    static func closesInline(_ kind: MarkdownBlock.Kind) -> Bool {
        switch kind {
        case .code, .rule: false
        default: true
        }
    }

    static func speculativelyClosed(_ s: String) -> String {
        var out = s
        let ticks = s.filter { $0 == "`" }.count
        if ticks % 2 == 1 { out += "`" }
        // Strong emphasis outside code spans.
        let outsideCode = s.split(separator: "`", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 0 }.map(\.element).joined()
        if outsideCode.components(separatedBy: "**").count % 2 == 0 { out += "**" }
        return out
    }
}
