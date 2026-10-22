import Foundation

/// Why listening stopped on its own. The recording is kept, never sent, until the user acts.
public enum ListenStopReason: Sendable, Equatable {
    /// 10 s without speech.
    case silence
    /// The 2-minute limit.
    case maxLength
    case screenLocked
    case systemSleep
    case screenSharing
    /// The user typed while listening.
    case typing
    /// The mic went silent or failed mid-recording; what was heard is kept.
    case micFailed
    /// The user pressed Esc on more than 30 s of speech: the mic stops and the recording is held
    /// while the UI asks "Esc again to discard". Always held, never a sound.
    case confirmingDiscard
}

/// Tap-to-talk safeguards, as pure logic over a clock and VAD transitions.
public struct ListenSafeguards: Sendable, Equatable {
    public struct Limits: Sendable, Equatable {
        public var silenceStop: Double = 10
        public var warnAt: Double = 105
        public var maxLength: Double = 120
        public var confirmDiscardOver: Double = 30

        public init() {}
    }

    public enum Action: Sendable, Equatable {
        /// 1:45 reached; shown once.
        case warnNearLimit
        case stop(ListenStopReason)
    }

    public let limits: Limits
    public let startedAt: Double
    private var speechStartedAt: Double?
    private var lastSpeechEndedAt: Double?
    private var finishedSpeech: Double = 0
    private var warned = false
    private var stopped = false
    /// Off when the VAD failed in this listen: without it, silence can't be told from speech.
    public private(set) var silenceStopEnabled = true

    public init(startedAt: Double, limits: Limits = Limits()) {
        self.startedAt = startedAt
        self.limits = limits
    }

    public var isSpeechActive: Bool { speechStartedAt != nil }
    /// Whether the VAD has heard any speech in this listen.
    public private(set) var heardSpeech = false

    public mutating func observe(_ activity: SpeechActivity, at now: Double) {
        switch activity {
        case .started:
            heardSpeech = true
            if speechStartedAt == nil { speechStartedAt = now }
        case .ended:
            if let s = speechStartedAt {
                finishedSpeech += max(0, now - s)
                speechStartedAt = nil
            }
            lastSpeechEndedAt = now
        }
    }

    /// Seconds of detected speech so far.
    public func speechSeconds(at now: Double) -> Double {
        finishedSpeech + (speechStartedAt.map { max(0, now - $0) } ?? 0)
    }

    /// Checks the limits. Returns each action once; after a stop it returns nothing.
    public mutating func tick(at now: Double) -> [Action] {
        guard !stopped else { return [] }
        let elapsed = now - startedAt
        if elapsed >= limits.maxLength {
            stopped = true
            return [.stop(.maxLength)]
        }
        if silenceStopEnabled, !isSpeechActive, now - (lastSpeechEndedAt ?? startedAt) >= limits.silenceStop {
            stopped = true
            return [.stop(.silence)]
        }
        if elapsed >= limits.warnAt, !warned {
            warned = true
            return [.warnNearLimit]
        }
        return []
    }

    /// The VAD failed: never stop for silence in this listen (the 2-minute limit still applies).
    public mutating func disableSilenceStop() { silenceStopEnabled = false }

    /// Discarding more than 30 s of speech needs the user's confirmation.
    public func discardNeedsConfirmation(at now: Double) -> Bool {
        speechSeconds(at: now) > limits.confirmDiscardOver
    }
}
