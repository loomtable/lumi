/// What the engine receives from the buddy key.
public enum BuddyKeyEvent: Sendable, Equatable {
    case gesture(GestureEvent)
    /// Secure Event Input turned on or off (see `KeySourceEvent.secureInput`).
    case secureInput(Bool)
}

/// Drives a `GestureMachine` from a `KeyEventSource`: feeds it input, delivers ticks at its
/// deadlines, and publishes gestures on `events`.
///
/// Event times come from the source (stamped when the tap callback ran), so hops through this
/// actor never shift gesture timing. Only the timer depends on scheduling, and the machine
/// settles a late deadline before the next input.
public actor BuddyKeyMonitor {
    public struct Options: Sendable, Equatable {
        public var key: BuddyKey
        public var gesture: GestureConfig
        /// Drop gestures while Secure Event Input is on. Off until decided (S1 report).
        public var ignoreDuringSecureInput: Bool

        public init(
            key: BuddyKey = .rightOption,
            gesture: GestureConfig = GestureConfig(),
            ignoreDuringSecureInput: Bool = false
        ) {
            self.key = key
            self.gesture = gesture
            self.ignoreDuringSecureInput = ignoreDuringSecureInput
        }
    }

    public nonisolated let events: AsyncStream<BuddyKeyEvent>
    private let continuation: AsyncStream<BuddyKeyEvent>.Continuation
    private let source: any KeyEventSource
    private let clock: any GestureClock
    private let stickyKeys: @Sendable () -> Bool

    private var options: Options
    private var machine: GestureMachine
    private var listening = false
    private var secureInput = false
    private var pump: Task<Void, Never>?
    /// Bumped on every start and stop. AsyncStream keeps handing out buffered events after
    /// finish and cancel, so events from an older pump are dropped by generation.
    private var generation = 0
    private var timer: Task<Void, Never>?
    private var timerDeadline: Nanos?

    public init(
        options: Options = Options(),
        source: any KeyEventSource,
        clock: any GestureClock = UptimeClock(),
        stickyKeys: @escaping @Sendable () -> Bool = StickyKeys.isEnabled
    ) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.options = options
        self.source = source
        self.clock = clock
        self.stickyKeys = stickyKeys
        machine = GestureMachine(key: options.key, config: options.gesture)
    }

    deinit {
        pump?.cancel()
        timer?.cancel()
        continuation.finish()
    }

    public func start() throws(KeySourceError) {
        guard pump == nil else { throw .alreadyStarted }
        let stream = try source.start()
        generation += 1
        let current = generation
        machine.resync(flags: source.currentFlags())
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
    }

    /// While listening, a tap sends at once instead of waiting out the double-tap window.
    public func setListening(_ listening: Bool) {
        self.listening = listening
    }

    /// Rebinds the key or changes timing. Any gesture in progress is dropped.
    public func update(_ options: Options) {
        self.options = options
        machine = GestureMachine(key: options.key, config: options.gesture)
        machine.resync(flags: source.currentFlags())
        cancelTimer()
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

    private func feed(_ input: InputEvent) {
        let out = machine.handle(input)
        // Applied as a gesture starts (after any late deadline was settled), before its release.
        if out.contains(where: { if case .pressBegan = $0 { true } else { false } }) { refreshDoubleTap() }
        if !(options.ignoreDuringSecureInput && secureInput) {
            for gesture in out { continuation.yield(.gesture(gesture)) }
        }
        reschedule()
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
        guard let deadline = machine.deadline else {
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
        feed(.tick(time: clock.now(), flags: source.currentFlags()))
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        timerDeadline = nil
    }
}
