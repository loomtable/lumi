import BuddyBridge
import BuddyCore
import BuddyOverlay
import Foundation

/// The top-centre progress capsules (owner, Oct 29): one per running query, from the moment it's
/// sent until its answer appears or it ends without one. A query the pill already shows (the
/// question in front, while it thinks) or a page on screen already shows has no capsule.
///
/// The coordinator feeds it every turn it runs (voice and Glance); `PageFlow` feeds composer
/// turns, so a turn whose page the user hid still shows one. Every line is a real event's.
///
/// What runs and what it's doing is the session's (owner, Oct 29): each query tells `live` it
/// began and ended, and a Quick turn's lines (no session events of its own), so the session's
/// snapshot is the one source. A capsule shows that snapshot's live line and ask, and only while
/// its turn runs, so it never disagrees with the page, the sidebar or the switcher.
@MainActor
public final class ProgressBoard {
    struct Query: Equatable {
        var session: SessionID
        /// The coordinator's epoch the question was asked in; nil for a page's own turn.
        var epoch: Int?
        /// The question's first words, until the session has a title of its own.
        var fallbackTitle: String
    }

    private let overlay: any OverlayPresenting
    private(set) var stack = ProgressStack()
    private(set) var queries: [Int: Query] = [:]
    private var nextID = 0
    private var shown: ProgressStack.Shown = .empty

    /// The epoch whose question the pill shows now (the coordinator's, while it thinks), or nil.
    var pillEpoch: () -> Int? = { nil }
    /// Every Lumi page on screen and the session it shows.
    var visiblePages: () -> [SessionID: PageKind] = { [:] }
    /// A session's title, glyph, colour, and what runs in it and what it's doing.
    var snapshot: (SessionID) -> SessionSnapshot? = { _ in nil }
    /// The sessions' read model: told when a query begins and ends and a Quick turn's lines.
    /// Its changes re-decide the capsules. Nil with sessions off: the capsules follow the events.
    weak var live: LiveSessions? {
        didSet { follow() }
    }
    private var watch: Task<Void, Never>?

    init(overlay: any OverlayPresenting) {
        self.overlay = overlay
    }

    /// A query was sent. Returns its id for `event` and `end`.
    @discardableResult
    func begin(session: SessionID, question: String, line: String? = nil, epoch: Int? = nil) -> Int {
        nextID += 1
        let words = question.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        let query = Query(session: session, epoch: epoch, fallbackTitle: words)
        queries[nextID] = query
        live?.queryBegan(session, line: line)
        let look = Self.look(query, snapshot(session))
        stack.begin(ProgressItem(id: nextID, title: look.title, symbol: look.symbol, color: look.color,
                                 line: line ?? StatusMapper.thinking, session: session, teammates: look.teammates))
        refresh()
        return nextID
    }

    /// One event of the query's turn: a new live line, or its end.
    func event(_ event: TurnStreamEvent, query id: Int) {
        guard let query = queries[id] else { return }
        if Self.ends(event) { return end(id) }
        if let waiting = Self.needsYou(event) {
            // A Deep-lane ask comes on the cascade, not the pool: the session learns of it here.
            if case .cascade(.turn(_, .hostEvent(let e))) = event { live?.apply(e, to: query.session) }
            stack.setNeedsYou(id, waiting.needsYou, line: waiting.line)
            return refresh()
        }
        // A generic "Thinking" says less than the step already shown: keep the step.
        if let line = Self.line(for: event), line != StatusMapper.thinking {
            stack.update(id, line: line)
            // The session's own events reach `live` from the pool; a Quick turn's only from here.
            if case .cascade = event { live?.queryLine(query.session, line) }
        }
        refresh()
    }

    /// The query's answer appeared, or it ended without one.
    func end(_ id: Int) {
        guard let query = queries.removeValue(forKey: id) else { return }
        stack.end(id)
        if !queries.values.contains(where: { $0.session == query.session }) { live?.queryEnded(query.session) }
        refresh()
    }

    /// The query's voice answer is ready and waits its turn to be spoken: its capsule says
    /// "Ready" until `played`, and the turn's own events and end no longer touch it.
    func ready(_ id: Int) {
        guard let query = queries.removeValue(forKey: id) else { return }
        if !queries.values.contains(where: { $0.session == query.session }) { live?.queryEnded(query.session) }
        stack.setNeedsYou(id, false)
        stack.update(id, line: Self.readyLine)
        refresh()
    }

    static let readyLine = "Ready"

    /// A ready answer is on screen now: its capsule goes.
    func played(_ id: Int) {
        stack.end(id)
        refresh()
    }

    /// The coordinator cancelled the session's question: it ends without a capsule. A page's own
    /// turn in that session keeps its own.
    func end(session: SessionID) {
        for (id, query) in queries where query.session == session && query.epoch != nil { end(id) }
    }

    /// Re-decides what's on screen: call when the pill, a page or a session may have changed.
    func refresh() {
        var stopped: Set<Int> = []
        for (id, query) in queries {
            let session = snapshot(query.session)
            let look = Self.look(query, session)
            stack.rename(id, title: look.title, symbol: look.symbol, color: look.color, teammates: look.teammates)
            guard let session else { continue }
            if !session.turnRunning { stopped.insert(id) }
            let waiting = Self.waiting(session)
            stack.setNeedsYou(id, waiting != nil, line: waiting ?? session.liveLine ?? StatusMapper.thinking)
            stack.setLastEvent(id, session.lastEventAt)
        }
        let next = stack.shown(hiding: hidden().union(stopped))
        guard next != shown else { return }
        shown = next
        overlay.updateProgress(next)
    }

    /// Queries something else on screen already shows: the pill, or a page of their session.
    func hidden() -> Set<Int> {
        let pill = pillEpoch()
        let pages = visiblePages()
        return Set(queries.compactMap { id, q in
            q.epoch != nil && q.epoch == pill || pages[q.session] != nil ? id : nil
        })
    }

    /// Re-decides the capsules on every change of the sessions.
    private func follow() {
        watch?.cancel()
        guard let changes = live?.changes() else { return }
        watch = Task { [weak self] in
            for await _ in changes { self?.refresh() }
        }
    }

    /// The capsule's words for an ask the user hasn't seen yet (03 §3.5); nil when nothing new waits.
    nonisolated static func waiting(_ session: SessionSnapshot) -> String? {
        guard session.needsAttention, case .needsYou(let ask) = session.status else { return nil }
        switch ask.kind {
        case .permission: return "Needs your OK"
        case .question: return "Has a question"
        case .soft: return nil
        }
    }

    /// The session's title and glyph, the question's first words while it's still "New session",
    /// and its teammates still working.
    nonisolated static func look(_ query: Query, _ snapshot: SessionSnapshot?)
        -> (title: String, symbol: String?, color: ConversationColor, teammates: Int) {
        let title = snapshot.map(\.title).flatMap { $0.isEmpty || $0 == "New session" ? nil : $0 }
        let teammates = snapshot?.liveTeam.count { $0.state.isRunning } ?? 0
        return (title ?? query.fallbackTitle, snapshot?.symbol, snapshot?.color ?? .ember, teammates)
    }

    /// The turn starts or stops waiting on the user (03 §3.5's words); nil for anything else.
    nonisolated static func needsYou(_ event: TurnStreamEvent) -> (needsYou: Bool, line: String?)? {
        switch event {
        case .session(.permissionRequested), .cascade(.turn(_, .hostEvent(.permissionRequested))): (true, "Needs your OK")
        case .session(.questionAsked), .cascade(.turn(_, .hostEvent(.questionAsked))): (true, "Has a question")
        case .session(.permissionResolved), .cascade(.turn(_, .hostEvent(.permissionResolved))): (false, nil)
        default: nil
        }
    }

    /// The answer is about to show, or the turn is over.
    nonisolated static func ends(_ event: TurnStreamEvent) -> Bool {
        switch event {
        case .cascade(.done), .session(.turnEnded), .session(.processEnded): true
        default: false
        }
    }

    /// What the capsule says for one event, the pill's words: nil when it shouldn't change.
    nonisolated static func line(for event: TurnStreamEvent) -> String? {
        switch event {
        case .cascade(.turn(_, .status(let status))): status
        case .cascade(.turn(_, .retrying(let retry))): TurnFailureLine.retrying(retry)
        case .cascade(.turn(_, .reconnecting)): "Reconnecting…"
        case .cascade(.handingOff): "Going deeper"
        case .cascade(.researchRequested): "Starting research"
        case .session(.step(let step)) where step.subagent == nil: TrailCopy.presentLine(step)
        case .session(.retrying): TrailCopy.retrying
        default: nil
        }
    }
}
