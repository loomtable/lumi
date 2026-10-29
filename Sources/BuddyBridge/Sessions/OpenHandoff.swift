import BuddyCore
import Foundation

/// Quick handed off (or the user asked for Deep): the work goes to a new open session through the
/// pool, seeded with Quick's line as a `<quick-note>` (02 §D8.0: a Quick session can't become open).
/// The app builds the runner (it mints the session in the store); the cascade only forwards it.
public struct OpenHandoff: Sendable {
    public var question: Question
    public var state: ConversationState
    /// What Quick said: its hand-off line, or its answer for "go deeper".
    public var quickNote: String?

    public init(question: Question, state: ConversationState, quickNote: String?) {
        self.question = question
        self.state = state
        self.quickNote = quickNote
    }
}

/// Runs a hand-off in an open session as Deep-lane turn events, or nil to use the Deep lane
/// (legacy conversations, sessions off).
public typealias OpenHandoffRunner = @Sendable (OpenHandoff) async -> AsyncStream<TurnEvent>?

/// An open session's turn as the cascade's `TurnEvent`s, so the Glance shows a hand-off the way it
/// shows Deep today: status lines from steps, streamed text and speech, one `.finished` or `.failed`.
public enum SessionTurnEvents {
    public static func adapt(_ events: AsyncStream<SessionEvent>, sessionID: String = "") -> AsyncStream<TurnEvent> {
        AsyncStream { out in
            let relay = Task {
                var ended = false
                for await event in events {
                    for e in turnEvents(for: event, sessionID: sessionID) {
                        out.yield(e)
                        if case .finished = e { ended = true }
                        if case .failed = e { ended = true }
                    }
                }
                if !ended { out.yield(.failed(.cancelled)) }
                out.finish()
            }
            out.onTermination = { _ in relay.cancel() }
        }
    }

    /// The pill's line while an ask waits.
    public static let waitingLine = "Waiting for your OK"

    static func turnEvents(for event: SessionEvent, sessionID: String) -> [TurnEvent] {
        switch event {
        case .text(let text, nil): return [.text(text)]
        case .sayFirstSentence(let s): return [.sayFirstSentence(s)]
        case .say(let s): return [.say(s)]
        case .step(let step) where step.subagent == nil:
            return [.status(step.object.map { "\(step.verb) \($0)" } ?? step.verb)]
        case .permissionRequested, .questionAsked: return [.status(waitingLine), .hostEvent(event)]
        case .permissionResolved: return [.hostEvent(event)]
        case .retrying(let attempt, let delay, let reason):
            return [.retrying(StreamEvent.APIRetry(attempt: attempt, maxRetries: nil, retryDelayMS: delay, errorStatus: nil, error: reason))]
        case .turnEnded(let end):
            // The host first, so the lead's asks are cleared before the turn's answer shows.
            let host = TurnEvent.hostEvent(event)
            var result = StreamEvent.TurnResult(subtype: end.isError ? "error" : "success", isError: end.isError, sessionID: sessionID,
                                                text: end.markdown, terminalReason: nil, apiErrorStatus: nil, durationMS: nil,
                                                ttftMS: nil, costUSD: end.costUSD, permissionDenials: end.deniedTools.count)
            result.deniedTools = end.deniedTools
            result.contextTokens = end.contextTokens
            if end.isError { return [host, .failed(error(for: end, result: result))] }
            let extraction = BuddyBlockExtractor.Extraction(block: end.block, prose: end.markdown)
            return [host, .finished(TurnOutcome(result: result, extraction: extraction, timing: TurnTiming()))]
        case .processEnded(let status, true):
            return [.hostEvent(event), .failed(.processExited(status: status, stderr: ""))]
        default:
            return []
        }
    }

    /// A failed session turn as the cascade's error, so an open session's voice turn shows the same
    /// failure line as Quick's ("Claude Code isn't signed in.", a rate limit, no connection): the
    /// CLI's error code and text, Claude Code unavailable, or its process gone.
    public static func error(for end: TurnEnd, sessionID: String = "") -> BridgeError {
        var result = StreamEvent.TurnResult(subtype: "error", isError: true, sessionID: sessionID, text: end.markdown,
                                            terminalReason: nil, apiErrorStatus: nil, durationMS: nil, ttftMS: nil,
                                            costUSD: end.costUSD, permissionDenials: end.deniedTools.count)
        result.deniedTools = end.deniedTools
        return error(for: end, result: result)
    }

    private static func error(for end: TurnEnd, result: StreamEvent.TurnResult) -> BridgeError {
        var result = result
        switch end.error?.reason {
        case .unavailable(let detail)?: return .unavailable(detail)
        case .crashed?: return .processExited(status: 0, stderr: "")
        case .auth?: result.errorCode = "authentication_failed"
        case .rateLimited?: result.errorCode = "rate_limit"
        case .api(let detail)?: result.errorCode = detail // a code ("billing_error") or the CLI's own text
        case nil: break
        }
        return .turnFailed(result)
    }
}
