/// Apps the buddy never looks at (Trust). Checked before every capture:
/// a blocked front app means no packet and no screenshot, and blocked apps are left out of
/// the cursor element, recent apps and screenshots.
public struct Blocklist: Sendable, Equatable, Codable {
    /// Bundle IDs added by the user in Settings › Privacy.
    public var userBundleIDs: Set<String>

    public init(userBundleIDs: Set<String> = []) {
        self.userBundleIDs = userBundleIDs
    }

    /// Password managers. Each also blocks its sub-IDs (`com.apple.Passwords.MenuBarExtra`, helper
    /// and quick-access processes). IDs were read from Info.plist on the dev Mac or from the Homebrew
    /// cask's zap paths. There are no widely used native macOS banking apps; banking is in the
    /// browser and is blocked by URL in the browser sensor (M2).
    public static let defaultBundleIDs: Set<String> = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "org.keepassx.keepassxc",
        "com.lastpass.LastPass",
        "in.sinew.Enpass-Desktop",
        "me.proton.pass.electron",
    ]

    /// Matched as prefixes, for vendors that ship several bundle IDs (1Password 7 variants).
    public static let defaultPrefixes: [String] = ["com.agilebits.onepassword"]

    public func isBlocked(bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        if userBundleIDs.contains(id) || Self.defaultBundleIDs.contains(id) { return true }
        if Self.defaultPrefixes.contains(where: { id.hasPrefix($0) }) { return true }
        // Walk up the dot-separated parents: a.b.c.d is blocked if a.b.c is.
        var parent = Substring(id)
        while let dot = parent.lastIndex(of: ".") {
            parent = parent[..<dot]
            if Self.defaultBundleIDs.contains(String(parent)) || userBundleIDs.contains(String(parent)) { return true }
        }
        return false
    }
}
