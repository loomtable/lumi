import Foundation

/// Shared value types and contracts used by every Lumi module.
///
/// Rules for this module: no UI, no system side effects, no dependencies. Every target
/// depends on it, so change it with care.
public enum BuddyCore {
    public static let appName = "Lumi"
    /// The release app's bundle ID. Its data paths never move.
    public static let releaseBundleIdentifier = "com.loomtable.lumi"
    /// The running app's bundle ID when it's a Lumi one (`com.loomtable.lumi…`, e.g. a QA copy as
    /// `com.loomtable.lumi.qa`), else the release ID (tests, `swift run`). Everything Lumi stores
    /// is keyed on it, so a copy with another ID never touches the release app's data.
    public static let bundleIdentifier = resolveBundleIdentifier(Bundle.main.bundleIdentifier)
    /// The app's own folder under Application Support, Caches and Logs: the bundle ID.
    public static let folderName = bundleIdentifier
    /// Where this app keeps its data.
    public static let paths = DataPaths(bundleIdentifier: bundleIdentifier)

    public static func resolveBundleIdentifier(_ id: String?) -> String {
        guard let id, id.hasPrefix(releaseBundleIdentifier) else { return releaseBundleIdentifier }
        return id
    }
}

/// Every place Lumi keeps data, for one bundle ID. The release ID gives exactly the v1 paths.
public struct DataPaths: Sendable, Equatable {
    public let bundleIdentifier: String
    public let applicationSupport: URL
    public let caches: URL
    public let library: URL

    public init(bundleIdentifier: String, applicationSupport: URL = URL.applicationSupportDirectory,
                caches: URL = URL.cachesDirectory, library: URL = URL.libraryDirectory) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationSupport = applicationSupport
        self.caches = caches
        self.library = library
    }

    public var folderName: String { bundleIdentifier }
    public var isRelease: Bool { bundleIdentifier == BuddyCore.releaseBundleIdentifier }

    /// `~/Library/Application Support/<id>`.
    public var appFolder: URL { applicationSupport.appending(path: folderName, directoryHint: .isDirectory) }
    public var conversations: URL { applicationSupport.appending(path: "\(folderName)/conversations.sqlite") }
    /// The voice models (several GB, read-only once there) stay the release app's for every ID, so
    /// a QA copy doesn't download them again (lead, Oct 28). A copy only ever adds files there,
    /// never deletes (`VoiceController.removeModels` refuses, adoption never replaces).
    public var models: URL {
        applicationSupport.appending(path: "\(BuddyCore.releaseBundleIdentifier)/models", directoryHint: .isDirectory)
    }
    /// Dictation history: each dictation's words, kept on this Mac (Settings › Privacy applies).
    public var dictationHistory: URL { applicationSupport.appending(path: "\(folderName)/dictation-history.json") }
    public var reports: URL { applicationSupport.appending(path: "\(folderName)/reports", directoryHint: .isDirectory) }
    public var plugin: URL { applicationSupport.appending(path: "\(folderName)/plugin", directoryHint: .isDirectory) }
    /// Live session processes, for the orphan sweep: a copy sweeps only its own.
    public var sessionProcesses: URL { applicationSupport.appending(path: "\(folderName)/session-processes.json") }
    public var screenshots: URL { caches.appending(path: "\(folderName)/shots", directoryHint: .isDirectory) }
    /// Pictures pasted into a composer, kept a week so a sent turn's files stay readable.
    public var pastedImages: URL { caches.appending(path: "\(folderName)/pasted", directoryHint: .isDirectory) }
    public var logs: URL { library.appending(path: "Logs/\(folderName)", directoryHint: .isDirectory) }
    /// MCP tokens. The release app's folder never moves (the user's Claude Code config points at
    /// files there); another ID gets its own.
    public var connections: URL {
        applicationSupport.appending(path: isRelease ? "Loomtable/Lumi/connections" : "Loomtable/\(bundleIdentifier)/connections",
                                     directoryHint: .isDirectory)
    }
    /// A Keychain service name: `<id>.<name>`.
    public func keychainService(_ name: String) -> String { "\(bundleIdentifier).\(name)" }
    /// "~/Library/Logs/<id>", as Settings shows it.
    public var logsDisplayPath: String { "~/Library/Logs/\(folderName)" }
}
