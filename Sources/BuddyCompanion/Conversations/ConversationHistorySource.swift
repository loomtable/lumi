import BuddyConversations
import BuddyCore
import Foundation

/// What the Conversations window reads and changes. Real: `ManagerHistorySource` over
/// BuddyConversations' manager. Fake: `FakeHistorySource` in tests.
public nonisolated protocol ConversationHistorySource: Sendable {
    func list(limit: Int, offset: Int) async throws -> [ConversationRecord]
    func search(_ query: String) async throws -> [ConversationRecord]
    /// Makes this the current conversation: the next question continues it.
    func resume(_ id: String) async throws -> ConversationRecord?
    func prepareForget(_ id: String) async throws -> ForgetRequest?
    /// Nil when the conversation changed since `request` was shown: ask again.
    func forget(_ request: ForgetRequest) async throws -> ForgetReport?
    /// Whether conversations are being kept in memory only right now.
    func isTemporary() async -> Bool
    /// Turns temporary mode on or off (off forgets every temporary conversation). Idempotent.
    func setTemporary(_ on: Bool) async throws
    /// The conversation the next question continues, marked in the window. Nil: none or unknown.
    func currentID() async -> String?
    /// Removes conversations unused for `retentionDays` (idempotent with the shell's own prune on
    /// the same change), so the window can reload after it rather than guess when it's done.
    func prune(retentionDays: Int) async throws
    /// A conversation's shown turns, oldest first, for the window's detail. Empty: none, or unknown.
    func turns(_ id: String) async -> [TranscriptTurn]
}

public extension ConversationHistorySource {
    func currentID() async -> String? { nil }
    func prune(retentionDays: Int) async throws {}
    func turns(_ id: String) async -> [TranscriptTurn] { [] }
}

public nonisolated struct ManagerHistorySource: ConversationHistorySource {
    let manager: ConversationManager

    public init(manager: ConversationManager) { self.manager = manager }

    public func list(limit: Int, offset: Int) async throws -> [ConversationRecord] {
        try await manager.list(limit: limit, offset: offset)
    }

    public func search(_ query: String) async throws -> [ConversationRecord] { try await manager.search(query) }
    public func resume(_ id: String) async throws -> ConversationRecord? { try await manager.switchTo(id) }
    public func prepareForget(_ id: String) async throws -> ForgetRequest? { try await manager.prepareForget(id) }
    public func forget(_ request: ForgetRequest) async throws -> ForgetReport? { try await manager.forget(request) }
    public func isTemporary() async -> Bool { await manager.isTemporary }
    public func setTemporary(_ on: Bool) async throws { try await manager.setTemporary(on) }
    public func currentID() async -> String? { await manager.currentConversationID }
    public func prune(retentionDays: Int) async throws {
        _ = try await manager.prune(unusedSince: Date().addingTimeInterval(-TimeInterval(retentionDays) * 86_400))
    }
}
