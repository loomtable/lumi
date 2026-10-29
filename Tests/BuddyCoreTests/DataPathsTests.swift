import Foundation
import Testing
@testable import BuddyCore

/// A Lumi copy with another bundle ID (QA) never shares the release app's data.
struct DataPathsTests {
    static let base = (support: URL(filePath: "/Users/me/Library/Application Support", directoryHint: .isDirectory),
                       caches: URL(filePath: "/Users/me/Library/Caches", directoryHint: .isDirectory),
                       library: URL(filePath: "/Users/me/Library", directoryHint: .isDirectory))

    private func paths(_ id: String) -> DataPaths {
        DataPaths(bundleIdentifier: id, applicationSupport: Self.base.support, caches: Self.base.caches, library: Self.base.library)
    }

    /// Every stored location, by name.
    private func all(_ p: DataPaths) -> [String: String] {
        ["app": p.appFolder.path, "conversations": p.conversations.path, "models": p.models.path, "reports": p.reports.path,
         "plugin": p.plugin.path, "sessionProcesses": p.sessionProcesses.path, "screenshots": p.screenshots.path,
         "logs": p.logs.path, "connections": p.connections.path, "keychain": p.keychainService("elevenlabs")]
    }

    @Test func theReleaseIDKeepsExactlyTodaysPaths() {
        #expect(all(paths("com.loomtable.lumi")) == [
            "app": "/Users/me/Library/Application Support/com.loomtable.lumi",
            "conversations": "/Users/me/Library/Application Support/com.loomtable.lumi/conversations.sqlite",
            "models": "/Users/me/Library/Application Support/com.loomtable.lumi/models",
            "reports": "/Users/me/Library/Application Support/com.loomtable.lumi/reports",
            "plugin": "/Users/me/Library/Application Support/com.loomtable.lumi/plugin",
            "sessionProcesses": "/Users/me/Library/Application Support/com.loomtable.lumi/session-processes.json",
            "screenshots": "/Users/me/Library/Caches/com.loomtable.lumi/shots",
            "logs": "/Users/me/Library/Logs/com.loomtable.lumi",
            "connections": "/Users/me/Library/Application Support/Loomtable/Lumi/connections",
            "keychain": "com.loomtable.lumi.elevenlabs",
        ])
    }

    @Test func aQACopyDiffersInEveryPathButTheSharedVoiceModels() {
        let release = all(paths("com.loomtable.lumi")), qa = all(paths("com.loomtable.lumi.qa"))
        // The models are shared by decision (several GB, read-only): the copy reuses the release ones.
        #expect(qa["models"] == release["models"])
        for (name, path) in qa where name != "models" {
            #expect(path != release[name], "\(name) is shared")
            #expect(path.contains("com.loomtable.lumi.qa"), "\(name): \(path)")
        }
        #expect(qa["connections"] == "/Users/me/Library/Application Support/Loomtable/com.loomtable.lumi.qa/connections")
        // No QA path sits inside a release folder.
        for (name, path) in qa where name != "models" && path.hasPrefix("/") {
            #expect(!path.hasPrefix(release["app"]! + "/") && !path.hasPrefix("/Users/me/Library/Caches/com.loomtable.lumi/")
                    && !path.hasPrefix(release["logs"]! + "/"), "\(name)")
        }
    }

    @Test(arguments: [
        (nil as String?, "com.loomtable.lumi"),
        ("com.loomtable.lumi", "com.loomtable.lumi"),
        ("com.loomtable.lumi.qa", "com.loomtable.lumi.qa"),
        ("com.apple.dt.xctest.tool", "com.loomtable.lumi"),
        ("swift-run-binary", "com.loomtable.lumi"),
    ])
    func theRunningIDIsUsedOnlyWhenItsALumiOne(id: String?, expected: String) {
        #expect(BuddyCore.resolveBundleIdentifier(id) == expected)
    }

    @Test func testsAndSwiftRunUseTheReleasePaths() {
        #expect(BuddyCore.bundleIdentifier == BuddyCore.releaseBundleIdentifier)
        #expect(BuddyCore.folderName == "com.loomtable.lumi")
        #expect(BuddyCore.paths.conversations == URL.applicationSupportDirectory.appending(path: "com.loomtable.lumi/conversations.sqlite"))
    }
}
