import BuddyBridge
import BuddyCompanion
import BuddyContext
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyTrace
import BuddyVoice
import CoreGraphics
import Foundation
import Synchronization

/// Runs one question end to end: buddy key → listen → packet and screenshot →
/// Quick (→ Deep) → speak the headline and show the chip or card.
///
/// Everything it shows or says comes from a real event: a gesture, a voice event, a stream
/// event or a measured result. It never invents a status or an estimate.
///
/// Concurrency: the coordinator is main-actor isolated, but every path awaits voice, context or
/// the bridge, and the user can press the key or Esc in between. Each request takes the current
/// `epoch`; a new press, Esc, discard, new conversation or pause bumps it, and every path checks
/// `isCurrent` after each await and stops quietly when it is stale.
@MainActor
public final class BuddyCoordinator {
    public struct Settings: Sendable, Equatable {
        public enum VoiceReplies: Sendable, Equatable { case always, onlyWhenSpoken, off }

        public var routing: Routing = .auto
        public var quick: ModeConfig = .default(for: .quick)
        public var deep: ModeConfig = .default(for: .deep)
        /// For the Research lane's label; the job itself launches with the shell's config.
        public var research: ModeConfig = .default(for: .research)
        public var voiceReplies: VoiceReplies = .onlyWhenSpoken
        public var sounds = true
        /// Rings on screen. Off: no rings, and no OCR or AX work to place them.
        public var rings = true
        /// Insert & Replace. Off: the main button is only ever Copy.
        public var insert = true
        /// Shown in hints: "tap ⌥ to send".
        public var keySymbol = BuddyKey.rightOption.symbol

        public init() {}
    }

    public enum Phase: Equatable {
        case idle
        /// `confirmedTap` is true once the first tap is confirmed (tap-to-talk); the next tap sends.
        case listening(confirmedTap: Bool, holding: Bool)
        /// Listening stopped by itself and kept the recording: tap sends it, Esc discards it.
        case held
        /// The double-tap text box is open: ↵ sends, Esc closes.
        case typing
        case thinking
        case showing
    }

    /// Told of every phase change (the menu bar icon follows it).
    public var onPhaseChange: (@MainActor (Phase) -> Void)?

    /// The send (its epoch) waiting for its transcript: only its "Transcribing…" notices show, so a
    /// late one never lands on a later question (after Esc and a typed question, say).
    var awaitingTranscript: Int?
    /// That send showed a notice, which goes once the transcript is in.
    var transcribingShown = false
    public internal(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue {
                onPhaseChange?(phase)
                progress.refresh() // the pill may have taken or left a question
                answerHeard = false
                if phase == .idle { playNextReady() }
            }
            // The screen-sharing watch and the listen's flags live exactly as long as a listen.
            if case .listening = phase {} else {
                endSharingWatch()
                micLive = false
                interruptSent = false
            }
            noteFront()
        }
    }
    public var settings: Settings {
        didSet {
            guard settings.sounds != oldValue.sounds else { return }
            let (voice, on) = (voice, settings.sounds)
            Task { await voice.setSoundsEnabled(on) }
        }
    }
    /// Called each time a model's answer (chip or card) is shown; never for error lines, held
    /// recordings or cancels. Onboarding's "Try it" step uses it.
    public var onAnswerShown: (@MainActor () -> Void)?
    /// ⌘Y in a focused card: the shell opens the Lumi window, whose sidebar is the history.
    public var onOpenLumiWindow: (@MainActor () -> Void)?
    /// "Saved in Dictation history" › Open (`FixAction.openDictationHistory`).
    public var onOpenDictationHistory: (@MainActor () -> Void)?
    /// A failure chip's "Repair plugin" (`FixAction.repairPlugin`): the runtime copies a fresh plugin
    /// and restarts Claude Code onto it, so the coordinator never touches ClaudeCodeService.
    public var onRepairPlugin: (@MainActor () -> Void)?
    /// Each session's permission mode, from its `system/init` (`.initialized(info)`): the runtime
    /// shows a menu line while it isn't auto and clears it when auto is back.
    public var onPermissionMode: (@MainActor (String) -> Void)?
    /// Each session's MCP servers and their status, from its `system/init`: the runtime shows a menu
    /// line for any that need sign-in or failed to connect, per lane, and clears it once they're fine.
    public var onMCPServers: (@MainActor (Mode, [StreamEvent.MCPServer]) -> Void)?
    /// A failure chip's "Use Sonnet 5.5" (`FixAction.useModel`): the runtime switches that lane's model
    /// in Settings › Models, for good, and returns once the lane runs on it, so the question can be
    /// asked again. Show `TurnFailureLine.modelSwitched` afterwards: the switch is never silent.
    public var onUseModel: (@MainActor (ModelID, Mode) async -> Void)?
    /// A failure chip's "Fix" / "Open Settings": opens that pane of Lumi's Settings.
    public var onOpenSettingsPane: (@MainActor (SettingsPane) -> Void)?
    /// A click on a progress capsule that needs the user, when no voice turn of ours waits there:
    /// the runtime opens that session's page.
    public var onOpenWaiting: (@MainActor (SessionID) -> Void)?
    /// ⌘, in a card: Settings at whichever pane it last showed.
    public var onOpenSettings: (@MainActor () -> Void)?
    /// The permission chip's "Fix": the runtime's grant flow for that permission.
    public var onGrantPermission: (@MainActor (PermissionKind) -> Void)?
    /// Where the reply hint's lesson is kept: once the user has replied by the key and by clicking,
    /// the hint is gone for good. Nil keeps it for this run only (tests); the runtime sets it.
    public var hintDefaults: UserDefaults? {
        didSet {
            repliedByKey = repliedByKey || hintDefaults?.bool(forKey: Self.repliedByKeyKey) == true
            repliedByClick = repliedByClick || hintDefaults?.bool(forKey: Self.repliedByClickKey) == true
        }
    }
    static let repliedByKeyKey = "hints.repliedByKey"
    static let repliedByClickKey = "hints.repliedByClick"
    var repliedByKey = false
    var repliedByClick = false
    /// Whether the buddy key's double-tap works, read as a setup chip is worded: the key monitor
    /// turns it off while Sticky Keys is on, and then no chip offers it. The runtime sets it.
    public var doubleTapAvailable: @MainActor () -> Bool = { true }
    /// Paused from the menu bar: gestures are ignored and nothing is captured.
    public internal(set) var isPaused = false

    let voice: any VoicePort
    let context: any ContextPort
    let turns: any TurnPort
    let overlay: any OverlayPresenting
    let inserter: (any InsertPort)?
    let escape: (any EscapePort)?
    let pointer: any PointerPort
    let locator: (any LocatePort)?
    let interruptions: (any SystemInterruptionSource)?
    let tracer: (any TracePort)?
    let research: (any ResearchPort)?
    let setKeyListening: @Sendable (Bool) async -> Void
    let conversations: any ConversationPort
    /// Picks each turn's conversation (Phase 0: today's rules, `ConversationRouting`).
    var routing: any TurnRouting
    /// Picks each answer's surface (Phase 0: always the Glance).
    var delivery: any AnswerDelivery = GlanceDelivery()
    /// The Lumi pages on screen, for routing a talk-key turn into the page.
    var pages: any PageSurfaces = NoPageSurfaces()
    /// The switcher stream's flow; nil until it's built.
    var switcherFlow: SwitcherFlow?
    /// The conversation stream's Panel flow; nil until it's built.
    var pageFlow: PageFlow?
    /// Where the next question goes when a pick decided it (a switcher pick): read once by
    /// the next ask. It expires: a discard, Esc or a new listen clears it, and so does
    /// `routeSourceLifetime` passing, so a pick followed by nothing never steers a later question.
    /// A new-conversation request is `TurnRouting.startNewSession()` instead, which doesn't expire.
    var nextRouteSource: SummonInput.Source? {
        didSet { nextRouteSourceSetAt = nextRouteSource == nil ? nil : clock() }
    }
    var nextRouteSourceSetAt: Date?
    static let routeSourceLifetime: TimeInterval = 60
    /// A switcher pick made without speech (released on a tile): the next summon goes there, even
    /// over the context rule (V-12), within `routeSourceLifetime`.
    var switchedTo: (id: SessionID, at: Date)?
    /// The speech generation the in-page answer now speaking began in.
    var pageSpeechGeneration = 0

    /// The pick for this ask, if it's still fresh; cleared either way.
    func takeRouteSource() -> SummonInput.Source? {
        defer { nextRouteSource = nil }
        guard let source = nextRouteSource, let at = nextRouteSourceSetAt,
              clock().timeIntervalSince(at) <= Self.routeSourceLifetime else { return nil }
        return source
    }
    /// The dictation key's controller (keys stream); nil while `LumiFeatures.dictation` is off.
    var dictation: DictationController?
    /// Opens System Settings for a `buddy://settings/…` action.
    let openURL: (any OpenURLPort)?
    /// Trusted folders, read per question: they bound where a browser repo page looks for a local clone.
    let trust: @Sendable () -> FolderTrust

    var epoch = 0 {
        didSet { noteFront() }
    }
    /// With sessions on (the runtime sets it): a new press or the switcher never cancels a running
    /// turn. It moves to the background and finishes there (V-02); only Esc and Stop cancel.
    public var turnsKeepRunning = false
    /// Every turn `run` follows, in front and in the background.
    var tickets: [TurnTicket] = []
    /// Voice answers that finished behind a newer question, oldest first: each is shown and
    /// spoken in turn once the Glance is free (`playNextReady`).
    var readyAnswers: [ReadyAnswer] = []
    var readyTask: Task<Void, Never>?
    /// The voice is saying something (from a started `speak` to `.speakingFinished`), or about
    /// to (`speak` calls not yet returned).
    var speaking = false
    var speechStarting = 0
    /// The card up has had its turn (its reading time, `giveReadingTime`): the next ready answer
    /// may replace it once the voice is quiet. Every Glance starts without it.
    var answerHeard = false
    /// Counts the card's reading time (`giveReadingTime`).
    var readingTimer: Task<Void, Never>?
    /// Epochs Esc cancelled while their turn was still being sent: the send cancels it after.
    var cancelledEpochs: Set<Int> = []
    /// The approval card on screen (V-03), and the one that was up when the current listen began:
    /// a spoken yes or no answers it.
    var shownApproval: ShownApproval?
    var answeringApproval: ShownApproval?
    /// Told when what the Glance shows changes: its session, or the turn it follows.
    public var onFrontChanged: (@MainActor () -> Void)?
    var lastFront: Front?
    /// The running questions' capsules at the top centre.
    let progress: ProgressBoard
    /// Set after a discard asked for confirmation (over 30 s of speech): the next Esc confirms.
    var discardNeedsConfirmation = false
    /// Whether the held-recording chip is on screen, and whether a press just re-showed it.
    var heldChipVisible = false
    var heldReminderShown = false
    /// The current listen's mic started; before that an interrupt has nothing to keep.
    var micLive = false
    /// The current listen was already stopped from outside (one lid close sends several events).
    var interruptSent = false
    /// An interrupt landed while the key was still down: its release must not send the speech
    /// the user hasn't seen kept (it would go out over a shared screen).
    var releasePending = false
    /// The last buddy-key press had ⇧ (⌃) held: the listen it starts goes to a new conversation.
    var pressFresh = false
    /// This listen's question starts a new conversation (⇧ + buddy key, or "new topic").
    var listenFresh = false
    /// A ⇧ press that came while an answer was in flight or on screen, waiting to be a tap or hold.
    var freshPressWaiting = false
    /// Conversations already told they're long (once each).
    var longHinted: Set<String> = []
    /// Quick's context size (tokens) from which answers slow noticeably: the card says "long".
    static let longConversationTokens = 50_000
    /// Bumped by "stop speaking", so a reply still synthesising never starts afterwards, without
    /// detaching the turn itself (its answer still shows).
    var speechGeneration = 0
    var capture: Task<Summon, Never>?
    /// A screenshot that takes longer is given up on: the question goes without it.
    var screenshotDeadline: Duration = .milliseconds(1500)
    var summonSound: Task<Void, Never>?
    var escapeTask: Task<Void, Never>?
    var pumps: [Task<Void, Never>] = []
    var sharingWatch: Task<Void, Never>?
    /// Whether the overlay has put the last `showAnswer` on screen, and who waits for it.
    var answerOnScreen = true
    var presentWaiters: [CheckedContinuation<Void, Never>] = []
    var presentCap: Task<Void, Never>?
    /// Counts the wait in the pill when nothing new has been shown for a while.
    var quietStatus: Task<Void, Never>?
    /// After this long with no new status, the pill says "Thinking · 12 s", measured from the
    /// question, so a long turn never looks stuck. Then it ticks every `quietTick`.
    var quietAfter: Duration = .seconds(5)
    var quietTick: Duration = .seconds(1)
    /// A required permission that's missing (Accessibility or Screen Recording), from the runtime.
    var missingPermission: PermissionKind?
    /// Its chip shows once per app session, after an answer closes, and again only for a new kind.
    var permissionChipShown = false
    var permissionChipFade: Task<Void, Never>?
    /// Uninvited, like the Back chip, so it goes by itself after this long.
    var permissionChipLifetime: Duration = .seconds(8)
    let clock: @Sendable () -> Date
    /// When the last answer was shown: a summon after the idle limit starts a fresh conversation.
    var lastAnswerAt: Date?
    /// The longest an answer's speech waits for its card, so audio can't stall on the overlay. Past
    /// the card's own worst case (the overlay's 1.5 s card-load budget, then placement), so it's
    /// only a guard.
    static let presentWait: Duration = .seconds(2)
    /// How the summon sound's delay and the present cap wait. Tests pass one they release by hand,
    /// so neither depends on wall-clock time.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The last question asked, reused by Go deeper and actions.
    var lastQuestion: Question?
    /// The last screen sent in a conversation, under the token the bridge knows it by.
    var lastScreen: (conversation: String, fingerprint: ScreenFingerprint, token: String)?
    var lastAnswer: BuddyBlock?
    /// The shown answer's main button (Insert, Replace or Copy), if it has one.
    var lastMainAction: MainAction?
    /// The last real answer (never a chip), for `recallLastAnswer`: the very `Answer` shown, since
    /// the overlay finds its spot by it. Cleared as soon as a new question takes over the turn state.
    var kept: (answer: Answer, block: BuddyBlock, mainAction: MainAction?, conversationID: String, anchor: Anchor)?
    /// Whether the card up is that answer: a chip or the report card replaces it.
    var keptOnScreen = false
    /// The failure chip's fix button, while that chip is up.
    var shownFix: FixAction?
    /// The lane whose failure the fix chip reports (a model switch asks again there).
    var shownFixLane: Mode = .quick
    /// Whether the failed question was spoken: a model switch asks the same question again.
    var shownFixSpoke = false
    /// What was sent last, so "Try again" and "Use <model>" send it again the same way.
    var lastSent: Resend?

    enum Resend {
        /// Through the cascade: `shown` is the transcript's line when it isn't the prompt (an
        /// action's label); `typed`, whether it came from the keyboard.
        case ask(Question, shown: String?, typed: Bool)
        /// Go deeper.
        case deeper(Question)
        /// The screen capture was gone before a question existed: capture again, then ask.
        case capture(transcript: String, typed: Bool)
    }
    /// The app the turn was summoned in: Insert goes into its focused field.
    var targetPID: Int32?
    var lastAnchor: Anchor = .point(.zero)
    /// Where the listening pill opened, so the text box replaces it in place.
    var summonPoint: CGPoint = .zero
    /// The answer showing was typed for, so its card has keyboard focus (the overlay focuses it).
    var typedCardShowing = false
    /// A research report card is showing: it isn't this conversation's answer, so its reply
    /// field and buttons don't act (follow-ups on a report come later).
    var reportShowing = false
    /// The voice's latest setup state, and whether its chip is up (it then follows progress).
    var voiceSetup: VoiceController.PrepareState = .notStarted
    var setupChipVisible = false
    /// Whether the user spoke the request each research job came from (Voice replies).
    var researchSpoke: [UUID: Bool] = [:]
    /// The conversation of the turn last sent to the bridge: what Esc while thinking cancels,
    /// even if the shell switched the current conversation meanwhile.
    var inFlightConversation: String?

    /// The user is typing in the text box or a typed card. Right ⌥ then may be part of a
    /// character (é, €, AltGr layouts), so only a clean tap or hold starts listening.
    var keyboardInOverlay: Bool {
        phase == .typing || (phase == .showing && typedCardShowing)
    }
    /// The app the last answer's points are looked up in, kept for follow-ups in the same card.
    /// The summon screenshot is OCR'd only for that summon's own answer (`epoch`): later answers
    /// arrive after the screen may have scrolled, so they use AX only. It's dropped when the card
    /// closes, so a full-resolution capture isn't held while idle.
    var ringSource: RingSource?

    public init(
        settings: Settings = Settings(),
        voice: any VoicePort,
        context: any ContextPort,
        turns: any TurnPort,
        overlay: any OverlayPresenting,
        inserter: (any InsertPort)? = nil,
        escape: (any EscapePort)? = nil,
        pointer: any PointerPort,
        locator: (any LocatePort)? = nil,
        interruptions: (any SystemInterruptionSource)? = nil,
        trace: (any TracePort)? = nil,
        research: (any ResearchPort)? = nil,
        conversations: (any ConversationPort)? = nil,
        openURL: (any OpenURLPort)? = nil,
        trust: @escaping @Sendable () -> FolderTrust = { FolderTrust.load(home: FileManager.default.homeDirectoryForCurrentUser) },
        clock: @escaping @Sendable () -> Date = Date.init,
        setKeyListening: @escaping @Sendable (Bool) async -> Void = { _ in }
    ) {
        self.settings = settings
        self.voice = voice
        self.context = context
        self.turns = turns
        self.overlay = overlay
        self.inserter = inserter
        self.escape = escape
        self.pointer = pointer
        self.locator = locator
        self.interruptions = interruptions
        self.tracer = trace
        self.research = research
        self.setKeyListening = setKeyListening
        let conversations = conversations ?? MemoryConversations(clock: clock)
        self.conversations = conversations
        self.routing = ConversationRouting(conversations: conversations, trust: trust)
        self.openURL = openURL
        self.trust = trust
        self.clock = clock
        self.progress = ProgressBoard(overlay: overlay)
        // The turn the pill (or its approval card) shows has no capsule; one moved behind does.
        progress.pillEpoch = { [weak self] in
            guard let self, let ticket = self.foregroundTicket,
                  self.phase == .thinking || self.shownApproval?.ticket === ticket else { return nil }
            return ticket.id
        }
    }

    /// Starts consuming overlay events and voice levels. Call once.
    public func start() {
        research?.onDone = { [weak self] job in self?.researchFinished(job) }
        research?.activate()
        let (voiceForSounds, soundsOn) = (voice, settings.sounds)
        Task { await voiceForSounds.setSoundsEnabled(soundsOn) }
        let overlayEvents = overlay.events
        let levels = voice.levels
        let voiceEvents = voice.events
        pumps.append(Task { [weak self] in
            for await event in overlayEvents { self?.handle(event) }
        })
        pumps.append(Task { [weak self] in
            for await level in levels { self?.apply(level) }
        })
        pumps.append(Task { [weak self] in
            for await event in voiceEvents { await self?.handle(event) }
        })
        // Lock and sleep notifications arrive on the main run loop, so subscribe here, on main.
        if let system = interruptions?.events() {
            pumps.append(Task { [weak self] in
                for await event in system { await self?.handle(event) }
            })
        }
    }

    public func stop() {
        epoch += 1
        if phase != .idle, phase != .thinking, phase != .showing {
            Task { [voice] in _ = await voice.discard(confirmed: true, playSound: false) }
        }
        pumps.forEach { $0.cancel() }
        pumps.removeAll()
        endSharingWatch()
        capture?.cancel()
        summonSound?.cancel()
        escapeTask?.cancel()
        escape?.deactivate()
    }

    public func setPaused(_ paused: Bool) async {
        isPaused = paused
        guard paused else { return playNextReady() }
        await dictation?.cancel() // its words are kept
        await cancelCurrent()
        await voice.stopSpeaking()
        overlay.setSpeaking(false)
    }

    /// Ends whatever is in flight: discards a recording, or cancels a turn.
    func cancelCurrent() async {
        switch phase {
        case .listening, .held: await discardListening(sound: false)
        case .typing: closeTextBox()
        case .thinking: await escapePressed()
        case .showing, .idle: break
        }
    }

    func isCurrent(_ mine: Int) -> Bool { mine == epoch }

    /// A new request: everything older becomes stale.
    func nextEpoch() -> Int {
        epoch += 1
        return epoch
    }
}

/// Where an answer's points are looked up (see `ringSource`).
struct RingSource {
    var pid: Int32
    var shot: CapturedShot?
    var epoch: Int
}

/// What the summon captured while the user spoke.
extension BuddyCoordinator {
    /// The screenshot, or `capture_failed` once `deadline` passes. Not a task group: that would
    /// wait for a capture that never returns. A late capture is dropped.
    nonisolated static func screenshot(
        _ context: any ContextPort, displayID: UInt32?, focus: ModelRegion.Focus? = nil, within deadline: Duration
    ) async -> ShotOutcome {
        let once = Mutex<CheckedContinuation<ShotOutcome, Never>?>(nil)
        @Sendable func finish(_ outcome: ShotOutcome) {
            once.withLock { c in c.take() }?.resume(returning: outcome)
        }
        return await withCheckedContinuation { continuation in
            once.withLock { $0 = continuation }
            Task { finish(await context.screenshot(displayID: displayID, focus: focus)) }
            Task {
                try? await Task.sleep(for: deadline)
                finish(.unavailable(.captureFailed))
            }
        }
    }
}

struct Summon: Sendable {
    var context: SummonContext
    var shot: CapturedShot?
    /// Why `shot` is nil (never set for a blocked app, which isn't captured at all).
    var unavailable: ContextPacket.ScreenshotUnavailable?
    /// `shot` at the model's image size, to compare with the next one.
    var fingerprint: ScreenFingerprint?
    /// The token of the last screen sent, when this capture shows the same screen.
    var sameAs: String?
}

/// Per-turn bookkeeping while a cascade stream runs.
struct ReplyTracker {
    var question: String
    /// An open session's voice turn: its main-thread steps, for "⤢ 6 steps" on the card.
    var steps = StepTally()
    /// What the transcript shows as the question: the user's words, or a pressed button's label.
    var shownQuestion = ""
    var conversationID: String
    /// The send gesture (or the request, for typed questions and buttons), for trace timings.
    var startedAt: ContinuousClock.Instant = .now
    var sawEvent = false
    var deepStarted = false
    var handoffAt: ContinuousClock.Instant?
    /// Typed in the text box or the reply field: the answer card takes focus.
    var typed = false
    var lane: Mode?
    var spoken: String?
    var saidFull = false
    /// The pill shows the streamed headline while it's spoken.
    var headlineInPill = false
    /// The line shown from the captured packet at send ("Looking at Safari"), kept while Quick thinks.
    var opening: String?
    /// The cascade asked for Research (router or an allowed Quick hand-off).
    var researchRequested = false
    /// This turn has started a reply; later pieces continue it rather than cut it off. Safe only
    /// because a new turn always gets a new tracker and a new epoch.
    var speaking = false
    /// The speech generation the reply began in; a stop bumps it, silencing the rest of the turn.
    var speechGeneration: Int?

    mutating func startedSpeaking(_ generation: Int) {
        speaking = true
        if speechGeneration == nil { speechGeneration = generation }
    }
    var error: BridgeError?
    /// The buddy plugin didn't load in this turn's session.
    var pluginProblem: TurnFailureLine.Line?
    /// Tools Claude Code denied during the turn (`permissionNotice(.denied)`), possibly repeated.
    var deniedTools: [String] = []
    var finished = false
    /// A session turn's latency marks (first event; in a page, also first word and answer).
    var marks = TurnMarks()
}

/// A voice turn's main-thread steps (04 §3.3): the Glance card's ⤢ Continue shows their count
/// only when the turn did work worth reviewing (an edit, an approval or a teammate).
struct StepTally: Equatable {
    private var ids: Set<String> = []
    private var reviewable = false

    mutating func apply(_ event: SessionEvent) {
        switch event {
        case .step(let step) where step.subagent == nil:
            ids.insert(step.id)
            if step.kind == .edit || step.kind == .write || step.kind == .agent { reviewable = true }
        case .permissionRequested:
            reviewable = true
        case .task(.started(_, _, _, _, .agent)):
            reviewable = true
        default:
            break
        }
    }

    /// Nil when nothing is worth reviewing; otherwise at least 1.
    var shown: Int? { reviewable ? max(ids.count, 1) : nil }
}
