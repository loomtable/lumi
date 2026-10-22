import Foundation
import Testing
@testable import BuddyBridge

/// The contracts the bridge relies on, checked against the installed `claude`: our launch flags are
/// accepted, a missing `--resume` session looks the way the lanes expect, and an interrupt keeps the
/// process. Runs real Quick turns (Haiku, a few cents); opt in when Claude Code updates:
///   BUDDYBRIDGE_LIVE_CLI=1 Scripts/test.sh --filter LiveCLIContract
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUDDYBRIDGE_LIVE_CLI"] == "1"), .serialized)
struct LiveCLIContractTests {
    static let plugin = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("buddy-plugin")

    /// The Quick lane as the app launches it, in a scratch folder (never the user's home).
    static func quickSpec(resume: String? = nil) async throws -> LaunchSpec {
        let home = NSHomeDirectory()
        var base = ProcessInfo.processInfo.environment
        for key in base.keys where key.hasPrefix("CLAUDE_CODE") || key == "CLAUDECODE" { base[key] = nil }
        let shell = base["SHELL"] ?? "/bin/zsh"
        let loginPath = await LaunchEnvironment.loginShellPath(shell: shell, home: home)
        let env = LaunchEnvironment.make(base: base, loginShellPath: loginPath, home: home)
        let claude = try #require(LaunchEnvironment.locateClaude(preferred: nil, path: env["PATH"] ?? "", home: home),
                                  "claude not found")
        let folder = FileManager.default.temporaryDirectory.appending(path: "sb-cli-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var spec = LaunchSpec.quick(executable: claude, home: folder, plugin: plugin, environment: env)
        spec.resumeSessionID = resume
        return spec
    }

    static func launch(_ spec: LaunchSpec) async throws -> ClaudeSession {
        try await ClaudeSession.launch(spec)
    }

    @Test func quickFlagsAreAcceptedAndInterruptsAreOffered() async throws {
        let session = try await Self.launch(try await Self.quickSpec())
        let events = await collect(await session.ask(TurnInput(text: "Reply with exactly: ok"), deadline: .seconds(60)))
        let info = events.compactMap { if case .initialized(let i) = $0 { i } else { nil } }.first
        print("claude \(info?.version ?? "?"), permissionMode \(info?.permissionMode ?? "?"), capabilities \(info?.capabilities ?? [])")
        guard case .finished(let outcome) = events.last else { Issue.record("the turn failed: \(String(describing: events.last))"); return }
        #expect(!outcome.result.isError)
        #expect(info?.capabilities.contains("interrupt_receipt_v1") == true, "Esc relies on interrupts (#149)")
        #expect(info?.pluginErrors.isEmpty == true, "the buddy plugin loads cleanly")
        await session.shutdown()
    }

    @Test func aMissingResumeSessionIsRecognised() async throws {
        // No API call: the CLI fails before the turn starts.
        let session = try await Self.launch(try await Self.quickSpec(resume: UUID().uuidString.lowercased()))
        let events = await collect(await session.ask(TurnInput(text: "hi"), deadline: .seconds(30)))
        #expect(events.contains { $0.isMissingSession }, "the lanes start fresh only on this (#148): \(events)")
    }

    @Test func anInterruptKeepsTheProcessForTheNextQuestion() async throws {
        let session = try await Self.launch(try await Self.quickSpec())
        let stream = await session.ask(TurnInput(text: "Count slowly from 1 to 300, one number per line, nothing else."),
                                       deadline: .seconds(60))
        for await event in stream { if case .text = event { break } }
        #expect(await session.cancel())
        let next = await collect(await session.ask(TurnInput(text: "Reply with exactly: ok"), deadline: .seconds(60)))
        guard case .finished(let outcome) = next.last else { Issue.record("no answer after the interrupt: \(String(describing: next.last))"); return }
        #expect(!outcome.result.isError)
        #expect(await session.isAlive, "still the warm process (#149)")
        await session.shutdown()
    }
}
