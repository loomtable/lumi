import Foundation

/// Lumi's handle for a session. v1 rows keep their "c_<uuid>" ids; new sessions are "s_<uuid>".
public struct SessionID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    /// "s_" + a lowercased UUID.
    public static func new() -> SessionID { SessionID(rawValue: "s_" + UUID().uuidString.lowercased()) }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Which Claude Code harness a session's turns run in. The system prompt is snapshotted on the
/// first request, so this is fixed per Claude session, never toggled.
public enum Harness: String, Sendable, Codable, CaseIterable {
    /// The buddy-quick agent plus Lumi's rules (voice prelude; v1 Quick-only rows).
    case quick
    /// The user's full Claude Code; Lumi's voice layer is added to voice turns only.
    case open
    /// A v1 session with Lumi's Deep prompt: read-only. Continue starts a new open session.
    case legacy
}

/// How a user turn reached the session. It decides the input builder, the answer surface and
/// whether the buddy block is extracted.
public enum TurnKind: String, Sendable, Codable, CaseIterable {
    /// The talk key with no Lumi page on screen: `<lumi-voice>` envelope, Glance.
    case voice
    /// The talk key while the Panel or Studio shows the session: typed semantics (owner).
    case voiceInPage
    /// The text box, or the Panel or Studio composer: raw text, rendered in the page.
    case typed
    /// Typed while the turn runs.
    case steer
    /// "The user says to @name: …", relayed to a teammate through the lead.
    case relay
    /// A card's action button (an approved action).
    case action
}

/// A Lumi page that shows one session: the Panel or the Studio's column.
public enum PageKind: String, Sendable, Equatable {
    case panel, studio
}

/// A determinate step count for the thinking line ("3/5"), from the session's todo list.
public struct StepProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

public enum SessionStatus: Sendable, Equatable {
    case idle
    case thinking(since: Date, progress: StepProgress?)
    case needsYou(NeedsYou)
    case done(at: Date, unread: Bool)
    case failed(SessionFailure)
    /// Lumi quit mid-turn: "Interrupted · Continue".
    case interrupted(at: Date)
}

public struct NeedsYou: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Real: a `can_use_tool` control request is pending.
        case permission(PermissionAsk)
        /// AskUserQuestion or an elicitation.
        case question(QuestionAsk)
        /// The answer's buddy block asks the user something (`asks_user`).
        case soft(String)
    }

    public var kind: Kind
    public var since: Date
    /// The user has seen the ask (its card in a page or the Glance): it still waits, but asks for
    /// no more attention (amber, reminder) anywhere else.
    public var seen: Bool

    public init(kind: Kind, since: Date, seen: Bool = false) {
        self.kind = kind
        self.since = since
        self.seen = seen
    }
}

public struct PermissionAsk: Sendable, Equatable, Identifiable {
    /// The control request's `request_id`.
    public var id: String
    /// "Edit budget-notes.md", "Run npm test".
    public var title: String
    public var toolName: String
    public var detail: PermissionDetail
    public var tier: ApprovalTier
    /// The teammate's name when a subagent asks.
    public var asker: String?

    public init(id: String, title: String, toolName: String, detail: PermissionDetail, tier: ApprovalTier, asker: String? = nil) {
        self.id = id
        self.title = title
        self.toolName = toolName
        self.detail = detail
        self.tier = tier
        self.asker = asker
    }
}

extension PermissionAsk {
    /// What goes out, exactly (inspire #5): the command's first line, the file with its changed
    /// lines ("budget.md +3 −1", counted as the diff tile counts them), the address. The card's
    /// first line.
    public var payload: String {
        switch detail {
        case .command(let command):
            let first = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
            return first.trimmingCharacters(in: .whitespaces).isEmpty ? title : first.trimmingCharacters(in: .whitespaces)
        case .diff(let path, let old, let new):
            let name = URL(fileURLWithPath: path).lastPathComponent
            let changed = Self.changedLines(old: old, new: new)
            return "\(name.isEmpty ? title : name) +\(changed.added) −\(changed.removed)"
        case .url(let url):
            return url.absoluteString
        case .plain:
            return title
        }
    }

    /// Why, in the agent's words, as plain text: the card's second line. Nil when it says no
    /// more than the payload ("Edit budget.md", "Run `npm publish`" for `npm publish --access
    /// public`).
    public var reason: String? {
        switch detail {
        case .command:
            let said = MarkdownPreview.line(title)
            let bare = said.hasPrefix("Run ") ? String(said.dropFirst(4)) : said
            let out = payload
            return bare.isEmpty || out.hasPrefix(bare) || bare.hasPrefix(out) || said.contains(out.prefix(24)) ? nil : said
        case .diff, .url:
            return nil
        case .plain(let text):
            let text = MarkdownPreview.line(text)
            return text.isEmpty || text == title || text == toolName ? nil : text
        }
    }

    /// Lines added and removed, by the same line diff the diff tile draws (`DiffModel`).
    static func changedLines(old: String, new: String) -> (added: Int, removed: Int) {
        func lines(_ s: String) -> [Substring] { s.isEmpty ? [] : s.split(separator: "\n", omittingEmptySubsequences: false) }
        let diff = lines(new).difference(from: lines(old))
        return (diff.insertions.count, diff.removals.count)
    }
}

/// What an approval card shows.
public enum PermissionDetail: Sendable, Equatable {
    case diff(path: String, old: String, new: String)
    case command(String)
    case url(URL)
    case plain(String)
}

/// An AskUserQuestion (1–4 questions, 2–4 options each) or an elicitation.
public struct QuestionAsk: Sendable, Equatable, Identifiable {
    public struct Item: Sendable, Equatable {
        public var question: String
        /// At most 12 characters.
        public var header: String
        public var options: [Option]
        public var multiSelect: Bool

        public init(question: String, header: String, options: [Option], multiSelect: Bool = false) {
            self.question = question
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
        }
    }

    public struct Option: Sendable, Equatable {
        public var label: String
        public var description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    /// The control request's `request_id`.
    public var id: String
    public var items: [Item]
    public var asker: String?

    public init(id: String, items: [Item], asker: String? = nil) {
        self.id = id
        self.items = items
        self.asker = asker
    }
}

public struct SessionFailure: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case rateLimited(resetsAt: Date?)
        case crashed
        case api(String)
        case auth
        case unavailable(String)
    }

    public var reason: Reason
    /// "Couldn't finish: <step>".
    public var lastStep: String?
    public var retryable: Bool

    public init(reason: Reason, lastStep: String? = nil, retryable: Bool) {
        self.reason = reason
        self.lastStep = lastStep
        self.retryable = retryable
    }
}

/// Where the session came from: the routing context key, the origin badge and the
/// delivered-in-place target.
public struct SessionOrigin: Sendable, Equatable, Codable {
    public var key: ContextKey
    public var appName: String?
    public var windowTitle: String?
    /// For "the user is on the origin window".
    public var windowNumber: Int?

    public init(key: ContextKey, appName: String? = nil, windowTitle: String? = nil, windowNumber: Int? = nil) {
        self.key = key
        self.appName = appName
        self.windowTitle = windowTitle
        self.windowNumber = windowNumber
    }

    /// The origin of a session first asked about this packet; nil without a front app's bundle ID.
    public static func from(_ packet: ContextPacket) -> SessionOrigin? {
        guard let key = ContextKey.from(packet) else { return nil }
        return SessionOrigin(key: key, appName: packet.app?.name, windowTitle: packet.window?.title)
    }
}

/// The front app plus what it shows: the key a summon is matched on to continue a session.
public struct ContextKey: Hashable, Sendable, Codable {
    public var bundleID: String
    /// A document path, a URL as host + path, or the window title.
    public var target: String?

    public init(bundleID: String, target: String? = nil) {
        self.bundleID = bundleID
        self.target = target
    }

    /// The editor's file, then the window's document, then the browser page (host + path, no
    /// query or fragment, so tracking parameters don't split a page), then the window title.
    public static func from(_ packet: ContextPacket) -> ContextKey? {
        guard let bundle = packet.app?.bundle, !bundle.isEmpty else { return nil }
        return ContextKey(bundleID: bundle, target: target(in: packet))
    }

    private static func target(in packet: ContextPacket) -> String? {
        if let file = nonEmpty(packet.editor?.file) { return file }
        if let document = nonEmpty(packet.window?.document) { return document }
        if let raw = packet.browser?.url, let url = URL(string: raw), let host = url.host(), !host.isEmpty {
            let path = url.path()
            return host.lowercased() + (path == "/" ? "" : path)
        }
        return nonEmpty(packet.window?.title)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
