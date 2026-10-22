import Foundation

/// Settings › Connections: which recommended servers Lumi added to the user's Claude Code, so only
/// those offer Remove (the user's own servers are never touched).
public nonisolated struct ConnectionsPreferences: SettingsSection {
    public static let storageKey = "settings.connections.v1"

    /// `MCPRecommendation.id`s, in the order they were added.
    public var addedByLumi: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case addedByLumi }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        addedByLumi = c.value(.addedByLumi, default: Self().addedByLumi)
    }
}
