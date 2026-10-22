import Foundation

/// Finds an answer's quote in on-screen text the way people read it: case- and
/// diacritic-insensitive, whole words only, any run of whitespace or punctuation between words
/// equal to any other, punctuation inside a word optional, curly and straight quotes alike, all
/// dashes alike, and punctuation at either end of the quote ignored.
public nonisolated enum TextMatch {
    /// The range of `quote` in `text`, or nil.
    public static func range(of quote: String, in text: String) -> Range<String.Index>? {
        Matcher(quote)?.range(in: text)
    }

    /// The first `words` words of `quote`, for a quote that wraps onto further lines.
    public static func prefix(of quote: String, words: Int) -> String? {
        let parts = quote.split(whereSeparator: \.isWhitespace)
        guard parts.count > words else { return nil }
        return parts.prefix(words).joined(separator: " ")
    }

    /// `range` of `text` as an AX (UTF-16) range.
    public static func utf16Range(_ range: Range<String.Index>, in text: String) -> CFRange {
        CFRange(
            location: text.utf16.distance(from: text.startIndex, to: range.lowerBound),
            length: text.utf16.distance(from: range.lowerBound, to: range.upperBound))
    }

    /// One quote, compiled once and matched against many texts.
    public struct Matcher {
        public let quote: String
        let regex: Regex<AnyRegexOutput>

        public init?(_ quote: String) {
            let core = quote.trimmingCharacters(in: TextMatch.edgeTrim)
            let tokens = TextMatch.fold(core)
                .split { $0.isWhitespace || ($0.isPunctuation && !TextMatch.isWordPart($0)) }
                .map { token in token.map(TextMatch.pattern(for:)).joined() }
            guard !tokens.isEmpty, let first = core.first, let last = core.last else { return nil }
            // Whole words: "art" must not match inside "Chart". Swift Regex has no lookbehind, so
            // a simple word boundary is added where the quote starts or ends with a word character.
            let open = TextMatch.isWord(first) ? #"\b"# : ""
            let close = TextMatch.isWord(last) ? #"\b"# : ""
            guard let regex = try? Regex(open + tokens.joined(separator: TextMatch.separator) + close)
                .ignoresCase().wordBoundaryKind(.simple)
            else { return nil }
            self.quote = quote
            self.regex = regex
        }

        /// The first match in `text`, as a range of `text` itself.
        public func range(in text: String) -> Range<String.Index>? {
            let folded = Folded(text)
            return folded.text.firstRange(of: regex).map(folded.original)
        }
    }

    /// Between words: any whitespace and punctuation, at least one character.
    static let separator = #"[\s\p{P}]+"#

    static let edgeTrim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

    static let apostrophes: Set<Character> = ["'", "’", "‘", "`"]
    static let quotes: Set<Character> = ["\"", "“", "”", "„"]
    static let dashes: Set<Character> = ["-", "–", "—", "‐", "−"]

    static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    /// Punctuation kept inside a word and matched as optional there ("e-mail", "it's", "3.5").
    static func isWordPart(_ c: Character) -> Bool {
        apostrophes.contains(c) || dashes.contains(c) || c == "." || c == ","
    }

    static func pattern(for c: Character) -> String {
        if apostrophes.contains(c) { return "['’‘`]?" }
        if quotes.contains(c) { return "[\"“”„]?" }
        if dashes.contains(c) { return "[-–—‐−]?" }
        let literal = NSRegularExpression.escapedPattern(for: String(c))
        return c.isPunctuation ? "(?:\(literal))?" : literal
    }

    static func fold(_ text: String) -> String {
        Folded(text).text
    }

    /// A diacritic-folded copy with the same number of characters as the original, so a match
    /// in it maps back to the original text.
    struct Folded {
        let text: String
        /// Nil when the copy is the original (ASCII, or folding would change the length).
        private let source: String?

        init(_ original: String) {
            guard !original.utf8.allSatisfy({ $0 < 0x80 }) else {
                text = original
                source = nil
                return
            }
            var out = ""
            out.reserveCapacity(original.utf8.count)
            for c in original {
                let f = String(c).folding(options: .diacriticInsensitive, locale: nil)
                out.append(f.count == 1 ? f : String(c))
            }
            if out.count == original.count {
                text = out
                source = original
            } else {
                text = original
                source = nil
            }
        }

        func original(_ range: Range<String.Index>) -> Range<String.Index> {
            guard let source else { return range }
            let lower = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            let start = source.index(source.startIndex, offsetBy: lower)
            return start..<source.index(start, offsetBy: length)
        }
    }
}
