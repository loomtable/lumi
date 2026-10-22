import Foundation
import Synchronization
import Testing
@testable import BuddyBridge

struct ClaudeCodeProbeTests {
    private let claude = "/Users/me/.local/bin/claude"
    private let plugin = URL(fileURLWithPath: "/Users/me/Library/Application Support/com.loomtable.lumi/plugin")

    private func probe(_ outputs: [String: (Int32, String)?], installed: Bool = true, pluginThere: Bool = true) -> ClaudeCodeProbe {
        ClaudeCodeProbe(run: { _, args, _ in
            outputs[args.prefix(2).joined(separator: " ")] ?? nil
        }, isExecutable: { installed && $0 == "/Users/me/.local/bin/claude" }, directoryExists: { _ in pluginThere })
    }

    private let signedIn = #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "someone@example.com", "orgId": "x", "orgName": "Org", "subscriptionType": "max"}"#

    @Test func aHealthyInstall() async {
        let p = probe(["--version": (0, "2.1.296 (Claude Code)\n"), "auth status": (0, signedIn), "plugin validate": (0, "✔ Validation passed")])
        let r = await p.check(preferred: nil, plugin: plugin, environment: ["PATH": "/usr/bin"], home: "/Users/me")
        #expect(r.executable?.path == claude)
        #expect(r.version == "2.1.296")
        #expect(r.auth == .init(loggedIn: true, method: "claude.ai", subscription: "max", provider: "firstParty"))
        #expect(r.plugin == .valid)
        #expect(!String(describing: r).contains("someone@example.com"), "the account itself is never kept")
    }

    @Test func notInstalledReportsNothingElse() async {
        let r = await probe([:], installed: false, pluginThere: false).check(preferred: nil, plugin: plugin, environment: [:], home: "/Users/me")
        #expect(r == ClaudeCodeReport())
        let withPlugin = await probe([:], installed: false).check(preferred: nil, plugin: plugin, environment: [:], home: "/Users/me")
        guard case .unknown = withPlugin.plugin else { Issue.record("\(withPlugin.plugin)"); return }
    }

    @Test func aCheckThatTimesOutIsUnknownNotBroken() async {
        let runner = ClaudeCodeProbe.runner(deadline: .milliseconds(300))
        let clock = ContinuousClock(), start = clock.now
        #expect(await runner(URL(fileURLWithPath: "/bin/sleep"), ["5"], [:]) == nil)
        // Ignores SIGTERM: killed 1 s later.
        #expect(await runner(URL(fileURLWithPath: "/bin/sh"), ["-c", "trap '' TERM; sleep 5"], [:]) == nil)
        // Exits at once, but a grandchild keeps stdout open.
        #expect(await runner(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 5 & echo hi"], [:]) == nil)
        #expect(clock.now - start < .seconds(4.5))
        let p = probe([:])
        let r = await ClaudeCodeProbe(run: { _, _, _ in nil }, isExecutable: p.isExecutable, directoryExists: { _ in true })
            .check(preferred: nil, plugin: plugin, environment: [:], home: "/Users/me")
        #expect(r.version == nil && r.auth == nil)
        guard case .unknown = r.plugin else { Issue.record("\(r.plugin)"); return }
    }

    @Test func signedOutAndABrokenPlugin() async {
        let p = probe(["--version": (0, "2.1.296 (Claude Code)"), "auth status": (1, #"{"loggedIn": false}"#),
                       "plugin validate": (1, Self.realValidateFailure)])
        let r = await p.check(preferred: nil, plugin: plugin, environment: [:], home: "/Users/me")
        #expect(r.auth?.loggedIn == false)
        #expect(r.plugin == .invalid("agents[0]: Path not found: ./nope.md. The runtime loader will report this as a load failure."))
    }

    /// Recorded from `claude plugin validate --strict` 2.1.296 on a plugin with a missing agent file.
    static let realValidateFailure = """
        Validating plugin manifest: /Users/me/Library/Application Support/com.loomtable.lumi/plugin/.claude-plugin/plugin.json

        ✘ Found 1 error:

          ❯ agents[0]: Path not found: ./nope.md. The runtime loader will report this as a load failure.

        ⚠ Found 2 warnings:

          ❯ description: No description provided. Adding a description helps users understand what your plugin does
          ❯ author: No author information provided. Consider adding author details for plugin attribution

        ✘ Validation failed

        """

    @Test func theProblemIsTheErrorLineNotTheHeaderOrAWarning() {
        #expect(ClaudeCodeProbe.firstProblem("✘ Found 1 error:\n\n  ❯ json: Invalid JSON syntax: JSON Parse error: Unexpected token '}'\n\n✘ Validation failed")
                == "json: Invalid JSON syntax: JSON Parse error: Unexpected token '}'")
        #expect(ClaudeCodeProbe.firstProblem("⚠ Found 1 warning:\n  ❯ author: none\n✘ Validation failed") == "✘ Validation failed")
    }

    @Test func everyCommandGetsTheEnvironmentUnchanged() async {
        let seen = Mutex<[[String: String]]>([])
        let env = ["PATH": "/usr/bin", "HOME": "/Users/me", "USER": "me"]
        let p = ClaudeCodeProbe(run: { _, _, e in seen.withLock { $0.append(e) }; return (0, "") },
                                isExecutable: { $0 == "/Users/me/.local/bin/claude" }, directoryExists: { _ in true })
        _ = await p.check(preferred: nil, plugin: plugin, environment: env, home: "/Users/me")
        #expect(seen.withLock { $0 }.count == 3)
        #expect(seen.withLock { $0 }.allSatisfy { $0 == env }, "USER must reach `auth status`, or the keychain login isn't found")
    }

    @Test func missingPluginFolderIsNotInstalled() async {
        let r = await probe(["--version": (0, "2.1.296")], pluginThere: false).check(preferred: nil, plugin: plugin, environment: [:], home: "/Users/me")
        #expect(r.plugin == .notInstalled)
    }

    @Test func garbageOutputIsUnknownNotGuessed() {
        #expect(ClaudeCodeProbe.parseVersion("command not found") == nil)
        #expect(ClaudeCodeProbe.parseAuth("not json") == nil)
        #expect(ClaudeCodeProbe.parseAuth(#"{"email": "x"}"#) == nil)
    }

    @Test func versionsBelowTheMinimumAreRefused() {
        for v in ["2.1.259", "2.1.300", "2.2.0", "3.0.0", "2.1.259-beta", "2.1.1000"] {
            #expect(ClaudeCodeProbe.isSupported(v), "\(v)")
        }
        for v in ["2.1.258", "2.1.99", "2.0.999", "1.9.300", "2.1"] {
            #expect(!ClaudeCodeProbe.isSupported(v), "\(v)")
        }
    }

    @Test func versionIsReadOrNilNeverGuessed() async {
        let claude = URL(fileURLWithPath: "/Users/me/.local/bin/claude")
        #expect(await probe(["--version": (0, "2.1.301 (Claude Code)")]).version(of: claude, environment: [:]) == "2.1.301")
        #expect(await probe(["--version": (1, "2.1.301")]).version(of: claude, environment: [:]) == nil)
        #expect(await probe(["--version": nil]).version(of: claude, environment: [:]) == nil)
    }

    @Test func theRealRunnerRunsACommand() async {
        let r = await ClaudeCodeProbe.runProcess(URL(fileURLWithPath: "/bin/echo"), ["2.1.296", "(Claude Code)"], [:])
        #expect(r?.status == 0)
        #expect(r.flatMap { ClaudeCodeProbe.parseVersion($0.stdout) } == "2.1.296")
    }
}

struct PluginInstallerTests {
    @Test func installThenReplaceInPlace() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("plugin-install-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundle/buddy-plugin")
        try fm.createDirectory(at: bundled.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
        try Data(#"{"name":"buddy","version":"1"}"#.utf8).write(to: bundled.appendingPathComponent(".claude-plugin/plugin.json"))
        let destination = root.appendingPathComponent("Application Support/com.loomtable.lumi/plugin")

        try PluginInstaller.install(bundled: bundled, destination: destination)
        #expect(fm.fileExists(atPath: destination.appendingPathComponent(".claude-plugin/plugin.json").path))

        // A damaged install (a stray file, an edited manifest) is replaced wholesale by Repair.
        try Data("junk".utf8).write(to: destination.appendingPathComponent("stray.txt"))
        try Data("broken".utf8).write(to: destination.appendingPathComponent(".claude-plugin/plugin.json"))
        try PluginInstaller.install(bundled: bundled, destination: destination)
        #expect(!fm.fileExists(atPath: destination.appendingPathComponent("stray.txt").path))
        let manifest = try String(contentsOf: destination.appendingPathComponent(".claude-plugin/plugin.json"), encoding: .utf8)
        #expect(manifest.contains("\"buddy\""))
        #expect(try fm.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).filter { $0.hasPrefix(".plugin-staging") }.isEmpty)
    }

    @Test func sourceFallsBackToTheDevFolderThenTheCheckout() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("plugin-source-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent(".claude-plugin/plugin.json"))
        let empty = Bundle(for: BundleToken.self)
        #expect(PluginInstaller.source(bundle: empty, environment: ["LUMI_PLUGIN_DIR": root.path])?.path == root.path)
        #expect(PluginInstaller.source(bundle: empty, environment: ["LUMI_PLUGIN_DIR": "/nonexistent"]) == nil,
                "a wrong dev path is an error, not a silent fallback")
        #if DEBUG
        #expect(PluginInstaller.source(bundle: empty, environment: [:])?.lastPathComponent == "buddy-plugin", "the checkout in debug")
        #endif
    }

    @Test func aSymlinkedOrDanglingDestinationIsReplacedNotFollowed() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("plugin-link-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundle")
        try fm.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: bundled.appendingPathComponent("plugin.json"))
        let elsewhere = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: elsewhere.appendingPathComponent("mine.txt"))
        let destination = root.appendingPathComponent("support/plugin")
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        try fm.createSymbolicLink(at: destination, withDestinationURL: elsewhere)
        try PluginInstaller.install(bundled: bundled, destination: destination)
        #expect(try fm.destinationOfSymbolicLinkOrNil(destination) == nil, "now a real folder")
        #expect(fm.fileExists(atPath: destination.appendingPathComponent("plugin.json").path))
        #expect(fm.fileExists(atPath: elsewhere.appendingPathComponent("mine.txt").path), "the link's target is untouched")

        try fm.removeItem(at: destination)
        try fm.createSymbolicLink(at: destination, withDestinationURL: root.appendingPathComponent("gone"))
        try PluginInstaller.install(bundled: bundled, destination: destination)
        #expect(fm.fileExists(atPath: destination.appendingPathComponent("plugin.json").path))
    }

    @Test func leftoverStagingFoldersAreSwept() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("plugin-sweep-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundle")
        try fm.createDirectory(at: bundled, withIntermediateDirectories: true)
        let stale = root.appendingPathComponent("support/.plugin-staging-old")
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try PluginInstaller.install(bundled: bundled, destination: root.appendingPathComponent("support/plugin"))
        #expect(!fm.fileExists(atPath: stale.path))
    }

    @Test func aMissingBundleLeavesTheOldPluginAlone() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("plugin-install-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("plugin")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("keep.txt"))
        #expect(throws: (any Error).self) {
            try PluginInstaller.install(bundled: root.appendingPathComponent("missing"), destination: destination)
        }
        #expect(fm.fileExists(atPath: destination.appendingPathComponent("keep.txt").path))
    }
}

private final class BundleToken {}

private extension FileManager {
    func destinationOfSymbolicLinkOrNil(_ url: URL) throws -> String? {
        (try? attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
            ? try destinationOfSymbolicLink(atPath: url.path) : nil
    }
}
