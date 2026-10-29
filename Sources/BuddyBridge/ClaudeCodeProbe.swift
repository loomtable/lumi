import BuddyCore
import Foundation
import Synchronization

/// What Settings › Claude Code shows about the user's install (step 2).
public struct ClaudeCodeReport: Sendable, Equatable {
    public var executable: URL?
    /// "2.1.296".
    public var version: String?
    public var auth: Auth?
    /// `claude plugin validate --strict` on the installed plugin folder.
    public var plugin: PluginCheck

    public struct Auth: Sendable, Equatable {
        public var loggedIn: Bool
        /// "claude.ai" (subscription) or "api_key"…, as the CLI reports it.
        public var method: String?
        /// "max", "pro", "team"… for subscription logins.
        public var subscription: String?
        /// "firstParty", "bedrock", "vertex"…
        public var provider: String?

        public init(loggedIn: Bool, method: String? = nil, subscription: String? = nil, provider: String? = nil) {
            self.loggedIn = loggedIn
            self.method = method
            self.subscription = subscription
            self.provider = provider
        }
    }

    public enum PluginCheck: Sendable, Equatable {
        case notInstalled
        case valid
        case invalid(String)
        case unknown(String)
    }

    public init(executable: URL? = nil, version: String? = nil, auth: Auth? = nil, plugin: PluginCheck = .notInstalled) {
        self.executable = executable
        self.version = version
        self.auth = auth
        self.plugin = plugin
    }
}

/// Runs a command and returns its exit status and stdout (stderr discarded). Real: `Process`
/// with a deadline; tests: canned output.
public typealias CommandRunner = @Sendable (_ executable: URL, _ arguments: [String], _ environment: [String: String]) async -> (status: Int32, stdout: String)?

/// Checks the user's Claude Code: where it is, which version, whether it's signed in, and
/// whether the bundled plugin is intact. Reads nothing that identifies the account: the CLI's
/// `auth status` includes the email and organisation, and they are never kept.
public struct ClaudeCodeProbe: Sendable {
    public var run: CommandRunner
    public var isExecutable: @Sendable (String) -> Bool
    public var directoryExists: @Sendable (URL) -> Bool

    public init(run: @escaping CommandRunner = ClaudeCodeProbe.runProcess,
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                directoryExists: @escaping @Sendable (URL) -> Bool = {
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
                }) {
        self.run = run
        self.isExecutable = isExecutable
        self.directoryExists = directoryExists
    }

    /// `preferred`: a path the user chose in Settings, if any. `environment`: the child
    /// environment (`LaunchEnvironment.make` from the app's own), whose PATH is also searched. It
    /// must keep `USER`: without it `auth status` can't find the login in the keychain and
    /// reports signed out.
    public func check(preferred: String?, plugin: URL, environment: [String: String], home: String) async -> ClaudeCodeReport {
        var report = ClaudeCodeReport()
        guard let claude = LaunchEnvironment.locateClaude(preferred: preferred, path: environment["PATH"] ?? "",
                                                          home: home, isExecutable: isExecutable) else {
            if directoryExists(plugin) { report.plugin = .unknown("Claude Code isn't installed, so the plugin can't be checked.") }
            return report
        }
        report.executable = claude
        async let version = version(of: claude, environment: environment)
        async let auth = run(claude, ["auth", "status", "--json"], environment)
        report.version = await version
        report.auth = (await auth).flatMap { Self.parseAuth($0.stdout) }
        if directoryExists(plugin) {
            if let result = await run(claude, ["plugin", "validate", "--strict", plugin.path], environment) {
                report.plugin = result.status == 0 ? .valid : .invalid(Self.firstProblem(result.stdout))
            } else {
                report.plugin = .unknown("The plugin check didn't finish.")
            }
        }
        return report
    }

    /// The oldest Claude Code Lumi runs: 2.1.312, the version the session engine was verified on
    /// (stream events, `can_use_tool` over stdio, replayed user turns, `--session-id`, subagent
    /// files). Quick and Deep need `--permission-prompts` (2.1.259) too.
    public static let minimumVersion = "2.1.312"

    /// `claude --version`, or nil when it can't be read. Takes well under a second.
    public func version(of claude: URL, environment: [String: String]) async -> String? {
        await run(claude, ["--version"], environment).flatMap { $0.status == 0 ? Self.parseVersion($0.stdout) : nil }
    }

    /// Whether `version` is at least `minimumVersion`, comparing numbers part by part ("2.1.1000" >
    /// "2.1.312"); a suffix such as "-beta" is ignored.
    public static func isSupported(_ version: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let have = parts(version), need = parts(minimumVersion)
        for i in 0..<max(have.count, need.count) {
            let a = i < have.count ? have[i] : 0, b = i < need.count ? need[i] : 0
            if a != b { return a > b }
        }
        return true
    }

    /// "2.1.296 (Claude Code)" → "2.1.296".
    static func parseVersion(_ output: String) -> String? {
        let token = output.split(whereSeparator: \.isWhitespace).first.map(String.init)
        guard let token, token.first?.isNumber == true else { return nil }
        return token
    }

    static func parseAuth(_ output: String) -> ClaudeCodeReport.Auth? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              let loggedIn = o["loggedIn"] as? Bool else { return nil }
        func text(_ key: String) -> String? { (o[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        // Deliberately not read: email, orgId, orgName.
        return .init(loggedIn: loggedIn, method: text("authMethod"), subscription: text("subscriptionType"),
                     provider: text("apiProvider"))
    }

    /// The reason from `claude plugin validate` output: the first `❯` line under the "✘ Found N
    /// error(s):" header (warnings follow under "⚠"), else the first ✘ line, else the last line.
    static func firstProblem(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var inErrors = false
        for line in lines {
            if line.hasPrefix("✘") { inErrors = line.lowercased().contains("error"); continue }
            if line.hasPrefix("⚠") { inErrors = false; continue }
            if inErrors, line.hasPrefix("❯") {
                return String(line.dropFirst().trimmingCharacters(in: .whitespaces).prefix(200))
            }
        }
        let problem = lines.first { $0.hasPrefix("✘") }
        return String((problem ?? lines.last ?? "The plugin check failed.").prefix(200))
    }

    /// The real runner, with a 10 s deadline.
    public static let runProcess: CommandRunner = runner(deadline: .seconds(10))

    /// Runs on a GCD thread (it blocks), never the cooperative pool. Returns nil, never a guess,
    /// when it can't launch, misses the deadline (SIGTERM, then SIGKILL 1 s later), or its output
    /// stays open after it exits (a grandchild holding stdout). Stdout only.
    /// `currentDirectory`: where the command runs (nil: Lumi's own).
    public static func runner(deadline: Duration, currentDirectory: URL? = nil) -> CommandRunner {
        { executable, arguments, environment in
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let outcome = runBlocking(executable, arguments, environment, deadline: deadline, keepStandardError: false,
                                              currentDirectory: currentDirectory)
                    continuation.resume(returning: outcome.map { ($0.status, $0.stdout) })
                }
            }
        }
    }

    /// The same, keeping stderr too: `claude mcp` reports its refusals there.
    static func outputRunner(deadline: Duration) -> ClaudeCodeMCP.OutputRunner {
        { executable, arguments, environment in
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: runBlocking(executable, arguments, environment, deadline: deadline, keepStandardError: true))
                }
            }
        }
    }

    private nonisolated static func runBlocking(_ executable: URL, _ arguments: [String], _ environment: [String: String],
                                                deadline: Duration, keepStandardError: Bool,
                                                currentDirectory: URL? = nil) -> (status: Int32, stdout: String, stderr: String)? {
        let process = Process()
        process.executableURL = executable
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.arguments = arguments
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        let err = keepStandardError ? Pipe() : nil
        process.standardError = err ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        // Drain concurrently so a full pipe can't stall the child.
        let output = Mutex(Data())
        let drained = DispatchSemaphore(value: 0)
        let reader = out.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            let data = reader.readDataToEndOfFile()
            output.withLock { $0 = data }
            drained.signal()
        }
        // Stderr the same way, so neither pipe can fill and stall the child.
        let errors = Mutex(Data())
        // Starts at 0 either way: a semaphore disposed below its initial value traps.
        let errorsDrained = DispatchSemaphore(value: 0)
        let errorReader = err?.fileHandleForReading
        if let errorReader {
            DispatchQueue.global(qos: .utility).async {
                let data = errorReader.readDataToEndOfFile()
                errors.withLock { $0 = data }
                errorsDrained.signal()
            }
        } else {
            errorsDrained.signal()
        }
        let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
        if exited.wait(timeout: .now() + seconds) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            try? reader.close()
            try? errorReader?.close()
            return nil
        }
        // Both outputs within 2 s of the exit: a grandchild holding one open is a nil, never a hang.
        let afterExit = DispatchTime.now() + 2
        guard drained.wait(timeout: afterExit) == .success, errorsDrained.wait(timeout: afterExit) == .success else {
            try? reader.close()
            try? errorReader?.close()
            return nil
        }
        return (process.terminationStatus, String(decoding: output.withLock { $0 }, as: UTF8.self),
                String(decoding: errors.withLock { $0 }, as: UTF8.self))
    }
}

/// Installs the bundled plugin where every process loads it from: copied on first run,
/// after each update, and by "Repair plugin". Settings never edit plugin files.
public enum PluginInstaller {
    /// Where every process loads the plugin from: `--plugin-dir`.
    public static var destination: URL {
        BuddyCore.paths.plugin
    }

    /// The plugin to install: the app bundle's copy; else `LUMI_PLUGIN_DIR`; else, in debug
    /// builds run from the checkout (`swift run`), the repo's `buddy-plugin/`.
    public static func source(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment,
                              fileManager: FileManager = .default) -> URL? {
        func isPlugin(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.appending(path: ".claude-plugin/plugin.json").path)
        }
        if let bundled = bundle.resourceURL?.appending(path: "buddy-plugin", directoryHint: .isDirectory), isPlugin(bundled) {
            return bundled
        }
        if let dev = environment["LUMI_PLUGIN_DIR"] {
            let url = URL(filePath: dev, directoryHint: .isDirectory)
            return isPlugin(url) ? url : nil
        }
        #if DEBUG
        // Sources/BuddyBridge/ClaudeCodeProbe.swift → repo root.
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "buddy-plugin", directoryHint: .isDirectory)
        if isPlugin(repo) { return repo }
        #endif
        return nil
    }

    /// At launch and from "Repair plugin": installs `source()` at `destination` and returns it.
    @discardableResult
    public static func install(fileManager: FileManager = .default) throws -> URL {
        guard let source = source(fileManager: fileManager) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "No buddy-plugin found in the app bundle."])
        }
        try install(bundled: source, destination: destination, fileManager: fileManager)
        return destination
    }

    /// Replaces `destination` with a fresh copy of `bundled`, atomically: the new copy is made
    /// next to it first, so a failed copy leaves the old plugin in place. Internal: the app only
    /// ever installs to `destination` (through `install()`); tests pass a temporary folder.
    static func install(bundled: URL, destination: URL, fileManager: FileManager = .default) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        // Staging folders left by an install that was interrupted.
        for name in (try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(".plugin-staging-") {
            try? fileManager.removeItem(at: parent.appendingPathComponent(name))
        }
        // A symlink (even a dangling one) is replaced itself, never followed.
        if (try? fileManager.attributesOfItem(atPath: destination.path))?[.type] as? FileAttributeType == .typeSymbolicLink {
            try fileManager.removeItem(at: destination)
        }
        let staging = parent.appendingPathComponent(".plugin-staging-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: bundled, to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }
}
