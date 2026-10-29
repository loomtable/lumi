import BuddyBridge
import BuddyCompanion
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay
import Foundation

extension AppRuntime {
    /// The Studio window's data source. Runs after `makeSessionEngine`, so the session store is
    /// ready to attach; with sessions off (the kill switch) the window shows no sessions.
    func makeStudioBridge(_ coordinator: BuddyCoordinator, features: LumiFeatures) {
        guard let sessions else { return }
        // makeSessionEngine attached the store and its transcripts already.
        let source = studioSource
        source.hooks.opened = { [weak sessions] id in sessions?.markSeen(id) }
        // The page's composer, stop, approvals, answers and relays: the same flow as the Panel's.
        source.hooks.handle = { [weak coordinator] event in await coordinator?.pageFlow?.handle(event, from: .studio) }
        // Live events for the open page, voice and page turns alike (R11).
        source.hooks.events = { [weak coordinator] id in
            coordinator?.pageFlow?.events(for: id) ?? AsyncStream { $0.finish() }
        }
        // Home's composer: a new open session, then the typed turn through the page flow (R11).
        source.hooks.startSession = { [weak coordinator] text, files in
            guard let flow = coordinator?.pageFlow, let id = await flow.newSession() else { return nil }
            let submit = PageSubmit(text: text, attachments: files.map(PageAttachment.file))
            // Studio shows the question itself (Home's first question, QA S-02).
            Task { await flow.handle(.submit(id, submit), from: .studio) }
            return id
        }
        // A page opened mid-turn shows that turn's question (QA U7).
        source.hooks.lastSentTurn = { [weak sessions] id in
            await sessions?.lastSentTurn(id).map { SentTurn(uuid: $0.uuid, shown: $0.shown, kind: $0.kind, at: $0.at) }
        }
        // Home's mic: hold to dictate into Home's composer, through the dictation key's path (QA U23).
        if features.dictation {
            source.hooks.dictate = { [weak coordinator] down in await coordinator?.dictation?.handle(down ? .began : .ended) }
        }
        // Lanes of teammates that already exist (QA U30), from the open Claude session's subagent
        // files. Only for open sessions, so this never mints a Claude session.
        source.hooks.teammateLanes = { [weak sessions] id in
            guard let open = await sessions?.openClaudeSession(of: id) else { return [:] }
            let claude = open.id.uuidString.lowercased()
            return await Task.detached(priority: .userInitiated) {
                Dictionary(TranscriptReader().teammateLanes(session: claude).map { ($0.toolUseID, $0.history) },
                           uniquingKeysWith: { first, _ in first })
            }.value
        }
        // Details: the open Claude session and its folder, for "Copy resume command". Read-only:
        // opening the inspector never mints a Claude session or changes the current session.
        // Model, mode and cost: what Claude Code reported in the session's turns (QA S-05).
        source.hooks.details = { [weak sessions, weak coordinator] id in
            let facts = coordinator?.pageFlow?.facts[id] ?? SessionFacts()
            let open = await sessions?.openClaudeSession(of: id)
            return SessionDetails(claudeSessionID: open?.id.uuidString.lowercased(), workingDirectory: open?.cwd.path,
                                  model: facts.model, permissionMode: facts.permissionMode, costUSD: facts.costUSD)
        }
        source.hooks.folders = { [weak sessions] id in await sessions?.folders(of: id) ?? [] }
        // "Open as Panel" (⌘⇧P). The Panel's ⌘⇧E back into Studio is onOpenStudioSession (LumiApp).
        source.hooks.openPanel = { [weak coordinator] id in await coordinator?.pageFlow?.open(id) }
        // A talk-key turn while Studio shows a session goes into its page (R3). `studio` is weak;
        // studioSource lives as long as the runtime.
        coordinator.pageFlow?.studio = source
    }
}

/// Dictation types into Studio's focused composer, Home's or the open page's (QA R8).
extension SessionsStudioSource: DictationComposer {
    public var composerIsKey: Bool { pageHost?.composerIsKey ?? false }
    public func insertIntoComposer(_ text: String) { pageHost?.insertIntoComposer(text) }
}

extension SessionsStudioSource: StudioPageHost {
    public var shownSession: (id: SessionID, isKey: Bool)? { pageHost?.shownSession }

    public func record(question: String, kind: TurnKind, context: ContextStrip?, to session: SessionID) {
        pageHost?.record(question: question, kind: kind, context: context, to: session)
    }

    public func applyEdit(_ edit: PageEdit, to session: SessionID) {
        pageHost?.applyEdit(edit, to: session)
    }
}

/// Studio's data source over the session store (`SessionsPort`) and the engine. What the store
/// doesn't own (starting a session, a page's transcript and live events, its composer, the
/// inspector's details, the Panel) comes in as `Hooks`; each does nothing until it is wired.
@MainActor
public final class SessionsStudioSource: StudioDataSource {
    public struct Hooks {
        /// The first message and the files from Home's ＋.
        public var startSession: @MainActor (String, [URL]) async -> SessionID? = { _, _ in nil }
        /// The last turn the user sent in a session (QA U7).
        public var lastSentTurn: @MainActor (SessionID) async -> SentTurn? = { _ in nil }
        /// Home's mic, held or let go; nil hides it (QA U23).
        public var dictate: (@MainActor (Bool) async -> Void)?
        public var transcript: @MainActor (SessionID) async -> [TranscriptTurn] = { _ in [] }
        public var teammateLanes: @MainActor (SessionID) async -> [String: LaneHistory] = { _ in [:] }
        public var events: @MainActor (SessionID) -> AsyncStream<SessionEvent> = { _ in AsyncStream { $0.finish() } }
        public var handle: @MainActor (PanelEvent) async -> Void = { _ in }
        public var details: @MainActor (SessionID) async -> SessionDetails = { _ in SessionDetails() }
        public var folders: @MainActor (SessionID) async -> [URL] = { _ in [] }
        public var openPanel: @MainActor (SessionID) async -> Void = { _ in }
        /// The user opened the session in Studio: its unread answer counts as seen.
        public var opened: @MainActor (SessionID) -> Void = { _ in }

        public init() {}
    }

    public private(set) var port: (any SessionsPort)?
    public var hooks: Hooks
    /// The Studio window's model, set by the shell when Studio is on: which page is on screen.
    public weak var pageHost: (any StudioPageShowing)?
    private var listeners: [UUID: AsyncStream<[SessionSnapshot]>.Continuation] = [:]
    private var relay: Task<Void, Never>?
    /// What listeners last got, so the store's first value after `changes()` isn't sent twice.
    private var lastSent: [SessionSnapshot]?

    /// Nil `port`: no session store yet, so Studio shows an empty sidebar until `attach`.
    public init(port: (any SessionsPort)? = nil, hooks: Hooks = Hooks()) {
        self.hooks = hooks
        attach(port)
    }

    /// Follows `port` from now on; pages already listening get its snapshots at once.
    public func attach(_ port: (any SessionsPort)?) {
        self.port = port
        relay?.cancel()
        relay = nil
        guard let port else { return publish([]) }
        let changes = port.changes()
        relay = Task { [weak self] in
            for await snapshots in changes { self?.publish(snapshots) }
        }
    }

    public var snapshots: [SessionSnapshot] { port?.snapshots ?? [] }

    public func changes() -> AsyncStream<[SessionSnapshot]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [SessionSnapshot].self)
        let key = UUID()
        listeners[key] = continuation
        lastSent = snapshots
        continuation.yield(snapshots)
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.listeners[key] = nil } }
        return stream
    }

    private func publish(_ snapshots: [SessionSnapshot]) {
        guard snapshots != lastSent else { return }
        lastSent = snapshots
        for listener in listeners.values { listener.yield(snapshots) }
    }

    public func open(_ id: SessionID) async {
        hooks.opened(id)
        await port?.setCurrent(id)
    }
    public func setPinned(_ pinned: Bool, for id: SessionID) async { await port?.setPinned(pinned, for: id) }
    public func setArchived(_ archived: Bool, for id: SessionID) async { await port?.setArchived(archived, for: id) }
    public func rename(_ id: SessionID, to title: String) async { await port?.rename(id, to: title) }
    public func forget(_ id: SessionID) async throws { try await port?.forget(id) }
    public func startSession(text: String) async -> SessionID? { await hooks.startSession(text, []) }
    public func startSession(text: String, attachments: [URL]) async -> SessionID? { await hooks.startSession(text, attachments) }
    public var canDictate: Bool { hooks.dictate != nil }
    public var hasSessions: Bool { port != nil }
    public func lastSentTurn(for id: SessionID) async -> SentTurn? { await hooks.lastSentTurn(id) }
    public func dictate(_ down: Bool) async { await hooks.dictate?(down) }
    public func transcript(for id: SessionID) async -> [TranscriptTurn] { await hooks.transcript(id) }
    public func teammateLanes(for id: SessionID) async -> [String: LaneHistory] { await hooks.teammateLanes(id) }
    public func events(for id: SessionID) -> AsyncStream<SessionEvent> { hooks.events(id) }
    public func handle(_ event: PanelEvent) async { await hooks.handle(event) }
    public func details(for id: SessionID) async -> SessionDetails { await hooks.details(id) }
    public func folders(for id: SessionID) async -> [URL] { await hooks.folders(id) }
    public func openPanel(_ id: SessionID) async { await hooks.openPanel(id) }
    /// The router's rule 3 and the pool's keep-warm rule (QA R6): the store learns which session's
    /// page Studio shows.
    public func shownSessionChanged(from old: SessionID?, to new: SessionID?) {
        if let old { port?.pageHidden(old, kind: .studio) }
        if let new { port?.pageShown(new, kind: .studio) }
    }
}
