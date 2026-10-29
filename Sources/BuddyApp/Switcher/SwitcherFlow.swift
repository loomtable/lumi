import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyTrace
import Foundation

/// Runs one-shot work after a delay on the main actor; injectable so tests fire it by hand.
public struct SwitcherScheduler: Sendable {
    public var after: @MainActor @Sendable (Duration, @escaping @MainActor () -> Void) -> Task<Void, Never>

    public init(after: @escaping @MainActor @Sendable (Duration, @escaping @MainActor () -> Void) -> Task<Void, Never>) {
        self.after = after
    }

    public static let live = SwitcherScheduler { delay, work in
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { work() }
        }
    }
}

/// The switcher's gesture logic (03 §3.4, 00-PLAN): hold the buddy key and press Tab to pick
/// a session, or press Tab while Lumi listens after a tap.
///
/// Held: the press prepares the strip hidden (`prepare`); the first switcher key opens it and
/// the recording goes on; the release commits. With at least 0.4 s of speech the recording
/// goes to the highlighted session (or a new one for ＋); without, that session becomes
/// current and its answer peeks for 4 s. Esc restores the original.
///
/// Tap mode: the live recording retargets at once ("→ Trip to Lisbon" on the pill) and the pick
/// commits on Return, at the end of speech, or 1.5 s after the last switcher key.
///
/// The coordinator owns the recording and the send; this type only decides where it goes.
@MainActor
public final class SwitcherFlow {
    public enum Target: Sendable, Equatable {
        case session(SessionID)
        case new
    }

    public enum Outcome: Sendable, Equatable {
        /// The strip never came into it: handle the release as before.
        case none
        /// The user spoke: send the recording to the target (a session is already current).
        case send(Target)
        /// No speech: the session is now current and its answer peeks. Nothing is sent.
        case switched(SessionID)
        /// No speech on ＋: the next question starts a new session.
        case fresh
        /// Esc'd: still talking to the original session; `spoke` sends as a plain hold would.
        case restored(spoke: Bool)
    }

    public static let speechThreshold: TimeInterval = 0.4
    public static let peekAfterSwitch: Duration = .seconds(4)
    public static let tapCommitAfter: Duration = .milliseconds(1500)
    public static let archiveConfirmWithin: TimeInterval = 1.5
    /// The highlight resting this long on a session peeks its last answer (63-SWITCHER-UX).
    public static let dwellPeek: Duration = .milliseconds(600)

    private enum Phase: Equatable { case idle, prepared, open, locked, cancelled }

    private let presenter: any SwitcherPresenting
    private let sessions: any SessionsPort
    /// Seconds of speech the VAD heard since the press; nil when the voice can't tell, which
    /// counts as speech (the send then finds out).
    private let heardSpeech: @MainActor () async -> TimeInterval?
    private let scheduler: SwitcherScheduler
    private let trace: (any TracePort)?
    private let now: @MainActor () -> Date

    private var phase = Phase.idle
    private var tapMode = false
    private var tiles: [SessionSnapshot] = []
    private var highlight = 0
    private var original: SessionID?
    private var peeking = false
    private var archiveArmed: (id: SessionID, at: Date)?
    private var tapTimer: Task<Void, Never>?
    private var peekTimer: Task<Void, Never>?
    /// The 4 s peek after a switch is up (`showAnswer(of:)`).
    private var answerPeek = false
    private var dwellTimer: Task<Void, Never>?
    /// The open peek came from a dwell (not Space): the next move closes it instead of following.
    private var peekByDwell = false
    private var openedAt: ContinuousClock.Instant?
    /// The pick the next send must route to (held release with speech, or tap-mode commit),
    /// until the send takes it, a new listen starts, or the gesture is cancelled.
    private var pendingPick: Target?

    /// The pill's trailing hint: "→ Trip to Lisbon" while retargeting in tap mode, nil to
    /// restore the default.
    public var onHint: (@MainActor (String?) -> Void)?
    /// The name of the "next" key for the buddy key ("Tab", or "`" for a ⌘ buddy key).
    public var nextKeyName = "Tab"
    /// Tap mode: the pick is made (Return, the 1.5 s timeout, a click, the send) or Esc'd, so
    /// the key monitor should take only the openers again.
    public var onTapClosed: (@MainActor () -> Void)?
    /// Tap mode: the recording now goes to `target` (a session is already current).
    public var onTapCommit: (@MainActor (Target) -> Void)?
    /// The peek's inline Allow or Deny (request id, session, allow). Wired by the permission
    /// host; until then the buttons do nothing.
    public var onApprove: (@MainActor (String, SessionID, Bool) async -> Void)?
    /// Who the pill talks to as the highlight moves (the pill is the strip's header).
    public var onTarget: (@MainActor (PillTarget) -> Void)?

    public init(
        presenter: any SwitcherPresenting, sessions: any SessionsPort,
        heardSpeech: @escaping @MainActor () async -> TimeInterval? = { nil },
        scheduler: SwitcherScheduler = .live, trace: (any TracePort)? = nil,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.presenter = presenter
        self.sessions = sessions
        self.heardSpeech = heardSpeech
        self.scheduler = scheduler
        self.trace = trace
        self.now = now
    }

    /// The strip is on screen.
    public var isOpen: Bool { phase == .open }
    /// The strip or a peek is up: a ready answer waits (65-SURFACE-RULES, rule 4).
    public var holdsGlance: Bool { phase == .open || phase == .locked || peeking || answerPeek }
    /// The strip and its peeks are gone: the ready queue may go on.
    public var onGlanceFree: (@MainActor () -> Void)?

    private func noteGlanceFree() {
        if !holdsGlance { onGlanceFree?() }
    }
    /// Retargeting a tap-mode recording.
    public var inTapMode: Bool { tapMode }
    /// The buddy key's press, or listening started in tap mode: build the strip hidden.
    public func prepare() {
        guard phase == .idle else { return }
        original = sessions.current
        tiles = StripOrder.order(sessions.snapshots, current: original, now: now())
        highlight = StripOrder.firstHighlight(tiles, current: original)
        peeking = false
        archiveArmed = nil
        presenter.prepare(tiles: tiles)
        phase = .prepared
    }

    /// The gesture ended without the switcher (tap, hold, cancel), or listening stopped.
    public func reset() {
        tapTimer?.cancel()
        dwellTimer?.cancel()
        peekByDwell = false
        if phase != .idle { presenter.close(commit: false) }
        if peeking { presenter.peek(nil) }
        phase = .idle
        tapMode = false
        peeking = false
        noteGlanceFree()
    }

    /// A dictation began: close any strip or peek, end tap mode (so the key monitor takes only
    /// the openers again) and drop the pick.
    public func closeForDictation() {
        let wasTapMode = tapMode
        reset()
        pendingPick = nil
        if wasTapMode { onTapClosed?() }
    }

    /// A new listen started, or the gesture was abandoned: no pick carries over.
    public func clearPick() { pendingPick = nil }

    // MARK: Keys

    /// A switcher key while the buddy key is held (`GestureEvent.switcher`).
    public func key(_ key: SwitcherKey) async {
        if phase == .idle { prepare() }
        await apply(key)
    }

    /// A switcher key while Lumi listens with the key up (`BuddyKeyEvent.switcher`).
    public func tapKey(_ key: SwitcherKey) async {
        if phase == .idle { prepare() }
        tapMode = true
        await apply(key)
        switch phase {
        case .open:
            onHint?(hintForHighlight)
            tapTimer?.cancel()
            tapTimer = scheduler.after(Self.tapCommitAfter) { [weak self] in
                Task { await self?.commitTap() }
            }
        case .locked:
            await commitTap()
        case .cancelled:
            onHint?(nil)
            phase = .idle
            tapMode = false
            pendingPick = nil // Esc: back to the original
            onTapClosed?()
            noteGlanceFree()
        case .idle, .prepared:
            break
        }
    }

    private func apply(_ key: SwitcherKey) async {
        if phase == .prepared {
            guard key != .cancel, key != .unpeek else { return }
            var start = highlight
            switch key {
            case .prev: start = tiles.isEmpty ? 0 : tiles.count - 1
            case .index(let n) where n >= 1 && n <= tiles.count: start = n - 1
            case .new: start = tiles.count
            default: break
            }
            highlight = start
            openedAt = .now
            presenter.open(highlight: start)
            phase = .open
            onTarget?(pillTarget)
            armDwell()
            switch key {
            case .next, .prev, .index, .new: return
            default: break // peek, commit, pin… act on the opened strip
            }
        }
        guard phase == .open else { return }
        let count = tiles.count + 1 // ＋ is last
        switch key {
        case .next: move(to: (highlight + 1) % count)
        case .prev: move(to: (highlight - 1 + count) % count)
        case .index(let n): if n >= 1, n <= tiles.count { move(to: n - 1) }
        case .new: move(to: tiles.count)
        case .commit:
            phase = .locked
            closePeek()
            presenter.close(commit: true)
        case .cancel:
            highlight = original.flatMap { id in tiles.firstIndex { $0.id == id } } ?? 0
            phase = .cancelled
            closePeek()
            presenter.close(commit: false)
            onTarget?(original.flatMap { id in tiles.first { $0.id == id } }.map(PillTarget.session) ?? .none)
        case .peek:
            dwellTimer?.cancel()
            peekByDwell = false
            peeking.toggle()
            presenter.peek(peeking ? highlightedID : nil)
        case .unpeek:
            closePeek()
        case .teammates:
            dwellTimer?.cancel()
            peekByDwell = false
            peeking = true
            presenter.peek(highlightedID)
        case .pin:
            guard let s = highlighted else { return }
            await sessions.setPinned(!s.pinned, for: s.id)
            sessionsChanged(sessions.snapshots)
        case .archive:
            guard let s = highlighted else { return }
            if case .thinking = s.status {
                // A running session needs a second ⌫ within 1.5 s.
                let armed = archiveArmed.map { $0.id == s.id && now().timeIntervalSince($0.at) <= Self.archiveConfirmWithin } ?? false
                guard armed else {
                    archiveArmed = (s.id, now())
                    return
                }
            }
            archiveArmed = nil
            await sessions.setArchived(true, for: s.id)
            sessionsChanged(sessions.snapshots)
        }
    }

    private func move(to index: Int) {
        highlight = index
        archiveArmed = nil
        presenter.move(to: index)
        onTarget?(pillTarget)
        if peekByDwell { closePeek() }
        if peeking { presenter.peek(highlightedID) } else { armDwell() }
    }

    /// Peeks the highlighted session once the highlight rests (not ＋, not while a peek is up).
    private func armDwell() {
        dwellTimer?.cancel()
        guard !peeking, highlighted != nil else { return }
        let index = highlight
        dwellTimer = scheduler.after(Self.dwellPeek) { [weak self] in
            guard let self, self.phase == .open, self.highlight == index, !self.peeking else { return }
            self.peeking = true
            self.peekByDwell = true
            self.presenter.peek(self.highlightedID)
        }
    }

    private func closePeek() {
        dwellTimer?.cancel()
        if peeking { presenter.peek(nil) }
        peeking = false
        peekByDwell = false
        noteGlanceFree()
    }

    // MARK: Commit

    /// The buddy key's release while switching (`GestureEvent.switcherReleased`).
    public func released() async -> Outcome {
        tapTimer?.cancel()
        let was = phase
        let target = currentTarget
        phase = .idle
        tapMode = false
        switch was {
        case .idle:
            return .none
        case .prepared, .cancelled:
            if was == .prepared { presenter.close(commit: false) } // Esc already closed it
            return .restored(spoke: await spoke())
        case .open, .locked:
            closePeek()
            if was == .open { presenter.close(commit: true) }
            let spoke = await spoke()
            pendingPick = spoke ? target : nil
            switch target {
            case .session(let id):
                await sessions.setCurrent(id)
                if spoke { return .send(target) }
                showAnswer(of: id)
                return .switched(id)
            case .new:
                return spoke ? .send(.new) : .fresh
            }
        }
    }

    /// The pick the send routes to, taken once (QA R1: the pick, not the routing rules, decides
    /// where the turn goes). An open tap-mode strip commits first. Nil: route as usual.
    public func takePick() async -> Target? {
        await commitOpenTap()
        defer { pendingPick = nil }
        return pendingPick
    }

    /// Tap mode's sending tap: an open strip commits now, so the recording goes to the pick.
    public func commitOpenTap() async {
        if tapMode, phase == .open { await commitTap() }
    }

    private func commitTap() async {
        guard tapMode, phase == .open || phase == .locked else { return }
        tapTimer?.cancel()
        let target = currentTarget
        closePeek()
        if phase == .open { presenter.close(commit: true) }
        phase = .idle
        tapMode = false
        pendingPick = target
        if case .session(let id) = target { await sessions.setCurrent(id) }
        onHint?(hintFor(target))
        onTapCommit?(target)
        onTapClosed?()
    }

    /// The session's last answer as its peek, for 4 s (after a switch, or a banner click).
    public func showAnswer(of id: SessionID) {
        presenter.peek(id)
        peekTimer?.cancel()
        answerPeek = true
        peekTimer = scheduler.after(Self.peekAfterSwitch) { [weak self] in
            guard let self else { return }
            // Its 4 s are over whatever came since (a strip built for the next press, a user's own
            // peek), so it never holds the Glance longer; only a peek nobody replaced goes away.
            self.answerPeek = false
            if !self.peeking, self.phase == .idle || self.phase == .prepared { self.presenter.peek(nil) }
            self.noteGlanceFree()
        }
    }

    /// An answer took the Glance: a peek gives way, as one answer shows at a time
    /// (65-SURFACE-RULES, rule 1).
    public func glanceShown() {
        guard peeking || answerPeek else { return }
        peekTimer?.cancel()
        answerPeek = false
        dwellTimer?.cancel()
        (peeking, peekByDwell) = (false, false)
        presenter.peek(nil)
    }

    // MARK: Clicks and updates

    /// A click or hover on the strip.
    public func handle(_ event: SwitcherEvent) async {
        switch event {
        case .highlighted(let i) where phase == .open && i != highlight && i <= tiles.count:
            move(to: i)
        case .tileClicked(let id):
            guard phase == .open, let i = tiles.firstIndex(where: { $0.id == id }) else { return }
            move(to: i)
            await commitClick()
        case .newSessionClicked:
            guard phase == .open else { return }
            move(to: tiles.count)
            await commitClick()
        case .approve(let requestID, let session, let allow):
            await onApprove?(requestID, session, allow)
        default:
            break
        }
    }

    /// A click commits like Return: held, the release then sends or switches; in tap mode, now.
    private func commitClick() async {
        if tapMode {
            await commitTap()
        } else {
            phase = .locked
            closePeek()
            presenter.close(commit: true)
        }
    }

    /// The strip's first frame is on screen (`LiveSwitcher.onShown`).
    public func stripShown() {
        guard let openedAt else { return }
        trace?.record(.switcherShown, duration: .now - openedAt, lane: nil, outcome: nil, count: tiles.count)
        self.openedAt = nil
    }

    /// Every sessions change: keep the frozen tiles in step (archived and forgotten collapse).
    public func sessionsChanged(_ latest: [SessionSnapshot]) {
        guard phase != .idle else { return }
        let id = highlightedID
        tiles = StripOrder.refresh(tiles, with: latest)
        highlight = id.flatMap { id in tiles.firstIndex { $0.id == id } } ?? min(highlight, tiles.count)
    }

    /// Who a new press talks to, as far as it's known before the send: ＋ for a fresh press; the
    /// current session while a question would continue it (used within the idle limit and not
    /// running a turn, SummonRouter's rule 5); else nothing, and the send decides.
    public func pressTarget(fresh: Bool) -> PillTarget {
        if fresh { return .new }
        guard let id = sessions.current, let s = snapshot(id), !s.archived,
              now().timeIntervalSince(s.lastUsed) < ConversationBook.idleLimit else { return .none }
        if case .thinking = s.status { return .none }
        return .session(s)
    }

    public func snapshot(_ id: SessionID) -> SessionSnapshot? { sessions.snapshots.first { $0.id == id } }

    /// The listening pill's hint when something is waiting: "1 waiting · Tab".
    public func waitingHint() -> String? {
        let n = sessions.snapshots.count { s in
            s.id != sessions.current && !s.archived && s.needsAttention
        }
        return n == 0 ? nil : "\(n) waiting · \(nextKeyName)"
    }

    // MARK: -

    private var highlighted: SessionSnapshot? { highlight < tiles.count ? tiles[highlight] : nil }
    private var highlightedID: SessionID? { highlighted?.id }
    private var currentTarget: Target { highlighted.map { .session($0.id) } ?? .new }
    private var pillTarget: PillTarget { highlighted.map(PillTarget.session) ?? .new }
    private var hintForHighlight: String { hintFor(currentTarget) }

    private func hintFor(_ target: Target) -> String {
        switch target {
        case .session(let id): "→ " + (tiles.first { $0.id == id }?.title ?? "session")
        case .new: "→ New session"
        }
    }

    private func spoke() async -> Bool {
        guard let seconds = await heardSpeech() else { return true }
        return seconds >= Self.speechThreshold
    }
}
