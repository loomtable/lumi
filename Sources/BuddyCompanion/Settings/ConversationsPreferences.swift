import Foundation

/// Settings › Conversations: the index's behaviour.
public nonisolated struct ConversationsPreferences: SettingsSection {
    public static let storageKey = "settings.conversations.v1"

    /// After this long idle, the next question starts fresh (adjustable).
    public var idleTimeoutMinutes: Int = 30
    /// Conversations unused this long are removed from the index (default 90 days).
    public var retentionDays: Int = 90
    /// Save nothing: conversations live in memory and their files are deleted when it's turned off.
    public var temporaryMode: Bool = false

    public static let idleRange = 5...240
    public static let retentionRange = 1...365

    public init() {}

    enum CodingKeys: String, CodingKey {
        case idleTimeoutMinutes, retentionDays, temporaryMode
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        // Out of range: the default, not the nearest bound (a bad value is more likely corruption).
        let idle = c.value(.idleTimeoutMinutes, default: d.idleTimeoutMinutes)
        idleTimeoutMinutes = Self.idleRange.contains(idle) ? idle : d.idleTimeoutMinutes
        let days = c.value(.retentionDays, default: d.retentionDays)
        retentionDays = Self.retentionRange.contains(days) ? days : d.retentionDays
        temporaryMode = c.value(.temporaryMode, default: d.temporaryMode)
    }
}
