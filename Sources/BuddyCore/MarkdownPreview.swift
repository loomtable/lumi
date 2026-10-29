import Foundation

/// Markdown as one line of plain text, for every compact preview of an answer or ask: the
/// switcher's peek and tiles, and notifications. Previews are too small to
/// render Markdown, so its marks go and what they mark stays: `**Budapest**` reads "Budapest",
/// `[the doc](https://…)` reads "the doc", `` `npm test` `` reads "npm test". Fence lines, rules
/// and table separator rows are dropped (a code block's lines stay, as written); list, quote and
/// heading markers go; table cells are joined with " · "; line breaks become spaces.
public enum MarkdownPreview {
    /// One line, cut at a word to at most `limit` characters (with "…") when `limit` is given.
    public static func line(_ markdown: String, limit: Int? = nil) -> String {
        // Runs of prose (inline marks removed together, so a mark may span lines) and code
        // block lines (kept as written).
        var parts: [String] = []
        var prose: [String] = []
        var inFence = false
        func endProse() {
            if !prose.isEmpty { parts.append(inline(prose.joined(separator: " "))) }
            prose = []
        }
        for raw in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                endProse()
                inFence.toggle()
            } else if inFence {
                if !trimmed.isEmpty { parts.append(trimmed) }
            } else if let block = blockText(trimmed), !block.isEmpty {
                prose.append(block)
            }
        }
        endProse()
        let flat = parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let limit, flat.count > limit, limit > 1 else { return flat }
        let cut = flat.prefix(limit - 1)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    /// A line without its block marks; nil for a line that is only marks (a rule, a table's
    /// separator row).
    static func blockText(_ line: String) -> String? {
        if line.isEmpty { return nil }
        if matches(#"^([-*_])(\s*\1){2,}$"#, line) { return nil }               // --- *** ___
        if matches(#"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#, line) { return nil }  // |---|:--|
        var s = line
        s = replacing(#"^(>\s?)+"#, in: s, with: "")                            // > quote
        s = replacing(#"^#{1,6}\s+"#, in: s, with: "")                          // ## heading
        s = replacing(#"^([-*+]|\d{1,9}[.)])\s+"#, in: s, with: "")             // - item, 1. item
        s = replacing(#"^\[[ xX]\]\s+"#, in: s, with: "")                       // [x] task
        if s.hasPrefix("|") || s.hasSuffix("|") {                               // | a | b |
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
            s = replacing(#"\s*\|\s*"#, in: s, with: " · ")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Inline marks off, their text kept. Code spans and backslash escapes are set aside first,
    /// so the marks inside them stay as written.
    static func inline(_ text: String) -> String {
        var codes: [String] = []
        var s = text
        // \* and friends: the character itself, never a mark.
        let escape = try! NSRegularExpression(pattern: #"\\([\\`*_{}\[\]()#+\-.!>~|])"#)
        for m in escape.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: s), let char = Range(m.range(at: 1), in: s) else { continue }
            codes.append(String(s[char]))
            s.replaceSubrange(whole, with: "\u{E000}\(codes.count - 1)\u{E001}")
        }
        // `code` and ``code with ` inside``: keep the code, drop the ticks.
        let code = try! NSRegularExpression(pattern: #"(`+)(.+?)\1"#)
        for m in code.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: s), let body = Range(m.range(at: 2), in: s) else { continue }
            codes.append(s[body].trimmingCharacters(in: .whitespaces))
            s.replaceSubrange(whole, with: "\u{E000}\(codes.count - 1)\u{E001}")
        }
        s = replacing(#"!\[([^\]]*)\]\([^)]*\)"#, in: s, with: "$1")            // ![alt](src)
        s = replacing(#"\[([^\]]+)\]\([^)]*\)"#, in: s, with: "$1")             // [text](url)
        s = replacing(#"\[([^\]]+)\]\[[^\]]*\]"#, in: s, with: "$1")            // [text][ref]
        s = replacing(#"<((?:https?|mailto):[^>\s]+)>"#, in: s, with: "$1")     // <https://…>
        s = replacing(#"</?[A-Za-z][^>]*>"#, in: s, with: " ")                  // <br>, <b>
        s = replacing(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, in: s, with: "$2")     // **bold** __bold__
        s = replacing(#"~~(?=\S)(.+?)(?<=\S)~~"#, in: s, with: "$1")            // ~~struck~~
        s = replacing(#"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#, in: s, with: "$1")  // *em*
        s = replacing(#"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#, in: s, with: "$1")    // _em_, not snake_case
        for (i, c) in codes.enumerated() { s = s.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: c) }
        return s
    }

    private static func replacing(_ pattern: String, in s: String, with template: String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static func matches(_ pattern: String, _ s: String) -> Bool {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
