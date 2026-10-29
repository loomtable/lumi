import BuddyCore
import BuddyOverlay
import Foundation
import Observation

/// Studio's state: the sessions it shows, what is selected, which sidebar list is up, and the
/// inspector. Views read it; every change of sessions comes from the data source.
@Observable
public final class StudioModel: StudioPageShowing {
    /// What the content column shows.
    public enum Selection: Sendable, Equatable, Hashable {
        case home
        case session(SessionID)
        case settings(SettingsPage)
        /// Recent dictations (`DictationHistory`).
        case dictation
    }

    public enum InspectorTab: String, Sendable, CaseIterable, Identifiable {
        case team, files, context, details
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .team: "Team"
            case .files: "Files"
            case .context: "Context"
            case .details: "Details"
            }
        }
    }

    public private(set) var snapshots: [SessionSnapshot] = []
    public var selection: Selection = .home {
        didSet { selectionChanged(from: oldValue) }
    }
    /// The settings list replaces the sessions in the sidebar while a page is open.
    public var showsSettingsList: Bool { if case .settings = selection { true } else { false } }
    /// The page Settings opens at, when asked without one: the last shown.
    public private(set) var lastSettingsPage: SettingsPage = .general
    public var search = ""
    public var inspectorShown = false
    /// The sidebar's Archived group is open.
    public var archivedExpanded = false
    public var inspectorTab: InspectorTab = .team
    /// The last error to show (a forget that failed), cleared by the view.
    public var notice: String?
    /// Whether the Studio window is open (the shell sets it), for the one-Lumi rule.
    public var windowVisible = false { didSet { refreshPageVisibility() } }
    /// The window is on the active Space and not fully covered (its occlusion state).
    public var windowOnScreen = true { didSet { refreshPageVisibility() } }
    /// The window is key: a talk-key turn then goes to its page even over a Panel.
    public var windowKey = false
    /// Home's composer (here, so dictation can type into it): text, pictures, pastes, menus.
    public let homeComposer = ComposerState()
    /// Home's composer text.
    public var homeDraft: String {
        get { homeComposer.text }
        set { homeComposer.text = newValue }
    }
    /// Files from Home's ＋, a paste or a drop, sent with the first message (QA U23).
    public var homeAttachments: [URL] {
        get { homeComposer.attachments.map(\.url) }
        set { homeComposer.draft.attachments = newValue.map(PageAttachment.file) }
    }
    /// Home's composer has the keyboard focus.
    public var homeComposerFocused = false
    /// The open page's composer has the keyboard focus.
    public var pageComposerFocused = false
    /// The page of the selected session while its column is up (the column registers it).
    public private(set) var page: ConversationPageModel?
    /// The shown session last reported to the source.
    @ObservationIgnored private var reportedShown: SessionID?
    /// A teammate lane to open once `session`'s page comes up (a sidebar teammate row).
    @ObservationIgnored private var pendingLane: (session: SessionID, taskID: String)?
    /// Home's question for the session it just started: its page shows it, as a page send would.
    @ObservationIgnored private var firstQuestion: (session: SessionID, text: String)?
    /// Unsent composer text and files of pages the user left, restored when they come back.
    @ObservationIgnored private var drafts: [SessionID: ComposerDraft] = [:]

    @ObservationIgnored public let source: any StudioDataSource
    /// Every dictation's words; the sidebar lists its page while it's `available`.
    public let dictationHistory: DictationHistory?
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var follow: Task<Void, Never>?

    public init(source: any StudioDataSource, dictationHistory: DictationHistory? = nil,
                clock: @escaping @MainActor () -> Date = { Date() }) {
        self.source = source
        self.dictationHistory = dictationHistory
        self.clock = clock
        snapshots = source.snapshots
    }

    /// Follows the source's changes until `stop()`.
    public func start() {
        guard follow == nil else { return }
        let changes = source.changes()
        follow = Task { [weak self] in
            for await snapshots in changes { self?.receive(snapshots) }
        }
    }

    public func stop() {
        follow?.cancel()
        follow = nil
    }

    func receive(_ new: [SessionSnapshot]) {
        let wasArchived = Set(snapshots.filter(\.archived).map(\.id))
        snapshots = new
        // A forgotten session that was open, or one just archived: back to Home. One opened from
        // the Archived group stays open.
        if case .session(let id) = selection {
            let now = new.first { $0.id == id }
            if now == nil || (now?.archived == true && !wasArchived.contains(id)) { selection = .home }
        }
    }

    // MARK: Derived

    public func sidebar(now: Date? = nil) -> SidebarGrouping {
        SidebarGrouping(snapshots, now: now ?? clock(), search: search)
    }

    public var selectedSession: SessionSnapshot? {
        guard case .session(let id) = selection else { return nil }
        return snapshots.first { $0.id == id }
    }

    /// Home's Running cards: up to three, those that need you first.
    public var running: [SessionSnapshot] {
        Array(SidebarGrouping(snapshots, now: clock()).rows(.now).map(\.session).prefix(Self.homeCards))
    }

    /// Home's Recent cards: the three last used that aren't running.
    public var recent: [SessionSnapshot] {
        let live = Set(running.map(\.id))
        return Array(snapshots.filter { !$0.archived && !live.contains($0.id) && !Self.isLive($0) }
            .sorted { $0.lastUsed > $1.lastUsed }.prefix(Self.homeCards))
    }

    static let homeCards = 3

    /// Sessions working or waiting on the user right now (quitting asks first).
    public var workingCount: Int { snapshots.filter { !$0.archived && Self.isLive($0) }.count }

    /// No sessions ever: Home's empty state (the sleepy orb).
    public var isEmpty: Bool { snapshots.allSatisfy(\.archived) }

    /// Home's orb is on screen: any other Lumi (the on-screen companion) fades out meanwhile.
    public var homeOrbVisible: Bool { windowVisible && selection == .home }

    /// The session whose page is on screen: selected, its page up, the window open on this Space.
    /// Nil otherwise. Talk-key turns for it go into the page instead of a Glance card.
    public var shownSession: (id: SessionID, isKey: Bool)? {
        guard windowVisible, windowOnScreen, case .session(let id) = selection, page?.session == id else { return nil }
        return (id, windowKey)
    }

    /// The column's page for `session` came up (or went away: nil).
    public func register(_ page: ConversationPageModel?) {
        if let old = self.page, old !== page { keepDraft(of: old) }
        self.page = page
        if let page, let lane = pendingLane, lane.session == page.session {
            page.openLane = lane.taskID
            pendingLane = nil
        }
        refreshPageVisibility()
    }

    /// The page for `session`: its earlier turns, its teammates and what each has written so far
    /// (QA U30: a page opened on teammates already running, or reopened later), and its actions
    /// going to the engine as PanelEvents, as with the Panel.
    public func makePage(for session: SessionSnapshot) async -> ConversationPageModel {
        let source = source
        let history = await source.transcript(for: session.id)
        let page = ConversationPageModel(snapshot: session, history: history)
        let id = session.id
        page.composer.folders = { await source.folders(for: id) }
        // Opened mid-turn: the running turn's question and real clock (QA U7).
        if session.turnRunning, let sent = await source.lastSentTurn(for: session.id),
           !history.contains(where: { $0.id == sent.uuid }) {
            page.showRunning(userUUID: sent.uuid, question: sent.shown, kind: sent.kind,
                             since: Self.turnStart(session.status, sent: sent), live: session.liveLine)
        }
        // Started from Home: the question shows at once, unless the transcript already has it.
        if let first = firstQuestion, first.session == session.id {
            firstQuestion = nil
            if !page.page.turns.contains(where: { $0.question == first.text }) {
                page.record(question: first.text, kind: .typed, context: nil)
            }
        }
        if let kept = drafts.removeValue(forKey: session.id) { page.composer.draft = kept }
        if !session.teammates.isEmpty { page.seedLanes(await source.teammateLanes(for: session.id)) }
        page.onAction = { action in Task { await source.handle(PanelEvent(action, session: id)) } }
        return page
    }

    /// The draft of a page going away, kept for when its session is opened again.
    /// Text, files and collapsed pastes, so a paste chip still expands when the user comes back.
    private func keepDraft(of page: ConversationPageModel) {
        let draft = page.composer.draft
        drafts[page.session] = draft.isEmpty ? nil : draft
    }

    /// The sidebar's clock for a working session; else when the turn was sent.
    static func turnStart(_ status: SessionStatus, sent: SentTurn) -> Date {
        if case .thinking(let since, _) = status { return since }
        return sent.at
    }

    /// A fresh snapshot for an open page; teammates it hadn't seen get their lanes so far too.
    public func update(_ page: ConversationPageModel, with session: SessionSnapshot) async {
        let known = Set(page.page.teammates.map(\.id))
        page.update(session)
        guard session.teammates.contains(where: { !known.contains($0.id) }) else { return }
        page.seedLanes(await source.teammateLanes(for: session.id))
    }

    /// Opens a teammate's lane: its session's page, then the lane (04 §5.2).
    public func openTeammate(_ taskID: String, in session: SessionID) {
        if let page, page.session == session, selection == .session(session) {
            page.openLane = taskID
        } else {
            pendingLane = (session, taskID)
            selection = .session(session)
        }
    }

    /// A voice-in-page turn's question, shown in the page before its answer streams in.
    public func record(question: String, kind: TurnKind, context: ContextStrip?, to session: SessionID) {
        guard let page, page.session == session else { return }
        page.record(question: question, kind: kind, context: context)
    }

    /// What came of a prompt edited in the Panel or here, for the page showing that session.
    public func applyEdit(_ edit: PageEdit, to session: SessionID) {
        guard let page, page.session == session else { return }
        page.apply(edit)
    }

    /// A Studio composer has the keyboard: the window is key and Home's composer, or the open
    /// page's, is focused. Dictation then types into it instead of the app behind.
    public var composerIsKey: Bool {
        guard windowVisible, windowKey else { return false }
        switch selection {
        case .home: return homeComposerFocused
        case .session(let id): return pageComposerFocused && page?.session == id
        case .settings, .dictation: return false
        }
    }

    /// Dictated words into the focused composer: appended, with a space unless the draft is empty
    /// or already ends in one (the Panel's rule).
    public func insertIntoComposer(_ text: String) {
        guard composerIsKey else { return }
        if case .home = selection {
            homeDraft = Self.appending(text, to: homeDraft)
        } else if let page {
            page.draft = Self.appending(text, to: page.draft)
        }
    }

    static func appending(_ text: String, to draft: String) -> String {
        draft + (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + text
    }

    /// The page's `isVisible` follows the window, the Space and the selection.
    func refreshPageVisibility() {
        let shown = shownSession?.id
        page?.isVisible = shown != nil
        guard shown != reportedShown else { return }
        let old = reportedShown
        reportedShown = shown
        source.shownSessionChanged(from: old, to: shown)
    }

    static func isLive(_ s: SessionSnapshot) -> Bool {
        switch s.status {
        case .thinking, .needsYou: true
        default: false
        }
    }

    // MARK: Actions

    public func showHome() { selection = .home }

    /// Bumped by New session (⌘N): Home puts the cursor in its composer.
    public private(set) var composerFocusRequests = 0

    /// New session (⌘N): Home, ready to type.
    public func newSession() {
        selection = .home
        composerFocusRequests += 1
    }

    /// A Running card's bar: steps done of the plan, when the session reports one.
    static func progress(_ status: SessionStatus) -> Double? {
        guard case .thinking(_, let progress?) = status, progress.total > 0 else { return nil }
        return min(1, max(0, Double(progress.done) / Double(progress.total)))
    }

    public func showSettings(_ page: SettingsPage? = nil) { selection = .settings(page ?? lastSettingsPage) }

    /// The sidebar lists Dictation (a dictation key is set up).
    public var showsDictation: Bool { dictationHistory?.available == true }

    /// "‹ Sessions": back to the session list, on Home.
    public func leaveSettings() { selection = .home }

    public func select(_ id: SessionID) { selection = .session(id) }

    /// ↑/↓ in the sidebar: the next or previous session row, wrapping.
    public func move(by offset: Int) {
        let rows = sidebar().allRows.map(\.id)
        guard !rows.isEmpty else { return }
        let index: Int
        if case .session(let id) = selection, let at = rows.firstIndex(of: id) {
            index = ((at + offset) % rows.count + rows.count) % rows.count
        } else {
            index = offset >= 0 ? 0 : rows.count - 1
        }
        selection = .session(rows[index])
    }

    /// "Interrupted · Continue" (QA U11): resumes the turn Lumi's quit stopped, through the page flow.
    public func continueInterrupted(_ id: SessionID) async {
        guard case .interrupted = snapshots.first(where: { $0.id == id })?.status else { return }
        await source.handle(.action(id, .continueInterrupted))
    }

    /// Archive (or bring back) a session. Archiving the open one goes back to Home.
    public func setArchived(_ archived: Bool, for id: SessionID) async {
        await source.setArchived(archived, for: id)
    }

    /// Bumped by the Session menu's Rename…: the open session's header starts editing its title.
    public private(set) var renameRequests = 0
    public func requestRename() {
        guard selectedSession != nil else { return }
        renameRequests += 1
    }

    /// The Session menu's Stop: the open page's running turn.
    public var canStop: Bool { page?.page.isRunning == true && page?.session == selectedSession?.id }
    public func stopSelected() {
        guard canStop else { return }
        page?.stop()
    }

    public func togglePin(_ id: SessionID) async {
        guard let s = snapshots.first(where: { $0.id == id }) else { return }
        await source.setPinned(!s.pinned, for: id)
    }

    /// Empty or unchanged titles are ignored.
    public func rename(_ id: SessionID, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, snapshots.first(where: { $0.id == id })?.title != title else { return }
        await source.rename(id, to: title)
    }

    public func forget(_ id: SessionID) async {
        do {
            try await source.forget(id)
            drafts[id] = nil
            if selection == .session(id) { selection = .home }
        } catch {
            notice = "Couldn't forget that session."
        }
    }

    /// The session store is attached (false with the `sessions` kill switch off).
    public var hasSessions: Bool { source.hasSessions }

    /// Settings › Privacy's "Forget All Sessions": every session, archived ones too. Returns how
    /// many couldn't be forgotten; an open session page goes back to Home.
    public func forgetAll() async -> Int {
        var failed = 0
        for session in snapshots {
            do {
                try await source.forget(session.id)
                if selection == .session(session.id) { selection = .home }
            } catch {
                failed += 1
            }
        }
        return failed
    }

    /// Home's composer with the `sessions` kill switch off.
    static let sessionsOff = "Sessions are turned off."

    /// Home's composer: opens the new session's page once it exists.
    @discardableResult
    public func ask(_ text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard source.hasSessions else {
            notice = Self.sessionsOff
            return false
        }
        guard let id = await source.startSession(text: text, attachments: homeAttachments) else {
            notice = "Couldn't start a session. Check Claude Code in Settings."
            return false
        }
        homeAttachments = []
        firstQuestion = (id, text)
        selection = .session(id)
        return true
    }

    private func selectionChanged(from old: Selection) {
        guard selection != old else { return }
        refreshPageVisibility()
        switch selection {
        case .session(let id): Task { await source.open(id) }
        case .settings(let page): lastSettingsPage = page
        case .home, .dictation: break
        }
    }
}
