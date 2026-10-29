import AppKit
import BuddyCore
import os
import SwiftUI

/// The app's switcher: the hold-key + Tab strip that grows out of the listening pill (the pill's
/// row is its header; 63-SWITCHER-UX), and its peek.
///
/// The strip is built at the buddy key's press (`prepare`): its panel is ordered in, laid out
/// and drawn while invisible, so the Tab only flips its alpha and the highlight (budget:
/// ≤ 16.7 ms p95 from Tab to the first frame; `onShown` reports the commit).
public final class LiveSwitcher: SwitcherPresenting {
    public let events: AsyncStream<SwitcherEvent>
    /// After `open`, when the strip's first visible frame is committed to the render server.
    public var onShown: (@MainActor () -> Void)?
    /// The listening pill's frame (AppKit screen coordinates) and whether it sits at the bottom
    /// of the screen; nil without a pill. The strip is placed around it.
    public var pillAnchor: (@MainActor () -> (frame: CGRect, atBottom: Bool)?)?
    /// The strip opened or closed: the overlay's capsules step aside while it's open.
    public var onOpenChanged: (@MainActor (Bool) -> Void)?

    let model = SwitcherModel()
    private let continuation: AsyncStream<SwitcherEvent>.Continuation
    private let signposter = OSSignposter(subsystem: BuddyCore.bundleIdentifier, category: "switcher")

    /// Just under the overlay's panels, so the live pill (its level, its words) stays on top as
    /// the strip's header.
    private(set) lazy var stripPanel = SwitcherPanel(StripView(model: model, onEvent: { [weak self] in self?.send($0) }),
                                                level: SwitcherPanel.stripLevel)
    private lazy var peekPanel = SwitcherPanel(PeekView(model: model, onEvent: { [weak self] in self?.send($0) }))

    /// The active screen's visible frame, chosen at prepare.
    private var screen: CGRect = .zero
    /// The strip's plate, in screen coordinates.
    private(set) var plate: CGRect = .zero
    /// The pill the plate was placed around (screen coordinates); the strip grows out of it.
    private var pill: CGRect?
    /// Each tile's last on-screen frame, for a peek after the strip closed.
    private var tileFrames: [SessionID: CGRect] = [:]
    private var sessions: [SessionID: SessionSnapshot] = [:]
    private var hideTask: Task<Void, Never>?

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: SwitcherEvent.self)
    }

    // MARK: Strip

    public func prepare(tiles: [SessionSnapshot]) {
        hideTask?.cancel()
        let state = signposter.beginInterval("prepare")
        defer { signposter.endInterval("prepare", state) }
        for s in tiles { sessions[s.id] = s }
        model.tiles = tiles
        // The first Tab usually lands on slot 2 (slot 1 is the current session), so the strip
        // is drawn with that highlight already and `open` changes nothing SwiftUI draws.
        model.highlight = min(1, tiles.count)
        model.isOpen = false
        model.committed = false
        model.now = Date()
        loadIcons(for: tiles)
        screen = Self.activeScreen()?.visibleFrame ?? .zero
        layoutStrip()
        stripPanel.stage()
    }

    /// `latest` is every session (a tile missing from it was forgotten). Ages stay as of the press
    /// (`prepare`), like the order: a new `now` on every sessions change redrew every tile, and one
    /// landing just before the Tab put that work in the Tab's frame (U65).
    public func refresh(_ latest: [SessionSnapshot]) {
        for s in latest { sessions[s.id] = s }
        let byID = Dictionary(latest.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if !model.tiles.isEmpty {
            // Same order; archived and forgotten tiles collapse.
            let updated = model.tiles.compactMap { byID[$0.id] }.filter { !$0.archived }
            if updated != model.tiles {
                let rows = SwitcherGeometry.rows(sessions: model.tiles.count)
                model.tiles = updated
                move(to: min(model.highlight, updated.count))
                if rows != SwitcherGeometry.rows(sessions: updated.count) { layoutStrip() }
                // Prepared and hidden: draw the change now, so the Tab still only flips the alpha.
                if !model.isOpen, stripPanel.isVisible { stripPanel.warm() }
            }
        }
        if let peeked = model.peek, let new = byID[peeked.id], new != peeked {
            model.peek = new
            placePeek(new)  // a longer line or a new teammate row must not be cut off
        }
    }

    public func open(highlight: Int) {
        if model.tiles.isEmpty, !stripPanel.isVisible { prepare(tiles: []) }
        // The pill showed, moved or went since the press: place the plate around it now, so its
        // header row is exactly the pill's (and no row is kept for a pill that isn't there).
        if pillAnchor?()?.frame != pill { layoutStrip() }
        let state = signposter.beginInterval("open")
        move(to: highlight)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                self?.signposter.endInterval("open", state)
                self?.onShown?()
            }
        }
        model.isOpen = true
        stripPanel.reveal()
        CATransaction.commit()
        // Outside the measured transaction: its completion would wait for the spring.
        animateStrip(in: true, commit: false)
        onOpenChanged?(true)
    }

    public func move(to index: Int) {
        let i = min(max(0, index), model.tiles.count)
        // Unchanged at the first Tab (prepare drew it): writing it anyway would redraw the strip.
        if i != model.highlight { model.highlight = i }
    }

    public func close(commit: Bool) {
        guard model.isOpen || stripPanel.isVisible else { return }
        rememberTileFrames()
        model.committed = commit
        model.isOpen = false
        stripPanel.ignoresMouseEvents = true
        animateStrip(in: false, commit: commit)
        hidePeek()
        onOpenChanged?(false)
        hideTask?.cancel()
        let growing = pill != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(commit || growing ? 240 : 140))
            guard let self, !Task.isCancelled, !self.model.isOpen else { return }
            self.stripPanel.conceal()
        }
    }

    // MARK: Peek

    public func peek(_ id: SessionID?) {
        guard let id, let s = sessions[id] ?? model.tiles.first(where: { $0.id == id }) else {
            hidePeek()
            return
        }
        model.now = Date()
        model.peek = s
        model.peekShowsKeys = model.isOpen
        placePeek(s)
        peekPanel.reveal()
    }

    /// Sizes the peek to its card for `s` and puts it beside its tile.
    private func placePeek(_ s: SessionSnapshot) {
        let anchor = peekAnchor(for: s.id)
        let screen = Self.screen(containing: anchor) ?? self.screen
        let frame = SwitcherGeometry.peekFrame(size: peekCardSize(s), anchor: anchor, screen: screen)
        peekPanel.place(frame.insetBy(dx: -SwitcherPanelLayout.shadowRoom, dy: -SwitcherPanelLayout.shadowRoom))
    }

    /// The card's size measured from the view itself: the panel's own fitting size can still
    /// show the previous peek, since SwiftUI hasn't applied `model.peek` yet, which cut a
    /// longer card off at the bottom.
    func peekCardSize(_ s: SessionSnapshot) -> CGSize {
        let card = PeekCardView(session: s, look: TileLook.make(s, now: model.now), showsKeys: model.peekShowsKeys,
                                t: Tokens(.init(dark: false)), onEvent: { _ in })
        let fit = NSHostingController(rootView: card)
            .sizeThatFits(in: CGSize(width: SwitcherGeometry.peekWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: SwitcherGeometry.peekWidth, height: max(60, ceil(fit.height)))
    }

    private func hidePeek() {
        model.peek = nil
        peekPanel.conceal()
    }

    private func peekAnchor(for id: SessionID) -> CGRect {
        if model.isOpen, let i = model.tiles.firstIndex(where: { $0.id == id }) { return screenFrame(ofTile: i) }
        if let frame = tileFrames[id] { return frame }
        if plate != .zero { return plate }
        return CGRect(x: screen.midX, y: screen.maxY - SwitcherGeometry.screenMargin, width: 0, height: 0)
    }

    private func send(_ event: SwitcherEvent) { continuation.yield(event) }

    // MARK: Layout

    /// Open: around a pill, the plate grows out of the pill's capsule (a `settle` spring on a
    /// mask, so the pill's row never moves) and fades in; close shrinks it back. Without a pill:
    /// fade in and scale 0.96 → 1. Close fades out in 120 ms, 220 ms after a pick. Reduce Motion:
    /// cross-fades only. All in the render server.
    private func animateStrip(in opening: Bool, commit: Bool) {
        guard let layer = stripPanel.host.layer else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let b = layer.bounds
        let grows = !reduceMotion && grow(layer, opening: opening)
        if !grows { layer.mask = nil }
        Motion.animateWindow(layer, opening: opening, scale: grows ? 1 : 0.96,
                             anchor: CGPoint(x: b.midX, y: b.minY + SwitcherPanelLayout.shadowRoom), afterPick: commit,
                             reduceMotion: reduceMotion || grows)
    }

    /// The plate's mask runs between the pill's capsule and the whole panel. False without a pill.
    private func grow(_ layer: CALayer, opening: Bool) -> Bool {
        guard let pill else { return false }
        let window = pill.offsetBy(dx: -stripPanel.frame.minX, dy: -stripPanel.frame.minY)
        let small = stripPanel.host.convertToLayer(stripPanel.host.convert(window, from: nil))
        let full = layer.bounds
        guard small.width > 0, small.height > 0 else { return false }
        let r = small.height / 2 - 0.01
        let pillPath = CGPath(roundedRect: small, cornerWidth: r, cornerHeight: r, transform: nil)
        let R = SwitcherGeometry.stripRadius
        let fullPath = CGPath(roundedRect: full, cornerWidth: R, cornerHeight: R, transform: nil)
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        let from = mask.presentation()?.path ?? (opening ? pillPath : fullPath)
        mask.frame = full
        mask.path = opening ? fullPath : pillPath
        layer.mask = mask
        let a: CABasicAnimation
        if opening {
            let spring = CASpringAnimation(keyPath: "path")
            spring.stiffness = pow(2 * .pi / 0.25, 2)  // Motion.settle: response 0.25, no bounce
            spring.damping = 2 * sqrt(spring.stiffness)
            spring.duration = spring.settlingDuration
            a = spring
        } else {
            a = CABasicAnimation(keyPath: "path")
            a.duration = 0.2  // Motion.fold
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        }
        a.fromValue = from
        a.toValue = mask.path
        mask.add(a, forKey: "grow")
        return true
    }

    private func layoutStrip() {
        let anchor = pillAnchor?()
        pill = anchor?.frame
        if let anchor {
            let screen = Self.screen(containing: anchor.frame) ?? screen
            plate = SwitcherGeometry.plateFrame(around: anchor.frame, sessions: model.tiles.count, atBottom: anchor.atBottom,
                                                in: screen)
            model.headerHeight = anchor.frame.height + 2 * SwitcherGeometry.headerInset
            model.headerAtBottom = anchor.atBottom
            model.plateWidth = plate.width
        } else {
            plate = SwitcherGeometry.stripFrame(sessions: model.tiles.count, in: screen)
            model.headerHeight = 0
            model.headerAtBottom = false
            model.plateWidth = 0
        }
        stripPanel.place(plate.insetBy(dx: -SwitcherPanelLayout.shadowRoom, dy: -SwitcherPanelLayout.shadowRoom))
    }

    /// The header row the pill sits in (screen coordinates), nil without a pill.
    var headerRow: CGRect? {
        guard model.headerHeight > 0 else { return nil }
        let y = model.headerAtBottom ? plate.minY : plate.maxY - model.headerHeight
        return CGRect(x: plate.minX, y: y, width: plate.width, height: model.headerHeight)
    }

    /// A chip's frame on screen (the plate is laid out top-left, AppKit is bottom-left; a header
    /// on top pushes the chips down).
    private func screenFrame(ofTile index: Int) -> CGRect {
        let f = SwitcherGeometry.tileFrame(index)
        let top = plate.maxY - (model.headerAtBottom ? 0 : model.headerHeight)
        // The chips are centred in a plate wider than them (around a wide pill).
        let inset = max(0, (plate.width - SwitcherGeometry.stripWidth) / 2)
        return CGRect(x: plate.minX + inset + f.minX, y: top - f.maxY, width: f.width, height: f.height)
    }

    private func rememberTileFrames() {
        tileFrames = [:]
        for (i, s) in model.tiles.enumerated() { tileFrames[s.id] = screenFrame(ofTile: i) }
    }

    private func loadIcons(for tiles: [SessionSnapshot]) {
        for bundle in Set(tiles.compactMap { $0.origin?.key.bundleID }) where model.icons[bundle] == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { continue }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            model.icons[bundle] = icon
        }
    }

    /// The screen with the pointer: the one the user is working on.
    static func activeScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    static func screen(containing rect: CGRect) -> CGRect? {
        let p = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }?.visibleFrame
    }
}
