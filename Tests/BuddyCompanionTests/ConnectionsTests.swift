@testable import BuddyBridge
import Foundation
import Testing
@testable import BuddyCompanion

@Suite("Settings › Connections")
@MainActor
struct ConnectionsTests {
    let context7 = MCPCatalog.recommended.first { $0.id == "context7" }!
    let github = MCPCatalog.recommended.first { $0.id == "github" }!
    let linear = MCPCatalog.recommended.first { $0.id == "linear" }!

    func server(_ name: String, _ status: String, source: String? = nil) -> StreamEvent.MCPServer {
        StreamEvent.MCPServer(name: name, status: status, source: source)
    }

    @Test("status comes from the last session's servers, and Remove only for what Lumi added")
    func status() {
        #expect(ConnectionStatus.of(context7, servers: [], addedByLumi: []) == .notAdded)
        #expect(ConnectionStatus.of(context7, servers: [], addedByLumi: ["context7"]) == .added)
        #expect(ConnectionStatus.of(context7, servers: [server("context7", "connected", source: "user")], addedByLumi: ["context7"])
                == .connected(byLumi: true))
        #expect(ConnectionStatus.of(context7, servers: [server("Context7", "connected", source: "user")], addedByLumi: [])
                == .connected(byLumi: false), "the user's own server: no Remove")
        #expect(ConnectionStatus.of(linear, servers: [server("claude.ai Linear", "needs-auth", source: "claudeai")], addedByLumi: [])
                == .needsSignIn(claudeAI: true, byLumi: false))
        #expect(ConnectionStatus.of(github, servers: [server("github", "needs-auth", source: "user")], addedByLumi: ["github"])
                == .needsSignIn(claudeAI: false, byLumi: true), "an expired token: still ours, so Replace Token")
        #expect(ConnectionStatus.of(context7, servers: [server("context7", "disabled")], addedByLumi: ["context7"])
                == .disabled(byLumi: true))
        #expect(ConnectionStatus.of(github, servers: [server("github", "failed", source: "user")], addedByLumi: ["github"])
                == .failed(byLumi: true))
        #expect(ConnectionStatus.of(context7, servers: [server("context7", "pending")], addedByLumi: []) == .starting,
                "the user's own server starting is never \"Not added\"")
        #expect(ConnectionStatus.connected(byLumi: false).label == "In your Claude Code")
        #expect(ConnectionStatus.added.label == "Added · checked on your next question")
    }

    @Test("only a server Lumi added is recorded")
    func recording() {
        let none = ConnectionsPreferences()
        #expect(ConnectionRow.connections(after: .added, adding: "context7", to: none).addedByLumi == ["context7"])
        #expect(ConnectionRow.connections(after: .alreadyThere, adding: "context7", to: none).addedByLumi.isEmpty,
                "already theirs: never offered Remove")
        #expect(ConnectionRow.connections(after: .failed("no"), adding: "context7", to: none).addedByLumi.isEmpty)
        #expect(ConnectionRow.connections(after: .tokenReplaced, adding: "github", to: none).addedByLumi.isEmpty,
                "only an .added is recorded")
        var once = none
        once.addedByLumi = ["context7"]
        #expect(ConnectionRow.connections(after: .added, adding: "context7", to: once).addedByLumi == ["context7"])
    }

    @Test("results and confirmations say what happens, in plain words")
    func copy() {
        #expect(ConnectionRow.note(.alreadyThere) == "Already in your Claude Code.")
        #expect(ConnectionRow.note(.failed("server refused")) == "Couldn't add it: server refused")
        #expect(ConnectionRow.note(.added) == nil)
        #expect(ConnectionRow.note(.tokenReplaced) == "Token replaced · checked on your next question.")
        #expect(ConnectionRow.addMessage(context7) == "Adds Context7 to your Claude Code (all projects).")
        #expect(ConnectionRow.addMessage(github).contains("private file on this Mac"))
    }

    @Test("Your servers lists the rest of the last session's servers, with where they come from")
    func otherServers() {
        let servers = [server("context7", "connected"), server("my-db", "failed", source: "project"),
                       server("plugin:atlassian:atlassian", "connected", source: "plugin")]
        #expect(ConnectionsPane.otherServers(servers).map(\.name) == ["my-db"])
        #expect(ConnectionsPane.otherLabel(server("my-db", "failed", source: "project")) == "Couldn't start · this project")
        #expect(ConnectionsPane.otherLabel(server("x", "connected", source: "user")) == "Connected")
    }

    @Test("what Lumi added survives a reset and decodes leniently")
    func preferences() throws {
        let t = TestDefaults()
        let store = SettingsStore(defaults: t.defaults)
        store.connections.addedByLumi = ["context7"]
        store.resetAll()
        #expect(store.connections.addedByLumi == ["context7"])
        #expect(SettingsStore(defaults: t.defaults).connections.addedByLumi == ["context7"])
        let odd = try JSONDecoder().decode(ConnectionsPreferences.self, from: Data(#"{"addedByLumi":3}"#.utf8))
        #expect(odd.addedByLumi.isEmpty)
    }
}
