import BuddyCore
import Foundation

/// Settings › Models. Defaults come from
/// BuddyCore (`ModeConfig.default(for:)`, `Routing.auto`), never copied by hand.
public nonisolated struct ModelPreferences: SettingsSection {
    public static let storageKey = "settings.models.v1"

    public var routing: Routing = .auto
    public var quick: ModeConfig = .default(for: .quick)
    public var deep: ModeConfig = .default(for: .deep)
    public var research: ModeConfig = .default(for: .research)

    public init() {}

    /// "default" or "custom" in the pane.
    public func isDefault(_ mode: Mode) -> Bool {
        config(mode) == .default(for: mode)
    }

    public func config(_ mode: Mode) -> ModeConfig {
        switch mode {
        case .quick: quick
        case .deep: deep
        case .research: research
        }
    }

    public mutating func set(_ config: ModeConfig, for mode: Mode) {
        let clean = Self.cleaned(config, for: mode)
        switch mode {
        case .quick: quick = clean
        case .deep: deep = clean
        case .research: research = clean
        }
    }

    /// Settings › Models › Restore defaults: every mode and routing back to BuddyCore's defaults.
    public mutating func restoreDefaults() {
        self = Self()
    }

    /// A stored or typed config made safe to launch with: the model ID trimmed (an empty one
    /// falls back to the mode's default model) and the effort limited to the levels the mode
    /// offers (Settings › Models), else the mode's default effort.
    static func cleaned(_ config: ModeConfig, for mode: Mode) -> ModeConfig {
        let fallback = ModeConfig.default(for: mode)
        let id = config.model.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return ModeConfig(model: id.isEmpty ? fallback.model : ModelID(rawValue: id),
                          effort: mode.allowedEfforts.contains(config.effort) ? config.effort : fallback.effort)
    }

    enum CodingKeys: String, CodingKey {
        case routing, quick, deep, research
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        routing = c.value(.routing, default: d.routing)
        quick = Self.cleaned(c.value(.quick, default: d.quick), for: .quick)
        deep = Self.cleaned(c.value(.deep, default: d.deep), for: .deep)
        research = Self.cleaned(c.value(.research, default: d.research), for: .research)
    }
}
