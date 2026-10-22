/// Monotonic time in nanoseconds, `CLOCK_UPTIME_RAW` (see `GestureClock`).
public typealias Nanos = UInt64

/// Raw input as the event tap sees it, already reduced to what the gesture rules need.
public enum InputEvent: Sendable, Equatable {
    case flagsChanged(keyCode: UInt16, flags: UInt64, time: Nanos)
    case keyDown(keyCode: UInt16, time: Nanos)
    case mouseDown(time: Nanos)
    case scroll(time: Nanos)
    /// The tap was disabled (timeout or user input) or secure input started: events may be lost.
    case tapInterrupted(time: Nanos)
    /// The driver's timer fired at or after `deadline`. `flags` is the current hardware modifier
    /// state (`CGEventSource.flagsState`), used to recover events the tap has not delivered yet.
    case tick(time: Nanos, flags: UInt64?)

    public var time: Nanos {
        switch self {
        case .flagsChanged(_, _, let t), .keyDown(_, let t), .tick(let t, _): t
        case .mouseDown(let t), .scroll(let t), .tapInterrupted(let t): t
        }
    }
}

public enum CancelReason: Sendable, Equatable {
    case otherKey(UInt16)
    case otherModifier
    case mouseDown
    case scroll
    case tapInterrupted
}

/// What the engine acts on.
public enum GestureEvent: Sendable, Equatable {
    /// The buddy key went down alone, starting a new gesture. Show the pill and start the mic;
    /// audio is kept only if this becomes a tap or hold. `fresh`: the fresh modifier (⇧, or ⌃
    /// when the buddy key is a ⇧) was held with it, so the question starts a new conversation.
    case pressBegan(fresh: Bool)
    /// A confirmed tap. Emitted on release when double-tap is off, otherwise when the double-tap
    /// window expires.
    case tap
    /// Second clean tap inside the window. Discard audio since `pressBegan`, open the text box.
    case doubleTap
    /// The key has been down for more than the hold threshold (on the first press, or on a
    /// second press inside the double-tap window).
    case holdBegan
    /// Released after a hold: send.
    case holdEnded
    /// Interrupted during a hold: discard the recording.
    case holdDiscarded(CancelReason)
    /// The gesture was abandoned before it was confirmed.
    case cancelled(CancelReason)
}

public struct GestureConfig: Sendable, Equatable {
    public var holdThreshold: Nanos
    public var doubleTapWindow: Nanos
    /// Off while Sticky Keys is on, and while listening (so tap-to-send is immediate).
    public var doubleTapEnabled: Bool
    /// While holding or suppressed, how often to poll hardware flags for a release the tap lost.
    public var releasePollInterval: Nanos

    public init(
        holdThreshold: Nanos = 300_000_000,
        doubleTapWindow: Nanos = 300_000_000,
        doubleTapEnabled: Bool = true,
        releasePollInterval: Nanos = 250_000_000
    ) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
        self.doubleTapEnabled = doubleTapEnabled
        self.releasePollInterval = releasePollInterval
    }
}

/// Pure gesture state machine for a single-modifier buddy key. It owns no timers: after each
/// call the driver schedules a tick at `deadline` if it is non-nil.
///
/// Rules (with the M1 decisions):
/// - A gesture starts only when the buddy key goes down with no other modifier down, or with
///   only the fresh modifier (⇧, or ⌃ for a ⇧ buddy key): that gesture is fresh (a new
///   conversation). Its fresh modifier may come up or go down again at any point of the
///   gesture, and does not count against a second press; other keys still cancel it.
/// - Any other key, modifier, click or scroll before the gesture is confirmed cancels it.
/// - Down for more than `holdThreshold` (strictly) is a hold; release sends, any interruption
///   discards.
/// - A clean release starts the double-tap window (if enabled). A second press that goes down
///   inside the window and comes up within the hold threshold is a double-tap; held longer, it
///   becomes a hold (the user meant to talk).
/// - After a double-tap, buddy-key presses are ignored for one more window (no triple taps).
/// - After a cancel or discard, nothing happens until the buddy key is released.
/// - A deadline that has passed is settled before any later input, so a late timer never lets
///   input that arrived after the window rewrite the outcome.
/// - The tap may deliver events late or not at all. At a deadline the hardware flags decide:
///   key up at the hold deadline is a release, key down at the window end is a second press.
///   While holding or suppressed the driver polls the flags for a lost release, and a second
///   buddy-key down implies one (modifiers do not autorepeat).
/// - Key state comes from the device bit. When an event has no device bits (some keyboards,
///   remappers, Universal Control, Screen Sharing), each buddy-key flagsChanged toggles it.
public struct GestureMachine: Sendable {
    public enum State: Sendable, Equatable {
        case idle
        /// First press down, not yet a hold.
        case firstDown(since: Nanos)
        case holding(nextPoll: Nanos)
        /// First tap released; waiting for a second press until `until`.
        case awaitingSecond(until: Nanos)
        /// Second press down.
        case secondDown(since: Nanos)
        /// A double-tap just fired; buddy-key presses are ignored until `until`.
        case cooldown(until: Nanos)
        /// Gesture abandoned; waiting for the buddy key to come up.
        case suppressed(nextPoll: Nanos)

        public var isHolding: Bool { if case .holding = self { true } else { false } }
        public var isSuppressed: Bool { if case .suppressed = self { true } else { false } }
    }

    public let key: BuddyKey
    public var config: GestureConfig
    public private(set) var state: State = .idle {
        didSet {
            switch state {
            case .firstDown, .holding, .awaitingSecond, .secondDown: break
            case .idle, .cooldown, .suppressed: fresh = false  // the gesture is over
            }
        }
    }
    /// Last known physical state of the buddy key, for events without device bits.
    private var keyDown = false
    /// The gesture in progress began with the fresh modifier held.
    private var fresh = false

    public init(key: BuddyKey, config: GestureConfig = GestureConfig()) {
        self.key = key
        self.config = config
    }

    /// When the driver must deliver the next `.tick`, or nil if no timer is needed.
    public var deadline: Nanos? {
        switch state {
        case .firstDown(let since), .secondDown(let since): since &+ config.holdThreshold &+ 1
        case .awaitingSecond(let until), .cooldown(let until): until
        case .holding(let nextPoll), .suppressed(let nextPoll): nextPoll
        case .idle: nil
        }
    }

    /// Sets the believed key state from hardware flags, after a reset while the key may be held
    /// (only matters for events without device bits, which toggle it).
    public mutating func resync(flags: UInt64) {
        if let down = key.isDown(in: flags) { keyDown = down }
    }

    public mutating func handle(_ event: InputEvent) -> [GestureEvent] {
        var settled: [GestureEvent] = []
        if case .tick = event {} else { settled = settleOverdue(at: event.time) }
        return settled + dispatch(event)
    }

    private mutating func dispatch(_ event: InputEvent) -> [GestureEvent] {
        switch event {
        case .flagsChanged(let keyCode, let flags, let time):
            guard keyCode == key.keyCode else {
                // A fresh gesture's ⇧ may be let go (or pressed again) before or after the key.
                if fresh, key.freshKeyCodes.contains(keyCode) { return [] }
                return interrupt(.otherModifier, at: time)
            }
            let wasDown = keyDown
            keyDown = key.isDown(in: flags) ?? !keyDown
            return keyDown ? buddyDown(flags: flags, time: time, wasDown: wasDown) : buddyUp(time: time)
        case .keyDown(let keyCode, let time):
            return interrupt(.otherKey(keyCode), at: time)
        case .mouseDown(let time):
            return interrupt(.mouseDown, at: time)
        case .scroll(let time):
            return interrupt(.scroll, at: time)
        case .tapInterrupted(let time):
            return interrupt(.tapInterrupted, at: time)
        case .tick(let time, let flags):
            return tick(time: time, flags: flags)
        }
    }

    /// Runs the timer transition the driver was late to deliver. Flags are not consulted: the
    /// event being handled is newer than any hardware snapshot.
    private mutating func settleOverdue(at time: Nanos) -> [GestureEvent] {
        switch state {
        case .firstDown, .secondDown, .awaitingSecond, .cooldown:
            guard let deadline, time >= deadline else { return [] }
            return tick(time: time, flags: nil)
        case .idle, .holding, .suppressed:
            return []
        }
    }

    /// Time since `start`, saturating at 0 so clocks that disagree slightly never wrap.
    private func elapsed(_ start: Nanos, _ time: Nanos) -> Nanos {
        time >= start ? time - start : 0
    }

    private func suppressed(at time: Nanos) -> State {
        .suppressed(nextPoll: time &+ config.releasePollInterval)
    }

    /// Modifier bits that don't count as "other" during the gesture in progress.
    private var allowed: UInt64 { fresh ? key.freshMask : 0 }

    // MARK: - Transitions

    /// `wasDown`: the key was already believed down before this event, so this down means a
    /// release was lost. Otherwise it is the (possibly queued) down of a press seen in the flags.
    private mutating func buddyDown(flags: UInt64, time: Nanos, wasDown: Bool) -> [GestureEvent] {
        let alone = !key.othersDown(in: flags, allowing: allowed)
        switch state {
        case .idle:
            let withFresh = !alone && !key.othersDown(in: flags, allowing: key.freshMask)
            guard alone || withFresh else { state = suppressed(at: time); return [] }
            fresh = withFresh
            state = .firstDown(since: time)
            return [.pressBegan(fresh: withFresh)]
        case .awaitingSecond:
            guard alone else { state = suppressed(at: time); return [.cancelled(.otherModifier)] }
            state = .secondDown(since: time)
            return []
        case .cooldown:
            // Ignored, and the state keeps its deadline so every press in the window is ignored.
            // A press still down when the window ends is suppressed by the tick.
            return []
        case .holding:
            guard wasDown else { return [] }
            // The release was lost; the user did let go, so send, then start fresh.
            state = .idle
            return [.holdEnded] + buddyDown(flags: flags, time: time, wasDown: false)
        case .suppressed:
            // Not a lost release: e.g. the queued down of a press the cooldown tick already saw.
            guard wasDown else { return [] }
            state = .idle
            return buddyDown(flags: flags, time: time, wasDown: false)
        case .firstDown, .secondDown:
            // Within the hold threshold; the deadline tick resolves these.
            return []
        }
    }

    private mutating func buddyUp(time: Nanos) -> [GestureEvent] {
        switch state {
        case .firstDown:
            guard config.doubleTapEnabled else {
                state = .idle
                return [.tap]
            }
            state = .awaitingSecond(until: time &+ config.doubleTapWindow)
            return []
        case .holding:
            state = .idle
            return [.holdEnded]
        case .secondDown:
            state = .cooldown(until: time &+ config.doubleTapWindow)
            return [.doubleTap]
        case .suppressed:
            state = .idle
            return []
        case .idle, .awaitingSecond, .cooldown:
            return []
        }
    }

    private mutating func interrupt(_ reason: CancelReason, at time: Nanos) -> [GestureEvent] {
        switch state {
        case .idle, .suppressed, .cooldown:
            return []
        case .firstDown, .secondDown:
            state = suppressed(at: time)
            return [.cancelled(reason)]
        case .holding:
            state = suppressed(at: time)
            return [.holdDiscarded(reason)]
        case .awaitingSecond:
            // Key is up; nothing to wait for.
            state = .idle
            return [.cancelled(reason)]
        }
    }

    private mutating func tick(time: Nanos, flags: UInt64?) -> [GestureEvent] {
        let down = flags.flatMap { key.isDown(in: $0) }
        switch state {
        case .firstDown(let since), .secondDown(let since):
            guard elapsed(since, time) > config.holdThreshold else { return [] }
            if down == false {
                // Up at the deadline: the release is queued behind this timer or was lost.
                // The key was down for no more than the threshold, so this is a release.
                keyDown = false
                return buddyUp(time: since &+ config.holdThreshold)
            }
            // A long first press, or a long second press inside the window: both are holds.
            state = .holding(nextPoll: time &+ config.releasePollInterval)
            return [.holdBegan]
        case .awaitingSecond(let until):
            guard time >= until else { return [] }
            if down == true, let flags {
                // Key down at the window end: the second press is queued behind this timer.
                keyDown = true
                guard !key.othersDown(in: flags, allowing: allowed) else {
                    state = suppressed(at: time)
                    return [.cancelled(.otherModifier)]
                }
                state = .secondDown(since: time)
                return []
            }
            state = .idle
            return [.tap]
        case .cooldown(let until):
            guard time >= until else { return [] }
            state = down == true ? suppressed(at: time) : .idle
            return []
        case .holding:
            if down == false {
                keyDown = false
                state = .idle
                return [.holdEnded]
            }
            state = .holding(nextPoll: time &+ config.releasePollInterval)
            return []
        case .suppressed:
            if down == false {
                keyDown = false
                state = .idle
            } else {
                state = suppressed(at: time)
            }
            return []
        case .idle:
            return []
        }
    }
}
