import BuddyBridge
import BuddyConversations
import BuddyCore
import Foundation

/// Rebuilds a conversation's turns from Claude Code's own session files, for full screen after a
/// relaunch or Resume. Our index keeps no transcripts; they stay in Claude Code's
/// session files, which this only reads (Forget and temporary mode already delete them).
///
/// A turn is one Lumi prompt (a user line whose text starts `<buddy-packet>`) and the last
/// assistant message before the next prompt, if it ended the turn (`stop_reason == "end_turn"`).
/// Cancelled turns (a `<synthetic>` reply), a last turn still running, replies without a decodable
/// `buddy` block and Quick's hand-offs to Deep are left out, as the app never shows them as answers:
/// only answers that were shown come back.
/// The file format is Claude Code's, internal and undocumented: anything unexpected is skipped.
public struct TranscriptReader: Sendable {
    public let root: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")) {
        self.root = root
    }

    /// Every shown turn of the conversation, Quick and Deep together, oldest first.
    public func turns(for record: ConversationRecord) -> [TranscriptTurn] {
        var found: [(at: String, turn: TranscriptTurn)] = []
        var approvedActionTurns: Set<String> = []
        for (id, mode) in [(record.quickSessionID, Mode.quick), (record.deepSessionID, Mode.deep)] {
            guard let id else { continue }
            let session = parse(session: id, mode: mode)
            found += session.turns
            approvedActionTurns.formUnion(session.approvedActions)
        }
        // ISO 8601 timestamps sort as text; the order inside one file is kept for equal times.
        let ordered = found.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
        // A pressed action's prompt is model-written and never shown: the transcript shows the
        // button's label, as the app did. With no matching button earlier, the turn is left out.
        var shown: [TranscriptTurn] = []
        for (_, turn) in ordered {
            guard approvedActionTurns.contains(Self.key(turn)) else { shown.append(turn); continue }
            guard let label = shown.reversed().lazy
                .compactMap({ $0.block.actions.first { $0.prompt == turn.question }?.label }).first
            else { continue }
            var relabelled = turn
            relabelled.question = label
            shown.append(relabelled)
        }
        return shown
    }

    /// The shown turns of one session, in file order, with each prompt's timestamp.
    func turns(session id: String, mode: Mode) -> [(at: String, turn: TranscriptTurn)] {
        parse(session: id, mode: mode).turns
    }

    /// The session's turns, and which of them were a pressed action (`<approved-action/>`).
    func parse(session id: String, mode: Mode) -> (turns: [(at: String, turn: TranscriptTurn)], approvedActions: Set<String>) {
        guard let file = sessionFile(id), let data = try? Data(contentsOf: file) else { return ([], []) }
        var result: [(String, TranscriptTurn)] = []
        var approved: Set<String> = []
        var lastTimestamp = ""
        var pending: Prompt?
        var reply = Reply()
        func finish() {
            defer { pending = nil; reply = Reply() }
            guard let prompt = pending, !reply.cancelled, reply.stopReason == "end_turn",
                  let block = BuddyBlockExtractor.extract(from: reply.texts.joined(separator: "\n")).block,
                  // A hand-off is Quick's promise, not an answer: the app shows Deep's reply instead.
                  block.handoff == nil
            else { return }
            let model = reply.model.map(ModelID.init(rawValue:)) ?? ModeConfig.default(for: mode).model
            if prompt.approvedAction { approved.insert("\(mode)/\(prompt.id)") }
            result.append((prompt.at, TranscriptTurn(id: prompt.id, question: prompt.question, block: block,
                                                     mode: mode, model: model)))
        }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "user", var prompt = Prompt(object) {
                finish()
                // A line without a time keeps its file's order rather than sorting first.
                if prompt.at.isEmpty { prompt.at = lastTimestamp } else { lastTimestamp = prompt.at }
                pending = prompt
            } else if type == "assistant", pending != nil, let message = object["message"] as? [String: Any] {
                reply.add(message)
            }
        }
        finish()
        return (result, approved)
    }

    /// Prompt ids are per session file, so a turn is keyed by its lane too.
    static func key(_ turn: TranscriptTurn) -> String { "\(turn.mode)/\(turn.id)" }

    /// `projects/<encoded cwd>/<id>.jsonl`, found by ID (encoded paths can be hashed).
    func sessionFile(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        let projects = root.appending(path: "projects", directoryHint: .isDirectory)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return dirs.lazy.map { $0.appending(path: id + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A Lumi prompt line.
    struct Prompt {
        let id: String
        var at: String
        let question: String
        /// The engine marked it as a pressed action: `question` is the action's hidden prompt.
        let approvedAction: Bool

        init?(_ line: [String: Any]) {
            guard line["isMeta"] as? Bool != true, line["isCompactSummary"] as? Bool != true,
                  let id = line["uuid"] as? String,
                  let message = line["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]],
                  let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
                  text.hasPrefix("<buddy-packet>"),
                  let question = Self.question(in: text)
            else { return nil }
            self.id = id
            self.at = line["timestamp"] as? String ?? ""
            self.question = question
            approvedAction = text.contains("<approved-action/>")
        }

        /// The text between the first `<question>` after the packet and the next `</question>`,
        /// unescaped (`BuddyPrompt.escape` escapes `&`, `<` and `>`, so the tags can't occur inside).
        static func question(in text: String) -> String? {
            guard let packetEnd = text.range(of: "</buddy-packet>"),
                  let open = text.range(of: "<question>", range: packetEnd.upperBound..<text.endIndex),
                  let close = text.range(of: "</question>", range: open.upperBound..<text.endIndex)
            else { return nil }
            return unescape(String(text[open.upperBound..<close.lowerBound]))
        }

        static func unescape(_ text: String) -> String {
            text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
        }
    }

    /// The latest assistant message of the turn so far (one message can span several lines).
    struct Reply {
        var messageID: String?
        var texts: [String] = []
        var stopReason: String?
        var model: String?
        var cancelled = false

        mutating func add(_ message: [String: Any]) {
            let model = message["model"] as? String
            if model == "<synthetic>" {
                cancelled = true
                return
            }
            let id = message["id"] as? String
            if id != messageID {
                messageID = id
                texts = []
                stopReason = nil
            }
            self.model = model ?? self.model
            stopReason = message["stop_reason"] as? String ?? stopReason
            let content = message["content"] as? [[String: Any]] ?? []
            texts += content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
    }
}
