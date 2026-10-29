import BuddyCore
import CoreGraphics
import Foundation

/// What the user did on the switcher strip.
nonisolated public enum SwitcherEvent: Sendable, Equatable {
    /// The pointer moved onto tile `index` (`tiles.count` is ＋): highlight it.
    case highlighted(Int)
    case tileClicked(SessionID)
    case newSessionClicked
    /// The peek's inline Allow or Deny.
    case approve(requestID: String, session: SessionID, allow: Bool)
    /// The peek's Stop on a running session.
    case stop(SessionID)
    /// The strip closed by itself (the pointer clicked away).
    case closed
}

/// The hold-key + Tab strip at the bottom centre of the active screen. Implemented by `LiveSwitcher` and `FakeSwitcher`.
@MainActor
public protocol SwitcherPresenting: AnyObject {
    var events: AsyncStream<SwitcherEvent> { get }
    /// Builds the strip hidden (at the buddy key's press), so Tab only flips visibility. The
    /// tiles come in strip order; index `tiles.count` is ＋.
    func prepare(tiles: [SessionSnapshot])
    /// The latest state of every session: updates the strip's tiles in place (never
    /// reorders) and an open peek.
    func refresh(_ sessions: [SessionSnapshot])
    /// Shows the prepared strip with tile `highlight` selected.
    func open(highlight: Int)
    func move(to index: Int)
    /// The highlighted tile's peek (status, last answer, Allow/Deny); nil closes it.
    func peek(_ session: SessionID?)
    /// Hides the strip. `commit` plays the pick animation toward the chosen tile.
    func close(commit: Bool)
}

/// A recording fake for the shell's tests.
@MainActor
public final class FakeSwitcher: SwitcherPresenting {
    public enum Call: Sendable, Equatable {
        case prepare([SessionID])
        case refresh([SessionID])
        case open(highlight: Int)
        case move(Int)
        case peek(SessionID?)
        case close(commit: Bool)
    }

    public private(set) var calls: [Call] = []
    public private(set) var isOpen = false
    public let events: AsyncStream<SwitcherEvent>
    private let continuation: AsyncStream<SwitcherEvent>.Continuation

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: SwitcherEvent.self)
    }

    /// Simulates a click in tests.
    public func send(_ event: SwitcherEvent) { continuation.yield(event) }

    public func prepare(tiles: [SessionSnapshot]) { calls.append(.prepare(tiles.map(\.id))) }
    public func refresh(_ sessions: [SessionSnapshot]) { calls.append(.refresh(sessions.map(\.id))) }
    public func open(highlight: Int) {
        calls.append(.open(highlight: highlight))
        isOpen = true
    }
    public func move(to index: Int) { calls.append(.move(index)) }
    public func peek(_ session: SessionID?) { calls.append(.peek(session)) }
    public func close(commit: Bool) {
        calls.append(.close(commit: commit))
        isOpen = false
    }
}
