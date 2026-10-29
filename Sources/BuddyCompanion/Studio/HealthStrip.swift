import BuddyBridge
import BuddyVoice
import Foundation

/// Home's footer (04 §6.2): Claude Code, voice, connections and permissions, each one true line
/// with a coloured dot and a word, and a link to the Settings page that fixes it.
public struct HealthStrip: Sendable, Equatable {
    public enum Level: Sendable, Equatable {
        /// Sage.
        case ok
        /// Amber: works, but something wants a look.
        case attention
        /// Rose: doesn't work.
        case problem
        /// Secondary: off by choice, or not known yet.
        case neutral
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public var text: String
        public var level: Level
        public var page: SettingsPage
        public var id: SettingsPage { page }
    }

    public struct Inputs: Sendable, Equatable {
        public var claudeCode: ClaudeCodeStatus
        public var voiceChosen: Bool
        public var voice: VoiceController.PrepareState
        public var servers: [StreamEvent.MCPServer]
        /// Required grants that are missing, in the rows' order.
        public var missingPermissions: [PermissionKind]
        /// A grant waits for a reopen.
        public var permissionsNeedReopen: Bool

        public init(claudeCode: ClaudeCodeStatus = ClaudeCodeStatus(), voiceChosen: Bool = false,
                    voice: VoiceController.PrepareState = .notStarted, servers: [StreamEvent.MCPServer] = [],
                    missingPermissions: [PermissionKind] = [], permissionsNeedReopen: Bool = false) {
            self.claudeCode = claudeCode
            self.voiceChosen = voiceChosen
            self.voice = voice
            self.servers = servers
            self.missingPermissions = missingPermissions
            self.permissionsNeedReopen = permissionsNeedReopen
        }
    }

    public var items: [Item]

    public init(_ inputs: Inputs) {
        items = [Self.claudeCode(inputs.claudeCode), Self.voice(chosen: inputs.voiceChosen, inputs.voice),
                 Self.connections(inputs.servers),
                 Self.permissions(missing: inputs.missingPermissions, reopen: inputs.permissionsNeedReopen)]
    }

    static func claudeCode(_ s: ClaudeCodeStatus) -> Item {
        let (text, level): (String, Level) =
            if !s.checked { ("Checking Claude Code…", .neutral) }
            else if s.executablePath == nil { ("Claude Code not found", .problem) }
            else if s.loggedIn == false { ("Claude Code isn't signed in", .problem) }
            else if s.pluginProblem != nil || s.pluginLoaded == false { ("Claude Code plugin needs a repair", .attention) }
            else { (["Claude Code", s.version.map(shortVersion)].compactMap { $0 }.joined(separator: " "), .ok) }
        return Item(text: text, level: level, page: .claudeCode)
    }

    static func voice(chosen: Bool, _ state: VoiceController.PrepareState) -> Item {
        let (text, level): (String, Level) =
            if !chosen { ("Voice off", .neutral) }
            else {
                switch state {
                case .ready: ("Voice ready", .ok)
                case .notStarted, .preparing: ("Voice getting ready", .attention)
                case .failed: ("Voice needs a look", .problem)
                }
            }
        return Item(text: text, level: level, page: .voice)
    }

    static func connections(_ servers: [StreamEvent.MCPServer]) -> Item {
        let working = servers.filter { $0.status == "connected" }.count
        let broken = servers.filter { $0.status == "failed" || $0.status == "needs-auth" }.count
        let count = working == 1 ? "1 connection" : "\(working) connections"
        let (text, level): (String, Level) =
            if servers.isEmpty { ("No connections", .neutral) }
            else if broken > 0 { ("\(count) · \(broken) need\(broken == 1 ? "s" : "") a look", .attention) }
            else { (count, .ok) }
        return Item(text: text, level: level, page: .connections)
    }

    static func permissions(missing: [PermissionKind], reopen: Bool) -> Item {
        let (text, level): (String, Level) =
            if let first = missing.first, missing.count == 1 { ("\(first.title) needs a look", .attention) }
            else if !missing.isEmpty { ("\(missing.count) permissions need a look", .attention) }
            else if reopen { ("Reopen Lumi to finish permissions", .attention) }
            else { ("Permissions OK", .ok) }
        return Item(text: text, level: level, page: .permissions)
    }

    /// "2.1.312 (Claude Code)" → "2.1".
    static func shortVersion(_ version: String) -> String {
        let number = version.split(separator: " ").first.map(String.init) ?? version
        return number.split(separator: ".").prefix(2).joined(separator: ".")
    }
}
