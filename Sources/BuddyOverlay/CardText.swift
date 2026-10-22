import Foundation

/// A past turn's `card_html` as readable plain text, for full screen's history.
///
/// Past cards render as text, not as a web view each: a long conversation would otherwise
/// load one WKWebView per turn and re-size rows as their heights arrive, and past cards are
/// inert anyway. Text also takes its colours from the overlay's tokens. Paragraphs, headings
/// and rows become lines, list items get "• ", table cells are joined with " · ", `<pre>`
/// keeps its lines and indentation, and images, SVG diagrams, styles and scripts are left out.
/// The HTML is model output, so anything malformed is kept as text rather than dropped.
nonisolated enum CardText {
    /// Elements whose contents are never shown.
    private static let skipped: Set<String> = ["svg", "head", "title", "template", "noscript", "math"]
    /// Skipped elements whose contents are raw text: they end only at their own end tag.
    private static let raw: Set<String> = ["style", "script", "textarea", "xmp"]
    /// Elements that start (and end) a line.
    private static let blocks: Set<String> = [
        "p", "div", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "thead", "tbody",
        "tfoot", "tr", "pre", "blockquote", "section", "article", "header", "footer", "figure", "figcaption",
        "dl", "dt", "dd", "details", "summary", "caption",
    ]

    static func plainText(fromHTML html: String) -> String {
        let chars = Array(html.unicodeScalars)
        var out = ""
        var cellsInRow = 0
        var cellDepth = 0
        var preDepth = 0
        var skipping: String?  // the skipped element we're inside
        var skipDepth = 0
        var i = 0

        func newline() {
            if !out.isEmpty, !out.hasSuffix("\n") { out.append("\n") }
        }

        while i < chars.count {
            let c = chars[i]
            if c == "<", let (tag, next) = Self.tag(chars, at: i) {
                i = next
                guard let tag else { continue }  // comment, doctype
                if let s = skipping {
                    if tag.name == s { skipDepth += tag.closing ? -1 : (tag.selfClosing ? 0 : 1) }
                    if skipDepth <= 0 { skipping = nil }
                    continue
                }
                if raw.contains(tag.name) {
                    if !tag.closing, !tag.selfClosing { i = Self.endOfRaw(tag.name, chars, from: i) }
                    continue
                }
                if skipped.contains(tag.name) {
                    if !tag.closing, !tag.selfClosing {
                        skipping = tag.name
                        skipDepth = 1
                    }
                    continue
                }
                switch tag.name {
                case "pre": preDepth = max(0, preDepth + (tag.closing ? -1 : 1))
                case "tr": cellsInRow = 0
                case "td", "th":
                    if tag.closing {
                        cellDepth = max(0, cellDepth - 1)
                    } else {
                        if cellsInRow > 0 {
                            while out.hasSuffix(" ") { out.removeLast() }
                            out.append(" · ")
                        }
                        cellsInRow += 1
                        cellDepth += 1
                    }
                    continue
                default: break
                }
                if blocks.contains(tag.name) {
                    if cellDepth > 0 {
                        // Inside a cell the row stays on one line.
                        if !out.isEmpty, !out.hasSuffix(" "), !out.hasSuffix("\n") { out.append(" ") }
                    } else {
                        newline()
                        if tag.name == "li", !tag.closing { out.append("• ") }
                    }
                }
                continue
            }
            if skipping != nil {
                i += 1
                continue
            }
            if c == "&", let (decoded, next) = Self.entity(chars, at: i) {
                append(decoded, to: &out, pre: preDepth > 0)
                i = next
                continue
            }
            append(Character(c), to: &out, pre: preDepth > 0)
            i += 1
        }
        // Lines never start with collapsed whitespace, so only `<pre>` lines keep leading spaces.
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.reversed().drop { $0.isWhitespace }.reversed()) }
            .filter { line in line.contains { !$0.isWhitespace } && line != "•" }
            .joined(separator: "\n")
    }

    /// Source whitespace collapses to one space, except inside `<pre>`.
    private static func append(_ ch: Character, to out: inout String, pre: Bool) {
        if pre {
            out.append(ch == "\r" ? "\n" : ch)
        } else if ch.isWhitespace && ch != "\u{00A0}" {
            if !out.isEmpty, !out.hasSuffix(" "), !out.hasSuffix("\n") { out.append(" ") }
        } else {
            out.append(ch == "\u{00A0}" ? " " : ch)
        }
    }

    private static func append(_ s: String, to out: inout String, pre: Bool) {
        for ch in s { append(ch, to: &out, pre: pre) }
    }

    private struct Tag {
        var name: String
        var closing: Bool
        var selfClosing: Bool
    }

    /// The markup starting at `start` (a "<"): a tag (nil for a comment or doctype) and the
    /// index after it. Nil when the "<" is just text ("a < b") or never closes.
    private static func tag(_ chars: [Unicode.Scalar], at start: Int) -> (Tag?, Int)? {
        var i = start + 1
        guard i < chars.count else { return nil }
        if chars[i] == "!" {
            if i + 2 < chars.count, chars[i + 1] == "-", chars[i + 2] == "-" {
                // A comment ends at "-->"; an unclosed one hides the rest, as in a browser.
                var j = i + 3
                while j + 2 < chars.count, !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") { j += 1 }
                return (nil, min(j + 3, chars.count))
            }
            guard let end = chars[i...].firstIndex(of: ">") else { return nil }
            return (nil, end + 1)
        }
        if chars[i] == "?" {
            guard let end = chars[i...].firstIndex(of: ">") else { return nil }
            return (nil, end + 1)
        }
        let closing = chars[i] == "/"
        if closing { i += 1 }
        guard i < chars.count, chars[i].properties.isAlphabetic, chars[i].isASCII else { return nil }
        var name = ""
        while i < chars.count, chars[i].isASCII, chars[i].properties.isAlphabetic || ("0"..."9").contains(chars[i]) {
            name.unicodeScalars.append(chars[i])
            i += 1
        }
        // To the closing ">", skipping quoted attribute values.
        var quote: Unicode.Scalar?
        var last: Unicode.Scalar = " "
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                let selfClosing = last == "/" || name.lowercased() == "br" || name.lowercased() == "hr"
                return (Tag(name: name.lowercased(), closing: closing, selfClosing: selfClosing), i + 1)
            }
            if !c.properties.isWhitespace { last = c }
            i += 1
        }
        return nil
    }

    /// The index after `</name ...>` (any case), or the end when it never closes.
    private static func endOfRaw(_ name: String, _ chars: [Unicode.Scalar], from start: Int) -> Int {
        let needle = Array(("</" + name).unicodeScalars)
        var i = start
        while i + needle.count <= chars.count {
            if chars[i] == "<",
               zip(chars[i..<i + needle.count], needle).allSatisfy({ String($0).lowercased() == String($1) }) {
                return (chars[(i + needle.count)...].firstIndex(of: ">") ?? chars.count - 1) + 1
            }
            i += 1
        }
        return chars.count
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "middot": "·",
        "bull": "•", "hellip": "…", "mdash": "—", "ndash": "–", "rarr": "→", "larr": "←", "times": "×",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "deg": "°",
    ]

    /// `&name;`, `&#123;` or `&#x7B;` at `start`; nil leaves the `&` as text.
    private static func entity(_ chars: [Unicode.Scalar], at start: Int) -> (String, Int)? {
        let limit = min(chars.count, start + 12)
        guard let semi = chars[(start + 1)..<limit].firstIndex(of: ";") else { return nil }
        var body = ""
        body.unicodeScalars.append(contentsOf: chars[(start + 1)..<semi])
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            // No control characters (NUL included) from model output.
            guard let value, value >= 0x20 || value == 0x09 || value == 0x0A,
                  let scalar = Unicode.Scalar(value) else { return nil }
            return (String(Character(scalar)), semi + 1)
        }
        guard let text = named[body.lowercased()] else { return nil }
        return (text, semi + 1)
    }
}
