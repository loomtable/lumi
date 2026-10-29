/// How the dictation key works (Settings › General › Dictation; owner, Oct 29).
public enum DictationMode: String, Sendable, Equatable, CaseIterable {
    /// Tap to start, tap again to stop and type. A press held past the hold threshold still works
    /// as hold-to-talk. The default.
    case toggle
    /// Hold, speak, release to type. A short press does nothing.
    case hold
}

/// The dictation key's gesture: a `GestureMachine` plus the rules for when the mic may start and
/// what ends a dictation (owners, Oct 28 and 29).
///
/// When the mic starts: starting it lights macOS's orange privacy dot, so it must not flash on
/// every ⌘C.
/// - fn, which nobody chords with, begins on the press.
/// - Any other modifier begins `armingDelay` after the press, if the press is still clean. A key,
///   click or release before then ends it silently: no `began`, no mic.
///
/// What a press becomes:
/// - Toggle: a clean tap (no other key, click or scroll before its release) is `latched`: the
///   dictation runs until the key is pressed again (`ended` on that press's release) or Esc. A
///   tap shorter than the arming delay starts it on the release: `began` and `latched` together.
/// - Both modes: held past the hold threshold, the release is `ended` (hold-to-talk).
/// - Hold: a short press is `discarded`.
/// - A shortcut or click before the release (or before the threshold, for a hold) is `discarded`:
///   the user didn't mean to dictate.
///
/// Once a dictation runs (latched, or held past the threshold), scrolls and clicks never end it
/// (QA U47). Esc is `cancelled(.escape)`. Another key during a hold is `cancelled`, never
/// `discarded`: the words said so far are kept (in history), only not typed. While latched, other
/// keys, presses of the key with another key, and tap interruptions are ignored.
public struct DictationKeyGate: Sendable {
    /// How long a chord-prone key must be held alone before the mic starts. Speech in the
    /// first 120 ms is negligible.
    public static let armingDelay: Nanos = 120_000_000

    public let mode: DictationMode
    public private(set) var machine: GestureMachine
    /// When a clean press begins, for a key that waits.
    private var armAt: Nanos?
    private var began = false
    private var pressedAt: Nanos?
    /// Toggle: a clean tap started a dictation that runs until the key again or Esc.
    public private(set) var latched = false

    public init(key: BuddyKey, mode: DictationMode = .toggle, holdThreshold: Nanos = 300_000_000,
                releasePollInterval: Nanos = 250_000_000) {
        self.mode = mode
        machine = GestureMachine(key: key, config: GestureConfig(
            holdThreshold: holdThreshold, doubleTapEnabled: false, releasePollInterval: releasePollInterval))
    }

    public var key: BuddyKey { machine.key }
    /// fn begins on the press; every other key waits `armingDelay`.
    public var beginsOnPress: Bool { key == .function }
    /// A dictation is running: the mic was started and nothing has ended it yet.
    public var isActive: Bool { began || latched }

    /// When the driver must deliver the next `.tick`, or nil.
    public var deadline: Nanos? { [machine.deadline, armAt].compactMap { $0 }.min() }

    public mutating func resync(flags: UInt64) { machine.resync(flags: flags) }

    /// The dictation ended outside the key (the controller stopped it, or Esc went to Lumi's own
    /// Esc tap): forget it, so the next tap starts a new one.
    public mutating func endDictation() {
        armAt = nil
        began = false
        pressedAt = nil
        latched = false
    }

    public mutating func handle(_ input: InputEvent) -> [DictationGesture] {
        if isActive, case .keyDown(EscapeFilter.escapeKeyCode, _) = input {
            _ = machine.handle(input)  // a key still down now waits for its release
            endDictation()
            return [.cancelled(.escape)]
        }
        if latched { return handleLatched(input) }
        // A dictation held past the threshold: scrolls and clicks don't end it (QA U47).
        if began, machine.state.isHolding, input.isPointer { return [] }
        var out: [DictationGesture] = []
        // The press stayed clean until its arming time, which came before this input.
        if let armAt, input.time >= armAt { out += begin() }
        for gesture in machine.handle(input) {
            switch gesture {
            case .pressBegan:
                pressedAt = input.time
                if beginsOnPress {
                    out += begin()
                } else {
                    armAt = input.time &+ Self.armingDelay
                }
            case .holdBegan:
                out += begin()  // a late arming timer: the hold proves the press clean
            case .holdEnded:
                if began { out.append(.ended) }
                endDictation()
            case .tap:
                switch mode {
                case .toggle:
                    // A clean tap: the dictation starts (on this release, if the press was too
                    // short to arm) and runs until the next tap.
                    out += begin()
                    armAt = nil
                    pressedAt = nil
                    latched = true
                    out.append(.latched)
                case .hold:
                    if began {
                        let held = pressedAt.map { input.time >= $0 ? input.time - $0 : 0 } ?? 0
                        out.append(.discarded(.shortPress(key, held: held)))
                    }
                    endDictation()
                }
            case .cancelled(let reason):
                // Before the release or the threshold: a shortcut, not a dictation.
                if began { out.append(.discarded(.interrupted(reason))) }
                endDictation()
            case .holdDiscarded(let reason):
                // During a hold: keep what was said, don't type it.
                if began { out.append(.cancelled(.interrupted(reason))) }
                endDictation()
            case .doubleTap, .switcher, .switcherReleased:
                break
            }
        }
        return out
    }

    /// While latched only the key matters: its next press, released, stops the dictation. A press
    /// with another key is a shortcut and leaves it running.
    private mutating func handleLatched(_ input: InputEvent) -> [DictationGesture] {
        if input.isPointer { return [] }
        if case .tapInterrupted = input { return [] }
        for gesture in machine.handle(input) {
            switch gesture {
            case .tap, .holdEnded:
                endDictation()
                return [.ended]
            case .pressBegan, .holdBegan, .cancelled, .holdDiscarded, .doubleTap, .switcher, .switcherReleased:
                break
            }
        }
        return []
    }

    private mutating func begin() -> [DictationGesture] {
        armAt = nil
        guard !began else { return [] }
        began = true
        return [.began]
    }
}

extension InputEvent {
    /// A click or a scroll.
    var isPointer: Bool {
        switch self {
        case .mouseDown, .scroll: true
        default: false
        }
    }
}
