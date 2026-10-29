import BuddyCore
import BuddyOverlay
import Foundation

/// A recording `StudioDataSource` for tests and previews, and Studio's source until the live one
/// is wired. `set(_:)` replaces the sessions and tells every listener.
@MainActor
public final class FakeStudioSource: StudioDataSource {
    public enum Call: Sendable, Equatable {
        case open(SessionID)
        case pin(SessionID, Bool)
        case archive(SessionID, Bool)
        case rename(SessionID, String)
        case forget(SessionID)
        case start(String)
        case startWith(String, [URL])
        case dictate(Bool)
        case handle(PanelEvent)
        case panel(SessionID)
        case shown(SessionID?)
    }

    public private(set) var snapshots: [SessionSnapshot]
    public private(set) var calls: [Call] = []
    public var turns: [SessionID: [TranscriptTurn]] = [:]
    public var lanes: [SessionID: [String: LaneHistory]] = [:]
    public var detailsByID: [SessionID: SessionDetails] = [:]
    /// What `startSession` returns; nil makes it fail.
    public var nextSessionID: SessionID? = SessionID(rawValue: "s_new")
    private var listeners: [UUID: AsyncStream<[SessionSnapshot]>.Continuation] = [:]
    private var eventListeners: [SessionID: [AsyncStream<SessionEvent>.Continuation]] = [:]

    public init(_ snapshots: [SessionSnapshot] = []) {
        self.snapshots = snapshots
    }

    public func set(_ snapshots: [SessionSnapshot]) {
        self.snapshots = snapshots
        for listener in listeners.values { listener.yield(snapshots) }
    }

    /// Streams `event` to the pages listening to `id`.
    public func emit(_ event: SessionEvent, to id: SessionID) {
        for listener in eventListeners[id] ?? [] { listener.yield(event) }
    }

    public func changes() -> AsyncStream<[SessionSnapshot]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [SessionSnapshot].self)
        let key = UUID()
        listeners[key] = continuation
        continuation.yield(snapshots)
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.listeners[key] = nil } }
        return stream
    }

    public func open(_ id: SessionID) async { calls.append(.open(id)) }

    public func setPinned(_ pinned: Bool, for id: SessionID) async {
        calls.append(.pin(id, pinned))
        update(id) { $0.pinned = pinned }
    }

    public func setArchived(_ archived: Bool, for id: SessionID) async {
        calls.append(.archive(id, archived))
        update(id) { $0.archived = archived }
    }

    public func rename(_ id: SessionID, to title: String) async {
        calls.append(.rename(id, title))
        update(id) { $0.title = title }
    }

    public func forget(_ id: SessionID) async throws {
        calls.append(.forget(id))
        set(snapshots.filter { $0.id != id })
    }

    public func startSession(text: String) async -> SessionID? {
        calls.append(.start(text))
        return nextSessionID
    }

    public func startSession(text: String, attachments: [URL]) async -> SessionID? {
        guard !attachments.isEmpty else { return await startSession(text: text) }
        calls.append(.startWith(text, attachments))
        return nextSessionID
    }

    /// What `lastSentTurn(for:)` returns.
    public var sent: [SessionID: SentTurn] = [:]
    public func lastSentTurn(for id: SessionID) async -> SentTurn? { sent[id] }

    /// Home's mic shows when true.
    public var canDictate = false
    public var hasSessions = true
    public func dictate(_ down: Bool) async { calls.append(.dictate(down)) }

    public func transcript(for id: SessionID) async -> [TranscriptTurn] { turns[id] ?? [] }

    public func teammateLanes(for id: SessionID) async -> [String: LaneHistory] { lanes[id] ?? [:] }

    public func events(for id: SessionID) -> AsyncStream<SessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
        eventListeners[id, default: []].append(continuation)
        return stream
    }

    public func handle(_ event: PanelEvent) async { calls.append(.handle(event)) }

    public func details(for id: SessionID) async -> SessionDetails { detailsByID[id] ?? SessionDetails() }

    public func openPanel(_ id: SessionID) async { calls.append(.panel(id)) }

    public func shownSessionChanged(from old: SessionID?, to new: SessionID?) { calls.append(.shown(new)) }

    private func update(_ id: SessionID, _ change: (inout SessionSnapshot) -> Void) {
        guard let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
        var all = snapshots
        change(&all[index])
        set(all)
    }
}
