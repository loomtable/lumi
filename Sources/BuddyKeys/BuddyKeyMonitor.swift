import BuddyCore
import os

/// What the engine receives from the buddy key.
public enum BuddyKeyEvent: Sendable, Equatable {
    case gesture(GestureEvent)
    /// Secure Event Input turned on or off (see `KeySourceEvent.secureInput`).
    case secureInput(Bool)
    /// A switcher key in tap mode: Lumi is listening and the buddy key is up.
    case switcher(SwitcherKey)
    /// The dictation key (a second key: tap to toggle, or hold).
    case dictation(DictationGesture)
}

/// The dictation key (`DictationKeyGate`): tap to start and stop, or hold and release.
public enum DictationGesture: Sendable, Equatable {
    /// The key went down alone (or a short tap ended): start listening now, so the first word
    /// isn't clipped.
    case began
    /// Toggle: a clean tap. The dictation keeps running until the key again (`ended`) or Esc.
    case latched
    /// Released after a hold, or the stop tap: type the transcript.
    case ended
    /// Stopped without typing (Esc, another key during a hold): keep what was said, in history.
    case cancelled(DictationCancel)
    /// Not a dictation after all (a short press in hold mode, a ⌘ shortcut, a click before the
    /// release): throw the recording away and type nothing.
    case discarded(DictationDiscard)
}

/// Why a running dictation stopped without typing.
public enum DictationCancel: Sendable, Equatable {
    case escape
    /// Another key or modifier during a hold, the event tap was interrupted, or the key monitor
    /// stopped or was rebound.
    case interrupted(CancelReason)

    /// For the log; like `DictationDiscard.logDescription`, never a key that types text.
    public var logDescription: String {
        switch self {
        case .escape: "Esc"
        case .interrupted(let reason): DictationDiscard.interrupted(reason).logDescription
        }
    }
}

/// Why a dictation was thrown away.
public enum DictationDiscard: Sendable, Equatable {
    /// The key on its own, released `held` after the press: before the hold threshold.
    case shortPress(BuddyKey, held: Nanos)
    /// Another key, modifier, click or scroll, or the tap was interrupted.
    case interrupted(CancelReason)

    /// For the log: how long it was held, or what interrupted it. A key code only for keys that
    /// don't type text (`CancelReason.loggableKeyCode`).
    public var logDescription: String {
        switch self {
        case .shortPress(_, let held): "released after \(held / 1_000_000) ms, before the hold threshold"
        case .interrupted(.otherKey(let code)):
            CancelReason.loggableKeyCode(code).map { "another key (\($0))" } ?? "another key"
        case .interrupted(.otherModifier): "another modifier"
        case .interrupted(.mouseDown): "a click"
        case .interrupted(.scroll): "a scroll"
        case .interrupted(.tapInterrupted): "the event tap was interrupted or secure input started"
        }
    }
}

extension CancelReason {
    /// `code` if it is safe to record: modifiers, fn/🌐, function and navigation keys. Keys that
    /// type text (letters, digits, punctuation, space, return, the keypad) give nil.
    public static func loggableKeyCode(_ code: UInt16) -> UInt16? {
        code < 0x36 || (0x41...0x5F).contains(code) && ![0x4F, 0x50, 0x5A].contains(code) ? nil : code
    }
}

/// Drives a `GestureMachine` from a `KeyEventSource`: feeds it input, delivers ticks at its
/// deadlines, and publishes gestures on `events`.
///
/// Event times come from the source (stamped when the tap callback ran), so hops through this
/// actor never shift gesture timing. Only the timer depends on scheduling, and the machine
/// settles a late deadline before the next input.
///
/// With `options.gesture.switcher` set and a `switcherTap`, the tap is armed from `pressBegan`
/// until the gesture ends, and while listening after a tap (tap mode, where switcher keys come
/// out as `.switcher(key)` because the buddy key is up). If the tap can't start (no
/// Accessibility), that gesture runs without the switcher: Tab cancels as before.
///
/// With `options.dictationKey` set, a second machine runs on that key (`DictationKeyGate`, in
/// `options.dictationMode`): it begins on the press (fn) or 120 ms into a clean press (keys people
/// chord with, so ⌘C never starts the mic); a clean tap toggles it on, a hold ends on release.
/// Each machine sees the other's key as another modifier, so holding both cancels both. A
/// dictation still running when the monitor stops or is rebound is `cancelled`, so its words
/// are kept.
public actor BuddyKeyMonitor {
    /// Gesture outcomes only, never keys (QA U43).
    private static let log = Logger(subsystem: BuddyCore.bundleIdentifier, category: "keys")

    public struct Options: Sendable, Equatable {
        public var key: BuddyKey
        public var gesture: GestureConfig
        /// Drop gestures while Secure Event Input is on. Off until decided (S1 report).
        public var ignoreDuringSecureInput: Bool
        /// The dictation key, or nil for none. Ignored when it equals `key`.
        public var dictationKey: BuddyKey?
        /// Tap to toggle (the default) or hold to talk.
        public var dictationMode: DictationMode

        public init(
            key: BuddyKey = .rightOption,
            gesture: GestureConfig = GestureConfig(),
            ignoreDuringSecureInput: Bool = false,
            dictationKey: BuddyKey? = nil,
            dictationMode: DictationMode = .toggle
        ) {
            self.key = key
            self.gesture = gesture
            self.ignoreDuringSecureInput = ignoreDuringSecureInput
            self.dictationKey = dictationKey
            self.dictationMode = dictationMode
        }
    }

    public nonisolated let events: AsyncStream<BuddyKeyEvent>
    private let continuation: AsyncStream<BuddyKeyEvent>.Continuation
    private let source: any KeyEventSource
    private let clock: any GestureClock
    private let stickyKeys: @Sendable () -> Bool

    private var options: Options
    private var machine: GestureMachine
    /// The dictation key's gesture, when there is one.
    private var dictation: DictationKeyGate?
    private var listening = false
    private var secureInput = false
    private var pump: Task<Void, Never>?
    /// Bumped on every start and stop. AsyncStream keeps handing out buffered events after
    /// finish and cancel, so events from an older pump are dropped by generation.
    private var generation = 0
    private var timer: Task<Void, Never>?
    private var timerDeadline: Nanos?

    private let switcherTap: (any SwitcherInterceptor)?
    /// What the switcher tap is armed with right now; nil while it is off.
    private var armed: SwitcherFilter.Arming?
    private var switcherPump: Task<Void, Never>?
    /// Bumped each time the switcher tap stops, so its buffered keys are dropped.
    private var switcherGeneration = 0
    /// Tap mode: an opener came in while listening, so the strip is open.
    private var tapModeOpen = false

    public init(
        options: Options = Options(),
        source: any KeyEventSource,
        clock: any GestureClock = UptimeClock(),
        stickyKeys: @escaping @Sendable () -> Bool = StickyKeys.isEnabled,
        switcherTap: (any SwitcherInterceptor)? = nil
    ) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        let options = Self.normalized(options)
        self.options = options
        self.source = source
        self.clock = clock
        self.stickyKeys = stickyKeys
        self.switcherTap = switcherTap
        machine = GestureMachine(key: options.key, config: options.gesture)
        dictation = Self.dictationMachine(options)
    }

    deinit {
        pump?.cancel()
        timer?.cancel()
        switcherPump?.cancel()
        switcherTap?.deactivate()
        continuation.finish()
    }

    /// The switcher map always follows the buddy key.
    private static func normalized(_ options: Options) -> Options {
        var options = options
        if options.gesture.switcher != nil { options.gesture.switcher = SwitcherKeyMap(buddy: options.key) }
        if options.dictationKey == options.key { options.dictationKey = nil }
        return options
    }

    /// With the buddy key's timing.
    private static func dictationMachine(_ options: Options) -> DictationKeyGate? {
        options.dictationKey.map { key in
            DictationKeyGate(
                key: key, mode: options.dictationMode, holdThreshold: options.gesture.holdThreshold,
                releasePollInterval: options.gesture.releasePollInterval)
        }
    }

    public func start() throws(KeySourceError) {
        guard pump == nil else { throw .alreadyStarted }
        let stream = try source.start()
        generation += 1
        let current = generation
        machine.resync(flags: source.currentFlags())
        dictation?.resync(flags: source.currentFlags())
        pump = Task { [weak self] in
            for await event in stream {
                await self?.receive(event, generation: current)
            }
        }
    }

    public func stop() {
        generation += 1
        source.stop()
        pump?.cancel()
        pump = nil
        cancelTimer()
        machine = GestureMachine(key: options.key, config: machine.config)
        endRunningDictation()
        dictation = Self.dictationMachine(options)
        tapModeOpen = false
        disarm()
    }

    /// While listening, a tap sends at once instead of waiting out the double-tap window. It is
    /// also tap mode for the switcher: its keys are taken while listening.
    public func setListening(_ listening: Bool) {
        self.listening = listening
        if !listening { tapModeOpen = false }
        rearm()
    }

    /// Tap mode: the switcher committed or timed out, so only the openers are taken again.
    public func closeSwitcher() {
        tapModeOpen = false
        rearm()
    }

    /// Rebinds the key or changes timing. Any gesture in progress is dropped.
    public func update(_ options: Options) {
        let options = Self.normalized(options)
        self.options = options
        machine = GestureMachine(key: options.key, config: options.gesture)
        machine.resync(flags: source.currentFlags())
        endRunningDictation()
        dictation = Self.dictationMachine(options)
        dictation?.resync(flags: source.currentFlags())
        cancelTimer()
        tapModeOpen = false
        rearm()
    }

    // MARK: - Private

    private func receive(_ event: KeySourceEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .secureInput(let on):
            guard on != secureInput else { return }
            secureInput = on
            continuation.yield(.secureInput(on))
            if on { feed(.tapInterrupted(time: clock.now())) }
        case .input(let input):
            feed(input)
        }
    }

    /// `toBuddy`/`toDictation`: which machines get it (a timer tick goes only to those due).
    private func feed(_ input: InputEvent, toBuddy: Bool = true, toDictation: Bool = true) {
        if toDictation { feedDictation(input) }
        guard toBuddy else {
            reschedule()
            return
        }
        let out = machine.handle(input)
        // Applied as a gesture starts (after any late deadline was settled), before its release.
        if out.contains(where: { if case .pressBegan = $0 { true } else { false } }) {
            refreshDoubleTap()
            // Each gesture tries the switcher again (Accessibility may have been granted since).
            machine.config.switcher = options.gesture.switcher
            tapModeOpen = false
        }
        if !(options.ignoreDuringSecureInput && secureInput) {
            for gesture in out { continuation.yield(.gesture(gesture)) }
        }
        reschedule()
        rearm()
    }

    // MARK: - Dictation

    /// The dictation ended outside the key (the app stopped it, or Esc reached Lumi's own Esc tap
    /// instead of this one): the next tap starts a new one instead of stopping the old.
    public func endDictation() {
        dictation?.endDictation()
        reschedule()
    }

    /// The gate is about to be replaced: a dictation still running is stopped, its words kept.
    private func endRunningDictation() {
        guard dictation?.isActive == true else { return }
        dictation?.endDictation()
        let gesture = DictationGesture.cancelled(.interrupted(.tapInterrupted))
        Self.log.notice("dictation cancelled: the key monitor stopped or was rebound")
        continuation.yield(.dictation(gesture))
    }

    private func feedDictation(_ input: InputEvent) {
        guard var gate = dictation else { return }
        // A key the switcher tap took is, to the dictation key, just another key.
        let seen: InputEvent = if case .switcherKeyDown(_, let code, let time) = input {
            .keyDown(keyCode: code, time: time)
        } else {
            input
        }
        let out = gate.handle(seen)
        dictation = gate
        for gesture in out {
            switch gesture {
            case .discarded(let why): Self.log.notice("dictation discarded: \(why.logDescription, privacy: .public)")
            case .cancelled(let why): Self.log.notice("dictation cancelled: \(why.logDescription, privacy: .public)")
            default: break
            }
        }
        guard !(options.ignoreDuringSecureInput && secureInput) else { return }
        for gesture in out { continuation.yield(.dictation(gesture)) }
    }

    // MARK: - Switcher

    private func receiveSwitcher(_ input: InputEvent, generation: Int) {
        guard generation == switcherGeneration, case .switcherKeyDown(let key, _, _) = input else { return }
        if machine.state.isKeyDownInGesture {
            feed(input)
            return
        }
        // Tap mode: the buddy key is up and Lumi is listening.
        guard listening, armed != nil else { return }
        if SwitcherKeyMap.opens(key) { tapModeOpen = true }
        if key == .commit || key == .cancel { tapModeOpen = false }
        if !(options.ignoreDuringSecureInput && secureInput) { continuation.yield(.switcher(key)) }
        rearm()
    }

    /// What the switcher tap should take now, or nil for nothing.
    private var wantedArming: SwitcherFilter.Arming? {
        guard pump != nil, switcherTap != nil, let map = machine.config.switcher else { return nil }
        if machine.state.isKeyDownInGesture {
            return SwitcherFilter.Arming(map: map, fresh: machine.isFresh, open: machine.state.isSwitching)
        }
        guard listening else { return nil }
        return SwitcherFilter.Arming(map: map, open: tapModeOpen)
    }

    /// Starts, retunes or stops the switcher tap to match the gesture and listening state.
    private func rearm() {
        let wanted = wantedArming
        guard wanted != armed, let tap = switcherTap else { return }
        guard let wanted else {
            disarm()
            return
        }
        if armed != nil {
            tap.update(wanted)
            armed = wanted
            return
        }
        let stream: AsyncStream<InputEvent>
        do {
            stream = try tap.activate(wanted)
        } catch {
            // No Accessibility (or no tap): this gesture goes on without the switcher.
            machine.config.switcher = nil
            return
        }
        armed = wanted
        let current = switcherGeneration
        switcherPump = Task { [weak self] in
            for await input in stream {
                await self?.receiveSwitcher(input, generation: current)
            }
        }
    }

    private func disarm() {
        guard armed != nil else { return }
        armed = nil
        switcherGeneration += 1
        switcherPump?.cancel()
        switcherPump = nil
        switcherTap?.deactivate()
    }

    /// Double-tap is off while listening (tap sends) and while Sticky Keys is on. Changed only
    /// between gestures so a gesture in flight keeps its rules.
    private func refreshDoubleTap() {
        let enabled = !listening && !stickyKeys()
        if machine.config.doubleTapEnabled != enabled {
            machine.config.doubleTapEnabled = enabled
        }
    }

    private func reschedule() {
        guard let deadline = [machine.deadline, dictation?.deadline].compactMap({ $0 }).min() else {
            cancelTimer()
            return
        }
        guard deadline != timerDeadline else { return }
        timer?.cancel()
        timerDeadline = deadline
        let clock = clock
        timer = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            await self?.fire(deadline: deadline)
        }
    }

    private func fire(deadline: Nanos) {
        guard timerDeadline == deadline else { return }
        timerDeadline = nil
        timer = nil
        let now = clock.now()
        let due = { (d: Nanos?) in d.map { $0 <= now } ?? false }
        feed(.tick(time: now, flags: source.currentFlags()),
             toBuddy: due(machine.deadline), toDictation: due(dictation?.deadline))
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        timerDeadline = nil
    }
}
