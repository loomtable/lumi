import Foundation

/// Splits a reply into sentences so the voice can start speaking after the first one is synthesized.
///
/// A sentence ends at `.`, `!`, `?` or `…` (closing quotes and brackets included) followed by
/// whitespace or the end of the text. Abbreviations ("e.g.", "Dr."), decimals ("3.5") and versions
/// ("v2.1") don't end a sentence. Pieces shorter than `minimumWords` are merged into the next one, so
/// speech isn't choppy. Text without terminal punctuation is one segment.
public enum SentenceSplitter {
    public static let minimumWords = 4

    /// Lowercased, without the final period. A period after these doesn't end a sentence.
    static let abbreviations: Set<String> = [
        "e.g", "i.e", "vs", "mr", "mrs", "dr", "prof", "sr", "jr", "fig", "approx", "dept", "corp",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "u.s", "cf", "al",
    ]

    /// These end a sentence only when the next word starts with a capital ("…at 40 ms. The cache…",
    /// "…ends at 5 p.m. Then…", but "Ms. Lee" and "No. 5" stay whole when followed by a name or number).
    static let endsBeforeCapital: Set<String> = [
        "etc", "ms", "no", "st", "est", "inc", "ltd", "co", "min", "max", "a.m", "p.m",
    ]

    public static func split(_ text: String, minimumWords: Int = minimumWords) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return merge(rawSentences(trimmed), minimumWords: minimumWords)
    }

    /// Sentences as written, before short pieces are merged.
    static func rawSentences(_ text: String) -> [String] {
        let chars = Array(text)
        var sentences: [String] = []
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "." || c == "!" || c == "?" || c == "…" else { i += 1; continue }
            // Runs like "?!" or "..." end together.
            var end = i
            while end + 1 < chars.count, ".!?…".contains(chars[end + 1]) { end += 1 }
            // Closing quotes and brackets belong to the sentence they close.
            while end + 1 < chars.count, "\"'”’)]".contains(chars[end + 1]) { end += 1 }
            let atEnd = end + 1 >= chars.count
            let followedBySpace = !atEnd && chars[end + 1].isWhitespace
            if (atEnd || followedBySpace), !(c == "." && i == end && isNonTerminalPeriod(chars, at: i)) {
                let sentence = String(chars[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                start = end + 1
            }
            i = end + 1
        }
        let rest = String(chars[min(start, chars.count)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences
    }

    /// A single period that belongs to an abbreviation, an initial ("J. Smith") or a number.
    static func isNonTerminalPeriod(_ chars: [Character], at index: Int) -> Bool {
        // The word the period ends, including inner periods ("e.g", "U.S").
        var wordStart = index
        while wordStart > 0, !chars[wordStart - 1].isWhitespace, !"(\"'“‘".contains(chars[wordStart - 1]) {
            wordStart -= 1
        }
        let word = String(chars[wordStart..<index]).lowercased()
        if abbreviations.contains(word) { return true }
        if endsBeforeCapital.contains(word) {
            // "Ms. Lee" is a title; "40 ms." (after a number) is a unit and can end the sentence.
            let afterNumber = wordStart >= 2 && chars[wordStart - 2].isNumber
            if word == "ms", !afterNumber { return true }
            let next = chars[(index + 1)...].drop(while: { $0.isWhitespace || "\"'“‘([".contains($0) }).first
            return next.map { !$0.isUppercase } ?? false
        }
        // A single letter is an initial.
        if word.count == 1, word.first?.isLetter == true { return true }
        // Decimals and versions ("3.5", "v2.1") never get here: their period isn't followed by a space.
        return false
    }

    /// Merges pieces under `minimumWords` into the following one (the last into the previous one).
    static func merge(_ sentences: [String], minimumWords: Int) -> [String] {
        var out: [String] = []
        var pending = ""
        for sentence in sentences {
            let joined = pending.isEmpty ? sentence : pending + " " + sentence
            if wordCount(joined) < minimumWords {
                pending = joined
            } else {
                out.append(joined)
                pending = ""
            }
        }
        if !pending.isEmpty {
            if let last = out.popLast() { out.append(last + " " + pending) } else { out.append(pending) }
        }
        return out
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
