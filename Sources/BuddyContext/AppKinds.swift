import BuddyCore

/// Maps a bundle ID to the packet's app kind. IDs were read from Info.plist on the
/// dev Mac or from Homebrew cask zap paths. Unknown apps are `.other`.
public enum AppKinds {
    public static func kind(of bundleID: String?) -> ContextPacket.AppKind {
        guard let id = bundleID else { return .other }
        if let kind = exact[id] { return kind }
        if id.hasPrefix("com.jetbrains.") { return .editor }
        return .other
    }

    static let exact: [String: ContextPacket.AppKind] = {
        var map: [String: ContextPacket.AppKind] = [:]
        for id in browsers { map[id] = .browser }
        for id in editors { map[id] = .editor }
        for id in terminals { map[id] = .terminal }
        for id in chats { map[id] = .chat }
        for id in documents { map[id] = .document }
        map["com.apple.finder"] = .finder
        return map
    }()

    static let browsers = [
        "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser",
        "com.microsoft.edgemac", "org.mozilla.firefox", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "com.kagi.kagimacOS", "app.zen-browser.zen",
    ]
    static let editors = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4", "com.sublimetext.3",
        "com.panic.Nova", "com.barebones.bbedit", "com.google.android.studio",
    ]
    static let terminals = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "org.alacritty", "co.zeit.hyper", "org.tabby",
    ]
    static let chats = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS",
        "com.microsoft.teams2", "com.microsoft.teams", "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram", "com.tdesktop.Telegram", "org.whispersystems.signal-desktop",
        "us.zoom.xos",
    ]
    static let documents = [
        "com.apple.Preview", "com.apple.Pages", "com.apple.Numbers", "com.apple.Keynote",
        "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint",
        "com.apple.TextEdit", "com.apple.Notes", "md.obsidian", "notion.id", "com.adobe.Reader",
    ]
}
