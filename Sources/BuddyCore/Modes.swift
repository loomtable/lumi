/// The three lanes a question can run in.
public enum Mode: String, Codable, Sendable, CaseIterable {
    case quick
    case deep
    case research

    public var displayName: String {
        switch self {
        case .quick: "Quick"
        case .deep: "Deep"
        case .research: "Research"
        }
    }

    /// Efforts offered in Settings › Models for this mode.
    public var allowedEfforts: [Effort] {
        switch self {
        case .quick: [.low, .medium, .high]
        case .deep: [.medium, .high, .max]
        case .research: [.high, .max]
        }
    }
}

/// Passed to `claude --effort`. Mirrors the CLI's accepted values; Settings menus offer
/// the subset in `Mode.allowedEfforts`.
public enum Effort: String, Codable, Sendable, CaseIterable {
    case low, medium, high, xhigh, max
}

/// A Claude model ID. Any ID the user's Claude Code accepts is valid, so this is open.
public struct ModelID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let haiku: ModelID = "claude-haiku-5-5"
    public static let sonnet: ModelID = "claude-sonnet-5-5"
    public static let opus: ModelID = "claude-opus-5-5"
    public static let fable: ModelID = "claude-fable-5-1"

    /// The models listed in the Settings menu. Anything else shows its raw ID.
    public static let known: [ModelID] = [.haiku, .sonnet, .opus, .fable]

    public var displayName: String {
        switch self {
        case .haiku: "Haiku 5.5"
        case .sonnet: "Sonnet 5.5"
        case .opus: "Opus 5.5"
        case .fable: "Fable 5.1"
        default: rawValue
        }
    }
}

/// Model and effort for one mode.
public struct ModeConfig: Codable, Sendable, Equatable {
    public var model: ModelID
    public var effort: Effort

    public init(model: ModelID, effort: Effort) {
        self.model = model
        self.effort = effort
    }

    /// Defaults per mode (Deep = Opus 5.5).
    public static func `default`(for mode: Mode) -> ModeConfig {
        switch mode {
        case .quick: ModeConfig(model: .haiku, effort: .low)
        case .deep: ModeConfig(model: .opus, effort: .high)
        case .research: ModeConfig(model: .opus, effort: .max)
        }
    }

    public func isDefault(for mode: Mode) -> Bool { self == .default(for: mode) }
}

/// Settings › Models › Routing.
public enum Routing: String, Codable, Sendable, CaseIterable {
    case auto
    case alwaysQuick
    case alwaysDeep
}

/// Conversation dot colours, assigned in rotation. Rose is reserved for errors.
public enum ConversationColor: String, Codable, Sendable, CaseIterable {
    case ember, mist, sage, amber

    public static func forIndex(_ index: Int) -> ConversationColor {
        allCases[((index % allCases.count) + allCases.count) % allCases.count]
    }
}
