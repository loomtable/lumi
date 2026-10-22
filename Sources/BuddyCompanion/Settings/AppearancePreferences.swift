import Foundation

/// Settings › Appearance. The fields here are
/// the defaults: Smart placement, every effect on.
public nonisolated struct AppearancePreferences: SettingsSection {
    public static let storageKey = "settings.appearance.v1"

    public nonisolated enum Placement: String, Codable, Sendable, CaseIterable {
        case smart, nextToIt, centre
    }

    public nonisolated enum StatusPosition: String, Codable, Sendable, CaseIterable {
        case top, bottom
    }

    public var placement: Placement = .smart
    /// Where the listening pill and status lines sit: top centre by default.
    public var statusPosition: StatusPosition = .top
    /// Glow follows its voice.
    public var speakingGlow: Bool = true
    /// Dot field while you talk (otherwise 6 level bars).
    public var dotField: Bool = true
    /// Text inks in.
    public var inkIn: Bool = true
    public var sounds: Bool = true
    /// Answer actions, both on by default. Off: the packet tells Claude Code,
    /// so the model writes none, and the engine ignores any that arrive anyway.
    /// "Rings on screen": mark things on screen that the answer refers to (one-shot rings).
    public var showRings: Bool = true
    /// "Insert & Replace": put drafts into the field you were typing in. Off: the main button is Copy.
    public var insertAndReplace: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case placement, speakingGlow, dotField, inkIn, sounds, statusPosition, showRings, insertAndReplace
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        placement = c.value(.placement, default: d.placement)
        speakingGlow = c.value(.speakingGlow, default: d.speakingGlow)
        dotField = c.value(.dotField, default: d.dotField)
        inkIn = c.value(.inkIn, default: d.inkIn)
        sounds = c.value(.sounds, default: d.sounds)
        statusPosition = c.value(.statusPosition, default: d.statusPosition)
        showRings = c.value(.showRings, default: d.showRings)
        insertAndReplace = c.value(.insertAndReplace, default: d.insertAndReplace)
    }
}
