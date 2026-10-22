import Foundation

/// Spoken (or typed) conversation changes: "new topic" starts fresh, with the rest of
/// the sentence as its first question; a bare "go back" returns to the conversation before the
/// last new one. Only at the start, whole words, like the cascade's routing overrides.
enum ConversationCommand: Sendable, Equatable {
    case newTopic(rest: String)
    case goBack

    static let newTopicPhrases = ["new topic", "new conversation", "start over", "start fresh"]

    static func parse(_ text: String) -> ConversationCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        for phrase in newTopicPhrases where lower.hasPrefix(phrase) {
            let rest = trimmed.dropFirst(phrase.count)
            guard rest.first.map({ $0.isWhitespace || $0.isPunctuation }) ?? true else { continue }
            // Leading ", " goes; the question keeps its own "?".
            return .newTopic(rest: String(rest.drop { $0.isWhitespace || $0.isPunctuation }))
        }
        // "go back to the last page" is a question; only the bare phrase changes conversation.
        if lower.trimmingCharacters(in: separators) == "go back" { return .goBack }
        return nil
    }
}
