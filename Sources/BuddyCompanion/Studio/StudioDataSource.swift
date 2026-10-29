import BuddyCore
import BuddyOverlay
import Foundation

/// Everything Studio reads and does, so the window never touches the engine directly. The app shell
/// adapts `SessionsPort` and the session engine onto it (`AppRuntime+Studio`); tests and previews
/// use `FakeStudioSource`.
@MainActor
public protocol StudioDataSource: AnyObject {
    /// Every session that isn't forgotten, most recently used first.
    var snapshots: [SessionSnapshot] { get }
    /// The snapshots now, then after every change.
    func changes() -> AsyncStream<[SessionSnapshot]>
    /// The user opened `id` in Studio: the next summon continues it.
    func open(_ id: SessionID) async
    func setPinned(_ pinned: Bool, for id: SessionID) async
    /// Archived sessions leave the lists and the switcher; Studio's Archived group brings them back.
    func setArchived(_ archived: Bool, for id: SessionID) async
    func rename(_ id: SessionID, to title: String) async
    /// Deletes the session, its Claude sessions' transcripts and its screenshots.
    func forget(_ id: SessionID) async throws
    /// Home's composer: a typed turn in a new session. Returns it, or nil when none could start.
    func startSession(text: String) async -> SessionID?
    /// The earlier turns of `id`, for its page.
    func transcript(for id: SessionID) async -> [TranscriptTurn]
    /// Earlier text and steps of each teammate's lane, keyed by the teammate's tool use id, for a
    /// page that opens on teammates that already exist.
    func teammateLanes(for id: SessionID) async -> [String: LaneHistory]
    /// The live events of `id` from now on, for its page. Finishes when the page stops listening.
    func events(for id: SessionID) -> AsyncStream<SessionEvent>
    /// The page's composer, stop and approval buttons.
    func handle(_ event: PanelEvent) async
    /// The inspector's Files, Context and Details.
    func details(for id: SessionID) async -> SessionDetails
    /// The session's folders, for the composer's `@` files and project skills.
    func folders(for id: SessionID) async -> [URL]
    /// "Open as Panel" (⌘⇧P): the session's page floats over the frontmost app.
    func openPanel(_ id: SessionID) async
    /// The session whose page is on screen in Studio changed (nil: none), for the router and the
    /// pool's keep-warm rule.
    func shownSessionChanged(from old: SessionID?, to new: SessionID?)
    /// The last turn the user sent (not a steer or relay), for a page opened while it runs (QA U7).
    func lastSentTurn(for id: SessionID) async -> SentTurn?
    /// Home's composer with the files from its ＋ (QA U23).
    func startSession(text: String, attachments: [URL]) async -> SessionID?
    /// Home's mic can dictate (the dictation key's path is on).
    var canDictate: Bool { get }
    /// The session store is attached: false with the `sessions` kill switch off, when Studio has
    /// no sessions to show, start or forget.
    var hasSessions: Bool { get }
    /// Home's mic held (true) or let go (false): the words go into Home's composer.
    func dictate(_ down: Bool) async
}

/// A user turn as the store recorded it when it was sent.
public struct SentTurn: Sendable, Equatable {
    /// Its user line's uuid, which keys the transcript.
    public var uuid: String
    public var shown: String
    public var kind: TurnKind
    public var at: Date

    public init(uuid: String, shown: String, kind: TurnKind, at: Date) {
        self.uuid = uuid
        self.shown = shown
        self.kind = kind
        self.at = at
    }
}

public extension StudioDataSource {
    func lastSentTurn(for id: SessionID) async -> SentTurn? { nil }
    func folders(for id: SessionID) async -> [URL] { [] }
    func startSession(text: String, attachments: [URL]) async -> SessionID? { await startSession(text: text) }
    var canDictate: Bool { false }
    var hasSessions: Bool { true }
    func dictate(_ down: Bool) async {}
}

/// The Studio as a page on screen, for routing a talk-key turn into it (PageFlow's StudioPageHost).
@MainActor
public protocol StudioPageShowing: AnyObject {
    /// The session whose page is on screen, and whether the window is key; nil when none is.
    var shownSession: (id: SessionID, isKey: Bool)? { get }
    /// A voice-in-page turn's question, shown before its answer streams in.
    func record(question: String, kind: TurnKind, context: ContextStrip?, to session: SessionID)
    /// What came of a prompt edited in a page showing `session`.
    func applyEdit(_ edit: PageEdit, to session: SessionID)
    /// A Studio composer has the keyboard (dictation types into it).
    var composerIsKey: Bool { get }
    /// Dictated words into the focused composer.
    func insertIntoComposer(_ text: String)
}

/// What the inspector shows beyond the snapshot (04 §6.3).
public struct SessionDetails: Sendable, Equatable {
    public struct ContextItem: Sendable, Equatable, Identifiable {
        public var id: String
        public var appName: String
        public var title: String?
        /// The screenshot, while it's kept.
        public var imageURL: URL?

        public init(id: String, appName: String, title: String? = nil, imageURL: URL? = nil) {
            self.id = id
            self.appName = appName
            self.title = title
            self.imageURL = imageURL
        }
    }

    /// The Claude Code session id the resume command names.
    public var claudeSessionID: String?
    public var workingDirectory: String?
    public var model: String?
    public var permissionMode: String?
    /// Files the session read or changed.
    public var files: [URL]
    /// Every context strip of the session, oldest first.
    public var contexts: [ContextItem]
    /// Total cost, when the CLI reports it.
    public var costUSD: Double?

    public init(claudeSessionID: String? = nil, workingDirectory: String? = nil, model: String? = nil,
                permissionMode: String? = nil, files: [URL] = [], contexts: [ContextItem] = [], costUSD: Double? = nil) {
        self.claudeSessionID = claudeSessionID
        self.workingDirectory = workingDirectory
        self.model = model
        self.permissionMode = permissionMode
        self.files = files
        self.contexts = contexts
        self.costUSD = costUSD
    }

    /// "Copy resume command": continues the session in a terminal. Nil until Claude Code named it.
    public var resumeCommand: String? {
        guard let id = claudeSessionID else { return nil }
        let resume = "claude --resume \(id)"
        guard let dir = workingDirectory, !dir.isEmpty else { return resume }
        return "cd \(Self.shellQuoted(dir)) && \(resume)"
    }

    /// Single quotes, with any single quote inside closed, escaped and reopened.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
