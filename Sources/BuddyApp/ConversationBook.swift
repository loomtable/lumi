import BuddyCore
import Foundation

/// The current conversation, kept in memory: continue by default, start fresh after 30 min idle,
/// when a different project is in front, or on request. BuddyConversations replaces
/// the storage once it's wired in.
struct ConversationBook {
    struct Conversation: Equatable {
        var state: ConversationState
        var color: ConversationColor
        /// The project folder the conversation started in (localhost cwd, editor workspace or
        /// terminal cwd), standardised. Nil when none was in front.
        var project: String?
        /// Completed turns.
        var turn: Int
        /// The last three turns as text, for Quick follow-ups.
        var previous: [String]
        /// Every turn shown, oldest first, for full screen's transcript (in memory only).
        var turns: [TranscriptTurn] = []
        var lastUsed: Date
    }

    static let idleLimit: TimeInterval = 30 * 60

    private(set) var current: Conversation?
    private var created = 0
    private let clock: @Sendable () -> Date

    init(clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    /// The conversation the next question belongs to: the current one, unless it went idle or a
    /// different project is in front. An empty conversation adopts the project in front.
    mutating func prepare(project: String?) -> Conversation {
        let now = clock()
        guard var existing = current, now.timeIntervalSince(existing.lastUsed) < Self.idleLimit else {
            return startNew(project: project)
        }
        if let project, project != existing.project {
            if existing.project == nil && existing.turn == 0 {
                existing.project = project
                current = existing
                return existing
            }
            if existing.project != nil { return startNew(project: project) }
        }
        return existing
    }

    @discardableResult
    mutating func startNew(project: String? = nil) -> Conversation {
        let conversation = Conversation(
            state: ConversationState(id: "c_\(UUID().uuidString.prefix(8).lowercased())"),
            color: ConversationColor.forIndex(created),
            project: project,
            turn: 0,
            previous: [],
            lastUsed: clock())
        created += 1
        current = conversation
        return conversation
    }

    /// Applies the cascade's state (session ids, last lane) if it's still the current conversation.
    mutating func update(_ state: ConversationState) {
        guard current?.state.id == state.id else { return }
        current?.state = state
    }

    /// Records a finished turn on the conversation it was asked in; nil if that conversation is
    /// no longer current (the user started a new one meanwhile).
    mutating func recordTurn(
        conversationID: String, question: String, answer: String, transcript: TranscriptTurn? = nil
    ) -> Conversation? {
        guard var conversation = current, conversation.state.id == conversationID else { return nil }
        conversation.turn += 1
        if let transcript { conversation.turns.append(transcript) }
        conversation.previous = Array((conversation.previous
            + [ContextPacket.Conversation.recapEntry(question: question, answer: answer)]).suffix(ContextPacket.Conversation.maxPrevious))
        conversation.lastUsed = clock()
        current = conversation
        return conversation
    }
}
