@testable import BuddyApp
import BuddyConversations
import BuddyCore
import Foundation
import Testing

/// Open sessions in Claude Code's line format (synthetic; no real transcripts).
struct TranscriptReaderV2Tests {
    let session = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    final class Lines {
        var lines: [[String: Any]] = []
        private var last: String?
        private var second = 0

        @discardableResult
        func add(_ line: [String: Any], uuid: String = UUID().uuidString, parent: String? = nil, sidechain: Bool = false) -> String {
            var line = line
            line["uuid"] = uuid
            line["parentUuid"] = parent ?? last as Any
            line["isSidechain"] = sidechain
            second += 1
            line["timestamp"] = String(format: "2026-10-28T10:00:%02dZ", second)
            lines.append(line)
            if !sidechain { last = uuid }
            return uuid
        }

        func user(_ text: String, uuid: String) {
            add(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]], uuid: uuid)
        }

        func assistant(_ text: String, id: String, stop: String? = "end_turn") {
            add(["type": "assistant", "message": ["id": id, "model": "claude-opus-5-5", "stop_reason": stop as Any,
                                                  "content": [["type": "text", "text": text]]]])
        }

        func write(_ dir: URL, _ id: String) throws {
            let data = try lines.map { try JSONSerialization.data(withJSONObject: $0) }.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
            try data.write(to: dir.appending(path: id + ".jsonl"))
        }
    }

    private func setUp() throws -> (root: URL, dir: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "transcripts-v2-\(UUID().uuidString)")
        let dir = root.appending(path: "projects/-Users-me")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (root, dir)
    }

    private func record() -> ConversationRecord {
        var r = ConversationRecord(id: "s_1", title: "t", color: .ember, created: .now, lastUsed: .now)
        r.harness = .open
        r.claudeSessions = [ClaudeSessionRecord(sessionID: session, role: .open, created: .now)]
        return r
    }

    private func user(_ uuid: String, _ kind: TurnKind, _ shown: String) -> UserTurnRecord {
        UserTurnRecord(uuid: uuid, sessionID: session, kind: kind, shown: shown, at: .now)
    }

    @Test func typedTurnsKeepTheirMarkdownAndVoiceTurnsTheirBlock() throws {
        let (root, dir) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let l = Lines()
        l.user("fix the build", uuid: "u1")
        l.assistant("Looking.", id: "m1", stop: "tool_use")
        l.add(["type": "user", "message": ["content": [["type": "tool_result", "content": "ok"]]]])
        l.assistant("## Fixed\n\n```swift\nlet x = 1\n```", id: "m2")
        l.user("<lumi-voice>…</lumi-voice>", uuid: "u2")
        l.assistant("Done.\n```buddy\n{\"say\":\"It builds now.\",\"shape\":\"chip\"}\n```", id: "m3")
        l.user("<lumi-voice>…</lumi-voice>", uuid: "u3")
        l.assistant("No block, just prose.", id: "m4")
        try l.write(dir, session)

        let turns = TranscriptReader(root: root).turns(for: record(), userTurns: [
            user("u1", .typed, "fix the build"), user("u2", .voice, "does it build"), user("u3", .voice, "and now"),
        ])
        #expect(turns.map(\.question) == ["fix the build", "does it build", "and now"])
        #expect(turns[0].markdown == "## Fixed\n\n```swift\nlet x = 1\n```", "code fences are kept for typed turns")
        #expect(turns[0].kind == .typed && turns[0].block.say == "Fixed")
        #expect(turns[1].markdown == nil && turns[1].block.say == "It builds now.")
        #expect(turns[2].block.say == "No block, just prose.", "a voice turn without a block is kept")
    }

    @Test func linesThatArentLumisTurnsNeverStartOne() throws {
        let (root, dir) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let l = Lines()
        l.user("hello", uuid: "u1")
        l.add(["type": "user", "isMeta": true, "message": ["content": [["type": "text", "text": "meta"]]]], uuid: "meta")
        l.add(["type": "user", "isCompactSummary": true, "message": ["content": [["type": "text", "text": "summary"]]]], uuid: "sum")
        l.add(["type": "user", "message": ["content": [["type": "text", "text": "<task-notification>done</task-notification>"]]]])
        l.add(["type": "user", "sessionId": "other", "message": ["content": [["type": "text", "text": "elsewhere"]]]], uuid: "x")
        l.assistant("Hi there.", id: "m1")
        try l.write(dir, session)
        let turns = TranscriptReader(root: root).turns(for: record(), userTurns: [user("u1", .typed, "hello")])
        #expect(turns.map(\.markdown) == ["Hi there."])
    }

    @Test func sidechainLinesNameTeammatesAndARewoundBranchIsDropped() throws {
        let (root, dir) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let l = Lines()
        l.user("split this up", uuid: "u1")
        let branch = l.lines.last?["uuid"] as? String
        l.add(["type": "assistant", "agentName": "scout", "message": ["id": "s1", "content": [["type": "text", "text": "…"]]]], sidechain: true)
        l.add(["type": "assistant", "agentName": "scout", "message": ["id": "s2", "content": [["type": "text", "text": "…"]]]], sidechain: true)
        l.add(["type": "assistant", "agentName": "writer", "message": ["id": "s3", "content": [["type": "text", "text": "…"]]]], sidechain: true)
        l.assistant("Both done.", id: "m1")
        // A rewound attempt: a turn on a branch the main thread no longer reaches.
        l.add(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "abandoned"]]]], uuid: "u2", parent: branch)
        l.add(["type": "assistant", "message": ["id": "m2", "stop_reason": "end_turn", "content": [["type": "text", "text": "old"]]]], parent: "u2")
        // The thread continues from the first answer.
        let answer = l.lines.first { ($0["message"] as? [String: Any])?["id"] as? String == "m1" }?["uuid"] as? String
        l.add(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "next"]]]], uuid: "u3", parent: answer)
        l.assistant("Next answer.", id: "m3")
        try l.write(dir, session)

        let turns = TranscriptReader(root: root).turns(for: record(), userTurns: [
            user("u1", .typed, "split this up"), user("u2", .typed, "abandoned"), user("u3", .typed, "next"),
        ])
        #expect(turns.map(\.question) == ["split this up", "next"])
        #expect(turns.first?.teammates == ["scout", "writer"])
    }

    /// An edited prompt goes back to its parent line; the first prompt has none, and a prompt a
    /// compaction came after can't be gone back to. Turns that edited or wrote files say so.
    @Test func promptParentsAndFileChanges() throws {
        let (root, dir) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let l = Lines()
        l.user("first", uuid: "u1")
        l.add(["type": "assistant", "message": ["id": "m1", "stop_reason": "tool_use",
                                                "content": [["type": "tool_use", "name": "Edit", "id": "t1", "input": [:]]]]])
        l.assistant("Edited.", id: "m2")
        let attachment = l.add(["type": "attachment"])
        l.user("second", uuid: "u2")
        l.assistant("Plain.", id: "m3")
        try l.write(dir, session)
        let reader = TranscriptReader(root: root)
        #expect(reader.promptParent("u1", session: session) == .start)
        #expect(reader.promptParent("u2", session: session) == .message(attachment))
        #expect(reader.promptParent("missing", session: session) == nil)
        let turns = reader.turns(for: record(), userTurns: [user("u1", .typed, "first"), user("u2", .typed, "second")])
        #expect(turns.map(\.changedFiles) == [true, false])

        l.add(["type": "system", "subtype": "compact_boundary"])
        try l.write(dir, session)
        #expect(reader.promptParent("u2", session: session) == nil)
    }

    @Test func v1AndOpenSessionsOfOneSessionComeBackTogether() throws {
        let (root, dir) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let quick = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let v1 = Lines()
        v1.add(["type": "user", "message": ["role": "user", "content": [["type": "text",
            "text": "<buddy-packet>\n{}\n</buddy-packet>\n<question>first, on Quick</question>"]]]], uuid: "q1")
        v1.assistant("```buddy\n{\"say\":\"Quick answer.\",\"shape\":\"chip\"}\n```", id: "qa")
        try v1.write(dir, quick)
        let open = Lines()
        open.user("<quick-note>…</quick-note> continue", uuid: "u1")
        open.assistant("Continued.", id: "m1")
        // Later than the Quick turn.
        open.lines = open.lines.map { var l = $0; l["timestamp"] = "2026-10-28T11:00:00Z"; return l }
        try open.write(dir, session)
        var r = record()
        r.claudeSessions.insert(ClaudeSessionRecord(sessionID: quick, role: .quick, created: .now), at: 0)
        let turns = TranscriptReader(root: root).turns(for: r, userTurns: [user("u1", .typed, "continue")])
        #expect(turns.map(\.question) == ["first, on Quick", "continue"])
        #expect(turns.map(\.block.say) == ["Quick answer.", "Continued."])
    }
}
