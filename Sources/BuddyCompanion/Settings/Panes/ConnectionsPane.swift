import AppKit
import BuddyBridge
import BuddyOverlay
import SwiftUI

/// What Settings › Connections needs from the shell, which owns Claude Code (`ClaudeCodeMCP`). Nil
/// closures hide the buttons that need them.
public nonisolated struct ConnectionActions: Sendable {
    public var add: (@Sendable (MCPRecommendation, String?) async -> ClaudeCodeMCP.AddResult)?
    public var remove: (@Sendable (MCPRecommendation) async -> Bool)?
    public var hasRequirement: (@Sendable (MCPRecommendation) -> Bool)?

    public init(add: (@Sendable (MCPRecommendation, String?) async -> ClaudeCodeMCP.AddResult)? = nil,
                remove: (@Sendable (MCPRecommendation) async -> Bool)? = nil,
                hasRequirement: (@Sendable (MCPRecommendation) -> Bool)? = nil) {
        self.add = add
        self.remove = remove
        self.hasRequirement = hasRequirement
    }
}

extension EnvironmentValues {
    @Entry public var connectionActions = ConnectionActions()
    /// The servers of the latest session (`system/init`), from the shell; empty before the first question.
    @Entry public var mcpServers: [StreamEvent.MCPServer] = []
}

/// One recommendation's state, from the latest session's servers and what Lumi added.
enum ConnectionStatus: Equatable {
    case notAdded
    /// Lumi added it; the next session says whether it works.
    case added
    /// Working. `byLumi`: Remove is offered.
    case connected(byLumi: Bool)
    /// `claudeAI`: a claude.ai connector, signed in on claude.ai.
    case needsSignIn(claudeAI: Bool, byLumi: Bool)
    case failed(byLumi: Bool)
    /// Turned off in the user's Claude Code.
    case disabled(byLumi: Bool)
    /// The user's own server, still starting.
    case starting

    static func of(_ recommendation: MCPRecommendation, servers: [StreamEvent.MCPServer], addedByLumi: [String]) -> ConnectionStatus {
        let byLumi = addedByLumi.contains(recommendation.id)
        guard let server = recommendation.server(in: servers) else { return byLumi ? .added : .notAdded }
        switch server.status {
        case "connected": return .connected(byLumi: byLumi)
        case "needs-auth": return .needsSignIn(claudeAI: server.source == "claudeai", byLumi: byLumi)
        case "failed": return .failed(byLumi: byLumi)
        case "disabled": return .disabled(byLumi: byLumi)
        default: return byLumi ? .added : .starting  // pending
        }
    }

    var label: String {
        switch self {
        case .notAdded: "Not added"
        case .added: "Added · checked on your next question"
        case .connected(let byLumi): byLumi ? "Connected" : "In your Claude Code"
        case .needsSignIn: "Needs sign-in"
        case .failed: "Couldn't start"
        case .disabled: "Turned off in Claude Code"
        case .starting: "Starting"
        }
    }
}

/// Settings › Connections: the recommended servers, each added with one click (or a
/// pasted token, or on claude.ai for apps that sign in), and every server the last session had.
struct ConnectionsPane: View {
    @Bindable var store: SettingsStore
    @Environment(\.mcpServers) private var servers

    var body: some View {
        PaneForm {
            Section {
                ForEach(MCPCatalog.recommended) { recommendation in
                    ConnectionRow(recommendation: recommendation, store: store)
                }
            } header: {
                Text("Recommended")
            } footer: {
                Text("Added to your Claude Code for every project. Status is from your last question.")
            }
            let others = Self.otherServers(servers)
            if !others.isEmpty {
                Section("Your servers") {
                    ForEach(others, id: \.name) { server in
                        LabeledContent(server.name) {
                            Text(Self.otherLabel(server)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// The last session's servers that aren't one of the recommendations.
    static func otherServers(_ servers: [StreamEvent.MCPServer]) -> [StreamEvent.MCPServer] {
        servers.filter { server in !MCPCatalog.recommended.contains { $0.server(in: [server]) != nil } }
    }

    static func otherLabel(_ server: StreamEvent.MCPServer) -> String {
        let status = switch server.status {
        case "connected": "Connected"
        case "needs-auth": "Needs sign-in"
        case "failed": "Couldn't start"
        case "disabled": "Turned off"
        default: "Starting"
        }
        let source: String? = switch server.source {
        case "claudeai": "claude.ai"
        case "plugin": "plugin"
        case "project", "local": "this project"
        default: nil
        }
        return source.map { "\(status) · \($0)" } ?? status
    }
}

/// One recommendation: what it does, its status, and the one button that fits.
struct ConnectionRow: View {
    let recommendation: MCPRecommendation
    @Bindable var store: SettingsStore
    @Environment(\.mcpServers) private var servers
    @Environment(\.connectionActions) private var actions
    @Environment(\.openURL) private var openURL
    @State private var tokenDraft = ""
    @State private var askingToken = false
    @State private var confirmingAdd = false
    @State private var confirmingRemove = false
    @State private var working = false
    @State private var note: String?

    var body: some View {
        let status = ConnectionStatus.of(recommendation, servers: servers, addedByLumi: store.connections.addedByLumi)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recommendation.name)
                    Text(recommendation.benefit).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(status.label).font(.caption).foregroundStyle(.secondary)
                button(status)
            }
            if askingToken, case .remoteWithToken(_, let tokenPage) = recommendation.setup {
                HStack {
                    SecureField("GitHub token", text: $tokenDraft)
                    Button("Add") { confirmingAdd = true }
                        .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    Button("Cancel") { askingToken = false; tokenDraft = "" }
                }
                HStack(spacing: 6) {
                    Link("Create a token", destination: tokenPage).buttonStyle(.lumiLink).font(.caption)
                    Text("Lumi keeps the token in a private file on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.lumiAmber)
            }
        }
        .confirmationDialog("Add \(recommendation.name)?", isPresented: $confirmingAdd, titleVisibility: .visible) {
            // The token as shown now, whatever the dialog's dismissal does to state.
            let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            Button("Add") { Task { await add(token: token.isEmpty ? nil : token) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.addMessage(recommendation))
        }
        .confirmationDialog("Remove \(recommendation.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes \(recommendation.name) from your Claude Code (all projects).")
        }
    }

    @ViewBuilder private func button(_ status: ConnectionStatus) -> some View {
        switch status {
        case .notAdded:
            switch recommendation.setup {
            case .connector(let page):
                Button("Connect on claude.ai") { openURL(page) }
            case .local(_, _, let requirement) where actions.hasRequirement?(recommendation) == false:
                Link("Needs \(requirement.name)", destination: requirement.download).buttonStyle(.lumiLink)
            case .remoteWithToken:
                if actions.add != nil, !askingToken { Button("Add…") { askingToken = true } }
            case .remote, .local:
                if actions.add != nil { Button("Add…") { confirmingAdd = true }.disabled(working) }
            }
        case .connected(let byLumi), .failed(let byLumi), .disabled(let byLumi):
            ownButtons(status, byLumi: byLumi)
        case .added:
            if actions.remove != nil { Button("Remove…") { confirmingRemove = true }.disabled(working) }
        case .needsSignIn(let claudeAI, let byLumi):
            if claudeAI, case .connector(let page) = recommendation.setup {
                Button("Sign In") { openURL(page) }
            } else if claudeAI {
                Button("Sign In") { openURL(URL(string: "https://claude.ai/customize/connectors")!) }
            } else {
                // A token server that's refused (an expired token reads as needing sign-in).
                ownButtons(status, byLumi: byLumi)
            }
        case .starting:
            EmptyView()
        }
    }

    /// For a server Lumi added that isn't working: a new token where it takes one, else Remove.
    @ViewBuilder private func ownButtons(_ status: ConnectionStatus, byLumi: Bool) -> some View {
        if byLumi, status != .connected(byLumi: true), case .remoteWithToken = recommendation.setup {
            Button("Replace Token…") { askingToken = true }.disabled(working)
        } else if byLumi, actions.remove != nil {
            Button("Remove…") { confirmingRemove = true }.disabled(working)
        }
    }

    private func add(token: String?) async {
        guard let add = actions.add else { return }
        working = true
        defer { working = false }
        note = nil
        let result = await add(recommendation, token)
        store.connections = Self.connections(after: result, adding: recommendation.id, to: store.connections)
        note = Self.note(result)
        if result == .added || result == .tokenReplaced { askingToken = false; tokenDraft = "" }
    }

    private func remove() async {
        guard let remove = actions.remove else { return }
        working = true
        defer { working = false }
        note = nil
        if await remove(recommendation) {
            store.connections.addedByLumi.removeAll { $0 == recommendation.id }
        } else {
            note = "Couldn't remove it."
        }
    }

    static func addMessage(_ recommendation: MCPRecommendation) -> String {
        let base = "Adds \(recommendation.name) to your Claude Code (all projects)."
        if case .remoteWithToken = recommendation.setup { return base + " Lumi keeps the token in a private file on this Mac." }
        return base
    }

    /// Only a server Lumi itself added is recorded (and later offers Remove).
    static func connections(after result: ClaudeCodeMCP.AddResult, adding id: String,
                            to connections: ConnectionsPreferences) -> ConnectionsPreferences {
        guard result == .added, !connections.addedByLumi.contains(id) else { return connections }
        var connections = connections
        connections.addedByLumi.append(id)
        return connections
    }

    static func note(_ result: ClaudeCodeMCP.AddResult) -> String? {
        switch result {
        case .added: nil
        case .tokenReplaced: "Token replaced · checked on your next question."
        case .alreadyThere: "Already in your Claude Code."
        case .missingRequirement(let requirement): "Needs \(requirement.name) first."
        case .notAddable: "Lumi can't add this one."
        case .failed(let line): line.map { "Couldn't add it: \($0)" } ?? "Couldn't add it."
        }
    }
}
