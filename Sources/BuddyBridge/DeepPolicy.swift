import Foundation

/// Where and when Deep runs. Each default is one field
/// so a change of mind is a one-line edit.
public struct DeepPolicy: Sendable, Equatable {
    public enum Trust: Sendable, Equatable {
        /// Only a folder with `hasTrustDialogAccepted` itself.
        case exactFolder
        /// The folder or any ancestor (what interactive Claude Code honours).
        case folderOrAncestor
    }

    public enum Spawn: Sendable, Equatable {
        /// Start Deep when Quick hands off. Pays the ~0.85 s cold start (S4).
        case onHandoff
        /// Start Deep for the resolved folder at summon. Runs the folder's hooks and MCP
        /// servers on every summon, so it's off.
        case onSummon
    }

    public var trust: Trust
    public var spawn: Spawn

    public init(trust: Trust = .folderOrAncestor, spawn: Spawn = .onHandoff) {
        self.trust = trust
        self.spawn = spawn
    }

    public static let `default` = DeepPolicy()
}

/// Decides whether a folder may host a Deep process.
///
/// `-p` skips the trust dialog yet runs the folder's hooks and `.mcp.json` servers (S4), so
/// Deep only starts where the user already accepted the trust dialog in interactive Claude
/// Code: `~/.claude.json` → `projects[path].hasTrustDialogAccepted`. Folders listed under
/// `~/.claude/projects/` are not evidence, because any `-p` run creates that entry. The file is
/// an undocumented internal format: anything unreadable means untrusted.
public struct FolderTrust: Sendable {
    public var trustedPaths: Set<String>

    public init(trustedPaths: Set<String>) {
        self.trustedPaths = trustedPaths
    }

    /// Parses `~/.claude.json`. Returns an empty set (trust nothing) on any failure.
    public init(claudeJSON data: Data?) {
        guard let data,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else {
            self.init(trustedPaths: [])
            return
        }
        let trusted = projects.compactMap { path, value -> String? in
            Self.isJSONTrue((value as? [String: Any])?["hasTrustDialogAccepted"]) ? Self.normalize(path) : nil
        }
        self.init(trustedPaths: Set(trusted))
    }

    /// Only a JSON `true`. `as? Bool` also accepts the number 1, which would fail open.
    static func isJSONTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
    }

    public static func load(home: URL) -> FolderTrust {
        FolderTrust(claudeJSON: try? Data(contentsOf: home.appendingPathComponent(".claude.json")))
    }

    public func isTrusted(_ folder: URL, rule: DeepPolicy.Trust) -> Bool {
        var path = Self.normalize(folder.path)
        if trustedPaths.contains(path) { return true }
        guard rule == .folderOrAncestor else { return false }
        while path != "/" && !path.isEmpty {
            path = (path as NSString).deletingLastPathComponent
            if trustedPaths.contains(path) { return true }
        }
        return false
    }

    /// Chooses the Deep working directory: the resolved project folder when trusted,
    /// otherwise home. The only way to make a `DeepFolder`.
    public func deepDirectory(for project: URL?, home: URL, rule: DeepPolicy.Trust) -> DeepFolder {
        guard let project, isTrusted(project, rule: rule) else { return DeepFolder(url: home) }
        return DeepFolder(url: project)
    }

    static func normalize(_ path: String) -> String {
        let standard = (path as NSString).standardizingPath
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}

/// A folder Deep may run in: either trusted per `FolderTrust` or the home folder. `DeepLane` only
/// takes this type, so an unchecked folder can't reach it.
public struct DeepFolder: Sendable, Hashable {
    public let url: URL

    init(url: URL) {
        self.url = url
    }
}
