import Foundation

/// Settings › Privacy.
public nonisolated struct PrivacyPreferences: SettingsSection {
    public static let storageKey = "settings.privacy.v1"

    /// Bundle IDs the user blocked, on top of the built-in password managers.
    public var blockedBundleIDs: [String] = []
    /// How long summon screenshots are kept. 24 h at most.
    public var screenshotRetentionHours: Int = 24
    /// Timings and event types only, never transcripts or screenshots. Off by default.
    public var traceLogEnabled: Bool = false

    public static let retentionChoices = [1, 6, 24]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case blockedBundleIDs, screenshotRetentionHours, traceLogEnabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        blockedBundleIDs = c.value(.blockedBundleIDs, default: d.blockedBundleIDs)
        let hours = c.value(.screenshotRetentionHours, default: d.screenshotRetentionHours)
        screenshotRetentionHours = Self.retentionChoices.contains(hours) ? hours : d.screenshotRetentionHours
        traceLogEnabled = c.value(.traceLogEnabled, default: d.traceLogEnabled)
    }
}
