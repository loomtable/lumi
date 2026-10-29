import BuddyBridge
import BuddyCore
import BuddyOverlay
import BuddyTrace
import Foundation

/// The Studio's conversation column, as the page flow sees it. The Studio bridge implements it
/// over its window and selection.
@MainActor public protocol StudioPageHost: AnyObject {
    /// The session the column shows while the Studio window is visible on the active Space, and
    /// whether that window is key. Nil when hidden, on another Space, or nothing is selected.
    var shownSession: (id: SessionID, isKey: Bool)? { get }
    /// A turn the app sent into that page (a voice-in-page transcript), shown at once.
    func record(question: String, kind: TurnKind, context: ContextStrip?, to session: SessionID)
    /// What came of a prompt edited in a page showing `session`.
    func applyEdit(_ edit: PageEdit, to session: SessionID)
}

/// Opens the Panel and streams a session's events into its page; turns the page's actions
/// into turns, approvals and relays. Behind `LumiFeatures.panel`. It is also the app's
/// `PageSurfaces`: a talk-key turn while the Panel shows a session goes into that page.
@MainActor public final class PageFlow: PageSurfaces {
    /// What the coordinator builds for a composer send: the question (with a fresh screen read
    /// when the ▣ chip is on) and the conversation state, or nil when it can't be sent now.
    public typealias MakeRequest = @MainActor (_ session: SessionID, _ submit: PageSubmit) async -> TurnRequest?

    public let panel: any PanelPresenting
    private let turns: any TurnPort
    public let permissions: LivePermissionHost
    private let sessions: (any SessionsPort)?
    private let clock: () -> Date
    /// Settings › Voice "Speak answers" and notifications.
    public var settings: () -> DeliverySettings = { DeliverySettings() }
    public var makeRequest: MakeRequest = { _, _ in nil }
    /// ⌘⇧E: the Studio opens the session.
    public var onExpand: (SessionID) -> Void = { _ in }
    /// A finished turn's surface, for attention (a banner) and speech.
    public var onDelivered: (SessionID, Delivery) -> Void = { _, _ in }
    /// The engine's teammate stop, until the engine has a port for it.
    public var stopTeammate: (SessionID, String) async -> Void = { _, _ in }
    /// The composer's mic: the coordinator listens for a voice-in-page turn.
    public var onMic: (SessionID, Bool) -> Void = { _, _ in }
    /// "Continue" on an interrupted turn: the engine resumes it and its events stream back. Nil
    /// until the engine provides it (the page keeps showing the turn as interrupted).
    public var onContinue: (SessionID) async -> AsyncStream<TurnStreamEvent>? = { _ in nil }
    /// A new open session for a first typed turn (Home's composer, a page's ⌘⇧↩); nil when it
    /// can't be made (sessions off).
    public var newSession: () async -> SessionID? = { nil }
    /// Speaks a piece of an in-page answer ("Speak answers" on); `continuing` queues it.
    public var onSpeak: (String, _ continuing: Bool) -> Void = { _, _ in }
    /// A session's whole history, oldest first (`LiveSessions.transcript`), for a page opened on it.
    public var history: (SessionID) async -> [TranscriptTurn] = { _ in [] }
    /// A session's live feed from the pool (`pool.events(for:)`): the Panel shows turns the CLI
    /// starts on its own (a teammate handed back) from it, which no turn stream carries (R20).
    public var liveEvents: (SessionID) -> AsyncStream<SessionEvent> = { _ in AsyncStream { $0.finish() } }
    private var feed: (id: SessionID, task: Task<Void, Never>)?
    /// Sessions whose CLI-started turn the feed is rendering.
    private var backgroundTurn: Set<SessionID> = []
    /// What each session's in-page answer has spoken so far this turn.
    private var spoken: [SessionID: String] = [:]

    /// The Studio's page, once the Studio bridge attaches it.
    public weak var studio: (any StudioPageHost)?

    /// When each running turn started, for the ≥ 30 s banner rule.
    private var startedAt: [SessionID: Date] = [:]
    /// The user minimised or closed a session's page during its turn.
    private var dismissed: Set<SessionID> = []
    /// The session each page last started with ⌘⇧↩, for its "Started in a new session" toast.
    private var startedFrom: [SessionID: SessionID] = [:]
    private var listening: Task<Void, Never>?
    private var updating: Task<Void, Never>?
    /// Live subscribers to each session's events (the Studio's page).
    private var subscribers: [SessionID: [UUID: AsyncStream<SessionEvent>.Continuation]] = [:]
    /// What Claude Code reported for each session's turns: the inspector's model, mode and cost.
    public private(set) var facts: [SessionID: SessionFacts] = [:]

    public init(panel: any PanelPresenting, turns: any TurnPort, permissions: LivePermissionHost,
                sessions: (any SessionsPort)? = nil, clock: @escaping () -> Date = Date.init) {
        self.panel = panel
        self.turns = turns
        self.permissions = permissions
        self.sessions = sessions
        self.clock = clock
    }

    /// The session's snapshot from the store, when it has one.
    public func snapshot(for id: SessionID) -> SessionSnapshot? {
        sessions?.snapshots.first { $0.id == id }
    }

    // MARK: PageSurfaces

    /// The top-centre progress capsules: a turn whose page the user hides still shows one.
    public var progress: ProgressBoard?
    /// A composer turn's latency marks (QA U48), with the time since it was sent.
    public var trace: (TraceEvent, Duration, TraceOutcome?) -> Void = { _, _, _ in }

    /// The page a talk-key turn goes into: the Studio's when its window is key, else the Panel's.
    /// A Studio window that's only partly visible behind another app doesn't count (V-01): the
    /// user is in that app, so the ask gets the Glance.
    public var visiblePage: (id: SessionID, kind: PageKind)? {
        if let studio = studio?.shownSession, studio.isKey { return (studio.id, .studio) }
        return panel.visibleSession.map { ($0, .panel) }
    }

    /// The pages the user is looking at, for a Glance-path answer: the Panel's, and the Studio's
    /// only while its window is key. Otherwise the answer is a card where the user is.
    public var focusedPages: [SessionID: PageKind] {
        var pages: [SessionID: PageKind] = [:]
        if let id = panel.visibleSession { pages[id] = .panel }
        if let s = studio?.shownSession, s.isKey { pages[s.id] = .studio }
        return pages
    }

    /// Every page on screen and the session it shows (delivered-in-place).
    public var visiblePages: [SessionID: PageKind] {
        var pages: [SessionID: PageKind] = [:]
        if let id = panel.visibleSession { pages[id] = .panel }
        // Both show the same session: the focused Studio window wins.
        if let s = studio?.shownSession, s.isKey || pages[s.id] == nil { pages[s.id] = .studio }
        return pages
    }

    // MARK: Lifecycle

    /// Starts reading the Panel's events, and keeps its page in step with its session's snapshot
    /// (title, teammates, an ask it didn't see asked).
    public func start() {
        guard listening == nil else { return }
        let events = panel.events
        listening = Task { [weak self] in
            for await event in events { await self?.handle(event, from: .panel) }
        }
        guard let changes = sessions?.changes() else { return }
        updating = Task { [weak self] in
            var last: SessionSnapshot?
            for await list in changes {
                guard let self, let id = self.panel.visibleSession, let s = list.first(where: { $0.id == id }), s != last
                else { continue }
                last = s
                self.panel.update(s)
            }
        }
    }

    public func stop() {
        listening?.cancel()
        listening = nil
        updating?.cancel()
        updating = nil
    }

    // MARK: Turns

    /// Opens the Panel on a session, telling the store which session the Panel shows (router
    /// rule 3, and the pool keeps on-screen sessions warm; QA R6). Every Panel show goes here.
    public func show(_ snapshot: SessionSnapshot, history: [TranscriptTurn], dock: PanelDock? = nil) {
        let previous = panel.visibleSession
        panel.show(session: snapshot, page: history, dock: dock)
        progress?.refresh() // its running turn now shows in the page
        guard previous != snapshot.id else { return }
        if let previous { sessions?.pageHidden(previous, kind: .panel) }
        sessions?.pageShown(snapshot.id, kind: .panel)
        follow(snapshot.id)
    }

    /// Opens the Panel on a session with its whole history: a capsule or banner click (a
    /// deliberate pick, V-11). False when the store doesn't have it.
    @discardableResult
    public func open(_ id: SessionID) async -> Bool {
        guard let snapshot = snapshot(for: id) else { return false }
        show(snapshot, history: await history(id))
        return true
    }

    /// Follows the shown session's pool feed for turns nobody sent from a page.
    private func follow(_ id: SessionID) {
        feed?.task.cancel()
        let events = liveEvents(id)
        feed = (id, Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.fed(event, session: id)
            }
        })
    }

    /// A pool-feed event: rendered only for a turn the CLI started itself (no user uuid) while no
    /// page turn of this session runs; page turns arrive through their own streams.
    func fed(_ event: SessionEvent, session: SessionID) {
        switch event {
        case .turnStarted(nil, _) where startedAt[session] == nil:
            backgroundTurn.insert(session)
        default:
            break
        }
        guard backgroundTurn.contains(session) else { return }
        if case .turnEnded = event { backgroundTurn.remove(session) }
        if case .processEnded = event { backgroundTurn.remove(session) }
        publish(event, session: session)
        panel.append(event, to: session)
    }

    private func unfollow(_ id: SessionID) {
        guard feed?.id == id else { return }
        feed?.task.cancel()
        feed = nil
        backgroundTurn.remove(id)
    }

    /// A typed ask (the text box) or a voice-in-page turn: the page opens on the session and
    /// shows the question at once.
    public func begin(_ snapshot: SessionSnapshot, question: String, kind: TurnKind, context: ContextStrip?,
                      dock: PanelDock? = nil, history: [TranscriptTurn] = []) {
        if visiblePages[snapshot.id] == .studio, let studio {
            // The Studio shows it: the turn goes into that page; no Panel opens over it.
            studio.record(question: question, kind: kind, context: context, to: snapshot.id)
        } else {
            if panel.visibleSession != snapshot.id { show(snapshot, history: history, dock: dock) }
            panel.record(question: question, kind: kind, context: context, to: snapshot.id)
        }
        startedAt[snapshot.id] = clock()
        dismissed.remove(snapshot.id)
    }

    /// A Glance-path answer (a cascade turn) for a conversation the page shows: its question and
    /// answer become a finished turn there.
    public func showAnswer(_ block: BuddyBlock, question: String, session: SessionID, kind: TurnKind) {
        let end = SessionEvent.turnEnded(TurnEnd(kind: .typed, markdown: ConversationPage.answerText(block), block: block))
        switch visiblePages[session] {
        case .studio?:
            studio?.record(question: question, kind: kind, context: nil, to: session)
            publish(end, session: session)
        case .panel?:
            panel.record(question: question, kind: kind, context: nil, to: session)
            panel.append(end, to: session)
        case nil:
            break
        }
    }

    /// A typed question into each page on screen showing `id`, except the one it was typed in.
    private func mirror(_ question: String, in id: SessionID, from origin: PageKind?) {
        if origin != .studio, let studio, studio.shownSession?.id == id {
            studio.record(question: question, kind: .typed, context: nil, to: id)
        }
        if origin != .panel, panel.visibleSession == id {
            panel.record(question: question, kind: .typed, context: nil, to: id)
        }
    }

    /// An edited prompt's outcome: applied, every page showing `id` replaces the turns at once (QA
    /// S-26's rule: the Panel and Studio never disagree); failed, only the page that edited hears,
    /// and gets the words back.
    private func edit(_ edit: PageEdit, in id: SessionID, from origin: PageKind?) {
        if case .failed = edit {
            if origin == .studio { studio?.applyEdit(edit, to: id) } else { panel.applyEdit(edit, to: id) }
            return
        }
        studio?.applyEdit(edit, to: id)
        panel.applyEdit(edit, to: id)
    }

    /// Every event of `id`'s turns from now on, page and voice turns alike, for another page
    /// (the Studio column). It ends when the subscriber stops listening.
    public func events(for id: SessionID) -> AsyncStream<SessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
        let key = UUID()
        subscribers[id, default: [:]][key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id]?[key] = nil }
        }
        return stream
    }

    /// Hands one session event to the subscribers and the permission host. `receive` does this
    /// for page turns; the coordinator calls it for voice turns.
    public func publish(_ event: SessionEvent, session: SessionID) {
        permissions.observe(event, in: session)
        facts[session, default: SessionFacts()].note(event)
        for continuation in (subscribers[session] ?? [:]).values { continuation.yield(event) }
    }

    /// One event of a voice turn the Glance shows: the pages showing its session follow it as
    /// well (the Panel too), so they show what runs there as the capsules and the sidebar do.
    public func render(_ event: SessionEvent, session: SessionID) {
        publish(event, session: session)
        panel.append(event, to: session)
    }

    /// One event of a session's turn. Returns the delivery when the turn ended.
    @discardableResult
    public func receive(_ event: SessionEvent, session: SessionID, kind: TurnKind) -> Delivery? {
        // Render only: the session pool's feed is the one writer to the store (QA R19).
        publish(event, session: session)
        panel.append(event, to: session)
        switch event {
        case .turnStarted:
            if startedAt[session] == nil { startedAt[session] = clock() }
            spoken[session] = nil
            return nil
        case .sayFirstSentence(let sentence) where speaksInPage(kind):
            spoken[session] = sentence
            onSpeak(sentence, false)
            return nil
        case .say(let full) where speaksInPage(kind):
            let before = spoken[session]
            let rest = Self.remainder(of: full, after: before)
            spoken[session] = full
            if !rest.isEmpty { onSpeak(rest, before != nil) }
            return nil
        case .turnEnded(let end):
            // A typed answer has no spoken line: with "Speak answers" on, its first sentence.
            if spoken.removeValue(forKey: session) == nil, !end.isError, speaksInPage(end.kind),
               let line = Self.firstSpokenSentence(end.markdown) {
                onSpeak(line, false)
            }
            return delivered(session, kind: end.kind, failed: end.isError)
        case .processEnded(_, let midTurn) where midTurn:
            return delivered(session, kind: kind, failed: true)
        default:
            return nil
        }
    }

    /// Drains a turn's stream into the page.
    public func pump(_ stream: AsyncStream<TurnStreamEvent>, session: SessionID, kind: TurnKind) async {
        // A steer or relay folds into the running turn, which already has its capsule.
        let query = kind == .typed ? progress?.begin(session: session, question: "") : nil
        let start = ContinuousClock.now
        var marks = TurnMarks()
        for await e in stream {
            if let query { progress?.event(e, query: query) }
            guard case .session(let event) = e else { continue }
            receive(event, session: session, kind: kind)
            guard kind == .typed else { continue }
            for mark in marks.marks(for: event, inPage: true, speaks: speaksInPage(kind)) {
                trace(mark.event, .now - start, mark.outcome)
            }
        }
        if let query { progress?.end(query) }
    }

    /// "Speak answers" covers typed and voice-in-page turns read in a page.
    func speaksInPage(_ kind: TurnKind) -> Bool {
        (kind == .typed || kind == .voiceInPage) && settings().speakTypedAnswers
    }

    nonisolated static func remainder(of full: String, after spoken: String?) -> String {
        guard let spoken, full.hasPrefix(spoken) else { return full }
        return String(full.dropFirst(spoken.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The first sentence of the answer's first paragraph, without Markdown marks; nil when it
    /// opens with code or a table.
    nonisolated static func firstSpokenSentence(_ markdown: String) -> String? {
        guard let first = MarkdownSplitter.split(markdown).blocks.first, first.kind == .paragraph || first.kind == .list(ordered: false)
        else { return nil }
        let plain = first.text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "- ", with: "")
        let sentence = BuddyBlock.firstSentence(of: plain).trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? nil : sentence
    }

    private func delivered(_ session: SessionID, kind: TurnKind, failed: Bool) -> Delivery {
        let ran = startedAt.removeValue(forKey: session).map { clock().timeIntervalSince($0) } ?? 0
        let input = DeliveryInput(session: session, kind: kind, failed: failed, visiblePages: visiblePages, ranFor: ran,
                                  pageDismissed: dismissed.remove(session) != nil)
        let delivery = SurfaceRouter.deliver(input, settings: settings())
        onDelivered(session, delivery)
        return delivery
    }

    // MARK: Panel events

    /// A page's event: the Panel's, or the Studio column's (its data source can call this).
    /// `origin`: the page the user acted in, so a typed question also shows in the other page
    /// showing the same session (QA S-26); nil for a sender with no page of its own.
    public func handle(_ event: PanelEvent, from origin: PageKind? = nil) async {
        switch event {
        case .submit(let id, let submit):
            await send(submit, to: id, from: origin)
        case .stop(let id):
            await turns.cancel(conversation: id.rawValue)
        case .action(let id, let action):
            await handle(action, in: id, from: origin)
        case .expand(let id):
            // ⌘⇧E: the Studio opens the session and the Panel tucks away.
            onExpand(id)
            if panel.visibleSession == id { panel.minimise() }
        case .pinned(let id, let pinned):
            await sessions?.setPinned(pinned, for: id)
        case .minimised(let id), .closed(let id):
            // The session keeps running in the background; its answer won't reopen the page.
            if startedAt[id] != nil { dismissed.insert(id) }
            sessions?.pageHidden(id, kind: .panel)
            unfollow(id)
            progress?.refresh() // a running turn's capsule comes back
        }
    }

    private func handle(_ action: PageAction, in id: SessionID, from origin: PageKind?) async {
        switch action {
        case .approve(let request, let allow, let always, let message):
            let ask = permissions.ask(request)
            if !(await permissions.respond(request, in: id, allow: allow, always: always, message: message)), let ask {
                // Nothing was sent: the card comes back so the user can answer again.
                panel.append(.permissionRequested(ask), to: id)
                publish(.permissionRequested(ask), session: id)
            }
        case .answer(let request, let answers):
            let ask = permissions.questions.first { $0.ask.id == request }?.ask
            if !(await permissions.answerQuestion(request, in: id, answers: answers)), let ask {
                panel.append(.questionAsked(ask), to: id)
                publish(.questionAsked(ask), session: id)
            }
        case .relay(let teammate, let text):
            await send(PageSubmit(text: Self.relayLine(to: teammate, text), kind: .relay), to: id)
        case .stopTeammate(let taskID):
            await stopTeammate(id, taskID)
        case .mic(let down):
            onMic(id, down)
        case .submit(let submit):
            await send(submit, to: id, from: origin)
        case .submitToNewSession(let submit):
            // It runs in the background: no page opens for it, and its answer doesn't open one
            // either (as a minimised page's); its capsule shows while it works.
            guard let new = await newSession() else { return }
            startedFrom[id] = new
            dismissed.insert(new)
            await send(submit, to: new)
        case .openStartedSession:
            guard let new = startedFrom[id] else { return }
            if origin == .studio { onExpand(new) } else { await open(new) }
        case .stop:
            await turns.cancel(conversation: id.rawValue)
        case .continueInterrupted:
            guard let stream = await onContinue(id) else {
                // Nothing resumed: the page shows the turn interrupted again.
                receive(.processEnded(status: 0, midTurn: true), session: id, kind: .typed)
                return
            }
            startedAt[id] = clock()
            await pump(stream, session: id, kind: .typed)
        }
    }

    /// "The user says to @Writer: keep it short" (02 §D4): the lead relays it with SendMessage.
    nonisolated static func relayLine(to teammate: String, _ text: String) -> String {
        "The user says to @\(teammate): \(text)"
    }

    private func send(_ submit: PageSubmit, to id: SessionID, from origin: PageKind? = nil) async {
        let kind = submit.kind
        // The sending page shows its question itself; the other page on this session shows it too,
        // so the Panel and Studio never disagree (QA S-26). Steers and relays fold into a turn.
        // An edited prompt changes the pages only once the session went back (`edit`).
        if kind == .typed, submit.replacing == nil { mirror(submit.text, in: id, from: origin) }
        guard let request = await makeRequest(id, submit) else {
            if submit.replacing != nil {
                edit(.failed(text: submit.text), in: id, from: origin)
                return
            }
            receive(.turnEnded(TurnEnd(kind: kind, markdown: "", isError: true,
                                       error: SessionFailure(reason: .unavailable("Sessions aren't on yet"), retryable: false))),
                    session: id, kind: kind)
            return
        }
        if let prompt = submit.replacing { edit(.applied(prompt: prompt, question: submit.text), in: id, from: origin) }
        // A steer or relay folds into the running turn; a new turn starts its clock and shows
        // what was read for it.
        if kind == .typed {
            startedAt[id] = clock()
            let packet = request.question.packet
            panel.setContext(ContextStrip.from(packet, withScreen: submit.withScreen && packet.app != nil), to: id)
        }
        let stream = await turns.send(request)
        await pump(stream, session: id, kind: kind)
    }
}

/// A session's model, permission mode and cost as Claude Code reported them in its turns, for
/// Studio's inspector (QA S-05). Kept while Lumi runs.
public struct SessionFacts: Sendable, Equatable {
    public var model: String?
    public var permissionMode: String?
    /// What the session's turns cost since Lumi started it.
    public var costUSD: Double?
    /// The process's running total at its last result (`total_cost_usd` counts per process).
    private var processTotal: Double = 0

    public init() {}

    public mutating func note(_ event: SessionEvent) {
        switch event {
        case .initialized(let summary):
            model = summary.model ?? model
            permissionMode = summary.permissionMode ?? permissionMode
        case .turnEnded(let end):
            guard let total = end.costUSD else { return }
            // A smaller total is a new process (resumed after a suspend): it counts from zero.
            costUSD = (costUSD ?? 0) + (total >= processTotal ? total - processTotal : total)
            processTotal = total
        case .processEnded:
            processTotal = 0
        default:
            break
        }
    }
}
