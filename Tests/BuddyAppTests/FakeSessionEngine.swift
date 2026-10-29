@testable import BuddyApp
import BuddyBridge
import BuddyCore
import Foundation
import Synchronization

/// A `TurnPort` for tests: replays a script per target and records every request.
/// Cascade and Deeper turns replay `cascadeScript` (`.done` gets the asked conversation's id, as
/// the real cascade would); session turns replay `sessionScript`. With `manual` on, session streams
/// stay open and the test drives them with `emit` and `finish`.
final class FakeSessionEngine: TurnPort {
    struct Sent: Sendable {
        var request: TurnRequest
        var session: SessionID?
        var launch: SessionLaunch?
    }

    private struct State {
        var cascadeScript: [CascadeEvent] = []
        var sessionScript: [SessionEvent] = []
        var manual = false
        var sent: [Sent] = []
        var cancelled: [String] = []
        var open: [SessionID: [AsyncStream<TurnStreamEvent>.Continuation]] = [:]
    }

    private let state = Mutex(State())

    init(cascade: [CascadeEvent] = [], session: [SessionEvent] = [], manual: Bool = false) {
        state.withLock {
            $0.cascadeScript = cascade
            $0.sessionScript = session
            $0.manual = manual
        }
    }

    var sent: [Sent] { state.withLock { $0.sent } }
    var cancelled: [String] { state.withLock { $0.cancelled } }
    /// The launches session turns were sent with, in order.
    var launches: [SessionLaunch] { sent.compactMap(\.launch) }

    func setCascadeScript(_ script: [CascadeEvent]) { state.withLock { $0.cascadeScript = script } }
    func setSessionScript(_ script: [SessionEvent]) { state.withLock { $0.sessionScript = script } }

    func send(_ request: TurnRequest) async -> AsyncStream<TurnStreamEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TurnStreamEvent.self)
        switch request.target {
        case .cascade, .deeper:
            let script = state.withLock {
                $0.sent.append(Sent(request: request))
                return $0.cascadeScript
            }
            for event in script {
                if case .done(var result) = event {
                    result.state.id = request.state.id
                    continuation.yield(.cascade(.done(result)))
                } else {
                    continuation.yield(.cascade(event))
                }
            }
            continuation.finish()
        case .session(let id, let launch):
            let (script, manual) = state.withLock {
                $0.sent.append(Sent(request: request, session: id, launch: launch))
                if $0.manual { $0.open[id, default: []].append(continuation) }
                return ($0.sessionScript, $0.manual)
            }
            for event in script { continuation.yield(.session(event)) }
            if !manual { continuation.finish() }
        }
        return stream
    }

    func cancel(conversation: String) async { state.withLock { $0.cancelled.append(conversation) } }

    /// Manual mode: one event into every open stream of `id`.
    func emit(_ event: SessionEvent, to id: SessionID) {
        for continuation in state.withLock({ $0.open[id] ?? [] }) { continuation.yield(.session(event)) }
    }

    /// Manual mode: ends `id`'s open streams.
    func finish(_ id: SessionID) {
        for continuation in state.withLock({ $0.open.removeValue(forKey: id) ?? [] }) { continuation.finish() }
    }
}
