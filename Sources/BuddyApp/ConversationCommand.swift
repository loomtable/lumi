import Foundation

/// A spoken (or typed) conversation change: "new topic" starts fresh, with the rest of the
/// sentence as its first question. Only at the start, whole words, like the cascade's routing
/// overrides. Going back to an earlier conversation is the switcher's (Tab) or the history's.
enum ConversationCommand: Sendable, Equatable {
    case newTopic(rest: String)

    static let newTopicPhrases = ["new topic", "new session", "new conversation", "start over", "start fresh"]

    static func parse(_ text: String) -> ConversationCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for phrase in newTopicPhrases where lower.hasPrefix(phrase) {
            let rest = trimmed.dropFirst(phrase.count)
            guard rest.first.map({ $0.isWhitespace || $0.isPunctuation }) ?? true else { continue }
            // Leading ", " goes; the question keeps its own "?".
            return .newTopic(rest: String(rest.drop { $0.isWhitespace || $0.isPunctuation }))
        }
        return nil
    }
}
