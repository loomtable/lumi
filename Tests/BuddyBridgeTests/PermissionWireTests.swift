import Foundation
import Testing
@testable import BuddyBridge

struct PermissionWireTests {
    private func object(_ line: Data) throws -> [String: Any] {
        #expect(line.last == 0x0A)
        return try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    private func response(_ line: Data) throws -> [String: Any] {
        let o = try object(line)
        #expect(o["type"] as? String == "control_response")
        return try #require(o["response"] as? [String: Any])
    }

    private func recordedAsk(_ fixture: String) throws -> (String, CanUseTool) {
        try #require(try Fixture.events(fixture).compactMap { e -> (String, CanUseTool)? in
            if case .controlRequest(let id, .canUseTool(let a)) = e { (id, a) } else { nil }
        }.first)
    }

    @Test func allowEchoesTheOriginalInput() throws {
        let (id, ask) = try recordedAsk("can-use-tool.jsonl")
        let r = try response(PermissionWire.response(id, .allow(updatedInput: nil), for: ask))
        #expect(r["subtype"] as? String == "success")
        #expect(r["request_id"] as? String == id)
        let body = try #require(r["response"] as? [String: Any])
        #expect(body["behavior"] as? String == "allow")
        let input = try #require(body["updatedInput"] as? [String: Any])
        #expect(input["file_path"] as? String == "/Users/me/probe/note.txt")
        #expect(input["content"] as? String == "hi\n")
        #expect(body["updatedPermissions"] == nil)
    }

    /// The exact shape the CLI accepted in the recording: our reply is echoed in the fixture.
    @Test func allowMatchesTheRecordedReply() throws {
        let lines = try Fixture.lines("can-use-tool.jsonl")
        let (id, ask) = try recordedAsk("can-use-tool.jsonl")
        let recorded = try #require(lines.first { line in
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  o["type"] as? String == "control_response",
                  let r = o["response"] as? [String: Any] else { return false }
            return r["request_id"] as? String == id
        })
        let mine = PermissionWire.response(id, .allow(updatedInput: nil), for: ask)
        let a = try JSONSerialization.jsonObject(with: recorded) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: mine) as? NSDictionary
        #expect(a == b)
    }

    @Test func denyCarriesAMessage() throws {
        let (id, ask) = try recordedAsk("can-use-tool.jsonl")
        let body = try #require(try response(PermissionWire.response(id, .deny(message: nil), for: ask))["response"] as? [String: Any])
        #expect(body["behavior"] as? String == "deny")
        #expect((body["message"] as? String)?.isEmpty == false)
        let custom = try #require(try response(PermissionWire.response(id, .deny(message: "Not now"), for: ask))["response"] as? [String: Any])
        #expect(custom["message"] as? String == "Not now")
    }

    @Test func allowForSessionAppliesSuggestionsToTheSession() throws {
        let (id, ask) = try recordedAsk("can-use-tool-cancel.jsonl")   // Bash: addRules → localSettings
        let body = try #require(try response(PermissionWire.response(id, .allowForSession, for: ask))["response"] as? [String: Any])
        let updates = try #require(body["updatedPermissions"] as? [[String: Any]])
        #expect(!updates.isEmpty)
        #expect(updates.allSatisfy { $0["destination"] as? String == "session" })
        #expect(updates.first?["type"] as? String == "addRules")
    }

    @Test func allowForSessionIsPlainAllowWhenSuppressed() throws {
        var (id, ask) = try recordedAsk("can-use-tool-cancel.jsonl")
        ask.suppressAlwaysAllow = true
        let body = try #require(try response(PermissionWire.response(id, .allowForSession, for: ask))["response"] as? [String: Any])
        #expect(body["behavior"] as? String == "allow")
        #expect(body["updatedPermissions"] == nil)
        _ = id
    }

    @Test func updatedInputReplacesTheInput() throws {
        let (id, ask) = try recordedAsk("can-use-tool.jsonl")
        let edited = Data(#"{"file_path":"/Users/me/probe/other.txt","content":"x"}"#.utf8)
        let body = try #require(try response(PermissionWire.response(id, .allow(updatedInput: edited), for: ask))["response"] as? [String: Any])
        #expect((body["updatedInput"] as? [String: Any])?["file_path"] as? String == "/Users/me/probe/other.txt")
    }

    @Test func answersAskUserQuestion() throws {
        let (id, ask) = try recordedAsk("can-use-tool-ask.jsonl")
        let body = try #require(try response(PermissionWire.answers(id, ["Tea or coffee?": ["Tea"]], for: ask))["response"] as? [String: Any])
        let input = try #require(body["updatedInput"] as? [String: Any])
        #expect(input["answers"] as? [String: String] == ["Tea or coffee?": "Tea"])
        #expect((input["questions"] as? [Any])?.count == 1)
    }

    @Test func errorResponseIsTheSafetyNet() throws {
        let r = try response(PermissionWire.error("r9", "unsupported"))
        #expect(r["subtype"] as? String == "error")
        #expect(r["request_id"] as? String == "r9")
        #expect(r["error"] as? String == "unsupported")
    }

    @Test func parsesSDKOnlyFieldsAndStripsANSI() {
        let request: [String: Any] = [
            "subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "rm -rf build"],
            "tool_use_id": "toolu_1", "agent_id": "a1", "decision_reason": "\u{1B}[1mask rule\u{1B}[0m matched",
            "default_to_no": true, "suppress_always_allow_rule": true, "blocked_path": "/etc",
        ]
        guard case .canUseTool(let ask) = PermissionWire.parse(request) else { Issue.record("not parsed"); return }
        #expect(ask.agentID == "a1")
        #expect(ask.decisionReason == "ask rule matched")
        #expect(ask.defaultToNo && ask.suppressAlwaysAllow)
        #expect(ask.blockedPath == "/etc")
        #expect(ask.suggestions == nil)
        #expect(ask.stringInput == ["command": "rm -rf build"])
    }

    @Test func parsesElicitation() {
        let request: [String: Any] = ["subtype": "elicitation", "mcp_server_name": "github", "message": "Sign in",
                                      "mode": "url", "url": "https://github.com/login", "elicitation_id": "e1"]
        #expect(PermissionWire.parse(request) == .elicitation(Elicitation(
            serverName: "github", message: "Sign in", mode: "url", url: URL(string: "https://github.com/login"), elicitationID: "e1")))
        #expect(PermissionWire.parse(["subtype": "request_user_dialog"]) == .other(subtype: "request_user_dialog"))
    }
}
