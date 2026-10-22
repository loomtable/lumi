import Foundation

/// One finished turn of a conversation: what the user asked and the `buddy` block that
/// answered it, with the lane that produced it. Full screen shows a conversation's turns in
/// order; Codable so persisted history can hold the same value later.
public struct TranscriptTurn: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    /// The user's words: the transcript or the typed text.
    public var question: String
    public var block: BuddyBlock
    public var mode: Mode
    public var model: ModelID

    public init(id: String = UUID().uuidString, question: String, block: BuddyBlock, mode: Mode, model: ModelID) {
        self.id = id
        self.question = question
        self.block = block
        self.mode = mode
        self.model = model
    }
}
