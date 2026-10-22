import BuddyBridge
import BuddyCompanion
import BuddyContext
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
    private var awaitingTranscript: Int?
    /// That send showed a notice, which goes once the transcript is in.
    private var transcribingShown = false
    public private(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue { onPhaseChange?(phase) }
            // The screen-sharing watch and the listen's flags live exactly as long as a listen.
            if case .listening = phase {} else {
                endSharingWatch()
                micLive = false
                interruptSent = false
            }
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
    /// ⌘Y in a focused card: the shell opens the Conversations window.
    public var onOpenConversations: (@MainActor () -> Void)?
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
    private var repliedByKey = false
    private var repliedByClick = false
    /// Whether the buddy key's double-tap works, read as a setup chip is worded: the key monitor
    /// turns it off while Sticky Keys is on, and then no chip offers it. The runtime sets it.
    public var doubleTapAvailable: @MainActor () -> Bool = { true }
    /// Paused from the menu bar: gestures are ignored and nothing is captured.
    public private(set) var isPaused = false

    private let voice: any VoicePort
    private let context: any ContextPort
    private let bridge: any BridgePort
    private let overlay: any OverlayPresenting
    private let inserter: (any InsertPort)?
    private let escape: (any EscapePort)?
    private let pointer: any PointerPort
    private let locator: (any LocatePort)?
    private let interruptions: (any SystemInterruptionSource)?
    private let tracer: (any TracePort)?
    private let research: (any ResearchPort)?
    private let setKeyListening: @Sendable (Bool) async -> Void
    private let conversations: any ConversationPort
    /// Opens System Settings for a `buddy://settings/…` action.
    private let openURL: (any OpenURLPort)?
    /// Trusted folders, read per question: they bound where a browser repo page looks for a local clone.
    private let trust: @Sendable () -> FolderTrust

    private var epoch = 0
    /// Set after a discard asked for confirmation (over 30 s of speech): the next Esc confirms.
    private var discardNeedsConfirmation = false
    /// Whether the held-recording chip is on screen, and whether a press just re-showed it.
    private var heldChipVisible = false
    private var heldReminderShown = false
    /// The current listen's mic started; before that an interrupt has nothing to keep.
    private var micLive = false
    /// The current listen was already stopped from outside (one lid close sends several events).
    private var interruptSent = false
    /// An interrupt landed while the key was still down: its release must not send the speech
    /// the user hasn't seen kept (it would go out over a shared screen).
    private var releasePending = false
    /// The last buddy-key press had ⇧ (⌃) held: the listen it starts goes to a new conversation.
    private var pressFresh = false
    /// This listen's question starts a new conversation (⇧ + buddy key, or "new topic").
    private var listenFresh = false
    /// The conversation the Resume chip offers.
    private var resumeOffer: (id: String, title: String)?
    /// A ⇧ press that came while an answer was in flight or on screen, waiting to be a tap or hold.
    private var freshPressWaiting = false
    /// Conversations already told they're long (once each).
    private var longHinted: Set<String> = []
    /// Quick's context size (tokens) from which answers slow noticeably: the card says "long".
    static let longConversationTokens = 50_000
    /// Bumped by "stop speaking", so a reply still synthesising never starts afterwards, without
    /// detaching the turn itself (its answer still shows).
    private var speechGeneration = 0
    private var capture: Task<Summon, Never>?
    /// A screenshot that takes longer is given up on: the question goes without it.
    var screenshotDeadline: Duration = .milliseconds(1500)
    private var summonSound: Task<Void, Never>?
    private var escapeTask: Task<Void, Never>?
    private var pumps: [Task<Void, Never>] = []
    private var sharingWatch: Task<Void, Never>?
    /// Whether the overlay has put the last `showAnswer` on screen, and who waits for it.
    private var answerOnScreen = true
    private var presentWaiters: [CheckedContinuation<Void, Never>] = []
    private var presentCap: Task<Void, Never>?
    /// Counts the wait in the pill when nothing new has been shown for a while.
    private var quietStatus: Task<Void, Never>?
    /// After this long with no new status, the pill says "Thinking · 12 s", measured from the
    /// question, so a long turn never looks stuck. Then it ticks every `quietTick`.
    var quietAfter: Duration = .seconds(5)
    var quietTick: Duration = .seconds(1)
    /// A required permission that's missing (Accessibility or Screen Recording), from the runtime.
    private var missingPermission: PermissionKind?
    /// Its chip shows once per app session, after an answer closes, and again only for a new kind.
    private var permissionChipShown = false
    private var permissionChipFade: Task<Void, Never>?
    /// Uninvited, like the Back chip, so it goes by itself after this long.
    var permissionChipLifetime: Duration = .seconds(8)
    private let clock: @Sendable () -> Date
    /// When the last answer was shown: a summon after the idle limit starts a fresh conversation.
    private var lastAnswerAt: Date?
    /// The longest an answer's speech waits for its card, so audio can't stall on the overlay. Past
    /// the card's own worst case (the overlay's 1.5 s card-load budget, then placement), so it's
    /// only a guard.
    static let presentWait: Duration = .seconds(2)
    /// The last question asked, reused by Go deeper and actions.
    private var lastQuestion: Question?
    /// The last screen sent in a conversation, under the token the bridge knows it by.
    private var lastScreen: (conversation: String, fingerprint: ScreenFingerprint, token: String)?
    private var lastAnswer: BuddyBlock?
    /// The shown answer's main button (Insert, Replace or Copy), if it has one.
    private var lastMainAction: MainAction?
    /// The last real answer (never a chip), for `recallLastAnswer`: the very `Answer` shown, since
    /// the overlay finds its spot by it. Cleared as soon as a new question takes over the turn state.
    private var kept: (answer: Answer, block: BuddyBlock, mainAction: MainAction?, conversationID: String, anchor: Anchor)?
    /// Whether the card up is that answer: a chip or the report card replaces it.
    private var keptOnScreen = false
    /// The failure chip's fix button, while that chip is up.
    private var shownFix: FixAction?
    /// The lane whose failure the fix chip reports (a model switch asks again there).
    private var shownFixLane: Mode = .quick
    /// Whether the failed question was spoken: a model switch asks the same question again.
    private var shownFixSpoke = false
    /// What was sent last, so "Try again" and "Use <model>" send it again the same way.
    private var lastSent: Resend?

    private enum Resend {
        /// Through `bridge.ask`: `shown` is the transcript's line when it isn't the prompt (an
        /// action's label); `typed`, whether it came from the keyboard.
        case ask(Question, shown: String?, typed: Bool)
        /// Go deeper.
        case deeper(Question)
        /// The screen capture was gone before a question existed: capture again, then ask.
        case capture(transcript: String, typed: Bool)
    }
    /// The app the turn was summoned in: Insert goes into its focused field.
    private var targetPID: Int32?
    private var lastAnchor: Anchor = .point(.zero)
    /// Where the listening pill opened, so the text box replaces it in place.
    private var summonPoint: CGPoint = .zero
    /// The answer showing was typed for, so its card has keyboard focus (the overlay focuses it).
    private var typedCardShowing = false
    /// A research report card is showing: it isn't this conversation's answer, so its reply
    /// field and buttons don't act (follow-ups on a report come later).
    private var reportShowing = false
    /// The voice's latest setup state, and whether its chip is up (it then follows progress).
    private var voiceSetup: VoiceController.PrepareState = .notStarted
    private var setupChipVisible = false
    /// Whether the user spoke the request each research job came from (Voice replies).
    private var researchSpoke: [UUID: Bool] = [:]
    /// The conversation of the turn last sent to the bridge: what Esc while thinking cancels,
    /// even if the shell switched the current conversation meanwhile.
    private var inFlightConversation: String?

    /// The user is typing in the text box or a typed card. Right ⌥ then may be part of a
    /// character (é, €, AltGr layouts), so only a clean tap or hold starts listening.
    private var keyboardInOverlay: Bool {
        phase == .typing || (phase == .showing && typedCardShowing)
    }
    /// The app the last answer's points are looked up in, kept for follow-ups in the same card.
    /// The summon screenshot is OCR'd only for that summon's own answer (`epoch`): later answers
    /// arrive after the screen may have scrolled, so they use AX only. It's dropped when the card
    /// closes, so a full-resolution capture isn't held while idle.
    private var ringSource: RingSource?

    public init(
        settings: Settings = Settings(),
        voice: any VoicePort,
        context: any ContextPort,
        bridge: any BridgePort,
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
        self.bridge = bridge
        self.overlay = overlay
        self.inserter = inserter
        self.escape = escape
        self.pointer = pointer
        self.locator = locator
        self.interruptions = interruptions
        self.tracer = trace
        self.research = research
        self.setKeyListening = setKeyListening
        self.conversations = conversations ?? MemoryConversations(clock: clock)
        self.openURL = openURL
        self.trust = trust
        self.clock = clock
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
        guard paused else { return }
        await cancelCurrent()
        await voice.stopSpeaking()
        overlay.setSpeaking(false)
    }

    /// Ends whatever is in flight: discards a recording, or cancels a turn.
    private func cancelCurrent() async {
        switch phase {
        case .listening, .held: await discardListening(sound: false)
        case .typing: closeTextBox()
        case .thinking: await escapePressed()
        case .showing, .idle: break
        }
    }

    private func isCurrent(_ mine: Int) -> Bool { mine == epoch }

    /// A new request: everything older becomes stale.
    private func nextEpoch() -> Int {
        epoch += 1
        return epoch
    }

    // MARK: - Buddy key

    public func handle(_ event: BuddyKeyEvent) async {
        guard !isPaused, case .gesture(let gesture) = event else { return }
        if case .pressBegan(let fresh) = gesture { pressFresh = fresh }
        if releasePending {
            switch gesture {
            case .pressBegan:
                releasePending = false
            case .tap, .holdEnded, .holdDiscarded, .cancelled, .doubleTap:
                releasePending = false
                return // the release of the interrupted press
            default:
                return
            }
        }
        if keyboardInOverlay {
            await handleWhileTyping(gesture)
            return
        }
        // A press while an answer is in flight or on screen waits to become a real tap or hold:
        // a chord (AltGr+e types é, ⇧⌥- an em dash) ends in `.cancelled`, so it can't cancel a
        // minutes-long Deep turn or start the mic and a screenshot.
        if case .pressBegan = gesture, phase == .thinking || phase == .showing {
            freshPressWaiting = true
            return
        }
        if freshPressWaiting {
            freshPressWaiting = false
            switch gesture {
            case .tap, .holdBegan:
                await handleWhileTyping(gesture)
            case .doubleTap:
                await beginListening()
                await openTextBox()
            default:
                break
            }
            return
        }
        switch (gesture, phase) {
        case (.pressBegan, .listening(confirmedTap: true, _)):
            break // The release that follows sends.
        case (.pressBegan, .held):
            // A held recording always asks first, even if its chip was dismissed: the next tap
            // sends only once the user has seen what it will send.
            if heldChipVisible { break }
            showHeldChip()
            heldReminderShown = true
        case (.tap, .held), (.holdEnded, .held):
            if heldReminderShown {
                heldReminderShown = false // this tap only brought the chip back
            } else {
                await sendHeld()
            }
        case (.pressBegan, _):
            await beginListening()
        case (.tap, .listening(confirmedTap: false, _)):
            phase = .listening(confirmedTap: true, holding: false)
            await setKeyListening(true) // the next tap sends at once
        case (.tap, .listening(confirmedTap: true, _)),
             // The send press can race `setListening(true)` and still see double-tap enabled.
             (.doubleTap, .listening(confirmedTap: true, _)):
            await send()
        case (.holdBegan, .listening(let confirmed, _)):
            phase = .listening(confirmedTap: confirmed, holding: true)
            overlay.updateListeningHint(listenHint("release to send"))
        case (.holdEnded, .listening):
            await send()
        case (.holdDiscarded, .listening(confirmedTap: false, _)):
            await discardListening(confirmed: false) // a long hold may hold a lot of speech
        case (.cancelled, .listening(confirmedTap: false, _)):
            await discardListening()
        case (.cancelled(.otherKey), .listening(confirmedTap: true, _)):
            await interrupt(.typing) // typing elsewhere stops tap-to-talk and keeps the speech
        case (.doubleTap, .listening(confirmedTap: false, _)),
             // The double-tap the setup chip suggests, its first press having shown that chip.
             (.doubleTap, .showing) where setupChipVisible:
            await openTextBox()
        default:
            break
        }
    }

    /// A chord that types a character ends in `.cancelled`, never in `.tap` or `.holdBegan`, so
    /// the box and its draft survive it and the character reaches the field.
    private func handleWhileTyping(_ gesture: GestureEvent) async {
        // Over an answer (not a chip or the report), the key replies: the hint's lesson.
        let replying = phase == .showing && keptOnScreen && !reportShowing
        switch gesture {
        case .tap:
            await beginListening()
            guard case .listening = phase else { return }
            if replying { noteReply(byKey: true) }
            phase = .listening(confirmedTap: true, holding: false)
            await setKeyListening(true) // the next tap sends at once
        case .holdBegan:
            await beginListening()
            guard case .listening = phase else { return }
            if replying { noteReply(byKey: true) }
            phase = .listening(confirmedTap: false, holding: true)
            overlay.updateListeningHint(listenHint("release to send"))
        default:
            break
        }
    }

    // MARK: - Listening

    /// Reads the front app and takes the screenshot, off the listening path.
    private func startCapture() -> Task<Summon, Never> {
        let (context, tracer, shotDeadline) = (context, tracer, screenshotDeadline)
        let previousScreen = lastScreen.map { (fingerprint: $0.fingerprint, token: $0.token) }
        return Task {
            let summon = await context.capture()
            // A capture superseded by a new summon isn't traced; its numbers mean nothing.
            switch summon.result {
            case .blocked:
                if !Task.isCancelled {
                    tracer?.record(.contextPacket, duration: nil, lane: nil, outcome: .skipped, count: nil)
                }
                return Summon(context: summon, shot: nil) // Never capture a blocked app.
            case .packet(let p, let timings):
                if !Task.isCancelled {
                    // The builder's own measure, the "context packet" figure.
                    tracer?.record(.contextPacket, duration: .nanoseconds(Int64(timings.totalMs * 1_000_000)), lane: nil,
                                   outcome: timings.late.isEmpty ? .ok : .late, count: timings.late.count)
                }
                let shotStart = ContinuousClock.now
                let outcome = await Self.screenshot(
                    context, displayID: p.display?.id, focus: ModelRegion.focus(in: p), within: shotDeadline)
                let shot = outcome.shot
                if !Task.isCancelled {
                    tracer?.record(.screenshot, duration: .now - shotStart, lane: nil,
                                   outcome: shot == nil ? .failed : .ok, count: nil)
                    if outcome.unavailable == .notGranted {
                        tracer?.record(.permissionMissing, duration: nil, lane: nil, outcome: nil, count: nil)
                    }
                }
                return await Self.summon(summon, outcome, comparedWith: previousScreen, caret: Self.caret(in: p))
            case .noFrontApp:
                let outcome = await Self.screenshot(context, displayID: nil, within: shotDeadline)
                if outcome.unavailable == .notGranted, !Task.isCancelled {
                    tracer?.record(.permissionMissing, duration: nil, lane: nil, outcome: nil, count: nil)
                }
                return await Self.summon(summon, outcome, comparedWith: previousScreen)
            }
        }
    }

    private func beginListening() async {
        let summonAt = ContinuousClock.now // "key press → mic live" starts here
        let previous = inFlightConversation ?? conversations.current?.state.id
        let wasThinking = phase == .thinking
        let mine = nextEpoch()
        discardNeedsConfirmation = false
        releasePending = false
        phase = .listening(confirmedTap: false, holding: false)
        micLive = false
        interruptSent = false
        let point = pointer.location()
        lastAnchor = .point(point)
        summonPoint = point
        typedCardShowing = false
        reportShowing = false
        setupChipVisible = false
        overlay.setSpeaking(false)
        // Idle long enough that this question starts a fresh conversation: the pill and the
        // answer go back to their own spots, not where the user dragged the last one.
        if let last = lastAnswerAt, clock().timeIntervalSince(last) >= ConversationBook.idleLimit {
            overlay.resetPositions()
            lastAnswerAt = nil
        }
        listenFresh = pressFresh
        overlay.showListening(at: point, hint: listenHint("tap \(settings.keySymbol) to send"))
        trace(.summon)

        capture?.cancel()
        capture = startCapture()
        await voice.stopSpeaking() // first: the 150 ms stop target
        if wasThinking, let previous {
            trace(.cancelled, outcome: .cancelled) // asked again before the answer came
            await bridge.cancel(conversation: previous)
        }
        guard isCurrent(mine) else { return }
        do {
            try await voice.startListening()
            // Esc, Pause or a voice event may have ended this listen while the mic started.
            if !isCurrent(mine) {
                _ = await voice.discard(confirmed: true, playSound: false)
                return
            }
            micLive = true
            trace(.micLive, since: summonAt)
            playSummonSound(pressedAt: summonAt)
            watchScreenSharing(epoch: mine)
        } catch {
            guard isCurrent(mine) else { return }
            // Only the voice's own "still setting up" shows progress: a mic failure during setup's
            // later steps must say what it is.
            if let problem = error as? VoicePortError, problem.stillSettingUp {
                // Still loading the speech models (or retrying a failed load): show the real
                // progress and keep it live; before any, the voice's own line.
                let line = Self.setupLine(voiceSetup, key: typeKey) ?? Self.withTypeHint(problem.message, key: typeKey)
                await stopListeningWithProblem(line, followSetup: true)
            } else if let problem = error as? VoicePortError, problem.notSetUp {
                // No voice chosen yet: typing still works, and Settings › Voice sets it up.
                await stopListeningWithProblem(Self.withTypeHint(problem.message, key: typeKey),
                                               fix: .openSettings(.voice))
            } else {
                await stopListeningWithProblem(Self.voiceMessage(error, fallback: "The microphone didn't start."))
            }
        }
    }

    /// The summon sound says "I'm listening", so it waits for the mic to be live (the voice
    /// returns from `startListening` on its first real audio), and at least 300 ms after the
    /// press so a double-tap reads as one motion. A cancelled or failed listen is silent.
    private func playSummonSound(pressedAt: ContinuousClock.Instant) {
        guard settings.sounds else { return }
        let voice = voice
        let wait = max(.zero, Self.summonSoundDelay - (.now - pressedAt))
        summonSound?.cancel()
        summonSound = Task {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await voice.play(.summon)
        }
    }

    static let summonSoundDelay: Duration = .milliseconds(300)

    /// Discards the recording. `confirmed: false` lets the voice ask first when there's more
    /// than 30 s of speech; then the recording is kept and the next Esc confirms.
    private func discardListening(sound: Bool = true, confirmed: Bool = true) async {
        let mine = nextEpoch()
        summonSound?.cancel()
        let result = await voice.discard(confirmed: confirmed || discardNeedsConfirmation, playSound: sound)
        guard isCurrent(mine) else { return }
        if case .needsConfirmation(let seconds) = result {
            // Stop the mic first and keep the recording while asking (never ask over a live mic).
            if case .listening = phase {
                // Held from now on, so a lock or sharing event during the stop can't take over.
                phase = .held
                await setKeyListening(false)
                await voice.interrupt(.confirmingDiscard)
                guard isCurrent(mine) else { return }
            }
            discardNeedsConfirmation = true
            showChip("Press Esc again to discard \(Int(seconds.rounded())) s of speech, or tap \(settings.keySymbol) to send it.")
            phase = .held
            heldChipVisible = true
            return
        }
        discardNeedsConfirmation = false
        capture?.cancel()
        phase = .idle
        overlay.dismiss(.requested)
        await setKeyListening(false)
    }

    private func showHeldChip(_ reason: String? = nil) {
        let lead = reason.map { "\($0) " } ?? "I stopped listening. "
        showChip("\(lead)Tap \(settings.keySymbol) to send it, or press Esc to discard.")
        phase = .held // after showChip, which sets .showing
        heldChipVisible = true
    }

    /// Stops listening from outside (lock, sleep, screen sharing, typing) and keeps the speech.
    public func interrupt(_ reason: ListenInterruption) async {
        guard case .listening(let confirmed, let holding) = phase, !interruptSent else { return }
        // The mic isn't up yet: there's no speech to keep, so end the listen here (the voice
        // would have nothing to stop and never report back).
        guard micLive else {
            await discardListening(sound: false)
            return
        }
        interruptSent = true
        releasePending = !confirmed || holding
        _ = nextEpoch()
        summonSound?.cancel()
        await setKeyListening(false)
        await voice.interrupt(reason)
        // The voice reports what it kept with .autoStopped(held:), which shows the held chip.
    }

    // MARK: - Typing

    /// Double-tap: the audio since the first press is discarded and the text box opens where the
    /// pill was. The summon's capture keeps running, and the typed question uses it.
    private func openTextBox() async {
        _ = nextEpoch() // a mic still starting is discarded when it finishes
        summonSound?.cancel()
        discardNeedsConfirmation = false
        setupChipVisible = false // setup progress must not rewrite what's shown from here on
        phase = .typing
        overlay.showTextBox(at: summonPoint)
        _ = await voice.discard(confirmed: true, playSound: false)
    }

    private func closeTextBox() {
        _ = nextEpoch()
        capture?.cancel()
        dismissQuietly()
    }

    /// ↵ in the text box asks like a transcript; ↵ in a card's reply field is a follow-up.
    /// Typed questions are never answered aloud unless Voice replies is Always, and the answer
    /// card takes focus so the user can keep typing (Follow-up typing).
    private func submit(_ text: String, source: SubmitSource) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch (source, phase) {
        case (.textBox, .typing):
            let mine = epoch
            phase = .thinking
            overlay.showThinking(lane(for: .quick), status: nil)
            await ask(transcript: text, epoch: mine, spoke: false, typed: true)
        case (.reply, .showing) where !reportShowing:
            noteReply(byKey: false)
            await followUp(text)
        default:
            break
        }
    }

    /// The card has focus, so there's no front app to read: the follow-up reuses the last
    /// question's packet and screenshot with the new words, in the same conversation.
    private func followUp(_ text: String) async {
        guard var question = lastQuestion, let conversation = conversations.current else { return }
        question.packet.utterance = text
        question.packet.features = features
        question.packet.conversation = .init(
            id: conversation.state.id, turn: conversation.turn + 1, previous: conversation.previous)
        question.routing = settings.routing
        kept = nil // the follow-up owns the last question now, even if it's cancelled
        lastQuestion = question
        lastSent = .ask(question, shown: nil, typed: true)
        let mine = nextEpoch()
        phase = .thinking
        overlay.setSpeaking(false)
        overlay.showThinking(lane(for: .quick), status: nil)
        await voice.stopSpeaking() // the last answer may still be reading out
        guard isCurrent(mine) else { return }
        let stream = await bridge.ask(question, state: conversation.state)
        if !isCurrent(mine) { await bridge.cancel(conversation: conversation.state.id) }
        run(stream, question: text, conversationID: conversation.state.id, spoke: false, typed: true, epoch: mine)
    }

    // MARK: - System interruptions

    /// Screen lock and sleep stop listening and keep the speech (safeguards), and stop
    /// a reply reading out to an empty room. Display sleep alone doesn't: the user may still be
    /// talking, and a lock on display sleep sends its own notification.
    private func handle(_ event: SystemInterruption) async {
        switch event {
        case .screenLocked:
            await stopSpeakingForLock()
            await interrupt(.screenLocked)
        case .systemWillSleep:
            await stopSpeakingForLock()
            await interrupt(.systemSleep)
        case .remoteScreenSharingStarted: await interrupt(.screenSharing)
        case .screenUnlocked, .systemDidWake, .displaysDidSleep, .displaysDidWake, .remoteScreenSharingEnded: break
        }
    }

    private func stopSpeakingForLock() async {
        guard phase == .showing else { return }
        speechGeneration += 1 // a reply still synthesising must not start afterwards
        overlay.setSpeaking(false)
        await voice.stopSpeaking()
    }

    /// Inbound macOS Screen Sharing only (there's no API for Zoom, Meet or FaceTime sharing).
    /// Yields at once when a session is already running.
    private func watchScreenSharing(epoch mine: Int) {
        endSharingWatch()
        guard let stream = interruptions?.watchRemoteScreenSharing() else { return }
        sharingWatch = Task { [weak self] in
            for await event in stream {
                // An event the poll buffered before the watch ended must not stop a later listen.
                guard !Task.isCancelled, let self, self.isCurrent(mine) else { return }
                await self.handle(event)
            }
        }
    }

    private func endSharingWatch() {
        sharingWatch?.cancel() // ends the stream, which stops its poll
        sharingWatch = nil
    }

    /// Sends a recording the voice kept after stopping by itself.
    private func sendHeld() async {
        let mine = epoch
        let gesture = ContinuousClock.now
        discardNeedsConfirmation = false
        heldChipVisible = false
        phase = .thinking
        overlay.showThinking(lane(for: .quick), status: nil)
        do {
            guard let transcript = try await voice.sendHeld() else {
                if isCurrent(mine) { dismissQuietly() }
                return
            }
            guard isCurrent(mine) else { return }
            await ask(transcript: transcript, epoch: mine, startedAt: gesture)
        } catch {
            if isCurrent(mine) { showChip(Self.voiceMessage(error, fallback: "I couldn't hear that.")) }
        }
    }

    /// Listening ended on an error: stop the mic and side tasks, then show the line.
    /// `followSetup`: the chip then follows the voice's setup progress until it's ready.
    private func stopListeningWithProblem(_ message: String, fix: FixAction? = nil, followSetup: Bool = false) async {
        let (mine, shown) = (epoch, voiceSetup)
        summonSound?.cancel()
        capture?.cancel()
        showChip(message, fix: fix)
        setupChipVisible = followSetup // before the awaits, so no progress event is missed
        _ = await voice.discard(confirmed: true, playSound: false)
        await setKeyListening(false)
        // Catch up if setup moved on meanwhile.
        if followSetup, isCurrent(mine), voiceSetup != shown { showSetupProgress(voiceSetup) }
    }

    // MARK: - Asking

    private func send() async {
        let mine = epoch
        let gesture = ContinuousClock.now // the send gesture: every turn latency starts here
        summonSound?.cancel()
        phase = .thinking
        overlay.showThinking(lane(for: .quick), status: nil)
        await setKeyListening(false)

        let transcript: String
        awaitingTranscript = mine
        transcribingShown = false
        do {
            transcript = try await voice.finishListening()
            if awaitingTranscript == mine { awaitingTranscript = nil }
        } catch {
            if awaitingTranscript == mine { awaitingTranscript = nil }
            guard isCurrent(mine) else { return }
            showChip(Self.voiceMessage(error, fallback: "I couldn't hear that."))
            return
        }
        guard isCurrent(mine) else { return }
        if transcribingShown {   // the transcript is in: the pill no longer says it's transcribing
            transcribingShown = false
            overlay.updateStatus(nil)
        }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            trace(.transcriptFinal, since: gesture, outcome: .skipped) // nothing was said
            await discardListening()
            return
        }
        trace(.transcriptFinal, since: gesture, outcome: .ok)
        await ask(transcript: transcript, epoch: mine, startedAt: gesture)
    }

    /// Builds the question from the captured context and sends it to the cascade.
    /// `startedAt`: the send gesture, for trace timings (typed questions start at the request).
    private func ask(
        transcript: String, epoch mine: Int, spoke: Bool = true, typed: Bool = false,
        startedAt: ContinuousClock.Instant? = nil
    ) async {
        var transcript = transcript
        switch ConversationCommand.parse(transcript) {
        case .some(.newTopic(let rest)) where !rest.isEmpty:
            listenFresh = true
            transcript = rest
        case .some(let command):
            await runConversationCommand(command)
            return
        case nil:
            break
        }
        guard let captured = await capture?.value else {
            if isCurrent(mine) {
                lastSent = .capture(transcript: transcript, typed: typed)
                await showFailure(TurnFailureLine.screenUnreadable, lane: .quick, spoke: spoke, epoch: mine)
            }
            return
        }
        guard isCurrent(mine) else { return }
        // From here this question owns the turn state (target app, anchor, question), even if it's
        // cancelled before it's sent: the kept answer no longer matches it.
        kept = nil

        var packet: ContextPacket
        let shot = captured.shot
        switch captured.context.result {
        case .blocked(let app):
            ringSource = nil
            targetPID = nil
            capture = nil
            showChip("I don't look at \(app).")
            return
        case .packet(let p, _):
            packet = p
            ringSource = captured.context.pid.map { RingSource(pid: $0, shot: shot, epoch: mine) }
            targetPID = captured.context.pid
        case .noFrontApp:
            targetPID = nil
            packet = ContextPacket(askedAt: Date(), utterance: transcript)
            ringSource = nil // no app to look in; never the previous turn's
        }
        capture = nil // consumed; don't keep the screenshot alive in the task
        // The first seconds say what was actually captured, not a generic "Thinking".
        let opening = Self.openingStatus(packet)
        if let opening, phase == .thinking { overlay.updateStatus(opening) }
        let project = ProjectResolver.project(in: packet, trust: trust())?.standardizedFileURL.path
        if listenFresh {
            listenFresh = false
            await startNewConversation(epoch: mine)
        }
        let conversation = await conversations.prepare(project: project)
        // Only Resume: a Back offer comes from starting fresh, which showed it already.
        if case .resume = conversation.notice, isCurrent(mine) { showNotice(conversation.notice) }
        guard isCurrent(mine) else {
            if ringSource?.epoch == mine { ringSource = nil } // don't keep a stale capture alive
            return
        }
        packet.utterance = transcript
        packet.screenshot = shot?.path
        packet.screenshotUnavailable = captured.unavailable
        packet.screenshotDetail = shot?.detail.map { .init(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height) }
        packet.conversation = .init(
            id: conversation.state.id, turn: conversation.turn + 1, previous: conversation.previous)
        if let path = shot?.path {
            // Linked so Forget deletes it; off the question's path.
            let conversations = conversations, id = conversation.state.id
            Task { await conversations.recordScreenshot(path, conversationID: id) }
        }
        lastAnchor = anchor(for: packet)

        var question = Question(
            packet: packet,
            screenshot: shot.map { TurnInput.Image(data: $0.data, mediaType: $0.mediaType) },
            detail: shot?.detail.map { TurnInput.Image(data: $0.data, mediaType: "image/jpeg") },
            routing: settings.routing,
            screenToken: screenToken(captured, conversation: conversation.state.id))
        question.packet.features = features
        lastQuestion = question
        lastSent = .ask(question, shown: nil, typed: typed)
        let stream = await bridge.ask(question, state: conversation.state)
        if !isCurrent(mine) { await bridge.cancel(conversation: conversation.state.id) }
        run(stream, question: transcript, conversationID: conversation.state.id, spoke: spoke, typed: typed,
            startedAt: startedAt, opening: opening, epoch: mine)
    }

    /// Drains a cascade stream. If the request goes stale, the UI stops following it, but the
    /// stream is still drained so `.done`'s session ids reach the conversation (the cascade is
    /// told to cancel separately).
    private func run(
        _ stream: AsyncStream<CascadeEvent>, question: String, conversationID: String, spoke: Bool,
        typed: Bool = false, shownQuestion: String? = nil, startedAt: ContinuousClock.Instant? = nil,
        opening: String? = nil, epoch mine: Int
    ) {
        inFlightConversation = conversationID
        if isCurrent(mine) {
            setupChipVisible = false // the answer replaces any setup chip
            kept = nil // a new question: the answer to recall is its own
        }
        let start = startedAt ?? .now // typed questions, Go deeper and actions start here
        if isCurrent(mine) { trace(.questionSent) } // a stale request is cancelled at once
        Task { [weak self] in
            var reply = ReplyTracker(question: question, conversationID: conversationID, startedAt: start, typed: typed)
            reply.shownQuestion = shownQuestion ?? question
            reply.opening = opening
            self?.statusShown(since: start, epoch: mine)
            for await event in stream {
                guard let self else { return }
                if case .done(let result) = event { await self.conversations.update(result.state) }
                guard self.isCurrent(mine) else { continue }
                await self.apply(event, spoke: spoke, reply: &reply, epoch: mine)
            }
            guard let self, self.isCurrent(mine), !reply.finished else { return }
            self.trace(.error, lane: reply.lane, outcome: .failed)
            await self.showFailure(TurnFailureLine.stopped, lane: reply.lane ?? .quick, spoke: spoke, reply: reply, epoch: mine)
        }
    }

    private func apply(_ event: CascadeEvent, spoke: Bool, reply: inout ReplyTracker, epoch mine: Int) async {
        if case .turn(.quick, _) = event, !reply.sawEvent {
            reply.sawEvent = true // Quick's first event; Deep-only starts trace deepStarted instead
            trace(.quickFirstEvent, since: reply.startedAt, lane: .quick)
        }
        if case .turn(.deep, _) = event, !reply.deepStarted {
            reply.deepStarted = true
            trace(.deepStarted, since: reply.handoffAt ?? reply.startedAt, lane: .deep)
        }
        switch event {
        case .turn(let mode, .status(let status)):
            // The pill is showing the headline being spoken; a later status in the same lane waits.
            if reply.headlineInPill, reply.lane == mode { return }
            // Quick's generic "Thinking" says less than the opening line already shown: keep it.
            // A real step (a tool) still replaces it.
            if mode == .quick, status == StatusMapper.thinking, reply.opening != nil, (reply.lane ?? .quick) == .quick {
                reply.lane = .quick
                return
            }
            if reply.lane != mode {
                reply.lane = mode
                overlay.showThinking(lane(for: mode), status: status)
            } else {
                overlay.updateStatus(status)
            }
            statusShown(since: reply.startedAt, epoch: mine)
        case .turn(let mode, .retrying(let retry)):
            // Claude Code is retrying the API call: say why, nothing estimated.
            if let status = TurnFailureLine.retrying(retry), !reply.headlineInPill {
                if reply.lane != mode {
                    reply.lane = mode
                    overlay.showThinking(lane(for: mode), status: status)
                } else {
                    overlay.updateStatus(status)
                }
                statusShown(since: reply.startedAt, epoch: mine)
            }
        case .turn(_, .permissionNotice(.denied(let tools))):
            reply.deniedTools += tools
        case .turn(let mode, .initialized(let info)):
            reply.pluginProblem = TurnFailureLine.pluginProblem(info.pluginErrors)
            onPermissionMode?(info.permissionMode) // every turn: the menu line clears when auto is back
            onMCPServers?(mode, info.mcpServers)
        case .turn(let mode, .reconnecting(let attempt)):
            trace(.processRestart, lane: mode, count: attempt) // the lane's Claude Code restarting
            overlay.updateStatus("Reconnecting…")
            statusShown(since: reply.startedAt, epoch: mine)
        case .turn(_, .sayFirstSentence(let sentence)):
            // Quick's headline streams before its card exists: put the words in the pill for every
            // question, typed too, and before the voice starts, so nothing is heard that isn't shown.
            if phase == .thinking {
                overlay.showHeadline(sentence)
                reply.headlineInPill = true
                stopQuietStatus() // the headline stays until the card
            }
            guard shouldSpeak(spoke: spoke) else { return }
            reply.spoken = sentence
            if await say(sentence, continuing: reply.speaking, since: reply.speechGeneration, epoch: mine) { markSpoken(&reply) }
        case .turn(_, .say(let full)):
            // The whole headline has streamed before its card: all of it goes in the pill and the
            // rest is spoken now, so there's no silent gap while the card loads. It's on screen, so
            // nothing is heard that isn't shown; the card then shows it at once, without inking.
            guard phase == .thinking else { return }
            overlay.showHeadline(full)
            reply.headlineInPill = true
            stopQuietStatus()
            guard shouldSpeak(spoke: spoke), !reply.saidFull else { return }
            let rest = Self.remainder(of: full, after: reply.spoken)
            reply.spoken = full
            if !rest.isEmpty, await say(rest, continuing: reply.speaking, since: reply.speechGeneration, epoch: mine) {
                markSpoken(&reply)
            }
        case .turn(_, .failed(let error)):
            reply.error = error
        case .handingOff(let line):
            reply.headlineInPill = false
            reply.handoffAt = .now
            trace(.handoff, since: reply.startedAt, lane: .quick)
            reply.lane = .deep
            // The pill shows the line the voice says, not a label of its own.
            overlay.showThinking(lane(for: .deep), status: line ?? "Handing to Deep")
            statusShown(since: reply.startedAt, epoch: mine)
            // Quick's turn may already have spoken some or all of this line.
            await sayUnspoken(line, spoke: spoke, reply: &reply, epoch: mine)
            reply.spoken = nil
            reply.saidFull = false
        case .researchRequested(let line):
            reply.researchRequested = true
            // The router's start carries no line; the spoken reply for research.
            await sayUnspoken(line ?? "On it. I'll let you know when it's done.", spoke: spoke, reply: &reply, epoch: mine)
        case .done(let result):
            reply.finished = true
            stopQuietStatus()
            await finish(result, spoke: spoke, reply: reply, epoch: mine)
            // After the answer, so it's read as a note on it, not as the answer.
            if isCurrent(mine), let line = Self.deniedLine(reply.deniedTools) {
                overlay.showToast(line, at: pointer.location())
            }
        case .turn:
            break
        }
    }

    private func finish(_ result: CascadeResult, spoke: Bool, reply: ReplyTracker, epoch mine: Int) async {
        // Plain prose with no block is still the turn's answer, unless the turn failed.
        let block = result.outcome.flatMap {
            $0.extraction.block ?? (reply.error == nil ? Self.proseBlock($0.extraction.prose) : nil)
        }
        // Only the cascade's own request starts Research: the router heard the user say it, or an
        // allowed Quick hand-off asked. A block's `handoff` alone (Deep, an action, a "quick
        // answer" turn) never starts a background web job with model-written text as its topic.
        if reply.researchRequested {
            await startResearch(reply, spoke: spoke, epoch: mine)
            return
        }
        // A handoff block is Quick's promise, not an answer: if Deep failed, say that instead.
        guard let block, block.handoff == nil else {
            let failedLane = reply.lane ?? .quick
            if reply.handoffAt != nil || reply.deepStarted {
                trace(.deepFinished, since: reply.handoffAt ?? reply.startedAt, lane: .deep, outcome: .failed)
            }
            if let error = reply.error {
                let model = (failedLane == .deep ? settings.deep : settings.quick).model
                if var line = TurnFailureLine.line(for: error, model: model) {
                    // A plugin that didn't load explains a turn that couldn't finish.
                    if line == TurnFailureLine.generic, let plugin = reply.pluginProblem { line = plugin }
                    trace(.error, lane: failedLane, outcome: .failed)
                    await showFailure(line, lane: failedLane, spoke: spoke, reply: reply, epoch: mine)
                } else {
                    trace(.cancelled, lane: failedLane, outcome: .cancelled)
                    dismissQuietly()
                }
            } else {
                trace(.error, lane: failedLane, outcome: .failed)
                await showFailure(TurnFailureLine.noAnswer, lane: failedLane, spoke: spoke, reply: reply, epoch: mine)
            }
            return
        }
        let mode = result.lane ?? reply.lane ?? .quick
        // Quick's context only: Deep starts with Claude Code's full prompt and tools, and is
        // expected to take its time.
        let isLong = mode == .quick && (result.outcome?.result.contextTokens ?? 0) >= Self.longConversationTokens
        let shown = TranscriptTurn(question: reply.shownQuestion, block: block, mode: mode, model: lane(for: mode).model)
        let current = await conversations.record(shown, conversationID: reply.conversationID)
        guard isCurrent(mine) else { return }
        lastAnswer = block
        shownFix = nil
        // With today's toggles: an action's turn doesn't replace `lastQuestion`.
        var packet = lastQuestion?.packet
        packet?.features = features
        lastMainAction = Self.mainAction(for: block, packet: packet)
        reportShowing = false
        answerOnScreen = false
        lastAnswerAt = clock()
        let answer = Answer(
            block: block,
            lane: lane(for: mode),
            conversation: current?.color ?? .ember,
            turn: current?.turn ?? 1,
            replyHint: replyHint,
            // Full screen shows the whole conversation: every earlier turn, oldest first.
            question: reply.shownQuestion,
            // By id, so a port that returns the turns with or without this one both work.
            earlier: (current?.turns ?? []).filter { $0.id != shown.id },
            isLong: isLong,
            mainAction: lastMainAction)
        kept = (answer, block, lastMainAction, reply.conversationID, lastAnchor)
        keptOnScreen = true
        overlay.showAnswer(answer, anchor: lastAnchor)
        phase = .showing
        typedCardShowing = reply.typed
        if isLong, longHinted.insert(reply.conversationID).inserted {
            let fresh = BuddyKey.allCases.first { $0.symbol == settings.keySymbol }?.freshSymbol ?? "⇧"
            overlay.showToast("Long conversation · \(fresh) + \(settings.keySymbol) starts fresh", at: pointer.location())
        }
        trace(.answerShown, since: reply.startedAt, lane: mode, outcome: .ok)
        if mode == .deep { trace(.deepFinished, since: reply.handoffAt ?? reply.startedAt, lane: .deep, outcome: .ok) }
        ring(block.points, epoch: mine)
        onAnswerShown?()
        if shouldSpeak(spoke: spoke), !reply.saidFull {
            // The card presents asynchronously; the voice waits for it (at most `presentWait`).
            await waitForAnswerOnScreen()
            guard isCurrent(mine) else { return }
            let rest = Self.remainder(of: block.say, after: reply.spoken)
            // The only speech may be here (no streamed headline): still the first spoken word.
            if !rest.isEmpty, await say(rest, continuing: reply.speaking, since: reply.speechGeneration, epoch: mine),
               !reply.speaking {
                trace(.firstSpokenWord, since: reply.startedAt)
            }
        }
    }

    // MARK: - Overlay events

    private func handle(_ event: OverlayEvent) {
        switch event {
        case .dismissed(let reason):
            let answerClosed = phase == .showing && reason != .requested && reason != .appSwitched
            if reason == .escape || reason == .closeButton {
                Task { await voice.stopSpeaking() }
                overlay.setSpeaking(false)
            }
            if case .showing = phase { phase = .idle }
            reportShowing = false
            setupChipVisible = false
            if phase == .held { heldChipVisible = false }
            if phase == .typing { closeTextBox() } // Esc or a click away closed the text box
            ringSource?.shot = nil
            if reason != .requested { shownFix = nil } // the user closed its chip (ours may echo late)
            if answerClosed { offerPermissionFix() }
        case .action(let index):
            Task { await runAction(index) }
        case .mainAction(let action):
            Task { await runMainAction(action) }
        case .openLink(let url):
            openLink(url)
        case .goDeeper:
            Task { await goDeeper() }
        case .stopSpeaking:
            speechGeneration += 1
            Task { await voice.stopSpeaking() }
            overlay.setSpeaking(false)
        case .newConversation:
            Task {
                await cancelCurrent()
                _ = nextEpoch()
                overlay.resetPositions() // a new conversation opens at the default spots
                // UI first: a key press while the index starts the new conversation must not be
                // dismissed afterwards. Questions from then on wait for `startNew` (call order).
                overlay.dismiss(.requested)
                phase = .idle
                await startNewConversation()
            }
        case .backToPrevious:
            Task {
                guard await conversations.goBack() != nil else { return }
                overlay.showToast("Back to the previous conversation", at: pointer.location())
            }
        case .resumeConversation:
            guard let offer = resumeOffer else { return }
            resumeOffer = nil
            Task {
                guard await conversations.switchTo(offer.id) != nil else { return }
                overlay.showToast(Self.resumedToast(offer.title), at: pointer.location())
            }
        case .wantsEscape(let wants):
            setEscape(wants)
        case .answerPresented:
            answerOnScreen = true
            releasePresentWaiters()
        case .submitted(let text, let source):
            Task { await submit(text, source: source) }
        case .jump(let label):
            guard phase == .showing, let point = lastAnswer?.points.first(where: { $0.label == label }) else { return }
            ring([point], epoch: epoch)
        case .openConversations, .popOut:
            // ⇱ on a rich card too: the window marks the current conversation, which is this card's.
            onOpenConversations?()
        case .openSettings:
            onOpenSettings?()
        case .stopResearch:
            Task { [research] in await research?.handle(event) }
        case .openReport:
            // Never over a live mic, text box or turn in flight; the capsule keeps the report.
            guard phase == .idle || phase == .showing else { return }
            // The click on the capsule closed any card; the report card replaces it.
            _ = nextEpoch() // rings or speech still pending for the old card stop
            // The capsule click's dismissal offered the permission chip; the report takes its place.
            if case .grantPermission = shownFix { permissionChipShown = false }
            shownFix = nil
            lastAnswer = nil
            lastMainAction = nil
            typedCardShowing = false
            setupChipVisible = false
            reportShowing = true
            keptOnScreen = false
            phase = .showing
            Task { [research] in await research?.handle(event) }
        }
    }

    private func goDeeper() async {
        guard var question = lastQuestion, let conversation = conversations.current else { return }
        question.packet.conversation = .init(
            id: conversation.state.id, turn: conversation.turn + 1, previous: conversation.previous)
        let mine = nextEpoch()
        phase = .thinking
        overlay.showThinking(lane(for: .deep), status: nil)
        lastSent = .deeper(question)
        let stream = await bridge.goDeeper(question, state: conversation.state)
        if !isCurrent(mine) { await bridge.cancel(conversation: conversation.state.id) }
        run(stream, question: question.packet.utterance, conversationID: conversation.state.id, spoke: false, epoch: mine)
    }

    /// A model action sends its prompt to Deep; inserting is the main button's job.
    private func runAction(_ index: Int) async {
        if index == 0, phase == .showing, let fix = shownFix {
            shownFix = nil
            // The failure line may still be reading out.
            overlay.setSpeaking(false)
            await voice.stopSpeaking()
            switch fix {
            case .openSettings(let pane): onOpenSettingsPane?(pane)
            case .repairPlugin: onRepairPlugin?()
            case .grantPermission(let kind): onGrantPermission?(kind)
            case .useModel(let model):
                await useModel(model, lane: shownFixLane, spoke: shownFixSpoke)
                return
            case .retry:
                await retry(lane: shownFixLane, spoke: shownFixSpoke)
                return
            }
            dismissQuietly()
            return
        }
        // Only a button the user could see: a chip shows one, so keys 2–3 can't press a hidden one.
        guard let block = lastAnswer, index < Self.visibleActions(block, mainAction: lastMainAction),
              block.actions.indices.contains(index)
        else { return }
        // A settings link opens that System Settings pane directly: no model turn, no shell.
        if let url = SettingsLink.url(for: block.actions[index].prompt) {
            // The user is off to System Settings: the reply stops, like Esc, and the card closes.
            _ = nextEpoch()
            Task { await voice.stopSpeaking() }
            overlay.setSpeaking(false)
            openURL?.open(url)
            dismissQuietly()
            return
        }
        guard var question = lastQuestion, let conversation = conversations.current else { return }
        let prompt = block.actions[index].prompt
        question.packet.utterance = prompt
        question.packet.features = features
        question.packet.conversation = .init(
            id: conversation.state.id, turn: conversation.turn + 1, previous: conversation.previous)
        question.routing = .alwaysDeep
        // The user pressed it: the engine, never the model, marks the request as approved.
        question.isApprovedAction = true
        lastSent = .ask(question, shown: block.actions[index].label, typed: false)
        let mine = nextEpoch()
        phase = .thinking
        overlay.showThinking(lane(for: .deep), status: nil)
        let stream = await bridge.ask(question, state: conversation.state)
        if !isCurrent(mine) { await bridge.cancel(conversation: conversation.state.id) }
        // The transcript shows the button the user pressed, not the model-written prompt behind it.
        run(stream, question: prompt, conversationID: conversation.state.id, spoke: false,
            shownQuestion: block.actions[index].label, epoch: mine)
    }

    // MARK: - Rings

    /// Rings the points that can be found (the overlay decides how long). Located off
    /// the answer path, so the card and speech never wait on AX or OCR; points that can't be found
    /// are skipped.
    private func ring(_ points: [BuddyBlock.Point], epoch mine: Int) {
        guard settings.rings, let locator, let source = ringSource, !points.isEmpty else { return }
        let shot = source.epoch == mine ? source.shot : nil
        var quotes: [String] = []
        for point in points where !quotes.contains(point.quote) { quotes.append(point.quote) }
        Task { [weak self, quotes] in
            guard self?.isCurrent(mine) == true else { return }
            let found = await locator.locate(quotes, pid: source.pid, shot: shot)
            guard let self, self.isCurrent(mine), self.phase == .showing else { return }
            let rects = Dictionary(found.map { ($0.quote, $0.rect) }, uniquingKeysWith: { first, _ in first })
            let rings = points.compactMap { point in rects[point.quote].map { Ring(rect: $0, label: point.label) } }
            self.trace(.rings, outcome: rings.isEmpty ? .skipped : .ok, count: rings.count)
            if !rings.isEmpty { self.overlay.showRings(rings) }
        }
    }

    // MARK: - Research

    /// Quick or the router asked for Research: a background job starts and the capsule tracks it.
    /// The buddy stays free; the spoken "On it" line came with the request.
    private func startResearch(_ reply: ReplyTracker, spoke: Bool, epoch mine: Int) async {
        guard let research, var packet = lastQuestion?.packet else {
            showChip("Research isn't available right now.", lane: .research)
            return
        }
        packet.utterance = reply.question
        packet.screenshot = nil // outside the job's sandboxed folder; it couldn't read it
        packet.screenshotDetail = nil // no images go with a job
        // The user's own words are the job's instruction; nothing is paraphrased.
        let job = await research.start(
            ResearchRequest(conversationID: reply.conversationID, topic: Self.researchTopic(reply.question), packet: packet))
        researchSpoke[job.id] = spoke
        trace(.researchStarted, lane: .research)
        guard isCurrent(mine) else { return }
        dismissQuietly()
        overlay.showToast("Running in the background", at: pointer.location())
    }

    /// A job finished: the done chime, then its line, unless voice replies are off or the user is
    /// talking (the voice skips speech over a live mic).
    /// The line is spoken only when nothing else is happening: never over a listen, the text
    /// box, a turn or another answer (the capsule already says "Report ready"), never paused.
    private func researchFinished(_ job: ResearchJob) {
        let spokeIt = researchSpoke.removeValue(forKey: job.id) ?? true
        trace(.researchFinished, lane: .research, count: job.sourceCount)
        guard !isPaused else { return }
        let line = job.say ?? ResearchController.readyLine(job)
        let speak = phase == .idle && shouldSpeak(spoke: spokeIt)
        let (voice, sounds) = (voice, settings.sounds)
        let mine = epoch
        Task { [weak self] in
            if sounds { await voice.play(.researchDone) }
            guard speak, let self, self.isCurrent(mine) else { return }
            await self.say(line, epoch: mine)
        }
    }

    // MARK: - Esc

    private func setEscape(_ wants: Bool) {
        guard let escape else { return }
        if wants, escapeTask == nil {
            do {
                let presses = try escape.activate()
                escapeTask = Task { [weak self] in
                    for await _ in presses { await self?.escapePressed() }
                }
            } catch {
                // Missing Accessibility is the runtime's permission line and the permission chip;
                // the next summon tries again.
            }
        } else if !wants {
            escapeTask?.cancel()
            escapeTask = nil
            escape.deactivate()
        }
    }

    /// Esc: discard while listening, cancel while thinking, otherwise the overlay handles it.
    public func escapePressed() async {
        switch phase {
        case .listening, .held:
            await discardListening(confirmed: false)
        case .typing:
            closeTextBox()
        case .thinking:
            trace(.cancelled, outcome: .cancelled)
            _ = nextEpoch()
            phase = .idle
            overlay.dismiss(.escape)
            if let id = inFlightConversation ?? conversations.current?.state.id { await bridge.cancel(conversation: id) }
        case .showing, .idle:
            _ = nextEpoch() // a reply still synthesising must not start afterwards
            overlay.setSpeaking(false)
            overlay.handleEscape()
            await voice.stopSpeaking()
        }
    }

    // MARK: - Voice

    private func apply(_ level: VoiceLevel) {
        switch level {
        case .mic(let value): overlay.setMicLevel(value)
        case .reply(let value): overlay.setSpeechLevel(value)
        }
    }

    private func handle(_ event: VoiceEvent) async {
        switch event {
        case .speakingFinished:
            overlay.setSpeaking(false)
        case .autoStopped(let held, let message):
            guard case .listening = phase else { return }
            _ = nextEpoch()
            summonSound?.cancel()
            await setKeyListening(false)
            if held {
                showHeldChip(message) // speech that was captured is kept, even after a mic failure
            } else {
                capture?.cancel()
                if let message { showChip(message) } else { dismissQuietly() }
            }
        case .setup(let state):
            voiceSetup = state
            showSetupProgress(state)
        case .nearLimit:
            guard case .listening(_, let holding) = phase else { return }
            // At 1:45; the voice stops recording at 2:00. No countdown: it would go stale.
            overlay.updateListeningHint(holding ? "Stopping soon · release to send" : "Stopping soon · tap \(settings.keySymbol) to send")
        case .micProblem:
            // The voice follows a mic failure with .autoStopped(held:message:), which decides
            // whether the speech is kept; discarding here would lose it.
            break
        case .permissionDenied:
            trace(.permissionMissing)
        case .transcribing(let long):
            // Only for the send still waiting for its transcript, and only while it's thinking.
            guard case .thinking = phase, let waiting = awaitingTranscript, isCurrent(waiting) else { return }
            transcribingShown = true
            overlay.updateStatus(long ? "Still transcribing… Esc to cancel" : "Transcribing…")
        }
    }

    private func waitForAnswerOnScreen() async {
        guard !answerOnScreen else { return }
        await withCheckedContinuation { continuation in
            presentWaiters.append(continuation)
            presentCap?.cancel()
            presentCap = Task { [weak self] in
                try? await Task.sleep(for: Self.presentWait)
                guard !Task.isCancelled else { return }
                self?.releasePresentWaiters()
            }
        }
    }

    private func releasePresentWaiters() {
        presentCap?.cancel() // a stale cap must not release a later wait early
        presentCap = nil
        let waiters = presentWaiters
        presentWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Speaks only while the request is current, so a stale turn never talks over a new one.
    /// `continuing`: a later piece of this turn's reply, queued after what's playing instead of
    /// cutting it ("Let me check." then " One moment."). Returns whether it started or queued.
    /// `since`: the speech generation this turn's reply began in; after "stop speaking" (or a
    /// lock) the rest of the turn stays silent instead of starting a fresh reply.
    @discardableResult
    private func say(_ text: String, continuing: Bool = false, since: Int? = nil, epoch mine: Int) async -> Bool {
        guard isCurrent(mine), since.map({ $0 == speechGeneration }) ?? true else { return false }
        let generation = speechGeneration
        let started = (try? await voice.speak(text, continuing: continuing)) == true
        guard started else { return false }
        // Playback started after the request went stale (key press, Esc) or speech was stopped.
        guard isCurrent(mine), generation == speechGeneration else {
            await voice.stopSpeaking()
            return false
        }
        overlay.setSpeaking(true)
        return true
    }

    /// Speaks whatever part of `line` Quick's own turn hasn't already spoken.
    private func sayUnspoken(_ line: String?, spoke: Bool, reply: inout ReplyTracker, epoch mine: Int) async {
        guard let line, shouldSpeak(spoke: spoke), !reply.saidFull else { return }
        let rest = Self.remainder(of: line, after: reply.spoken)
        if !rest.isEmpty, await say(rest, continuing: reply.speaking, since: reply.speechGeneration, epoch: mine) { markSpoken(&reply) }
    }

    /// Something new is in the pill: the quiet count starts again from now.
    private func statusShown(since start: ContinuousClock.Instant, epoch mine: Int) {
        quietStatus?.cancel()
        let (after, tick) = (quietAfter, quietTick)
        quietStatus = Task { [weak self] in
            try? await Task.sleep(for: after)
            while !Task.isCancelled {
                guard let self, self.isCurrent(mine), self.phase == .thinking else { return }
                let seconds = Int((ContinuousClock.now - start) / .seconds(1))
                self.overlay.updateStatus("\(StatusMapper.thinking) · \(seconds) s")
                try? await Task.sleep(for: tick)
            }
        }
    }

    private func stopQuietStatus() {
        quietStatus?.cancel()
        quietStatus = nil
    }

    /// What the pill says while the question goes out, from what was actually captured.
    static func openingStatus(_ packet: ContextPacket) -> String? {
        guard let app = packet.app?.name, !app.isEmpty else { return nil }
        if let selection = packet.selection, selection.length > 0 { return "Reading your selection in \(app)" }
        return "Looking at \(app)"
    }

    /// A turn that ended in plain prose, with no block (a clarifying question, "A or B?"): its first
    /// sentence is the headline and the rest plain card text. Nil when there's nothing to show, or
    /// a fence is left (a block that didn't decode) that would show as raw JSON.
    static func proseBlock(_ prose: String) -> BuddyBlock? {
        let text = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("```") else { return nil }
        let say = BuddyBlock.firstSentence(of: text)
        // Past the headline's words in the original text, so the rest keeps its line breaks.
        var words = say.split(whereSeparator: \.isWhitespace).count
        var index = text.startIndex
        while words > 0, index < text.endIndex {
            index = text[index...].firstIndex { !$0.isWhitespace } ?? text.endIndex
            index = text[index...].firstIndex { $0.isWhitespace } ?? text.endIndex
            words -= 1
        }
        let rest = text[index...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return BuddyBlock(say: say, shape: .chip) }
        let escaped = rest.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let paragraphs = escaped.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>"))</p>" }
        return BuddyBlock(say: say, shape: .card, cardHTML: paragraphs.joined())
    }

    private func shouldSpeak(spoke: Bool) -> Bool {
        switch settings.voiceReplies {
        case .always: true
        case .onlyWhenSpoken: spoke
        case .off: false
        }
    }

    // MARK: - Helpers

    /// Kinds, timings and counts only: nothing the user said or saw can reach the trace.
    private func trace(_ event: TraceEvent, since start: ContinuousClock.Instant? = nil, lane: Mode? = nil,
                       outcome: TraceOutcome? = nil, count: Int? = nil) {
        tracer?.record(event, duration: start.map { .now - $0 }, lane: lane, outcome: outcome, count: count)
    }

    /// A piece of this turn's reply started or queued; the first one is the spoken-word latency.
    private func markSpoken(_ reply: inout ReplyTracker) {
        if !reply.speaking { trace(.firstSpokenWord, since: reply.startedAt) }
        reply.startedSpeaking(speechGeneration)
    }

    private func lane(for mode: Mode) -> Lane {
        switch mode {
        case .quick: Lane(mode: .quick, model: settings.quick.model)
        case .deep: Lane(mode: mode, model: settings.deep.model)
        case .research: Lane(mode: mode, model: settings.research.model)
        }
    }

    private func anchor(for packet: ContextPacket) -> Anchor {
        if let b = packet.selection?.bounds {
            return .rect(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
        }
        if let c = packet.cursor { return .point(CGPoint(x: c.x, y: c.y)) }
        return lastAnchor
    }

    /// `fix`: a button that puts it right, e.g. Settings › Claude Code.
    private func showChip(_ text: String, lane mode: Mode = .quick, fix: FixAction? = nil) {
        lastMainAction = nil // the chip has no main button
        keptOnScreen = false
        // A model switch needs the runtime's hook; without it there's no button.
        // "Try again" needs something to send again.
        let fix = fix.flatMap { fix -> FixAction? in
            switch fix {
            case .useModel where onUseModel == nil, .useModel where lastSent == nil, .retry where lastSent == nil: nil
            default: fix
            }
        }
        shownFix = fix
        shownFixLane = mode
        setupChipVisible = false
        typedCardShowing = false
        overlay.showAnswer(
            Answer(
                block: BuddyBlock(say: text, shape: .chip,
                                  actions: fix.map { [BuddyBlock.Action(label: $0.label, prompt: "")] } ?? []),
                lane: lane(for: mode),
                conversation: conversations.current?.color ?? .ember,
                turn: conversations.current?.turn ?? 0,
                replyHint: "",
                keepsPlacement: false), // a system chip never takes an answer's remembered spot
            anchor: lastAnchor)
        phase = .showing
    }

    /// A real answer of the current conversation to bring back, shown or tucked away. None after a
    /// new question starts, a new conversation, Forget or switching conversations.
    public var hasKeptAnswer: Bool {
        kept != nil && kept?.conversationID == conversations.current?.state.id
    }

    /// The card on screen is that answer (not a chip or a report).
    public var isShowingKeptAnswer: Bool {
        phase == .showing && keptOnScreen && hasKeptAnswer
    }

    /// The last answer back where it sat (the menu-bar dot, "Show Last Answer", reopening the app),
    /// silently: its main button, ⌘↵, jumps and actions work again. Only while idle.
    @discardableResult
    public func recallLastAnswer() -> Bool {
        guard phase == .idle, hasKeptAnswer, let kept else { return false }
        _ = nextEpoch() // a pending permission chip fade or ring is the old card's
        shownFix = nil
        lastAnswer = kept.block
        lastMainAction = kept.mainAction
        reportShowing = false
        typedCardShowing = false
        setupChipVisible = false
        phase = .showing
        answerOnScreen = false // the overlay says when it's back (`.answerPresented`)
        keptOnScreen = true
        overlay.recallAnswer(kept.answer, anchor: kept.anchor)
        return true
    }

    /// The menu-bar dot's own close: like ✕, but the answer stays to bring back.
    public func tuckAnswer() {
        guard isShowingKeptAnswer else { return }
        speechGeneration += 1
        Task { await voice.stopSpeaking() }
        overlay.setSpeaking(false)
        dismissQuietly(.closeButton) // a tuck, so it folds into the dot it comes back from
    }

    /// The runtime's permission state. A chip up for another kind (or a granted one) closes; a new
    /// kind is offered again.
    public func setMissingPermission(_ kind: PermissionKind?) {
        guard kind != missingPermission else { return }
        missingPermission = kind
        permissionChipShown = false
        if phase == .showing, case .grantPermission(let shown) = shownFix, shown != kind { dismissQuietly() }
    }

    /// After the user closes an answer: the missing permission's Fix chip, once. It never takes an
    /// answer's place and goes by itself unless something replaces it first.
    private func offerPermissionFix() {
        guard let kind = missingPermission, !permissionChipShown, phase == .idle else { return }
        permissionChipShown = true
        showChip(Self.permissionLine(kind), fix: .grantPermission(kind))
        let mine = epoch
        permissionChipFade?.cancel()
        permissionChipFade = Task { [weak self, lifetime = permissionChipLifetime] in
            try? await Task.sleep(for: lifetime)
            guard let self, !Task.isCancelled, isCurrent(mine), phase == .showing,
                  case .grantPermission = shownFix else { return }
            dismissQuietly()
        }
    }

    static func permissionLine(_ kind: PermissionKind) -> String {
        kind == .screenRecording
            ? "\(BuddyCore.appName) needs Screen Recording to see your screen."
            : "\(BuddyCore.appName) needs Accessibility to read your selection and close with Esc."
    }

    /// "tap ⌥ to reply · click to type" until both have been used once.
    private var replyHint: String {
        repliedByKey && repliedByClick ? "" : "tap \(settings.keySymbol) to reply · click to type"
    }

    private func noteReply(byKey: Bool) {
        if byKey {
            repliedByKey = true
            hintDefaults?.set(true, forKey: Self.repliedByKeyKey)
        } else {
            repliedByClick = true
            hintDefaults?.set(true, forKey: Self.repliedByClickKey)
        }
    }

    /// The pill's hint, saying when this listen starts a new conversation.
    private func listenHint(_ hint: String) -> String {
        listenFresh ? "new conversation · \(hint)" : hint
    }

    /// ⌘N, ＋, ⇧ + buddy key or "new topic": "↩ Back to '…'" when there's one to go back to,
    /// otherwise the toast.
    /// `epoch`: shows nothing if a newer request took over meanwhile.
    private func startNewConversation(epoch mine: Int? = nil) async {
        let turn = await conversations.startNew()
        guard mine.map(isCurrent) ?? true else { return }
        if turn.notice == nil { overlay.showToast("New conversation", at: pointer.location()) }
        showNotice(turn.notice)
    }

    private func showNotice(_ notice: ConversationNotice?) {
        switch notice {
        case .back(let title):
            overlay.showBackChip(title: title, at: pointer.location())
        case .resume(let id, let title, let lastUsed):
            resumeOffer = (id, title)
            overlay.showResumeChip(title: title, detail: Self.lastUsedText(lastUsed, now: clock()), at: pointer.location())
        case nil:
            break
        }
    }

    /// The Resume chip's toast: which conversation came back.
    static func resumedToast(_ title: String) -> String {
        // The toast is one line: a long title is cut so it stays readable.
        let title = title.count > 40 ? title.prefix(39).trimmingCharacters(in: .whitespaces) + "…" : title
        return (title.isEmpty ? "Resumed the conversation" : "Resumed ‘\(title)’") + " · your next question continues it"
    }

    /// "yesterday", "3 hours ago", "last week".
    static func lastUsedText(_ date: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }

    /// "go back" or a bare "new topic": a conversation change with no question to answer.
    private func runConversationCommand(_ command: ConversationCommand) async {
        let mine = epoch
        capture?.cancel()
        capture = nil
        ringSource = nil
        dismissQuietly()
        switch command {
        case .goBack:
            let back = await conversations.goBack()
            guard isCurrent(mine) else { return }
            overlay.showToast(back == nil ? "Nothing to go back to" : "Back to the previous conversation", at: pointer.location())
        case .newTopic:
            await startNewConversation(epoch: mine)
        }
    }

    /// The capture's screen fingerprint and whether it matches `previous`, made off the main actor
    /// while the user speaks (a few milliseconds at the model's image size).
    /// `caret`: the text caret's rectangle, the one place a change (its blink) doesn't count.
    nonisolated static func summon(_ context: SummonContext, _ outcome: ShotOutcome,
                                   comparedWith previous: (fingerprint: ScreenFingerprint, token: String)?,
                                   caret: CGRect? = nil) async -> Summon {
        let screenshot = outcome.shot?.screenshot
        let (fingerprint, same) = await Task.detached(priority: .userInitiated) { () -> (ScreenFingerprint?, Bool) in
            let fingerprint = screenshot?.fingerprint()
            return (fingerprint, fingerprint.map { previous?.fingerprint.isSameScreen(as: $0, caret: caret) ?? false } ?? false)
        }.value
        return Summon(context: context, shot: outcome.shot, unavailable: outcome.unavailable,
                      fingerprint: fingerprint, sameAs: same ? previous?.token : nil)
    }

    /// The caret's rectangle in global points: selection bounds with nothing selected, and only
    /// when it's caret-sized. A larger rect from some app would hide real changes, so it exempts
    /// nothing.
    nonisolated static func caret(in packet: ContextPacket) -> CGRect? {
        guard let selection = packet.selection, (selection.text ?? "").isEmpty, let b = selection.bounds,
              b.width <= caretMax.width, b.height <= caretMax.height else { return nil }
        return CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
    }

    /// At most 4 pt wide and 1.5 lines of large text tall.
    nonisolated static let caretMax = (width: 4.0, height: 32.0)

    /// Names the screen this question shows: the last token while the screen is unchanged in the
    /// same conversation, so the bridge doesn't send a session the same image twice.
    private func screenToken(_ captured: Summon, conversation: String) -> String? {
        guard let fingerprint = captured.fingerprint else { return nil }
        if let same = captured.sameAs, let last = lastScreen, last.token == same, last.conversation == conversation {
            return same
        }
        let token = UUID().uuidString
        lastScreen = (conversation, fingerprint, token)
        return token
    }

    /// `reason`: `.requested` folds toward the source; a user's close tucks it into the menu-bar dot.
    private func dismissQuietly(_ reason: DismissReason = .requested) {
        lastMainAction = nil
        shownFix = nil
        overlay.dismiss(reason)
        phase = .idle
    }

    /// How many of the model's actions the card shows, mirroring the overlay's `shownActions`: at
    /// most 3 buttons in all, counting the main button or an approval card's Cancel, and a card's
    /// link button; a chip has one.
    static func visibleActions(_ block: BuddyBlock, mainAction: MainAction? = nil) -> Int {
        let isChip = block.shape == .chip
        let reserved = (mainAction != nil || block.needsApproval ? 1 : 0) + (block.link != nil && !isChip ? 1 : 0)
        return min(block.actions.count, max(0, (isChip ? 1 : BuddyBlock.maxActions) - reserved))
    }

    /// The answer's main button, from the turn's packet: Replace when the selection is
    /// in an editable field, Insert into a focused field, otherwise Copy. Only with paste content:
    /// `insert` for Insert and Replace (never the spoken headline), `insert` or card HTML for Copy.
    /// Never in a terminal (inserting into a shell could run something), on an approval card, or
    /// when the user switched Insert & Replace off.
    static func mainAction(for block: BuddyBlock, packet: ContextPacket?) -> MainAction? {
        guard !block.needsApproval else { return nil }
        let insertAllowed = packet?.features?.insert != false
        let insert = !(block.insert ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if insert, insertAllowed, packet?.app?.kind != .terminal, let editable = packet?.editable, editable.field {
            return editable.selection ? .replace : .insert
        }
        return insert || !(block.cardHTML ?? "").isEmpty ? .copy : nil
    }

    /// The user pressed the card's link button (a draft the turn made elsewhere). Only the shown
    /// answer's own link, so a stale or forged event can't open anything else.
    private func openLink(_ url: URL) {
        guard phase == .showing, !reportShowing, let link = lastAnswer?.link, link.url == url else { return }
        openURL?.open(url)
    }

    /// "Use Sonnet 5.5": the lane switches for good (the toast says so), then the failed
    /// question is asked again there.
    /// `spoke`: the original question's flag (the same question, so its answer is read out alike).
    private func useModel(_ model: ModelID, lane mode: Mode, spoke: Bool) async {
        guard let onUseModel, canResend else { return dismissQuietly() }
        let mine = nextEpoch()
        phase = .thinking
        overlay.showThinking(lane(for: mode), status: "Switching to \(model.displayName)…")
        await onUseModel(model, mode)
        guard isCurrent(mine) else { return }
        overlay.showToast(TurnFailureLine.modelSwitched(mode: mode, model: model), at: pointer.location())
        await resend(lane: mode, spoke: spoke, epoch: mine)
    }

    /// "Try again": what failed is sent again, as it was sent.
    private func retry(lane mode: Mode, spoke: Bool) async {
        guard canResend else { return dismissQuietly() }
        let mine = nextEpoch()
        phase = .thinking
        await resend(lane: mode, spoke: spoke, epoch: mine)
    }

    /// Whether `resend` has something to send and somewhere to send it: a capture asks afresh
    /// (finding its conversation then); anything else needs the current one (gone after Forget or
    /// a temporary-mode switch).
    private var canResend: Bool {
        switch lastSent {
        case .capture: true
        case .ask, .deeper: conversations.current != nil
        case nil: false
        }
    }

    /// Sends `lastSent` again as the current conversation's next turn. `mode`: the lane that
    /// failed; a Deep failure is asked of Deep again.
    private func resend(lane mode: Mode, spoke: Bool, epoch mine: Int) async {
        guard let sent = lastSent else { return dismissQuietly() }
        overlay.showThinking(lane(for: mode), status: nil)
        if case .capture(let transcript, let typed) = sent {
            capture?.cancel()
            capture = startCapture()
            return await ask(transcript: transcript, epoch: mine, spoke: spoke, typed: typed)
        }
        guard let conversation = conversations.current else { return dismissQuietly() }
        let turn = ContextPacket.Conversation(id: conversation.state.id, turn: conversation.turn + 1, previous: conversation.previous)
        switch sent {
        case .capture:
            break // sent above
        case .ask(var question, let shown, let typed):
            question.packet.features = features
            question.packet.conversation = turn
            if mode == .deep { question.routing = .alwaysDeep }
            // A failed approved action may have partly run (a send, an edit): it comes back as a
            // fresh proposal that needs the user's OK again, never re-run on the old approval.
            question.isApprovedAction = false
            lastSent = .ask(question, shown: shown, typed: typed)
            let stream = await bridge.ask(question, state: conversation.state)
            if !isCurrent(mine) { await bridge.cancel(conversation: conversation.state.id) }
            run(stream, question: question.packet.utterance, conversationID: conversation.state.id, spoke: spoke,
                typed: typed, shownQuestion: shown, epoch: mine)
        case .deeper(var question):
            question.packet.conversation = turn
            lastSent = .deeper(question)
            let stream = await bridge.goDeeper(question, state: conversation.state)
            if !isCurrent(mine) { await bridge.cancel(conversation: conversation.state.id) }
            run(stream, question: question.packet.utterance, conversationID: conversation.state.id, spoke: spoke, epoch: mine)
        }
    }

    /// A failure chip with its fix, read out when the question was spoken. `reply`:
    /// the failed turn's, so a reply the user stopped stays silent.
    private func showFailure(_ line: TurnFailureLine.Line, lane mode: Mode, spoke: Bool, reply: ReplyTracker? = nil,
                             epoch mine: Int) async {
        showChip(line.text, lane: mode, fix: line.fix)
        shownFixSpoke = spoke
        guard shouldSpeak(spoke: spoke) else { return }
        _ = await say(line.text, since: reply?.speaking == true ? reply?.speechGeneration : nil, epoch: mine)
    }

    /// The job's topic, as the capsule shows it and the ready line says it ("Your research on QT is
    /// ready"): the question without the "research" command the router heard. A Quick hand-off's
    /// question has no command and stays whole.
    static func researchTopic(_ question: String) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = Substring(trimmed)
        guard rest.lowercased().hasPrefix("research"),
              rest.dropFirst(8).first.map({ $0.isWhitespace || $0.isPunctuation }) ?? false
        else { return trimmed }
        rest = rest.dropFirst(8).drop { $0.isWhitespace || $0.isPunctuation }
        for word in ["on", "about", "into", "for"] where rest.lowercased().hasPrefix(word + " ") {
            rest = rest.dropFirst(word.count + 1)
            break
        }
        let topic = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!")))
        return topic.isEmpty ? trimmed : topic
    }

    /// The tools Claude Code didn't allow this turn, each once.
    static func deniedLine(_ tools: [String]) -> String? {
        var seen = Set<String>()
        let unique = tools.filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.isEmpty ? nil : "Claude Code wasn't allowed to use \(unique.joined(separator: ", "))."
    }

    /// What the user switched off, told to the model on every ask (settings can change mid-conversation).
    private var features: ContextPacket.Features? {
        .unlessAllOn(rings: settings.rings, insert: settings.insert)
    }

    /// The main button: put `insert` into the user's app, or copy the answer.
    private func runMainAction(_ action: MainAction) async {
        guard phase == .showing, !reportShowing, let block = lastAnswer, action == lastMainAction else { return }
        switch action {
        case .copy:
            overlay.copyAnswer()
        case .insert, .replace:
            // Replace is the same call: the selection is still selected, so the text replaces it
            // (the app's own ⌘Z undoes it).
            guard let text = block.insert, let inserter else { return }
            let mine = epoch
            let problem = await inserter.insert(text, into: targetPID)
            trace(.insert, outcome: problem == nil ? .ok : .failed)
            guard isCurrent(mine) else { return }
            if let problem {
                // The card stays, so the draft isn't lost and the user can try again.
                overlay.showToast(problem, at: pointer.location())
                return
            }
            // Done: the card closes, so a second press can't insert it twice.
            _ = nextEpoch()
            Task { await voice.stopSpeaking() }
            overlay.setSpeaking(false)
            dismissQuietly()
        }
    }

    private func showSetupProgress(_ state: VoiceController.PrepareState) {
        guard setupChipVisible, phase == .showing else { return }
        switch state {
        case .preparing: if let line = Self.setupLine(state, key: typeKey) { overlay.updateChipText(line) }
        case .ready: overlay.updateChipText("Voice is ready. Tap \(settings.keySymbol) to talk.")
        // The next press retries setup (and says so).
        case .failed:
            let type = typeKey.map { ", or double-tap \($0) to type" } ?? ""
            overlay.updateChipText("Voice setup failed. Tap \(settings.keySymbol) to try again\(type).")
        case .notStarted: break
        }
    }

    /// The setup chip's line while the speech models load; nil once ready or failed. The
    /// percentage is the downloader's whole-load fraction (download and compile), the same figure
    /// Settings › Voice shows. Never an estimate of time. Typing works meanwhile, so
    /// the line says how (`key`: the buddy key's symbol; nil when double-tap is off).
    static func setupLine(_ state: VoiceController.PrepareState, key: String?) -> String? {
        guard case .preparing(let step) = state else { return nil }
        let detail: String? = switch step {
        case .speechModel(let progress?): "\(Int((min(max(progress.fraction, 0), 1) * 100 + 1e-9).rounded(.down)))%"
        case .speechModel(nil): nil
        case .voiceActivity: "loading voice detection"
        case .voice: "loading the voice"
        case .microphone: "starting the microphone"
        }
        return withTypeHint(detail.map { "Still setting up voice · \($0)" } ?? "Still setting up voice", key: key)
    }

    /// "… · double-tap ⌥ to type": typing works while the voice sets up. `key` nil: the line
    /// as it is, since nothing else opens the text box.
    static func withTypeHint(_ line: String, key: String?) -> String {
        guard let key else { return line.hasSuffix(".") || line.hasSuffix("…") ? line : line + "." }
        var line = Substring(line)
        while let last = line.last, last == "." || last == "…" { line = line.dropLast() }
        return "\(line) · double-tap \(key) to type"
    }

    /// The key a setup chip's typing hint names, or nil while double-tap is off (Sticky Keys).
    private var typeKey: String? { doubleTapAvailable() ? settings.keySymbol : nil }

    static func voiceMessage(_ error: any Error, fallback: String) -> String {
        (error as? VoicePortError)?.message ?? fallback
    }

    /// One true line per bridge failure. Cancelling shows nothing.
    /// What is left of `say` after its first sentence was spoken. Whitespace differences are
    /// ignored; if the spoken text isn't a prefix at all, the whole `say` is spoken rather than
    /// leaving the answer silent.
    static func remainder(of say: String, after spoken: String?) -> String {
        guard let spoken, !spoken.isEmpty else { return say }
        let fullWords = say.split(whereSeparator: \.isWhitespace)
        let spokenWords = spoken.split(whereSeparator: \.isWhitespace)
        guard fullWords.starts(with: spokenWords) else { return say }
        return fullWords.dropFirst(spokenWords.count).joined(separator: " ")
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
}
