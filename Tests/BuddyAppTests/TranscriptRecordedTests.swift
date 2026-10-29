@testable import BuddyApp
import BuddyConversations
import BuddyCore
import Foundation
import Testing

/// TranscriptReader on the layout CLI 2.1.312 writes, as seen in qa-engine's live runs (30-QA E3,
/// E8): the line types, the parent links through attachment and stop-hook lines, the compaction
/// boundary (`parentUuid: null`, `logicalParentUuid` → the line before), and subagents in
/// `<id>/subagents/agent-<agentId>.jsonl` with a `.meta.json`. Synthetic content, real shape.
struct TranscriptRecordedTests {
    final class File {
        var lines: [[String: Any]] = []
        var last: String?
        let session: String
        private var n = 0

        init(session: String) { self.session = session }

        @discardableResult
        func add(_ type: String, _ fields: [String: Any] = [:], uuid: String = UUID().uuidString.lowercased(),
                 parent: String?? = .none) -> String {
            n += 1
            var line: [String: Any] = ["type": type, "uuid": uuid, "sessionId": session, "isSidechain": false,
                                       "timestamp": String(format: "2026-10-28T14:%02d:%02dZ", n / 60, n % 60)]
            line["parentUuid"] = (parent ?? last).map { $0 as Any } ?? NSNull()
            for (k, v) in fields { line[k] = v }
            lines.append(line)
            last = uuid
            return uuid
        }

        /// A user turn as Lumi sends it, then the attachment lines the CLI adds after it.
        func user(_ text: String, uuid: String) {
            add("user", ["message": ["role": "user", "content": [["type": "text", "text": text]]]], uuid: uuid)
            add("attachment", ["attachment": ["type": "todo_reminder"]])
        }

        func assistant(_ content: [[String: Any]], id: String, stop: String?) {
            add("assistant", ["message": ["id": id, "model": "claude-haiku-5-5", "role": "assistant", "stop_reason": stop as Any,
                                          "content": content]])
        }

        func answer(_ text: String, id: String) {
            assistant([["type": "text", "text": text]], id: id, stop: "end_turn")
            add("system", ["subtype": "stop_hook_summary"])
        }

        func write(to url: URL) throws {
            let data = try lines.map { try JSONSerialization.data(withJSONObject: $0) }.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
            try data.write(to: url)
        }
    }

    private func projects() throws -> (root: URL, dir: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "recorded-\(UUID().uuidString)")
        let dir = root.appending(path: "projects/-Users-me-scratch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (root, dir)
    }

    private func record(_ session: String) -> ConversationRecord {
        var r = ConversationRecord(id: "s_1", title: "t", color: .ember, created: .now, lastUsed: .now)
        r.harness = .open
        r.claudeSessions = [ClaudeSessionRecord(sessionID: session, role: .open, created: .now)]
        return r
    }

    private func user(_ uuid: String, _ kind: TurnKind, _ shown: String, _ session: String) -> UserTurnRecord {
        UserTurnRecord(uuid: uuid, sessionID: session, kind: kind, shown: shown, at: .now)
    }

    private func block(_ say: String) -> String { "```buddy\n{\"say\": \"\(say)\", \"shape\": \"chip\"}\n```" }

    // QA E3: voice, voice, typed, /compact, voice: all four turns come back.
    @Test func turnsBeforeACompactionStay() throws {
        let (root, dir) = try projects()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let f = File(session: id)
        f.user("<lumi-voice>…</lumi-voice>", uuid: "u1"); f.answer(block("Four."), id: "m1")
        f.user("<lumi-voice>…</lumi-voice>", uuid: "u2"); f.answer(block("Six."), id: "m2")
        f.user("Reply with only a fenced python code block that prints hi.", uuid: "u3")
        f.answer("```python\nprint(\"hi\")\n```", id: "m3")
        let before = try #require(f.last)
        f.add("system", ["subtype": "compact_boundary", "logicalParentUuid": before], parent: .some(nil))
        f.add("user", ["isCompactSummary": true, "message": ["role": "user", "content": "This session is being continued…"]])
        f.add("user", ["isMeta": true, "message": ["role": "user", "content": "<local-command-caveat>…</local-command-caveat>"]])
        f.add("user", ["message": ["role": "user", "content": "<command-name>/compact</command-name>"]])
        f.add("user", ["message": ["role": "user", "content": "<local-command-stdout>Compacted </local-command-stdout>"]])
        f.user("<lumi-voice>…</lumi-voice>", uuid: "u4"); f.answer(block("Eight."), id: "m4")
        try f.write(to: dir.appending(path: id + ".jsonl"))

        let turns = TranscriptReader(root: root).turns(for: record(id), userTurns: [
            user("u1", .voice, "two plus two", id), user("u2", .voice, "three plus three", id),
            user("u3", .typed, "a python block", id), user("u4", .voice, "four plus four", id),
        ])
        #expect(turns.map(\.question) == ["two plus two", "three plus three", "a python block", "four plus four"])
        #expect([0, 1, 3].map { turns[$0].block.say } == ["Four.", "Six.", "Eight."])
        #expect(turns[2].markdown == "```python\nprint(\"hi\")\n```", "the typed turn keeps its fence")
    }

    // QA E8: a foreground Agent named scout lives in the subagent files; a rewound branch is hidden.
    @Test func teammatesAreNamedFromTheSubagentFilesAndTheirLanesRead() throws {
        let (root, dir) = try projects()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let f = File(session: id)
        f.user("Remember APPLE. Reply with just: ok", uuid: "u1"); f.answer("ok", id: "m1")
        f.user("Use the Agent tool once with name scout.", uuid: "u2")
        f.assistant([["type": "tool_use", "name": "Agent", "id": "toolu_scout",
                      "input": ["name": "scout", "description": "say hi", "prompt": "Reply with hi."]]], id: "m2", stop: "tool_use")
        f.add("user", ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_scout", "content": "hi"]]],
                       "toolUseResult": ["status": "completed", "agentId": "a63d"]])
        f.answer("scout said hi.", id: "m3")
        let fork = try #require(f.last)
        f.user("Forget APPLE. Remember BANANA.", uuid: "u3"); f.answer("ok", id: "m4")
        f.last = fork                                       // rewound: the thread goes on from the scout answer
        f.user("Which word did I ask you to remember?", uuid: "u4"); f.answer("APPLE", id: "m5")
        try f.write(to: dir.appending(path: id + ".jsonl"))

        let sub = dir.appending(path: "\(id)/subagents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let meta: [String: Any] = ["agentType": "general-purpose", "isBuiltIn": true, "description": "say hi", "name": "scout",
                                   "toolUseId": "toolu_scout", "spawnDepth": 1, "requestShape": "foreground", "finished": true]
        try JSONSerialization.data(withJSONObject: meta).write(to: sub.appending(path: "agent-a63d.meta.json"))
        let lane = File(session: id)
        lane.add("user", ["isSidechain": true, "agentId": "a63d", "message": ["role": "user", "content": "Reply with hi."]], parent: .some(nil))
        lane.add("assistant", ["isSidechain": true, "agentId": "a63d",
                               "message": ["id": "s0", "role": "assistant", "content": [
                                   ["type": "tool_use", "id": "toolu_ls", "name": "Bash", "input": ["command": "ls", "description": "List files"]]]]])
        lane.add("user", ["isSidechain": true, "agentId": "a63d", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "toolu_ls", "content": "a.txt", "is_error": false]]]])
        lane.add("assistant", ["isSidechain": true, "agentId": "a63d",
                               "message": ["id": "s1", "role": "assistant", "content": [["type": "text", "text": "hi"]]]])
        try lane.write(to: sub.appending(path: "agent-a63d.jsonl"))

        let reader = TranscriptReader(root: root)
        let turns = reader.turns(for: record(id), userTurns: [
            user("u1", .typed, "remember apple", id), user("u2", .typed, "ask scout", id),
            user("u3", .typed, "now banana", id), user("u4", .typed, "which word", id),
        ])
        #expect(turns.map(\.question) == ["remember apple", "ask scout", "which word"], "the rewound branch is hidden")
        #expect(turns[1].teammates == ["scout"])
        #expect(turns[0].teammates.isEmpty)
        let lanes = reader.teammateLanes(session: id)
        #expect(lanes.map(\.name) == ["scout"] && lanes.first?.texts == ["hi"])
        // The lane's earlier steps, mapped as the live stream maps them, at the file's times.
        let steps = try #require(lanes.first?.steps)
        #expect(steps.count == 2)
        guard case .step(let step) = steps[0].event, case .stepFinished(let done, let failed, _) = steps[1].event else {
            Issue.record("expected a step and its result"); return
        }
        #expect(step.id == "toolu_ls" && step.kind == .bash && step.subagent == "toolu_scout")
        #expect(done == "toolu_ls" && !failed)
        #expect(steps[0].at < steps[1].at && steps[0].at > Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func agentNamesComeFromTheCallThenTheMetaThenTheDescription() {
        let call: (String?, String) -> [String: Any] = { name, id in
            var input: [String: Any] = ["description": "find hotels"]
            if let name { input["name"] = name }
            return ["type": "tool_use", "name": "Agent", "id": id, "input": input]
        }
        let message: [String: Any] = ["content": [call("scout", "t1"), call(nil, "t2"), call(nil, "t3"),
                                                  ["type": "tool_use", "name": "Bash", "id": "t4", "input": [:] as [String: Any]]]]
        #expect(TranscriptReader.agentNames(in: message, metaNames: ["t2": "writer"]) == ["scout", "writer", "find hotels"])
    }
}
