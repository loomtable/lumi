import Foundation

/// How much a permission ask needs from the user.
public enum ApprovalTier: Sendable, Equatable {
    /// Reversible: a spoken "yes" is enough.
    case reversible
    /// Sends, deletes and anything leaving the Mac need a click (lead).
    case needsClick
}

extension ApprovalTier {
    /// Tools that only read.
    static let readOnlyTools: Set<String> = ["Read", "Glob", "Grep"]
    /// Tools that change a file in place; reversible only inside the session's directories.
    static let fileEditTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    /// Input fields that name the file a tool touches.
    static let pathKeys = ["file_path", "notebook_path", "path"]

    /// Conservative: Read, Glob and Grep anywhere are reversible, and so is a file edit inside one
    /// of the session's project folders. A project folder is never home, the filesystem root or an
    /// ancestor of home: a session with no trusted project runs in home, and that must not make
    /// every file under ~ approvable by voice (gatekeeper P0). Sensitive paths need a click even
    /// inside a project: any dot component (dotfiles, .ssh, .config, .git), anything in ~/Library,
    /// and keychains. Paths are resolved first (`..`, and symlinks where they exist). Everything
    /// else needs a click: Bash, web tools, every MCP tool, edits outside a project, edits with no
    /// absolute path, and any tool Lumi doesn't know.
    public static func classify(tool: String, input: [String: String], sessionDirs: [URL],
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ApprovalTier {
        if readOnlyTools.contains(tool) { return .reversible }
        guard fileEditTools.contains(tool) else { return .needsClick }
        guard let raw = pathKeys.lazy.compactMap({ input[$0] }).first, let file = absoluteURL(raw).map(resolved) else { return .needsClick }
        let home = resolved(home)
        guard !isSensitive(file, home: home) else { return .needsClick }
        let projects = sessionDirs.map(resolved).filter { isProject($0, home: home) }
        return projects.contains { dir in contains(dir, file) && !hasDotComponent(file, below: dir) } ? .reversible : .needsClick
    }

    private static func absoluteURL(_ raw: String) -> URL? {
        let path = (raw as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        return URL(filePath: path)
    }

    /// `..` and `.` removed, then symlinks resolved on the longest part that exists (a file being
    /// written doesn't exist yet; its folder may be a link).
    static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var out = existing.resolvingSymlinksInPath()
        for part in rest { out.appendPathComponent(part) }
        return out.standardizedFileURL
    }

    /// A folder that can be a project: not the root, home, or anything that contains home.
    static func isProject(_ dir: URL, home: URL) -> Bool {
        let d = dir.pathComponents
        guard d.count > 1 else { return false }
        return !(dir.path == home.path || contains(dir, home))
    }

    /// Dotfiles and dot folders, ~/Library, keychains: never by voice.
    static func isSensitive(_ file: URL, home: URL) -> Bool {
        let name = file.lastPathComponent.lowercased()
        if name.hasSuffix(".keychain") || name.hasSuffix(".keychain-db") || file.pathComponents.contains("Keychains") { return true }
        if contains(home.appending(path: "Library"), file) { return true }
        return hasDotComponent(file, below: contains(home, file) ? home : URL(filePath: "/"))
    }

    /// Any component under `base` that starts with a dot.
    static func hasDotComponent(_ file: URL, below base: URL) -> Bool {
        file.pathComponents.dropFirst(base.pathComponents.count).contains { $0.hasPrefix(".") }
    }

    /// Component-wise, after removing `.` and `..`, so "/a/bc" is not inside "/a/b" and
    /// "/a/b/../c" is not inside "/a/b".
    static func contains(_ dir: URL, _ file: URL) -> Bool {
        let d = dir.standardizedFileURL.pathComponents
        let f = file.standardizedFileURL.pathComponents
        return f.count > d.count && Array(f.prefix(d.count)) == d
    }
}
