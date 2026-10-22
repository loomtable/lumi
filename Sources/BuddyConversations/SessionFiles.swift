import Foundation

/// What Forget removed from Claude Code's own files.
public struct SessionDeletion: Sendable, Equatable {
    public var deleted: [String] = []
    /// Expected but absent (already gone): fine.
    public var missing: [String] = []
    /// Left alone: an unexpected layout or an ID that isn't a plain session ID.
    public var skipped: [String] = []

    public init(deleted: [String] = [], missing: [String] = [], skipped: [String] = []) {
        self.deleted = deleted
        self.missing = missing
        self.skipped = skipped
    }
}

/// Deletes Claude Code's files for given session IDs. Real: `ClaudeSessionFiles`. Fake:
/// `FakeSessionFiles`.
public protocol SessionFileStore: Sendable {
    func deleteSessions(_ ids: [String]) -> SessionDeletion
}

/// Claude Code 2.1.x keeps, per session ID (checked on the dev Mac; all
/// internal and undocumented):
/// - `projects/<encoded cwd>/<id>.jsonl` (transcript) and `projects/<encoded cwd>/<id>/`
/// - `session-env/<id>/`
/// - `file-history/<id>/`
/// Each is found by ID, never by rebuilding `<encoded cwd>` (long paths are hashed).
public struct ClaudeSessionFiles: SessionFileStore {
    public let root: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")) {
        self.root = root
    }

    /// Session IDs are UUIDs; anything else (slashes, "..", wildcards) is refused outright.
    static func isPlainID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    public func deleteSessions(_ ids: [String]) -> SessionDeletion {
        var result = SessionDeletion()
        let fm = FileManager.default
        let projects = root.appending(path: "projects", directoryHint: .isDirectory)
        let projectDirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []
        for id in ids {
            guard Self.isPlainID(id) else {
                result.skipped.append(id)
                continue
            }
            var candidates: [(URL, Bool)] = []  // (path, expected to be a directory)
            for dir in projectDirs {
                candidates.append((dir.appending(path: id + ".jsonl"), false))
                candidates.append((dir.appending(path: id, directoryHint: .isDirectory), true))
            }
            candidates.append((root.appending(path: "session-env/\(id)", directoryHint: .isDirectory), true))
            candidates.append((root.appending(path: "file-history/\(id)", directoryHint: .isDirectory), true))

            var found = false
            for (url, wantDirectory) in candidates {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                found = true
                // Must still be under root after resolving links, and of the expected kind.
                let resolved = url.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(root.resolvingSymlinksInPath().path + "/"), isDir.boolValue == wantDirectory,
                      (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
                else {
                    result.skipped.append(url.path)
                    continue
                }
                if (try? fm.removeItem(at: url)) != nil {
                    result.deleted.append(url.path)
                } else {
                    result.skipped.append(url.path)
                }
            }
            if !found { result.missing.append(id) }
        }
        return result
    }
}
