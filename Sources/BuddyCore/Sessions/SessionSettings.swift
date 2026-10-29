/// Settings › Voice › "Use Lumi's voice layer for".
public enum VoiceLayerScope: String, Codable, Sendable, CaseIterable {
    /// The `<lumi-voice>` envelope on voice turns only (default).
    case voiceTurns
    /// The envelope on typed turns too.
    case everyTurn
}

/// Settings › Teammates: whether a session may start background subagents.
public enum TeammatesMode: String, Codable, Sendable, CaseIterable {
    /// On voice turns, propose the split in one spoken line and wait for yes (default).
    case askFirst
    case automatic
    case off
}

/// The v2 session preferences the engine reads, mapped from Settings by the app shell.
public struct SessionSettings: Sendable, Equatable {
    public var voiceLayer: VoiceLayerScope
    /// Speak answers to typed and voice-in-page turns.
    public var speakTypedAnswers: Bool
    /// One banner when the user is away and a session ran at least 30 s.
    public var notifyWhenAway: Bool
    public var teammates: TeammatesMode
    /// `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, 1–5.
    public var maxSubagents: Int

    public static let maxSubagentsRange = 1...5

    public init(
        voiceLayer: VoiceLayerScope = .voiceTurns, speakTypedAnswers: Bool = false,
        notifyWhenAway: Bool = true, teammates: TeammatesMode = .askFirst,
        maxSubagents: Int = 3
    ) {
        self.voiceLayer = voiceLayer
        self.speakTypedAnswers = speakTypedAnswers
        self.notifyWhenAway = notifyWhenAway
        self.teammates = teammates
        self.maxSubagents = min(max(maxSubagents, Self.maxSubagentsRange.lowerBound), Self.maxSubagentsRange.upperBound)
    }
}
