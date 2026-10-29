@testable import BuddyBridge
import BuddyVoice
import Foundation
import Testing
@testable import BuddyCompanion

@Suite("Home health strip")
@MainActor
struct HomeHealthStripTests {
    static let healthyClaude = ClaudeCodeStatus(executablePath: "/usr/local/bin/claude", version: "2.1.312 (Claude Code)",
                                                loggedIn: true, pluginLoaded: true, checked: true)

    func server(_ name: String, _ status: String) -> StreamEvent.MCPServer { StreamEvent.MCPServer(name: name, status: status, source: nil) }

    @Test func allGood() {
        let strip = HealthStrip(.init(claudeCode: Self.healthyClaude, voiceChosen: true, voice: .ready,
                                      servers: [server("a", "connected"), server("b", "connected"), server("c", "connected")]))
        #expect(strip.items.map(\.text) == ["Claude Code 2.1", "Voice ready", "3 connections", "Permissions OK"])
        #expect(strip.items.allSatisfy { $0.level == .ok })
        #expect(strip.items.map(\.page) == [.claudeCode, .voice, .connections, .permissions])
    }

    @Test(arguments: [
        (ClaudeCodeStatus(), "Checking Claude Code…", HealthStrip.Level.neutral),
        (ClaudeCodeStatus(checked: true), "Claude Code not found", .problem),
        (ClaudeCodeStatus(executablePath: "/c", loggedIn: false, checked: true), "Claude Code isn't signed in", .problem),
        (ClaudeCodeStatus(executablePath: "/c", loggedIn: true, pluginLoaded: false, pluginProblem: "x", checked: true),
         "Claude Code plugin needs a repair", .attention),
        (ClaudeCodeStatus(executablePath: "/c", loggedIn: true, pluginLoaded: true, checked: true), "Claude Code", .ok),
    ])
    func claudeCode(status: ClaudeCodeStatus, text: String, level: HealthStrip.Level) {
        let item = HealthStrip(.init(claudeCode: status)).items[0]
        #expect(item.text == text)
        #expect(item.level == level)
    }

    @Test func voice() {
        func item(_ chosen: Bool, _ state: VoiceStateCase) -> HealthStrip.Item {
            HealthStrip(.init(voiceChosen: chosen, voice: state.value)).items[1]
        }
        #expect(item(false, .ready).text == "Voice off")
        #expect(item(false, .ready).level == .neutral)
        #expect(item(true, .ready).level == .ok)
        #expect(item(true, .notStarted).text == "Voice getting ready")
        #expect(item(true, .failed).level == .problem)
    }

    @Test func connections() {
        func item(_ servers: [StreamEvent.MCPServer]) -> HealthStrip.Item { HealthStrip(.init(servers: servers)).items[2] }
        #expect(item([]).text == "No connections")
        #expect(item([]).level == .neutral)
        #expect(item([server("a", "connected")]).text == "1 connection")
        let mixed = item([server("a", "connected"), server("b", "needs-auth"), server("c", "pending")])
        #expect(mixed.text == "1 connection · 1 needs a look")
        #expect(mixed.level == .attention)
    }

    @Test func permissions() {
        func item(_ missing: [PermissionKind], reopen: Bool = false) -> HealthStrip.Item {
            HealthStrip(.init(missingPermissions: missing, permissionsNeedReopen: reopen)).items[3]
        }
        #expect(item([.screenRecording]).text == "\(PermissionKind.screenRecording.title) needs a look")
        #expect(item([.screenRecording, .microphone]).text == "2 permissions need a look")
        #expect(item([], reopen: true).text == "Reopen Lumi to finish permissions")
        #expect(item([]).level == .ok)
    }

    @Test func shortVersion() {
        #expect(HealthStrip.shortVersion("2.1.312 (Claude Code)") == "2.1")
        #expect(HealthStrip.shortVersion("3") == "3")
    }
}

/// `PrepareState` cases for table rows (its payloads aren't needed here).
enum VoiceStateCase {
    case ready, notStarted, failed
    var value: VoiceController.PrepareState {
        switch self {
        case .ready: .ready
        case .notStarted: .notStarted
        case .failed: .failed("x")
        }
    }
}
