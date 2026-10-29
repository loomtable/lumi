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
    /// v2 open sessions: how the turn was given, and the answer as Markdown (typed turns are
    /// rendered from it; `block` then only carries its first line). Nil for v1 turns.
    public var kind: TurnKind?
    public var markdown: String?
    /// Teammates (subagents) that worked during the turn, by name, in order of first appearance.
    public var teammates: [String] = []
    /// The turn edited or wrote files (an Edit, Write or NotebookEdit call): editing an earlier
    /// prompt says those changes stay.
    public var changedFiles = false

    public init(id: String = UUID().uuidString, question: String, block: BuddyBlock, mode: Mode, model: ModelID,
                kind: TurnKind? = nil, markdown: String? = nil, teammates: [String] = [], changedFiles: Bool = false) {
        self.id = id
        self.question = question
        self.block = block
        self.mode = mode
        self.model = model
        self.kind = kind
        self.markdown = markdown
        self.teammates = teammates
        self.changedFiles = changedFiles
    }

    enum CodingKeys: String, CodingKey { case id, question, block, mode, model, kind, markdown, teammates, changedFiles }

    /// The v2 fields are optional on decode, so a turn stored before them still reads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        question = try c.decode(String.self, forKey: .question)
        block = try c.decode(BuddyBlock.self, forKey: .block)
        mode = try c.decode(Mode.self, forKey: .mode)
        model = try c.decode(ModelID.self, forKey: .model)
        kind = try c.decodeIfPresent(TurnKind.self, forKey: .kind)
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown)
        teammates = try c.decodeIfPresent([String].self, forKey: .teammates) ?? []
        changedFiles = try c.decodeIfPresent(Bool.self, forKey: .changedFiles) ?? false
    }
}
