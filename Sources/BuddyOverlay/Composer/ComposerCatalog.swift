import Foundation

/// What the `/` menu lists: the Claude Code commands that work in a Lumi session, then the user's
/// skills and custom commands, read from where Claude Code reads them (61-COMPOSER §1): the user's
/// `~/.claude`, each session folder's `.claude`, and enabled plugins.
nonisolated public enum CommandCatalog {
    /// Built-ins documented to work in `-p` (headless docs). Terminal-only ones (`/login`, …) aren't.
    static let builtIns: [CompletionItem] = [
        ("compact", "Summarize the conversation so far to free up context"),
        ("model", "Switch the model for this session"),
        ("effort", "Set how hard Claude thinks"),
        ("mcp", "Show the connected MCP servers"),
    ].map { CompletionItem(kind: .command, title: $0.0, detail: $0.1, source: "Claude Code", insert: "/\($0.0) ") }

    /// Reads the skills and commands off the caller's actor. `claudeHome` is `~/.claude`.
    @concurrent
    public static func load(claudeHome: URL, folders: [URL]) async -> [CompletionItem] {
        var items = builtIns
        for folder in folders { items += read(folder.appending(path: ".claude"), source: "Project", prefix: "") }
        items += read(claudeHome, source: "Skill", prefix: "")
        for (name, root) in enabledPlugins(claudeHome) { items += read(root, source: name, prefix: name + ":") }
        var seen = Set<String>()
        return items.filter { seen.insert($0.title).inserted }
    }

    /// The live session's command names as menu rows: the built-ins first, then those the scan
    /// knows (with their descriptions), then the rest by name. A scanned skill the session doesn't
    /// list is left out: only what runs.
    public static func live(_ names: [String], known: [CompletionItem]) -> [CompletionItem] {
        let live = Set(names)
        let builtIn = Set(builtIns.map(\.title))
        let first = builtIns.filter { live.contains($0.title) }
        let scanned = known.filter { live.contains($0.title) && !builtIn.contains($0.title) }
        let covered = Set((first + scanned).map(\.title))
        let rest = live.subtracting(covered).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { CompletionItem(kind: .command, title: $0, source: "Claude Code", insert: "/\($0) ") }
        return first + scanned + rest
    }

    /// `skills/<name>/SKILL.md` (one level, plus `skills/synced/*/`) and `commands/**/*.md` under `root`.
    static func read(_ root: URL, source: String, prefix: String) -> [CompletionItem] {
        let fm = FileManager.default
        var out: [CompletionItem] = []
        var skillDirs = children(root.appending(path: "skills"))
        skillDirs += skillDirs.filter { $0.lastPathComponent == "synced" }.flatMap(children)
        for dir in skillDirs {
            let file = dir.appending(path: "SKILL.md")
            guard let meta = frontMatter(file), meta["user-invocable"] != "false" else { continue }
            let name = meta["name"] ?? dir.lastPathComponent
            out.append(item(prefix + name, meta["description"], source: source == "Skill" ? "Skill" : source))
        }
        let commands = root.appending(path: "commands")
        // Paths relative to `commands`: commands/frontend/component.md → /frontend:component.
        for rel in (try? fm.subpathsOfDirectory(atPath: commands.path)) ?? [] where rel.hasSuffix(".md") {
            guard !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            let meta = frontMatter(commands.appending(path: rel)) ?? [:]
            out.append(item(prefix + rel.dropLast(3).replacingOccurrences(of: "/", with: ":"), meta["description"],
                            source: source == "Skill" ? "Command" : source))
        }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func item(_ name: String, _ detail: String?, source: String) -> CompletionItem {
        CompletionItem(kind: .command, title: name, detail: detail.map(oneLine), source: source, insert: "/\(name) ")
    }

    private static func children(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    /// The first sentence, at most 90 characters.
    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let sentence = flat.range(of: ". ").map { String(flat[..<$0.lowerBound]) + "." } ?? flat
        return sentence.count > 90 ? String(sentence.prefix(89)) + "…" : sentence
    }

    /// `key: value` lines between the leading `---` fences (simple YAML: one line per key, quotes
    /// stripped). Nil when the file is missing or has none.
    static func frontMatter(_ file: URL) -> [String: String]? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8_192), let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
            if !value.isEmpty { out[key] = value }
        }
        return out
    }

    /// Enabled plugins (settings.json `enabledPlugins`) and their install folders
    /// (`plugins/installed_plugins.json`), by plugin name.
    static func enabledPlugins(_ claudeHome: URL) -> [(String, URL)] {
        func json(_ path: String) -> [String: Any] {
            (try? Data(contentsOf: claudeHome.appending(path: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        let enabled = (json("settings.json")["enabledPlugins"] as? [String: Any] ?? [:]).filter { $0.value as? Bool == true }.keys
        let installed = json("plugins/installed_plugins.json")["plugins"] as? [String: Any] ?? [:]
        return enabled.sorted().compactMap { key in
            guard let entry = (installed[key] as? [[String: Any]])?.last, let path = entry["installPath"] as? String else { return nil }
            return (String(key.split(separator: "@").first ?? Substring(key)), URL(fileURLWithPath: path, isDirectory: true))
        }
    }
}

/// The `@` menu's files and folders: a breadth-first walk of the session's folders, so shallow
/// paths come first, skipping hidden folders and build and dependency folders, capped so a home
/// folder stays quick.
nonisolated public enum FileIndex {
    /// `@rel` inside the first folder (the session's running folder); a full path in the others.
    static func mention(_ rel: String, folder: URL, first: Bool) -> String {
        let shown = first ? rel : folder.path + (folder.path.hasSuffix("/") ? "" : "/") + rel
        return shown.contains(where: \.isWhitespace) ? "@\"\(shown)\"" : "@\(shown)"
    }

    public static let cap = 6_000
    static let skipped: Set<String> = ["node_modules", "Library", "build", "dist", "DerivedData", "Pods", "target",
                                       "vendor", "__pycache__", "venv", "Applications", "Pictures", "Music", "Movies"]

    @concurrent
    public static func load(_ folders: [URL], cap: Int = cap) async -> [CompletionItem] {
        var out: [CompletionItem] = []
        var seen = Set<String>()
        for folder in folders {
            // Each folder with its path relative to `folder` (paths aren't compared as strings:
            // /var and /private/var are one folder).
            var queue: [(URL, String)] = [(folder, "")]
            while !queue.isEmpty, out.count < cap {
                let (dir, dirRel) = queue.removeFirst()
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]) else { continue }
                for url in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                    guard out.count < cap, seen.insert(url.path).inserted else { continue }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    let isFolder = values?.isDirectory == true && values?.isPackage != true
                    let rel = dirRel + url.lastPathComponent
                    if isFolder {
                        guard !skipped.contains(url.lastPathComponent) else { continue }
                        queue.append((url, rel + "/"))
                    }
                    let shown = isFolder ? rel + "/" : rel
                    out.append(CompletionItem(kind: isFolder ? .folder : .file, title: shown,
                                              source: folders.count > 1 ? folder.lastPathComponent : nil,
                                              insert: mention(shown, folder: folder, first: folder == folders.first) + " "))
                }
            }
        }
        return out
    }
}
