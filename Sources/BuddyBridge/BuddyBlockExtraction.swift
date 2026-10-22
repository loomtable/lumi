import BuddyCore
import Foundation

/// Finds the `buddy` answer block in a final message (the last fenced block).
public enum BuddyBlockExtractor {
    public struct Extraction: Sendable, Equatable {
        /// Nil when there is no fenced block or it doesn't decode (`say` missing, bad JSON).
        public var block: BuddyBlock?
        /// The message with the block removed, trimmed.
        public var prose: String
    }

    /// Takes the last fence tagged `buddy`; failing that, the last `json` or untagged fence
    /// whose body decodes as a block.
    public static func extract(from raw: String) -> Extraction {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let fences = fencedBlocks(in: text)
        let tagged = fences.last { $0.tag == "buddy" }
        let candidates = tagged.map { [$0] } ?? fences.reversed().filter { $0.tag == "json" || $0.tag.isEmpty }
        for fence in candidates {
            if let block = try? JSONDecoder().decode(BuddyBlock.self, from: Data(fence.body.utf8)) {
                var prose = text
                prose.removeSubrange(fence.range)
                return Extraction(block: block, prose: prose.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return Extraction(block: nil, prose: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    struct Fence {
        var tag: String
        var body: String
        var range: Range<String.Index>
    }

    /// A closing fence is a line that is exactly ``` (an opener like ```swift is not a close).
    static func closingFence(in text: String, from start: String.Index) -> Range<String.Index>? {
        var from = start
        while let r = text.range(of: "\n```", range: from..<text.endIndex) {
            let after = text[r.upperBound...]
            let rest = after.prefix { $0 != "\n" }
            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                return r.lowerBound..<text.index(r.upperBound, offsetBy: rest.count)
            }
            from = r.upperBound
        }
        return nil
    }

    /// Fences open with ``` plus an optional tag at line start and close with a bare ``` line.
    static func fencedBlocks(in text: String) -> [Fence] {
        var fences: [Fence] = []
        var searchFrom = text.startIndex
        while let open = text.range(of: "```", range: searchFrom..<text.endIndex) {
            guard open.lowerBound == text.startIndex || text[text.index(before: open.lowerBound)] == "\n",
                  let tagEnd = text[open.upperBound...].firstIndex(of: "\n") else {
                searchFrom = open.upperBound
                continue
            }
            let tag = text[open.upperBound..<tagEnd].trimmingCharacters(in: .whitespaces).lowercased()
            let bodyStart = text.index(after: tagEnd)
            guard let close = closingFence(in: text, from: bodyStart) else { break }
            fences.append(Fence(tag: tag, body: String(text[bodyStart..<close.lowerBound]),
                                range: open.lowerBound..<close.upperBound))
            searchFrom = close.upperBound
        }
        return fences
    }
}

/// Watches streamed answer text and yields speech as early as possible, so the voice can start
/// before the rest of the block (card HTML) has streamed. The buddy-answer skill puts `say`
/// first in the block, so the first spoken word waits only for `say`'s first sentence.
public struct SayStreamExtractor: Sendable {
    public enum Speech: Sendable, Equatable {
        /// The first sentence of `say`, the moment it closes: start speaking.
        case firstSentence(String)
        /// All of `say`, once its string closes. Speak whatever follows the first sentence.
        case complete(String)
    }

    private var text = ""
    private var sentEmitted = false
    private var done = false

    /// Stop looking this far past the fence: `say` comes first, so it isn't coming.
    static let searchLimit = 4_000

    public init() {}

    /// Feed each text delta of one assistant message. Returns what became speakable.
    public mutating func append(_ delta: String) -> [Speech] {
        guard !done, text.utf8.count < Self.searchLimit * 4 else { return [] }
        text += delta.replacingOccurrences(of: "\r\n", with: "\n")
        guard let scan = Self.scanSay(in: text) else { return [] }
        var out: [Speech] = []
        if !sentEmitted, let sentence = scan.firstSentence {
            sentEmitted = true
            out.append(.firstSentence(sentence))
        }
        if let complete = scan.complete {
            done = true
            if !sentEmitted {
                sentEmitted = true
                out.append(.firstSentence(complete))
            }
            out.append(.complete(complete))
        }
        return out
    }

    struct Scan {
        var firstSentence: String?
        var complete: String?
    }

    /// Reads `"say": "…` inside a ```buddy fence at line start, as far as it has streamed.
    static func scanSay(in text: String) -> Scan? {
        guard let fence = text.range(of: "```buddy"),
              fence.lowerBound == text.startIndex || text[text.index(before: fence.lowerBound)] == "\n" else { return nil }
        let window = text[fence.upperBound...].prefix(searchLimit)
        guard let key = window.range(of: #""say""#) else { return nil }
        var i = key.upperBound
        while i < text.endIndex, text[i] == " " || text[i] == ":" || text[i] == "\n" || text[i] == "\t" {
            i = text.index(after: i)
        }
        guard i < text.endIndex, text[i] == "\"" else { return nil }
        let open = i
        var scan = Scan()
        var escaped = false
        i = text.index(after: i)
        while i < text.endIndex {
            let c = text[i]
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                scan.complete = decode(text[open..<i])
                if scan.firstSentence == nil { scan.firstSentence = scan.complete.map(BuddyBlock.firstSentence(of:)) }
                return scan
            } else if scan.firstSentence == nil, text[text.index(before: i)] == " ", c != " ",
                      let partial = decode(text[open...i]) {
                // The first letter of a new word: apply the headline rules ("Dr. Ortiz", "5 p.m. tomorrow",
                // "38 ms. Then"). They look one word past a period, and its first letter decides,
                // except after an initial, which waits for the whole next word ("A. J. Smith").
                let first = BuddyBlock.firstSentence(of: partial)
                let firstWords = first.split(whereSeparator: \.isWhitespace)
                let words = partial.split(whereSeparator: \.isWhitespace).count
                let afterInitial = firstWords.last.map(isInitial) ?? false
                if firstWords.count < words, !(afterInitial && firstWords.count == words - 1) {
                    scan.firstSentence = first
                }
            }
            i = text.index(after: i)
        }
        return scan
    }

    /// "A." or "(J.": one capital letter and a period, possibly part of a name.
    private static func isInitial(_ word: Substring) -> Bool {
        let core = Array(word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’()[]")))
        return core.count == 2 && core[0].isLetter && core[0].isUppercase && core[1] == "."
    }

    /// Decodes the JSON string body that starts at the opening quote (closing quote added).
    private static func decode(_ literalWithoutClose: Substring) -> String? {
        try? JSONDecoder().decode(String.self, from: Data((literalWithoutClose + "\"").utf8))
    }
}
