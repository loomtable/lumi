import Foundation

/// Settings › General › "Show in Dock": on by default. Off, Lumi lives in the menu bar only (as
/// before 0.2). It applies at once, with no relaunch.
public nonisolated struct DockPreferences: SettingsSection {
    public static let storageKey = "settings.dock.v1"

    public var showInDock: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case showInDock
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showInDock = c.value(.showInDock, default: Self().showInDock)
    }
}
