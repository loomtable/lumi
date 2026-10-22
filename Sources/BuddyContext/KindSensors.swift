import ApplicationServices
import BuddyCore
import Foundation

// Sensors for the app-kind fields (table). Each is a protocol with a real and a fake
// implementation; the builder runs the one that matches the front app's kind.

public protocol LocalServerSensor: Sendable {
    /// The local process serving `url`, when the URL is localhost.
    func server(for url: String) -> ContextPacket.LocalServer?
}

public protocol TerminalSensor: Sendable {
    /// cwd and running command of the terminal's front tab.
    func terminal(app: FrontApp) -> ContextPacket.Terminal?
}

public protocol EditorSensor: Sendable {
    /// Workspace folder and open file of the editor's front window.
    func editor(app: FrontApp) -> ContextPacket.Editor?
}

// MARK: - Local server

public struct LibprocLocalServerSensor: LocalServerSensor {
    public init() {}

    public func server(for url: String) -> ContextPacket.LocalServer? {
        guard let port = LocalURL.port(of: url), let pid = Processes.listeningPID(port: port) else { return nil }
        return ContextPacket.LocalServer(
            port: port, pid: pid, cwd: Processes.cwd(pid), command: Processes.command(pid))
    }
}

/// Recognises URLs served from this Mac.
public enum LocalURL {
    /// The port of a localhost URL (explicit, or 80/443 by scheme), else nil.
    public static func port(of url: String) -> Int? {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased(),
              isLocal(host) else { return nil }
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    public static func isLocal(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h.hasSuffix(".localhost") || h == "127.0.0.1" || h == "::1" || h == "0.0.0.0"
    }
}

// MARK: - Terminal

/// Finds the front tab's shell in the terminal app's process tree. Terminal.app and Ghostty
/// publish the front tab's cwd as the window's AXDocument (shell integration); iTerm2 does not,
/// so there the tab whose tty the user typed into last is taken as the front one.
public struct ProcessTreeTerminalSensor: TerminalSensor {
    public init() {}

    public func terminal(app: FrontApp) -> ContextPacket.Terminal? {
        let documentCwd = AXWindowSensor().window(pid: app.pid)?.document
        let all = Processes.userProcesses()
        let byParent = Dictionary(grouping: all, by: \.ppid)
        // Descendants of the terminal app that own a tty (iTerm2: app → iTermServer → login → shell).
        var stack = [app.pid]
        var withTTY: [Processes.Info] = []
        while let pid = stack.popLast() {
            for child in byParent[pid] ?? [] {
                if child.tty != nil { withTTY.append(child) }
                stack.append(child.pid)
            }
        }
        let ttys = Dictionary(grouping: withTTY, by: { $0.tty! })
        guard !ttys.isEmpty else { return documentCwd.map { ContextPacket.Terminal(cwd: $0) } }

        // The foreground job of each tty is its process group leader.
        func foreground(_ tty: UInt32) -> Int32? {
            let procs = ttys[tty] ?? []
            guard let group = procs.first?.ttyForegroundGroup else { return nil }
            return procs.contains { $0.pid == group } ? group : nil
        }
        let latest: ([UInt32]) -> UInt32? = { $0.max { TTY.lastInput($0) < TTY.lastInput($1) } }
        let chosen: UInt32?
        if let documentCwd {
            // Match the tab by its shell's cwd (a job like `make -C` can move its own), with
            // symlinks resolved (/tmp vs /private/tmp). Several matches: the one typed into last.
            let want = Self.realpath(documentCwd)
            let matches = ttys.keys.filter { tty in
                Self.shell(on: ttys[tty] ?? []).flatMap { Processes.cwd($0.pid) }.map(Self.realpath) == want
            }
            // No match: report the cwd alone rather than another tab's command.
            guard let match = latest(matches) else { return ContextPacket.Terminal(cwd: documentCwd) }
            chosen = match
        } else {
            chosen = latest(Array(ttys.keys))
        }
        guard let tty = chosen, let job = foreground(tty) else {
            return documentCwd.map { ContextPacket.Terminal(cwd: $0) }
        }
        let name = all.first { $0.pid == job }?.name ?? ""
        // At a prompt the foreground job is the shell itself: no command is running.
        let command = Self.shells.contains(name) ? nil : Processes.command(job)
        return ContextPacket.Terminal(cwd: documentCwd ?? Processes.cwd(job), command: command)
    }

    static let shells: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "pwsh", "login",
    ]

    /// The tty's shell: the process on it whose name is a shell and whose parent is not on it.
    static func shell(on procs: [Processes.Info]) -> Processes.Info? {
        let pids = Set(procs.map(\.pid))
        return procs.first { shells.contains($0.name) && !pids.contains($0.ppid) && $0.name != "login" }
            ?? procs.first { shells.contains($0.name) && $0.name != "login" }
    }
}

extension ProcessTreeTerminalSensor {
    /// Resolving symlinks looks at every component, so a protected folder is compared as written.
    static func realpath(_ path: String) -> String {
        if ProtectedFolders.contains(path) { return URL(fileURLWithPath: path).standardizedFileURL.path }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

enum TTY {
    /// When the tty was last read from (input), from its device node's atime.
    static func lastInput(_ dev: UInt32) -> Date {
        guard let name = devname(dev_t(bitPattern: dev), mode_t(S_IFCHR)) else { return .distantPast }
        var st = stat()
        guard stat("/dev/" + String(cString: name), &st) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))
    }
}

// MARK: - Editor

/// The open file from the window's AXDocument (VS Code, Cursor, Xcode, Zed set it); the
/// workspace is the ancestor folder named in the window title ("file.ts — web").
public struct TitleAndDocumentEditorSensor: EditorSensor {
    public init() {}

    public func editor(app: FrontApp) -> ContextPacket.Editor? {
        guard let window = AXWindowSensor().window(pid: app.pid) else { return nil }
        let file = window.document
        let workspace = file.flatMap { EditorTitle.workspace(file: $0, title: window.title) }
        guard file != nil || workspace != nil else { return nil }
        return ContextPacket.Editor(workspace: workspace, file: file)
    }
}

public enum EditorTitle {
    /// Title segments, split on the separator the editor uses: " — " (VS Code, Xcode) or " – "
    /// (JetBrains); " - " only when neither appears, since folder names can contain it.
    public static func segments(_ title: String) -> [String] {
        let dashes = [" — ", " – "].filter(title.contains)
        var parts = [title]
        for sep in dashes.isEmpty ? [" - "] : dashes {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        return parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ●•*")) }.filter { !$0.isEmpty }
    }

    /// The ancestor of `file` whose name is a title segment. With several (a/web/packages/web),
    /// the one that looks like a project root (.git, .vscode, a .code-workspace) wins, else the
    /// nearest.
    public static func workspace(
        file: String, title: String?, isProjectRoot: (String) -> Bool = EditorTitle.looksLikeProjectRoot
    ) -> String? {
        guard let title else { return nil }
        let names = Set(segments(title))
        var candidates: [String] = []
        var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        while dir.path != "/" {
            if names.contains(dir.lastPathComponent) { candidates.append(dir.path) }
            dir.deleteLastPathComponent()
        }
        return candidates.first(where: isProjectRoot) ?? candidates.first
    }

    /// Never touches a folder macOS guards with a privacy prompt (Desktop, Documents, Downloads,
    /// iCloud Drive, media folders, other volumes): looking would ask "Lumi would like to
    /// access files in your Desktop folder" in the middle of a question. There the nearest title
    /// match is used instead.
    public static func looksLikeProjectRoot(_ path: String) -> Bool {
        looksLikeProjectRoot(path, protectedRoots: ProtectedFolders.roots)
    }

    static func looksLikeProjectRoot(
        _ path: String, protectedRoots: [String], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        list: (String) -> [String]? = { try? FileManager.default.contentsOfDirectory(atPath: $0) }
    ) -> Bool {
        guard !ProtectedFolders.contains(path, roots: protectedRoots) else { return false }
        if fileExists(path + "/.git") || fileExists(path + "/.vscode") { return true }
        return list(path)?.contains { $0.hasSuffix(".code-workspace") } ?? false
    }

}

/// Folders macOS guards per app with a privacy prompt (TCC Files and Folders, iCloud Drive,
/// File Provider cloud folders, other apps' data, removable and network volumes). Nothing in
/// BuddyContext reads inside them: one look asks "Lumi would like to access files in…"
/// in the middle of a question. Matching is by path only, so checking costs no disk access.
enum ProtectedFolders {
    static let roots = roots(home: FileManager.default.homeDirectoryForCurrentUser.path)

    static func roots(home: String) -> [String] {
        let inHome = [
            "Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage",
            "Library/Containers", "Library/Group Containers", "Pictures", "Movies", "Music",
        ]
        // The data volume's firmlink spelling reaches the same folders.
        return [home, "/System/Volumes/Data" + home].flatMap { h in inHome.map { h + "/" + $0 } }
            + ["/Volumes", "/Network", "/net"]
    }

    /// Case- and Unicode-insensitive, as APFS is by default ("~/desktop" is ~/Desktop). A symlink
    /// from outside into a protected folder isn't seen: resolving it would itself look inside.
    static func contains(_ path: String, roots: [String] = roots) -> Bool {
        let path = key(URL(fileURLWithPath: path).standardizedFileURL.path)
        return roots.contains { root in
            let root = key(root)
            return path == root || path.hasPrefix(root + "/")
        }
    }

    private static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
}
