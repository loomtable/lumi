import BuddyCore
import Foundation
import os

/// A voice that can't produce speech, as opposed to playback failing. Only these move
/// `FallbackSpeaker` to the other voice; a playback error would fail the same way for both.
public enum VoiceUnavailable: Error, Equatable, Sendable {
    /// The models or voice didn't load. The fallback takes over until the next `warmUp()`.
    case loadFailed(String)
    /// This text couldn't be synthesized. The fallback speaks this reply only.
    case synthesisFailed(String)
}

/// A speaker whose readiness can be checked, so a fallback can take over before the first reply.
public protocol LoadableSpeaker: SpeechSpeaker {
    func load() async throws
}

extension KokoroSpeaker: LoadableSpeaker {}

/// Kokoro by default; AVSpeechSynthesizer when Kokoro can't speak (Speak).
///
/// - A load failure switches to the fallback. Each `warmUp()` (app launch, models re-downloaded) tries
///   the primary again and switches back when it loads.
/// - A synthesis failure for one reply speaks that reply with the fallback and keeps the primary.
/// - Playback errors are thrown as they are; the fallback plays through the same engine.
public actor FallbackSpeaker: SpeechSpeaker {
    public enum Active: Sendable, Equatable { case primary, fallback }

    private let primary: any SpeechSpeaker
    private let fallback: any SpeechSpeaker
    public private(set) var active: Active = .primary
    /// Which voice said the last reply, so a continuation goes to the same one.
    private var speaking: Active?
    /// Bumped by `stop()`, so a reply that moves to the fallback after a stop is not spoken.
    private var stops = 0
    /// Bumped by each `speak`, so a reply that times out after a newer one began leaves that one alone.
    private var replies = 0
    private let log = Logger(subsystem: BuddyCore.bundleIdentifier, category: "voice")
    /// How long the primary has to start a reply, loading not counted. Kokoro's first sentence takes
    /// well under a second (0.72 s for 51 words with the Neural Engine busy, M5), but a Core ML call on
    /// a saturated Neural Engine can hang without failing; past this, the system voice says the reply.
    /// Generous and fixed, so only a hang is cut. Nil: no limit.
    private let primaryDeadline: Duration?
    /// How long a reply waits for the primary's load in progress before the system voice says it; the
    /// load carries on. Short, because the first launch also downloads the models.
    private let primaryLoadGrace: Duration?

    public init(primary: any SpeechSpeaker, fallback: any SpeechSpeaker, primaryDeadline: Duration? = .seconds(30),
                primaryLoadGrace: Duration? = .seconds(3)) {
        self.primary = primary
        self.fallback = fallback
        self.primaryDeadline = primaryDeadline
        self.primaryLoadGrace = primaryLoadGrace
    }

    /// Whether the primary is loaded, waiting for a load in progress up to `primaryLoadGrace`
    /// (launch: models and warm-up, or the first run's download). A load failure switches to the
    /// fallback, as in `warmUp`.
    private func primaryLoaded() async -> Bool {
        guard let loadable = primary as? any LoadableSpeaker else { return true }
        let loading = Task { try await loadable.load() }
        let outcome: Raced<Void> = if let primaryLoadGrace {
            await race(loading, within: primaryLoadGrace)
        } else {
            .done(await loading.result)
        }
        switch outcome {
        case .done(.success): return true
        case .done(.failure(let error)):
            switchToFallback(error)
            return false
        case .timedOut:
            log.error("Primary voice is still loading; using the system voice for this reply")
            return false
        }
    }

    public func warmUp() async {
        if let loadable = primary as? any LoadableSpeaker {
            do {
                try await loadable.load()
                if active == .fallback { log.notice("Primary voice loaded; switching back") }
                active = .primary
            } catch {
                switchToFallback(error)
            }
        }
        // Warm whichever voice will answer; the primary's warm-up also prepares the output engine.
        if active == .primary { await primary.warmUp() } else { await fallback.warmUp() }
    }

    public func speak(_ text: String) async throws -> AsyncStream<Float> {
        let stopsAtStart = stops
        replies += 1
        let reply = replies
        if active == .primary, await primaryLoaded(), stops == stopsAtStart, reply == replies {
            let primary = self.primary
            let work = Task { try await primary.speak(text) }
            let outcome: Raced<AsyncStream<Float>> = if let primaryDeadline {
                await race(work, within: primaryDeadline)
            } else {
                .done(await work.result)
            }
            // Stopped or overtaken meanwhile (a new summon, Esc): whatever the primary reports is the
            // stop's doing. No log, no switch to the system voice, nothing said.
            if case .done(.failure) = outcome, stops != stopsAtStart || reply != replies { return AsyncStream { $0.finish() } }
            switch outcome {
            case .done(.success(let levels)):
                speaking = .primary
                return levels
            case .done(.failure(VoiceUnavailable.loadFailed(let reason))):
                switchToFallback(VoiceUnavailable.loadFailed(reason))
            case .done(.failure(VoiceUnavailable.synthesisFailed(let reason))):
                log.error("Primary voice couldn't say this reply, using the system voice: \(reason, privacy: .private)")
            case .done(.failure(let error)):
                throw error
            case .timedOut:
                // Stopped or overtaken while it waited: stopping the primary now would cut the newer reply.
                guard stops == stopsAtStart, reply == replies else { return AsyncStream { $0.finish() } }
                log.error("Primary voice didn't start within the deadline; using the system voice for this reply")
                // Its reply may still come: stopped now, it never plays over the system voice.
                await primary.stop()
            }
        }
        // Stopped or overtaken while the primary loaded or timed out: this reply is gone.
        guard stops == stopsAtStart, reply == replies else { return AsyncStream { $0.finish() } }
        let levels = try await fallback.speak(text)
        speaking = .fallback
        return levels
    }

    public func continueReply(_ text: String) async -> Bool {
        switch speaking {
        case .primary: await primary.continueReply(text)
        case .fallback: await fallback.continueReply(text)
        case nil: false
        }
    }

    public func stop() async {
        stops += 1
        speaking = nil
        async let a: Void = primary.stop()
        async let b: Void = fallback.stop()
        _ = await (a, b)
    }

    public func retryPrimary() {
        active = .primary
    }

    private func switchToFallback(_ error: any Error) {
        guard active == .primary else { return }
        active = .fallback
        log.error("Primary voice failed, using the system voice: \(String(describing: error), privacy: .private)")
    }
}
