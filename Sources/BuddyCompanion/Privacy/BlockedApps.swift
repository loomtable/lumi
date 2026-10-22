import AppKit
import BuddyContext
import BuddyCore
import Foundation
import UniformTypeIdentifiers

/// One row of Settings › Privacy › Blocked apps.
public nonisolated struct BlockedApp: Sendable, Equatable, Identifiable {
    public var bundleID: String
    public var name: String
    /// Built-in password managers can't be removed.
    public var builtIn: Bool

    public var id: String { bundleID }
}

public enum BlockedApps {
    /// Built-in entries first (only those installed, plus Apple's), then the user's, by name.
    @MainActor
    public static func rows(user: [String], installedName: @MainActor (String) -> String? = { BlockedApps.installedName($0) }) -> [BlockedApp] {
        let builtIn = Blocklist.defaultBundleIDs.compactMap { id -> BlockedApp? in
            guard let name = installedName(id) else { return nil }
            return BlockedApp(bundleID: id, name: name, builtIn: true)
        }
        let mine = user.filter { !Blocklist.defaultBundleIDs.contains($0) }
            .map { BlockedApp(bundleID: $0, name: installedName($0) ?? $0, builtIn: false) }
        return builtIn.sorted { $0.name < $1.name } + mine.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Adds `bundleID` to the user's list unless it is already blocked or is Lumi itself.
    /// Returns the new list.
    public static func adding(_ bundleID: String, to user: [String]) -> [String] {
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id != BuddyCore.bundleIdentifier, !user.contains(id),
              !Blocklist().isBlocked(bundleID: id) else { return user }
        return user + [id]
    }

    public static func removing(_ bundleID: String, from user: [String]) -> [String] {
        user.filter { $0 != bundleID }
    }

    /// The app's display name if it is installed (looked up once per Privacy pane refresh).
    @MainActor
    public static func installedName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let bundle = Bundle(url: url)
        return bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? FileManager.default.displayName(atPath: url.path)
    }

    /// Asks the user for an app and returns its bundle ID.
    @MainActor
    public static func chooseApp() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Block"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}
