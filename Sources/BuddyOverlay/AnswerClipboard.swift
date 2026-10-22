import AppKit
import BuddyCore

/// What Copy puts on the clipboard: plain text always, and HTML too when the
/// answer is formatted, so rich editors keep its tables and lists.
nonisolated struct ClipboardContents: Sendable, Equatable {
    var plain: String
    var html: String?
}

nonisolated enum AnswerClipboard {
    /// The paste text when the answer has one (a rewrite or draft): exactly what Insert would
    /// insert, never the spoken headline. Otherwise the headline and the card's text.
    static func contents(for block: BuddyBlock) -> ClipboardContents {
        if let insert = block.insert, !insert.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ClipboardContents(plain: insert, html: nil)
        }
        guard let html = block.cardHTML, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ClipboardContents(plain: block.say, html: nil)
        }
        let text = plainText(fromHTML: html)
        return ClipboardContents(plain: text.isEmpty ? block.say : block.say + "\n\n" + text,
                                 html: "<p><strong>\(escape(block.say))</strong></p>\n" + richHTML(html))
    }

    /// Card HTML has no length limit; nothing past this is copied (and nothing slow runs on it).
    static let maxHTML = 200_000

    /// Text from the card's HTML without loading it anywhere (an HTML importer could fetch
    /// remote resources). One linear pass: `<pre>` keeps its whitespace; elsewhere whitespace
    /// collapses as a browser's would, block ends become line breaks, bullets become "• ",
    /// table cells are tab-separated, tags go and entities are decoded.
    static func plainText(fromHTML raw: String) -> String {
        let html = removingElements(["script", "style"], from: String(raw.prefix(maxHTML)))
        var out = ""
        var rest = Substring(html)
        while let open = openingTag("pre", in: rest), let close = rest[open.upperBound...].range(of: "</pre>", options: .caseInsensitive) {
            out += flow(rest[..<open.lowerBound])
            out += "\n" + preformatted(rest[open.upperBound..<close.lowerBound]) + "\n"
            rest = rest[close.upperBound...]
        }
        out += flow(rest)
        // At most one blank line in a row.
        var lines: [String] = []
        for line in out.components(separatedBy: "\n") where !(line.isEmpty && (lines.last?.isEmpty ?? true)) {
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The card's HTML for a rich paste: no scripts or styles, no `buddy://` links (they only
    /// mean something inside the card).
    static func richHTML(_ raw: String) -> String {
        removingElements(["script", "style"], from: String(raw.prefix(maxHTML)))
            .replacing(/\s*href\s*=\s*["']buddy:[^"']*["']/, with: "")
    }

    private static func flow(_ text: Substring) -> String {
        var s = String(text).replacing(/\s+/, with: " ")
        s = s.replacing(/(?i)<li\b[^>]*>/, with: "\n• ")
        s = s.replacing(/(?i)<br\s*\/?>|<\/(p|div|tr|h[1-6]|blockquote|table|ul|ol)>/, with: "\n")
        s = s.replacing(/(?i)<\/t[dh]>/, with: "\t")
        s = decodeEntities(s.replacing(/<[^>]*>/, with: "")).replacing(/[ ]*\t[ ]*/, with: "\t")
        return s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    /// Code keeps its indentation; only trailing spaces go.
    private static func preformatted(_ text: Substring) -> String {
        decodeEntities(String(text).replacing(/<[^>]*>/, with: ""))
            .components(separatedBy: "\n")
            .map { line in String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    /// Named entities the model writes, and every numeric one (`&#8217;`, `&#x27;`).
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var s = text.replacing(/&#(x[0-9a-fA-F]+|[0-9]+);/) { match in
            let digits = match.1
            let value = digits.hasPrefix("x") || digits.hasPrefix("X")
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.0)
        }
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
                               ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
                               ("&rdquo;", "”"), ("&ldquo;", "“"), ("&middot;", "·"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s
    }

    /// `<name` followed by `>` or whitespace (so `<pre` never matches `<prefix`); the range
    /// ends after the tag's closing `>`.
    private static func openingTag(_ name: String, in text: Substring) -> Range<Substring.Index>? {
        var from = text.startIndex
        while let start = text[from...].range(of: "<" + name, options: .caseInsensitive) {
            let next = start.upperBound < text.endIndex ? text[start.upperBound] : ">"
            if next == ">" || next.isWhitespace, let end = text[start.upperBound...].firstIndex(of: ">") {
                return start.lowerBound..<text.index(after: end)
            }
            from = start.upperBound
        }
        return nil
    }

    /// Drops whole elements with a linear scan (no backtracking on unclosed tags).
    private static func removingElements(_ names: [String], from html: String) -> String {
        var s = Substring(html)
        for name in names {
            var out = ""
            while let open = openingTag(name, in: s) {
                out += s[..<open.lowerBound]
                guard let close = s[open.upperBound...].range(of: "</\(name)>", options: .caseInsensitive) else {
                    s = s[s.endIndex...]  // unclosed: the rest is that element
                    break
                }
                s = s[close.upperBound...]
            }
            out += s
            s = Substring(out)
        }
        return String(s)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// The system clipboard; tests use a recording fake.
protocol ClipboardWriting {
    func write(_ contents: ClipboardContents)
}

struct SystemClipboard: ClipboardWriting {
    func write(_ contents: ClipboardContents) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes(contents.html == nil ? [.string] : [.html, .string], owner: nil)
        pasteboard.setString(contents.plain, forType: .string)
        if let html = contents.html { pasteboard.setString(html, forType: .html) }
    }
}
