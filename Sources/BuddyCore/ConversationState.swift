import Foundation

/// What the bridge keeps per conversation between questions. The app persists it in the
/// conversation index (quickSessionId, deepSessionId, project folder).
public struct ConversationState: Sendable, Equatable, Codable {
    public var id: String
    public var quickSessionID: String?
    public var deepSessionID: String?
    /// The lane that answered last: follow-ups go there.
    public var lastLane: Mode?
    /// The folder Deep last ran in, reused for follow-ups.
    public var deepFolder: URL?
    /// Quick's last answer, handed to Deep by "Go deeper".
    public var lastQuickAnswer: String?
    /// When Deep last answered. A follow-up within a couple of minutes stays on Deep; later ones go
    /// back to Quick unless they're about the same project. In memory only.
    public var lastDeepAnswerAt: Date?
    /// For each Claude Code session, the recap entries it already holds (its own answers, or a
    /// recap it was sent), so a recap carries only the turns that session hasn't seen. In memory
    /// only: a session with no entry gets the whole recap.
    public var seenRecaps: [String: [String]] = [:]
    /// For each Claude Code session, the screen it was last shown. In memory only: a session with
    /// no entry gets the whole packet and the screenshot.
    public var seenScreens: [String: SeenScreen] = [:]

    public init(id: String) {
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case id, quickSessionID, deepSessionID, lastLane, deepFolder, lastQuickAnswer
    }
}

/// What a session was last shown: its screenshot (by the engine's screen token, and the turn it
/// came with) and the packet's slower-changing fields as they were encoded then.
public struct SeenScreen: Sendable, Equatable {
    public var token: String?
    public var turn: Int
    public var fields: [String: Data]

    public init(token: String?, turn: Int, fields: [String: Data]) {
        self.token = token
        self.turn = turn
        self.fields = fields
    }
}
