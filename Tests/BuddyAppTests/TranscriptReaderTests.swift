@testable import BuddyApp
@testable import BuddyBridge
import BuddyConversations
import BuddyCore
import Foundation
import Testing

/// Synthetic session files in Claude Code's line format (no real transcripts).
struct TranscriptReaderTests {
    final class Session {
        var lines: [[String: Any]] = []
        private var n = 0

        func prompt(_ question: String, at second: Int?, image: Bool = false, approved: Bool = false) {
            n += 1
            var text = "<buddy-packet>\n{\"utterance\":\"…\"}\n</buddy-packet>\n<question>" + BuddyPrompt.escape(question) + "</question>"
            if approved { text += "\n<quick-note>…</quick-note>\n<approved-action/>" }
            var content: [[String: Any]] = [["type": "text", "text": text]]
            if image { content.insert(["type": "image", "source": [:] as [String: Any]], at: 0) }
            var line: [String: Any] = ["type": "user", "uuid": "u\(n)", "message": ["role": "user", "content": content]]
            if let second { line["timestamp"] = String(format: "2026-10-14T10:00:%02dZ", second) }
            lines.append(line)
            // Claude Code's companion meta line, which must not start a turn.
            lines.append(["type": "user", "isMeta": true, "uuid": "m\(n)",
                          "message": ["role": "user", "content": [["type": "text", "text": "<buddy-packet> meta"]]]])
        }

        func assistant(id: String, _ items: [[String: Any]], stop: String?, model: String = "claude-haiku-5-5") {
            for item in items {
                lines.append(["type": "assistant", "uuid": UUID().uuidString,
                              "message": ["id": id, "model": model, "stop_reason": stop as Any, "content": [item]]])
            }
        }

        func answer(_ say: String, id: String, model: String = "claude-haiku-5-5") {
            assistant(id: id, [["type": "thinking", "thinking": "…"],
                               ["type": "text", "text": "```buddy\n{\"say\":\"\(say)\",\"shape\":\"chip\"}\n```"]],
                      stop: "end_turn", model: model)
        }

        func write(to dir: URL, id: String) throws {
            let data = try lines.map { try JSONSerialization.data(withJSONObject: $0) }
                .reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
            try data.write(to: dir.appending(path: id + ".jsonl"))
        }
    }

    private func root() throws -> (root: URL, home: URL, project: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "transcripts-\(UUID().uuidString)")
        let home = root.appending(path: "projects/-Users-me"), project = root.appending(path: "projects/-Users-me-Developer-web")
        for d in [home, project] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        return (root, home, project)
    }

    @Test func shownTurnsComeBackInOrderWithTheirQuestionBlockAndModel() throws {
        let (root, home, _) = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = Session()
        s.prompt("why is <this> list empty & stale?", at: 1, image: true)
        s.answer("Your filter drops last week.", id: "a1")
        s.prompt("loosen it", at: 2)
        // A tool round first: its text isn't the answer.
        s.assistant(id: "a2", [["type": "text", "text": "Let me check."], ["type": "tool_use", "name": "Read"]], stop: "tool_use")
        s.lines.append(["type": "user", "message": ["content": [["type": "tool_result", "content": "…"]]]])
        s.answer("Loosened to 14 days.", id: "a3")
        let quick = UUID().uuidString
        try s.write(to: home, id: quick)

        let turns = TranscriptReader(root: root).turns(for: ConversationRecord(
            id: "c1", title: "t", color: .ember, created: .now, lastUsed: .now, quickSessionID: quick))
        #expect(turns.map(\.question) == ["why is <this> list empty & stale?", "loosen it"])
        #expect(turns.map(\.block.say) == ["Your filter drops last week.", "Loosened to 14 days."])
        #expect(turns.map(\.id) == ["u1", "u2"] && turns.allSatisfy { $0.mode == .quick && $0.model == .haiku })
    }

    @Test func cancelledUnfinishedAndBlocklessTurnsAreLeftOut() throws {
        let (root, home, _) = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = Session()
        s.prompt("cancelled one", at: 1)
        s.assistant(id: "x", [["type": "text", "text": "No response requested."]], stop: "stop_sequence", model: "<synthetic>")
        s.prompt("no block", at: 2)
        s.assistant(id: "b", [["type": "text", "text": "plain prose"]], stop: "end_turn")
        s.prompt("shown", at: 3)
        s.answer("Here.", id: "c")
        s.prompt("still running", at: 4)
        s.assistant(id: "d", [["type": "thinking", "thinking": "…"]], stop: nil)
        let id = UUID().uuidString
        try s.write(to: home, id: id)
        #expect(TranscriptReader(root: root).turns(session: id, mode: .quick).map(\.turn.question) == ["shown"])
    }

    @Test func aHandoffToDeepIsNotATurnButDeepsAnswerIs() throws {
        let (root, home, project) = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let q = Session(), d = Session()
        q.prompt("why is this list empty?", at: 1)
        q.assistant(id: "h", [["type": "text", "text": "```buddy\n{\"say\":\"Let me check the repo.\",\"shape\":\"chip\",\"handoff\":\"deep\"}\n```"]],
                    stop: "end_turn")
        d.prompt("why is this list empty?", at: 2)
        d.answer("Your date filter drops last week.", id: "d1", model: "claude-opus-5-5")
        let qid = UUID().uuidString, did = UUID().uuidString
        try q.write(to: home, id: qid)
        try d.write(to: project, id: did)
        let turns = TranscriptReader(root: root).turns(for: ConversationRecord(
            id: "c", title: "t", color: .sage, created: .now, lastUsed: .now, quickSessionID: qid, deepSessionID: did))
        #expect(turns.map(\.block.say) == ["Your date filter drops last week."] && turns.first?.mode == .deep)
    }

    @Test func aPressedActionShowsItsButtonLabelNotItsPrompt() throws {
        let (root, home, project) = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let q = Session(), d = Session()
        q.prompt("why is this list empty?", at: 1)
        q.assistant(id: "a", [["type": "text", "text": "```buddy\n{\"say\":\"The filter.\",\"shape\":\"card\",\"actions\":[{\"label\":\"Loosen it\",\"prompt\":\"Change the date filter in web/list.ts to 14 days\"}]}\n```"]],
                    stop: "end_turn")
        d.prompt("Change the date filter in web/list.ts to 14 days", at: 2, approved: true)
        d.answer("Done.", id: "d1", model: "claude-opus-5-5")
        d.prompt("a hidden prompt with no button", at: 3, approved: true)
        d.answer("Done too.", id: "d2", model: "claude-opus-5-5")
        let qid = UUID().uuidString, did = UUID().uuidString
        try q.write(to: home, id: qid)
        try d.write(to: project, id: did)
        let turns = TranscriptReader(root: root).turns(for: ConversationRecord(
            id: "c", title: "t", color: .sage, created: .now, lastUsed: .now, quickSessionID: qid, deepSessionID: did))
        #expect(turns.map(\.question) == ["why is this list empty?", "Loosen it"], "the label, and no unmatched hidden prompt")
    }

    @Test func aTurnWithoutATimeKeepsItsPlaceInItsFile() throws {
        let (root, home, project) = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let q = Session(), d = Session()
        q.prompt("first", at: 1); q.answer("1", id: "q1")
        q.prompt("third", at: nil); q.answer("3", id: "q2")
        d.prompt("second", at: 2); d.answer("2", id: "d1")
        let qid = UUID().uuidString, did = UUID().uuidString
        try q.write(to: home, id: qid)
        try d.write(to: project, id: did)
        let turns = TranscriptReader(root: root).turns(for: ConversationRecord(
            id: "c", title: "t", color: .sage, created: .now, lastUsed: .now, quickSessionID: qid, deepSessionID: did))
        #expect(turns.first?.question == "first", "not sorted ahead of everything")
    }

    @Test func quickAndDeepSessionsMergeByTime() throws {
        let (root, home, project) = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let q = Session(), d = Session()
        q.prompt("first", at: 1); q.answer("1", id: "q1")
        d.prompt("second", at: 2); d.answer("2", id: "d1", model: "claude-opus-5-5")
        q.prompt("third", at: 3); q.answer("3", id: "q2")
        let qid = UUID().uuidString, did = UUID().uuidString
        try q.write(to: home, id: qid)
        try d.write(to: project, id: did)
        let turns = TranscriptReader(root: root).turns(for: ConversationRecord(
            id: "c", title: "t", color: .sage, created: .now, lastUsed: .now, quickSessionID: qid, deepSessionID: did))
        #expect(turns.map(\.question) == ["first", "second", "third"])
        #expect(turns.map(\.mode) == [.quick, .deep, .quick] && turns[1].model == .opus)
    }

    @Test func aMissingFileOrABadIDGivesNothing() throws {
        let (root, _, _) = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = TranscriptReader(root: root)
        #expect(reader.turns(session: UUID().uuidString, mode: .quick).isEmpty)
        #expect(reader.sessionFile("../../etc/passwd") == nil, "only plain session IDs are looked up")
    }
}

/// Opt-in: `BUDDYAPP_LIVE_TRANSCRIPTS=1 Scripts/test.sh --filter LiveTranscripts`. Reads this Mac's
/// real Lumi sessions and prints counts only, never content, to check the format still holds.
struct LiveTranscriptsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUDDYAPP_LIVE_TRANSCRIPTS"] == "1"))
    func realSessionsParse() throws {
        let reader = TranscriptReader()
        let projects = reader.root.appending(path: "projects")
        var files = 0, prompts = 0, turns = 0
        for dir in (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "jsonl" {
                guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains("<buddy-packet>") else { continue }
                files += 1
                prompts += text.components(separatedBy: "\"isMeta\":true").count >= 0
                    ? text.components(separatedBy: "\"promptSource\":\"sdk\"").count - 1 : 0
                turns += reader.turns(session: file.deletingPathExtension().lastPathComponent, mode: .quick).count
            }
        }
        print("LIVE transcripts: files=\(files) sdkPrompts=\(prompts) shownTurns=\(turns)")
        #expect(files == 0 || turns > 0, "Lumi sessions exist but no turn was read")
    }
}
