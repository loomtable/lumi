import AppKit
import BuddyCore
import Foundation
import SwiftUI

/// What the user did in the conversation Panel.
nonisolated public enum PanelEvent: Sendable, Equatable {
    /// The composer's send: text, steer or typed, the ▣ chip, attachments and mode.
    case submit(SessionID, PageSubmit)
    /// The composer's stop (■ or ⌘.), while a turn runs.
    case stop(SessionID)
    /// Approvals, questions, teammates and the mic, as the page reported them.
    case action(SessionID, PageAction)
    /// ⌘⇧E: open the session in the Studio.
    case expand(SessionID)
    case pinned(SessionID, Bool)
    /// ⌘M: the session keeps running in the background.
    case minimised(SessionID)
    case closed(SessionID)
}

/// Where to dock the Panel: the origin window and the anchor Lumi read from, in AppKit
/// screen coordinates.
nonisolated public struct PanelDock: Sendable, Equatable {
    public var originWindow: CGRect?
    public var anchor: CGPoint?

    public init(originWindow: CGRect? = nil, anchor: CGPoint? = nil) {
        self.originWindow = originWindow
        self.anchor = anchor
    }
}

/// The conversation Panel: a non-activating panel that shows one session's page and streams its
/// events in place. Implemented by `LivePanel` and `FakePanel`.
@MainActor
public protocol PanelPresenting: AnyObject {
    var events: AsyncStream<PanelEvent> { get }
    /// The session the Panel shows, while it's on screen.
    var visibleSession: SessionID? { get }
    /// True while the composer has keyboard focus (dictation types into it).
    var composerIsKey: Bool { get }
    /// Opens the Panel on `session`, with its earlier turns, docked beside `dock`'s window.
    func show(session: SessionSnapshot, page: [TranscriptTurn], dock: PanelDock?)
    /// Streams one event into the page of `session`; ignored unless it's the visible one.
    func append(_ event: SessionEvent, to session: SessionID)
    /// A turn the app sent into the visible page (a voice-in-page transcript, a card action).
    func record(question: String, kind: TurnKind, context: ContextStrip?, to session: SessionID)
    /// What came of a prompt edited in a page showing `session`.
    func applyEdit(_ edit: PageEdit, to session: SessionID)
    /// A fresher snapshot: title, symbol.
    func update(_ snapshot: SessionSnapshot)
    /// What was read for the latest turn: its "Read from" strip.
    func setContext(_ strip: ContextStrip, to session: SessionID)
    /// Types `text` at the composer's cursor.
    func insertIntoComposer(_ text: String)
    func minimise()
}

extension PanelEvent {
    /// A page action as the Panel (and the Studio column) reports it.
    public init(_ action: PageAction, session id: SessionID) {
        switch action {
        case .submit(let submit): self = .submit(id, submit)
        case .stop: self = .stop(id)
        default: self = .action(id, action)
        }
    }
}

extension PanelPresenting {
    public func show(session: SessionSnapshot, page: [TranscriptTurn]) { show(session: session, page: page, dock: nil) }
}

/// The app's Panel (04 §3.2). One `ConversationPanel` window, reused across sessions.
@MainActor
public final class LivePanel: PanelPresenting {
    public let events: AsyncStream<PanelEvent>
    public private(set) var visibleSession: SessionID?
    public private(set) var composerIsKey = false
    /// The page on screen, for the Studio handoff.
    public private(set) var model: ConversationPageModel?
    /// A session's folders, for the composer's `@` files and project skills.
    public var composerFolders: @MainActor (SessionID) async -> [URL] = { _ in [] }

    private let continuation: AsyncStream<PanelEvent>.Continuation
    private var panel: ConversationPanel?
    private let chrome = PanelChrome()
    private var dock: PanelDock?
    private var contentHeight = PanelDocking.minHeight
    private let defaults: UserDefaults
    static let positionsKey = "v2.panelPositions"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        (events, continuation) = AsyncStream.makeStream(of: PanelEvent.self)
    }

    public func show(session: SessionSnapshot, page: [TranscriptTurn], dock: PanelDock?) {
        if visibleSession == session.id, let model {
            model.update(session)
            panel?.orderFrontRegardless()
            return
        }
        let model = ConversationPageModel(snapshot: session, history: page)
        let id = session.id
        model.composer.folders = { [weak self] in await self?.composerFolders(id) ?? [] }
        model.onAction = { [weak self] action in self?.forward(action, from: session.id) }
        self.model = model
        self.dock = dock
        chrome.pinned = session.pinned
        let panel = self.panel ?? makePanel()
        panel.setRoot(root(model))
        visibleSession = session.id
        model.isVisible = true
        place(panel)
        let opening = !panel.isVisible
        panel.orderFrontRegardless()
        // Opens like the switcher strip: a fade and a small spring up to full size, all in the
        // render server. Already on screen (another session's page), it just swaps.
        if opening, let host = panel.contentView {
            host.wantsLayer = true
            if let layer = host.layer {
                Motion.animateWindow(layer, opening: true, scale: Self.openScale,
                                     anchor: CGPoint(x: layer.bounds.midX, y: layer.bounds.midY),
                                     reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }
    }

    /// The Panel grows from this scale as it opens.
    static let openScale: CGFloat = 0.98

    public func append(_ event: SessionEvent, to session: SessionID) {
        guard session == visibleSession else { return }
        model?.apply(event)
    }

    public func record(question: String, kind: TurnKind, context: ContextStrip?, to session: SessionID) {
        guard session == visibleSession else { return }
        model?.record(question: question, kind: kind, context: context)
    }

    public func applyEdit(_ edit: PageEdit, to session: SessionID) {
        guard session == visibleSession else { return }
        model?.apply(edit)
    }

    public func update(_ snapshot: SessionSnapshot) {
        guard snapshot.id == visibleSession else { return }
        model?.update(snapshot)
        chrome.pinned = snapshot.pinned
    }

    public func setContext(_ strip: ContextStrip, to session: SessionID) {
        guard session == visibleSession else { return }
        model?.setContext(strip)
    }

    public func insertIntoComposer(_ text: String) {
        guard let model else { return }
        model.draft += (model.draft.isEmpty || model.draft.hasSuffix(" ") ? "" : " ") + text
    }

    public func minimise() {
        guard let id = visibleSession else { return }
        hide()
        continuation.yield(.minimised(id))
    }

    public func close() {
        guard let id = visibleSession else { return }
        hide()
        continuation.yield(.closed(id))
    }

    // MARK: Private

    private func hide() {
        model?.isVisible = false
        panel?.orderOut(nil)
        visibleSession = nil
        composerIsKey = false
        model = nil
    }

    private func forward(_ action: PageAction, from id: SessionID) {
        switch action {
        default:
            continuation.yield(PanelEvent(action, session: id))
        }
    }

    private func root(_ model: ConversationPageModel) -> some View {
        PanelRootView(
            model: model, chrome: chrome,
            onPin: { [weak self] in
                guard let self, let id = self.visibleSession else { return }
                self.chrome.pinned.toggle()
                self.continuation.yield(.pinned(id, self.chrome.pinned))
            },
            onExpand: { [weak self] in
                guard let self, let id = self.visibleSession else { return }
                self.continuation.yield(.expand(id))
            },
            onMinimise: { [weak self] in self?.minimise() },
            onClose: { [weak self] in self?.close() },
            onComposerFocus: { [weak self] focused in self?.composerIsKey = focused },
            onContentHeight: { [weak self] h in self?.grow(to: h) })
    }

    private func makePanel() -> ConversationPanel {
        let p = ConversationPanel(root: EmptyView())
        p.onKey = { [weak self] e in self?.key(e) ?? false }
        p.onFocusChange = { [weak self] key in if !key { self?.composerIsKey = false } }
        p.onMoved = { [weak self] corner, display in self?.remember(corner, display: display) }
        panel = p
        return p
    }

    /// Esc with an empty composer (no text, no files) and no running turn closes the Panel (⎋:
    /// stop speaking → clear → close). Otherwise the composer takes it: menu, clear, interrupt.
    private func key(_ e: NSEvent) -> Bool {
        // ⌘. stops the running turn even while a steer is being typed (QA U12).
        if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == ".",
           let model, model.page.isRunning {
            model.stop()
            return true
        }
        guard e.keyCode == 53, model?.composer.draft.isEmpty ?? true, !(model?.page.isRunning ?? false) else { return false }
        close()
        return true
    }

    private func grow(to height: CGFloat) {
        guard abs(height - contentHeight) > 1, let panel else { return }
        contentHeight = height
        place(panel)
    }

    private func place(_ panel: ConversationPanel) {
        guard let screen = screen(for: dock) ?? panel.screen ?? NSScreen.main else { return }
        if panel.isVisible {
            // Grow downward from the top edge, staying on screen.
            var f = panel.frame
            let h = PanelDocking.height(content: contentHeight, visible: screen.visibleFrame)
            f.origin.y = f.maxY - h
            f.size.height = h
            panel.place(PanelDocking.clamp(f, to: screen.visibleFrame), animate: false)
            return
        }
        let input = PanelDocking.Input(visible: screen.visibleFrame, originWindow: dock?.originWindow, anchor: dock?.anchor,
                                       contentHeight: contentHeight, remembered: remembered(screen.displayID))
        panel.place(PanelDocking.frame(input), animate: false)
    }

    private func screen(for dock: PanelDock?) -> NSScreen? {
        let point = dock?.anchor ?? dock?.originWindow.map { CGPoint(x: $0.midX, y: $0.midY) }
        guard let point else { return nil }
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func remembered(_ display: CGDirectDisplayID) -> CGPoint? {
        guard let all = defaults.dictionary(forKey: Self.positionsKey) as? [String: [Double]],
              let xy = all[String(display)], xy.count == 2 else { return nil }
        return CGPoint(x: xy[0], y: xy[1])
    }

    private func remember(_ corner: CGPoint, display: CGDirectDisplayID) {
        var all = defaults.dictionary(forKey: Self.positionsKey) as? [String: [Double]] ?? [:]
        all[String(display)] = [corner.x, corner.y]
        defaults.set(all, forKey: Self.positionsKey)
    }
}

/// A recording fake for the shell's tests.
@MainActor
public final class FakePanel: PanelPresenting {
    public enum Call: Sendable, Equatable {
        case show(SessionID, turns: Int)
        case append(SessionEvent, SessionID)
        case record(String, TurnKind, SessionID)
        case edit(PageEdit, SessionID)
        case update(SessionID)
        case context(ContextStrip, SessionID)
        case insert(String)
        case minimise
    }

    public private(set) var calls: [Call] = []
    public var visibleSession: SessionID?
    public var composerIsKey = false
    public private(set) var lastDock: PanelDock?
    public let events: AsyncStream<PanelEvent>
    private let continuation: AsyncStream<PanelEvent>.Continuation

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: PanelEvent.self)
    }

    /// Simulates a user interaction in tests.
    public func send(_ event: PanelEvent) { continuation.yield(event) }

    public func show(session: SessionSnapshot, page: [TranscriptTurn], dock: PanelDock?) {
        calls.append(.show(session.id, turns: page.count))
        visibleSession = session.id
        lastDock = dock
    }
    public func append(_ event: SessionEvent, to session: SessionID) { calls.append(.append(event, session)) }
    public func record(question: String, kind: TurnKind, context: ContextStrip?, to session: SessionID) {
        calls.append(.record(question, kind, session))
    }
    public func applyEdit(_ edit: PageEdit, to session: SessionID) { calls.append(.edit(edit, session)) }
    public func update(_ snapshot: SessionSnapshot) { calls.append(.update(snapshot.id)) }
    public func setContext(_ strip: ContextStrip, to session: SessionID) { calls.append(.context(strip, session)) }
    public func insertIntoComposer(_ text: String) { calls.append(.insert(text)) }
    public func minimise() {
        calls.append(.minimise)
        visibleSession = nil
    }
}
