import Foundation

/// The v2 features. All ship on (owner, Oct 28: the Back/Resume chips are gone, so sessions and
/// the switcher are how conversations continue). Each still reads the `v2.<name>` Bool in
/// UserDefaults as a kill switch: set to false, that feature is off; unset or true, it's on.
/// Read at launch; nothing toggles them at runtime. Studio, the Lumi window, has no switch: it is
/// the app's only window (the v1 Conversations and Settings windows are gone).
public struct LumiFeatures: Sendable, Equatable {
    public var sessions = true
    public var switcher = true
    public var panel = true
    public var dictation = true
    public var permissionHost = true

    /// Everything on: what ships.
    public init() {}

    /// Everything off: the v1 engine (Glance only, ConversationRules), for parity tests and the
    /// full kill switch. The windows stay v2's.
    public static let allOff = LumiFeatures(sessions: false, switcher: false, panel: false, dictation: false,
                                            permissionHost: false)

    public init(sessions: Bool, switcher: Bool, panel: Bool, dictation: Bool, permissionHost: Bool) {
        self.sessions = sessions
        self.switcher = switcher
        self.panel = panel
        self.dictation = dictation
        self.permissionHost = permissionHost
    }

    /// Each flag is on unless its key is set to false.
    public init(defaults: UserDefaults) {
        func on(_ name: String) -> Bool { defaults.object(forKey: Self.key(name)) as? Bool ?? true }
        sessions = on("sessions")
        switcher = on("switcher")
        panel = on("panel")
        dictation = on("dictation")
        permissionHost = on("permissionHost")
    }

    /// From `UserDefaults.standard`.
    public static func current() -> LumiFeatures { LumiFeatures(defaults: .standard) }

    /// "v2.<name>", e.g. `defaults write <bundle id> v2.switcher -bool NO` to turn the switcher off.
    public static func key(_ name: String) -> String { "v2." + name }

    public static let names = ["sessions", "switcher", "panel", "dictation", "permissionHost"]
}
