import BuddyBridge
import BuddyConversations
import BuddyCore
import Foundation

/// Rebuilds a conversation's turns from Claude Code's own session files, for full screen after a
/// relaunch or Resume. Our index keeps no transcripts; they stay in Claude Code's
/// session files, which this only reads (Forget and temporary mode already delete them).
///
/// v1 (Quick and Deep sessions): a turn is one Lumi prompt (a user line whose text starts
/// `<buddy-packet>`) and the last assistant message before the next prompt, if it ended the turn
/// (`stop_reason == "end_turn"`).
/// Cancelled turns (a `<synthetic>` reply), a last turn still running, replies without a decodable
/// `buddy` block and Quick's hand-offs to Deep are left out, as the app never shows them as answers:
/// only answers that were shown come back.
///
/// v2 (open sessions): a turn is a user line whose `uuid` Lumi recorded when it sent the turn
/// (the replayed echo), shown as Lumi recorded it. The answer is the last assistant message that
/// ended the turn: typed turns keep its Markdown, voice turns its buddy block when it has one, and
/// a turn without a block is kept rather than dropped. Meta lines, compact summaries, tool results,
/// task notifications and lines from another session never start a turn; subagent (sidechain) lines
/// only name the turn's teammates. The main thread is rebuilt by walking `parentUuid` back from the
/// last line, so a rewound or forked branch doesn't show.
/// The file format is Claude Code's, internal and undocumented: anything unexpected is skipped.
public struct TranscriptReader: Sendable {
    public let root: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")) {
        self.root = root
    }

    /// Every shown turn of the conversation, Quick, Deep (each folder's) and open sessions together,
    /// oldest first. `userTurns`: what Lumi recorded sending, which keys the open sessions' turns.
    public func turns(for record: ConversationRecord, userTurns: [UserTurnRecord] = []) -> [TranscriptTurn] {
        var found: [(at: String, turn: TranscriptTurn)] = []
        var approvedActionTurns: Set<String> = []
        var sessions = record.claudeSessions.map { ($0.sessionID, $0.role) }
        for (id, role) in [(record.quickSessionID, ClaudeRole.quick), (record.deepSessionID, .deepLegacy)] {
            if let id, !sessions.contains(where: { $0.0 == id }) { sessions.append((id, role)) }
        }
        for (id, role) in sessions {
            switch role {
            case .quick, .deepLegacy:
                let session = parse(session: id, mode: role == .quick ? .quick : .deep)
                found += session.turns
                approvedActionTurns.formUnion(session.approvedActions)
            case .open:
                found += parseOpen(session: id, userTurns: userTurns.filter { $0.sessionID == id })
            case .research:
                continue
            }
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

    /// An open session's turns, keyed on the user turns Lumi recorded for it.
    func parseOpen(session id: String, userTurns: [UserTurnRecord]) -> [(at: String, turn: TranscriptTurn)] {
        guard !userTurns.isEmpty, let file = sessionFile(id), let data = try? Data(contentsOf: file) else { return [] }
        let byUUID = Dictionary(userTurns.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let lines = data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let main = Self.mainThread(lines)
        // CLI 2.1.312 keeps subagent lines in `<id>/subagents/agent-*.jsonl`, named in each
        // `.meta.json`; the main file only has the Agent call (QA E8).
        let metaNames = Dictionary(subagentMetas(beside: file).map { ($0.toolUseID, $0.name) }, uniquingKeysWith: { a, _ in a })
        var result: [(String, TranscriptTurn)] = []
        var pending: (user: UserTurnRecord, at: String)?
        var reply = Reply()
        var teammates: [String] = []
        var changedFiles = false
        var lastTimestamp = ""
        func finish() {
            defer { pending = nil; reply = Reply(); teammates = []; changedFiles = false }
            guard let (user, at) = pending, !reply.cancelled, reply.stopReason == "end_turn" else { return }
            let prose = reply.texts.joined(separator: "\n")
            let extraction = BuddyBlockExtractor.extract(from: prose)
            let markdown = user.kind == .voice ? nil : prose
            let block = (user.kind == .voice ? extraction.block : nil)
                ?? BuddyBlock(say: Self.firstLine(extraction.prose.isEmpty ? prose : extraction.prose), shape: .rich)
            let model = reply.model.map(ModelID.init(rawValue:)) ?? ModeConfig.default(for: .deep).model
            result.append((at, TranscriptTurn(id: user.uuid, question: user.shown, block: block, mode: .deep, model: model,
                                              kind: user.kind, markdown: markdown, teammates: teammates,
                                              changedFiles: changedFiles)))
        }
        for line in lines {
            guard let type = line["type"] as? String, line["isMeta"] as? Bool != true, line["isCompactSummary"] as? Bool != true
            else { continue }
            if let other = line["sessionId"] as? String, other != id { continue }
            if line["isSidechain"] as? Bool == true {
                if pending != nil, let name = (line["agentName"] as? String) ?? (line["agentId"] as? String), !teammates.contains(name) {
                    teammates.append(name)
                }
                continue
            }
            if let uuid = line["uuid"] as? String, let main, !main.contains(uuid) { continue }
            if type == "user", let uuid = line["uuid"] as? String, let user = byUUID[uuid] {
                finish()
                let at = line["timestamp"] as? String ?? ""
                if !at.isEmpty { lastTimestamp = at }
                pending = (user, at.isEmpty ? lastTimestamp : at)
            } else if type == "assistant", pending != nil, let message = line["message"] as? [String: Any] {
                reply.add(message)
                for name in Self.agentNames(in: message, metaNames: metaNames) where !teammates.contains(name) {
                    teammates.append(name)
                }
                if Self.changesFiles(message) { changedFiles = true }
            }
        }
        finish()
        return result
    }

    /// Whether an assistant message calls a tool that edits or writes a file.
    static func changesFiles(_ message: [String: Any]) -> Bool {
        let content = message["content"] as? [[String: Any]] ?? []
        return content.contains { $0["type"] as? String == "tool_use" && fileTools.contains($0["name"] as? String ?? "") }
    }

    static let fileTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// Where an edited prompt goes back to.
    public enum PromptParent: Sendable, Equatable {
        /// The session's first line: there is nothing before it.
        case start
        /// The message just before the prompt (`--resume-session-at`).
        case message(String)
    }

    /// The prompt `uuid`'s parent in the open session's file. Nil when the file or the prompt isn't
    /// there, or a compaction came after it: a resume loads only from the last compaction on, so
    /// there is no message to go back to.
    public func promptParent(_ uuid: String, session id: String) -> PromptParent? {
        guard let file = sessionFile(id), let data = try? Data(contentsOf: file) else { return nil }
        var parent: PromptParent?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if parent == nil, object["uuid"] as? String == uuid, object["type"] as? String == "user" {
                parent = (object["parentUuid"] as? String).map(PromptParent.message) ?? .start
            } else if parent != nil, object["type"] as? String == "system", object["subtype"] as? String == "compact_boundary" {
                return nil
            }
        }
        return parent
    }

    /// The uuids on the thread that ends at the last main-thread line, walking `parentUuid`. Nil
    /// when the file has no parent links (older formats): every line counts.
    static func mainThread(_ lines: [[String: Any]]) -> Set<String>? {
        var parent: [String: String] = [:]
        var last: String?
        for line in lines where line["isSidechain"] as? Bool != true {
            guard let uuid = line["uuid"] as? String else { continue }
            // A compaction boundary has no parent; its logical parent carries the thread on, so the
            // turns before a compaction stay (QA E3).
            if let p = (line["parentUuid"] as? String) ?? (line["logicalParentUuid"] as? String) { parent[uuid] = p }
            last = uuid
        }
        guard !parent.isEmpty, var cursor = last else { return nil }
        var chain: Set<String> = [cursor]
        while let next = parent[cursor], chain.insert(next).inserted { cursor = next }
        return chain
    }

    /// The teammates an assistant message starts: each Agent (or Task) call's name, else its
    /// subagent file's name, else its description.
    static func agentNames(in message: [String: Any], metaNames: [String: String]) -> [String] {
        let content = message["content"] as? [[String: Any]] ?? []
        return content.compactMap { item in
            guard item["type"] as? String == "tool_use", ["Agent", "Task"].contains(item["name"] as? String ?? "") else { return nil }
            let input = item["input"] as? [String: Any] ?? [:]
            let named = (input["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return named ?? (item["id"] as? String).flatMap { metaNames[$0] } ?? (input["description"] as? String)
        }
    }

    /// One subagent's file, as CLI 2.1.312 keeps it beside the session's.
    public struct SubagentMeta: Sendable, Equatable {
        public var agentID: String
        public var toolUseID: String
        public var name: String
        public var description: String?
    }

    /// The `subagents/agent-*.meta.json` files beside `file` (`<id>.jsonl` → `<id>/subagents/`).
    func subagentMetas(beside file: URL) -> [SubagentMeta] {
        let dir = file.deletingPathExtension().appending(path: "subagents", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("agent-") && $0.hasSuffix(".meta.json") }.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: dir.appending(path: name)),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let toolUse = meta["toolUseId"] as? String else { return nil }
            let agentID = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
            let description = meta["description"] as? String
            return SubagentMeta(agentID: agentID, toolUseID: toolUse,
                                name: (meta["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? description ?? "Teammate",
                                description: description)
        }
    }

    /// A teammate's own transcript (its lane): its name and what it wrote, in order.
    public struct TeammateLane: Sendable, Equatable {
        public var name: String
        public var toolUseID: String
        public var texts: [String]
        /// Its tool steps and their results, timed from the file, mapped through StatusMapper.
        public var steps: [LaneHistory.Step] = []

        public var history: LaneHistory { LaneHistory(texts: texts, steps: steps) }
    }

    /// Every teammate's lane in an open session, from its subagent files.
    public func teammateLanes(session id: String) -> [TeammateLane] {
        guard UUID(uuidString: id) != nil, let file = sessionFile(id) else { return [] }
        let dir = file.deletingPathExtension().appending(path: "subagents", directoryHint: .isDirectory)
        return subagentMetas(beside: file).map { meta in
            let data = (try? Data(contentsOf: dir.appending(path: "agent-\(meta.agentID).jsonl"))) ?? Data()
            var texts: [String] = []
            var steps: [LaneHistory.Step] = []
            var reply = Reply()
            var lastAt = Date.distantPast
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                // The lane's earlier steps, as the live mapper would show them.
                if let at = (object["timestamp"] as? String).flatMap(Self.date) { lastAt = at }
                if let event = StreamEvent(line: Data(line)) {
                    steps += SessionEventMapper.historyEvents(event, lane: meta.toolUseID).map { LaneHistory.Step($0, at: lastAt) }
                }
                guard object["type"] as? String == "assistant", let message = object["message"] as? [String: Any] else { continue }
                let id = message["id"] as? String
                if id != reply.messageID, !reply.texts.isEmpty { texts.append(reply.texts.joined(separator: "\n")) }
                reply.add(message)
            }
            if !reply.texts.isEmpty { texts.append(reply.texts.joined(separator: "\n")) }
            return TeammateLane(name: meta.name, toolUseID: meta.toolUseID, texts: texts, steps: steps)
        }
    }

    /// A transcript line's ISO 8601 `timestamp` (with or without fractional seconds).
    static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    /// The first non-empty line of an answer, without Markdown heading or list marks.
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return String(line.drop { "#*-> ".contains($0) })
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
