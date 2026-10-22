import Foundation

/// A hosted repository named by a browser URL or a git remote: GitHub or GitLab, compared
/// case-insensitively. GitLab repos can sit in nested groups, so `path` is everything after the
/// host, for example "group/sub/repo".
public struct HostedRepo: Sendable, Equatable {
    public enum Host: String, Sendable { case github, gitlab }

    public var host: Host
    public var path: String

    public init(host: Host, path: String) {
        self.host = host
        self.path = path.lowercased()
    }

    /// A page in the browser: github.com/owner/repo[/…] or gitlab.com/group/…/repo[/-/…].
    public init?(browserURL: String) {
        guard let url = URL(string: browserURL), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host.flatMap(Self.host(named:)) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        let repo: [String]
        switch host {
        case .github:
            repo = Array(parts.prefix(2))
        case .gitlab:
            repo = Array(parts.prefix { $0 != "-" })
        }
        guard repo.count >= 2, !Self.reserved.contains(repo[0].lowercased()) else { return nil }
        self.init(host: host, path: Self.trimGit(repo.joined(separator: "/")))
    }

    /// A git remote: `git@github.com:owner/repo.git`, `ssh://git@github.com/owner/repo`,
    /// `https://github.com/owner/repo.git`. An SSH host alias such as `github.com-work` counts as
    /// its host, as set up for several accounts in ~/.ssh/config.
    public init?(remote: String) {
        let remote = remote.trimmingCharacters(in: .whitespaces)
        var hostPart: Substring
        var path: Substring
        if let range = remote.range(of: "://") {
            let rest = remote[range.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            hostPart = rest[..<slash]
            path = rest[rest.index(after: slash)...]
        } else if let colon = remote.firstIndex(of: ":") {
            hostPart = remote[..<colon]
            path = remote[remote.index(after: colon)...]
        } else {
            return nil
        }
        if let at = hostPart.lastIndex(of: "@") { hostPart = hostPart[hostPart.index(after: at)...] }
        if let port = hostPart.firstIndex(of: ":") { hostPart = hostPart[..<port] }
        guard let host = Self.host(named: String(hostPart)) else { return nil }
        let trimmed = Self.trimGit(path.split(separator: "/").joined(separator: "/"))
        guard trimmed.split(separator: "/").count >= 2 else { return nil }
        self.init(host: host, path: trimmed)
    }

    static func host(named name: String) -> Host? {
        let name = name.lowercased()
        for (domain, host) in [("github.com", Host.github), ("gitlab.com", .gitlab)]
        where name == domain || name == "www." + domain || name.hasPrefix(domain + "-") {
            return host
        }
        return nil
    }

    static func trimGit(_ path: String) -> String {
        path.hasSuffix(".git") ? String(path.dropLast(4)) : path
    }

    /// First path parts that are site pages, not owners.
    static let reserved: Set<String> = ["settings", "notifications", "explore", "marketplace", "orgs", "users",
                                        "topics", "search", "login", "dashboard", "pulls", "issues", "sponsors"]
}

/// Finds local clones of a hosted repo among trusted folders and their direct children, by
/// reading each `.git` config (no `git` process). Only folders the user trusted are searched,
/// so the cost stays small and nothing private elsewhere is read.
public enum RepoClones {
    public static func find(_ repo: HostedRepo, in trust: FolderTrust) -> [String] {
        var seen = Set<String>()
        var found: [(dir: String, worktree: Bool)] = []
        for root in trust.trustedPaths.sorted() {
            for dir in [root] + children(of: root) where seen.insert(dir).inserted {
                let (remotes, worktree) = remotes(of: dir)
                if remotes.contains(repo) { found.append((dir, worktree)) }
            }
        }
        // A trusted folder itself first, then a main clone over a worktree, then the shortest path.
        func key(_ f: (dir: String, worktree: Bool)) -> (Int, Int, Int, String) {
            (trust.trustedPaths.contains(f.dir) ? 0 : 1, f.worktree ? 1 : 0, f.dir.count, f.dir)
        }
        return found.sorted { key($0) < key($1) }.map(\.dir)
    }

    static func children(of dir: String) -> [String] {
        let url = URL(fileURLWithPath: dir)
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { FolderTrust.normalize($0.path) }.sorted()
    }

    /// The remotes in a folder's git config. A worktree's or submodule's `.git` file points at
    /// its git dir; a worktree's config lives in the shared (common) dir.
    static func remotes(of dir: String) -> (remotes: [HostedRepo], worktree: Bool) {
        let dotGit = (dir as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return ([], false) }
        var gitDir = dotGit
        if !isDir.boolValue {
            guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return ([], true) }
            gitDir = absolute(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), from: dir)
            if let common = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"), encoding: .utf8) {
                gitDir = absolute(common.trimmingCharacters(in: .whitespacesAndNewlines), from: gitDir)
            }
        }
        guard let config = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("config"), encoding: .utf8)
        else { return ([], !isDir.boolValue) }
        return (remoteURLs(inConfig: config).compactMap(HostedRepo.init(remote:)), !isDir.boolValue)
    }

    /// `url = …` lines inside `[remote "…"]` sections.
    static func remoteURLs(inConfig config: String) -> [String] {
        var inRemote = false
        var urls: [String] = []
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inRemote = line.hasPrefix("[remote "); continue }
            guard inRemote, let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "url" else { continue }
            urls.append(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        }
        return urls
    }

    static func absolute(_ path: String, from base: String) -> String {
        FolderTrust.normalize(path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path))
    }
}
