import Foundation

/// The composer's text rules, as Claude Code's own input has them (61-COMPOSER §1): a long paste
/// collapses into a `[Pasted text #1 +40 lines]` chip that expands on send, a dropped file becomes
/// `@path`, and a leading `/name`, an `@mention` and a paste chip are styled as tokens.
nonisolated public enum ComposerText {
    /// A paste this long collapses (lines or characters, whichever comes first).
    public static let collapseLines = 12
    public static let collapseCharacters = 2_000

    public static func shouldCollapse(_ pasted: String) -> Bool {
        pasted.count >= collapseCharacters || lineCount(pasted) >= collapseLines
    }

    static func lineCount(_ text: String) -> Int {
        text.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
    }

    /// "[Pasted text #2 +40 lines]".
    public static func placeholder(_ number: Int, for pasted: String) -> String {
        "[Pasted text #\(number) +\(lineCount(pasted)) lines]"
    }

    /// `text` with each paste chip replaced by what was pasted. A chip whose paste is gone stays
    /// as typed.
    public static func expand(_ text: String, pastes: [Int: String]) -> String {
        guard !pastes.isEmpty else { return text }
        let ns = text as NSString
        var out = "", last = 0
        for match in pasteChip.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let number = Int(ns.substring(with: match.range(at: 1))), let pasted = pastes[number] else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last)) + pasted
            last = NSMaxRange(match.range)
        }
        return out + ns.substring(from: last)
    }

    /// `@path` for a dropped or chosen file or folder, relative to the first session folder that
    /// holds it, quoted when it has a space (`@"Q3 plan.pdf"`), as `TypedTurn` quotes path lines.
    public static func mention(_ url: URL, isFolder: Bool? = nil, folders: [URL] = []) -> String {
        let path = url.standardizedFileURL.path
        var shown = path
        for folder in folders {
            let base = folder.standardizedFileURL.path
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix), path.count > prefix.count { shown = String(path.dropFirst(prefix.count)); break }
        }
        if isFolder ?? url.hasDirectoryPath, !shown.hasSuffix("/") { shown += "/" }
        return shown.contains(where: \.isWhitespace) ? "@\"\(shown)\"" : "@\(shown)"
    }

    // MARK: Tokens

    nonisolated public struct Token: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case command, mention, paste }
        public var kind: Kind
        /// UTF-16 range, as NSTextView counts.
        public var range: NSRange
    }

    /// The tokens in `text`, in order, never overlapping.
    public static func tokens(in text: String) -> [Token] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var out: [Token] = []
        if let m = command.firstMatch(in: text, range: all) { out.append(Token(kind: .command, range: m.range)) }
        out += pasteChip.matches(in: text, range: all).map { Token(kind: .paste, range: $0.range) }
        for m in mentionPattern.matches(in: text, range: all) where !out.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) {
            out.append(Token(kind: .mention, range: m.range))
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// The paste chip a backspace at `caret` (UTF-16) deletes whole: the chip ending at, or holding,
    /// the caret. Chips are opaque; mentions and commands delete a character at a time, as typed.
    public static func chip(endingAt caret: Int, in text: String) -> NSRange? {
        tokens(in: text).first { $0.kind == .paste && caret > $0.range.location && caret <= NSMaxRange($0.range) }?.range
    }

    private static let command = try! NSRegularExpression(pattern: #"^/[A-Za-z][\w:.\-]*"#)
    private static let pasteChip = try! NSRegularExpression(pattern: #"\[Pasted text #(\d+) \+\d+ lines\]"#)
    private static let mentionPattern = try! NSRegularExpression(pattern: #"(?<![^\s])@(?:"[^"\n]+"|[^\s"]+)"#)
}
