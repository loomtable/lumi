import BuddyKeys
import Foundation

/// Settings › Keys.
public nonisolated struct KeysPreferences: SettingsSection {
    public static let storageKey = "settings.keys.v1"

    /// `BuddyKey.rawValue`; right ⌥ by default (Open 3).
    public var buddyKey: String = BuddyKey.rightOption.rawValue
    /// Down for more than this is a hold.
    public var holdThresholdMs: Int = 300
    /// A second press within this of the first release is a double-tap.
    public var doubleTapWindowMs: Int = 300
    /// Ignore the buddy key while another app holds Secure Event Input (undecided; S1).
    public var ignoreDuringSecureInput: Bool = false

    /// Allowed range for both timings in the Keys pane.
    public static let timingRange = 150...600

    public init() {}

    public var key: BuddyKey {
        get { BuddyKey(rawValue: buddyKey) ?? .rightOption }
        set { buddyKey = newValue.rawValue }
    }

    enum CodingKeys: String, CodingKey {
        case buddyKey, holdThresholdMs, doubleTapWindowMs, ignoreDuringSecureInput
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        buddyKey = c.value(.buddyKey, default: d.buddyKey)
        holdThresholdMs = Self.clamped(c.value(.holdThresholdMs, default: d.holdThresholdMs))
        doubleTapWindowMs = Self.clamped(c.value(.doubleTapWindowMs, default: d.doubleTapWindowMs))
        ignoreDuringSecureInput = c.value(.ignoreDuringSecureInput, default: d.ignoreDuringSecureInput)
    }

    static func clamped(_ ms: Int) -> Int {
        min(max(ms, timingRange.lowerBound), timingRange.upperBound)
    }
}
