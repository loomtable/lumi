import AppKit
import BuddyCore
import SwiftUI

/// Converts between AppKit screen coordinates (bottom-left origin) and the global
/// top-left points the rest of the app uses.
enum ScreenSpace {
    /// Height of the primary display, which defines the flip.
    static var primaryMaxY: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func topLeft(_ r: NSRect) -> CGRect { topLeft(r, primaryMaxY: primaryMaxY) }
    static func topLeft(_ r: NSRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }

    static func topLeft(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryMaxY - p.y) }

    /// The display with the active menu bar, where the research capsule goes. With
    /// "Displays have separate Spaces" every display has a menu bar and the active one
    /// follows keyboard focus; otherwise only the primary display has one.
    ///
    /// Not `NSScreen.main`: that follows the key window, which is our own panel while the
    /// text box or a card has focus. The frontmost app's frontmost window decides instead
    /// (window bounds need no Screen Recording).
    static var menuBarScreen: NSScreen? {
        let screens = NSScreen.screens
        let frames = screens.map { topLeft($0.frame) }
        let index = menuBarScreenIndex(separateSpaces: NSScreen.screensHaveSeparateSpaces, screenFrames: frames,
                                       frontWindowCentre: frontmostWindowCentre())
        return index.map { screens[$0] } ?? screens.first
    }

    /// Pure rule for tests: the primary display unless every display has its own menu bar;
    /// then the display holding the frontmost app's window, or the primary as a fallback.
    nonisolated static func menuBarScreenIndex(separateSpaces: Bool, screenFrames: [CGRect], frontWindowCentre: CGPoint?) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        guard separateSpaces, let c = frontWindowCentre else { return 0 }
        return screenFrames.firstIndex { $0.contains(c) } ?? 0
    }

    /// Centre of the frontmost app's frontmost normal window (global top-left), if any.
    static func frontmostWindowCentre() -> CGPoint? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return frontWindowCentre(in: list, frontmostPID: app.processIdentifier, ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// Pure part, for tests: the frontmost app's first normal (layer 0) window, never ours.
    nonisolated static func frontWindowCentre(in windows: [[String: Any]], frontmostPID: Int32, ownPID: Int32) -> CGPoint? {
        guard frontmostPID != ownPID else { return nil }
        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == frontmostPID,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"], w > 0, h > 0 else { continue }
            return CGPoint(x: x + w / 2, y: y + h / 2)  // CG window bounds are already top-left
        }
        return nil
    }

    /// Which display the research report opens on: the capsule's own display while it's
    /// visible, otherwise the menu-bar display.
    nonisolated static func reportScreenIndex(capsuleFrame: CGRect, capsuleVisible: Bool, screenFrames: [CGRect],
                                              menuBarIndex: Int?) -> Int? {
        if capsuleVisible, let i = screenFrames.firstIndex(of: capsuleFrame) { return i }
        return menuBarIndex
    }

    /// The screen containing a global top-left point, or the main screen.
    static func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { topLeft($0.frame).contains(p) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

/// A level sample that views poll from a TimelineView instead of observing.
final class LevelBox {
    var value = 0.0
}

/// Everything the overlay views render. Owned by `BuddyOverlayController`.
@Observable
final class OverlayModel {
    enum Surface: Equatable {
        case none
        case listening(hint: String)
        /// The double-tap text box (shares the pill's glass, so the pill morphs into it).
        case textBox
        case thinking(Lane, status: String?)
        case answer(Answer, Placement, Placer.Style)

        var isAnswer: Bool { if case .answer = self { true } else { false } }
        var isListening: Bool { if case .listening = self { true } else { false } }
        var isPill: Bool {
            switch self {
            case .listening, .textBox, .thinking: true
            case .none, .answer: false
            }
        }
    }

    var surface: Surface = .none
    var settings = OverlaySettings() {
        didSet {
            if settings.statusPosition != oldValue.statusPosition { placeStatusPill() }
            if !settings.rings, oldValue.rings { rings.removeAll() }  // "Rings on screen" turned off
        }
    }
    /// The backdrop around the visible surface is bright: stronger hairline and shadow.
    var brightBackdrop = false
    /// Bumps for every new answer, so motion restarts.
    var answerID = 0
    /// Global top-left frame of the display that shows the overlay.
    var screenFrame: CGRect = .zero
    /// Pill frame in global top-left points. The size is measured from the view.
    var pillOrigin: CGPoint = .zero
    /// The display's visible frame (global top-left) the pill must stay inside.
    var pillBounds: CGRect = .zero
    /// Measured from the view. The pill stays centred on its fixed spot as it grows (thinking
    /// is wider than listening).
    var pillSize = CGSize(width: 180, height: 36) {
        didSet { if pillSize != oldValue { placeStatusPill() } }
    }
    var pillFrame: CGRect { CGRect(origin: pillOrigin, size: pillSize) }
    /// Where the user dragged the pill, from its fixed spot; kept for the conversation.
    var pillDrag: CGSize = .zero
    /// Where the user dragged an answer (top-left, global); later answers in the conversation
    /// open there. Nil: placed by the placement mode.
    var answerOrigin: CGPoint?
    /// Where the user dragged the capsule from its spot under the menu bar; kept while it shows.
    var capsuleDrag: CGSize = .zero

    /// The pill's fixed spot: centred at the top of the visible frame (below the
    /// capsule when it shows on this display) or at the bottom, plus the user's drag, kept inside.
    func statusPillOrigin(size: CGSize, in bounds: CGRect) -> CGPoint {
        let area = bounds.insetBy(dx: Placer.edgeMargin, dy: Placer.edgeMargin)
        // Under the research capsule whenever its spot would cover the pill's, even nudged by a drag.
        let home = CGRect(x: (area.midX - size.width / 2).rounded(), y: area.minY, width: size.width, height: size.height)
        let covers = capsuleVisible && capsuleScreenFrame == screenFrame && home.intersects(capsuleFrame.insetBy(dx: 0, dy: -8))
        let top = covers ? max(area.minY, capsuleFrame.maxY + 8) : area.minY
        let y = settings.statusPosition == .top ? top : area.maxY - size.height
        let origin = CGPoint(x: (area.midX - size.width / 2).rounded() + pillDrag.width, y: y + pillDrag.height)
        return Self.clamp(origin, size: size, in: bounds)
    }

    func placeStatusPill() {
        guard pillBounds.width > 0 else { return }
        pillOrigin = statusPillOrigin(size: pillSize, in: pillBounds)
    }
    /// "Listening" for the first 2 s, then the hint.
    var showsListeningHint = false
    /// The mic is live (`setMicReady`); until then the pill shows no "Listening".
    var micReady = true
    /// The mic is taking a while: the pill says "Getting ready…".
    var showsGettingReady = false

    /// The listening pill's words: nothing visible until the mic is ready (then "Getting ready…"
    /// once it takes a while), "Listening" for its first 2 s, then the hint.
    static func listeningLabel(hint: String, micReady: Bool, gettingReady: Bool, showsHint: Bool) -> (text: String, visible: Bool) {
        if !micReady { return (gettingReadyLine, gettingReady) }
        return (showsHint ? hint : "Listening", true)
    }

    static let gettingReadyLine = "Getting ready…"
    /// Mic level for the dots and rim. Updates arrive at about 50 Hz, so the value lives
    /// outside observation: a level update invalidates nothing, and only the dot field and
    /// rim read it, each on its own 30 fps timeline.
    @ObservationIgnored let mic = LevelBox()
    /// Reply level for the speaking glow, outside observation like `mic`: only the glow's own
    /// 30 Hz timeline reads it, so the card's text and web view never re-render with the voice.
    @ObservationIgnored let speech = LevelBox()
    var speaking = false
    /// The thinking pill's status is the answer's headline (`showHeadline`).
    var statusIsHeadline = false
    /// The answer on screen has the headline the pill just showed: no ink-in.
    var headlineAlreadyShown = false
    /// True while the visible surface folds away (0.2 s), before it is removed.
    var folding = false
    /// Where the current answer grew from (global top-left), for pop and fold origins.
    var source: CGPoint = .zero
    /// How small the surface folds: .55 toward its source, .06 when tucked into the orb.
    var foldScale: CGFloat = Motion.foldScale
    /// True when the answer morphs out of a visible pill or previous answer (no pop).
    var morphs = false
    /// Bumps when an answer appears without a morph, which plays the pop.
    var popTrigger = 0
    /// What the current answer is placed against, so it can be re-placed when its web
    /// content changes height or the display changes.
    var anchor: Anchor?
    /// Full screen (F or ⤢): about 94% × 90% of the display, centred.
    var fullScreen = false
    var fullScreenFrame: CGRect = .zero
    var fullScreenWebHeight: CGFloat = 0
    /// The card HTML's height as last reported at the full-screen width; nil until then.
    var fullScreenContentHeight: CGFloat?
    var web: CardWebContent?
    /// Text box and reply field contents.
    var draft = ""
    var reply = ""
    /// The conversation started by typing: focus stays in the card (Follow-up typing).
    var typed = false
    /// True while the overlay panel is key (the card or text box has keyboard focus).
    var hasFocus = false
    /// The card HTML's full content height (it scrolls itself only while that is unknown).
    var webHeight: CGFloat = 0
    /// The answer is taller than its cap, so its body scrolls inside the card.
    var answerScrolls = false

    /// Each display's frame (global top-left), so a panel can tell what to render.
    var displayFrames: [CGDirectDisplayID: CGRect] = [:]

    // MARK: Research capsule

    /// Jobs to show, most recent first.
    var capsules: [CapsuleState] = []
    /// The display with the active menu bar (global top-left frame), where the capsule sits.
    var capsuleScreenFrame: CGRect = .zero
    /// Its visible frame (below the menu bar).
    var capsuleBounds: CGRect = .zero
    /// Measured capsule and peek sizes, for hit testing.
    var capsuleSize = CGSize(width: 180, height: 26)
    var peekSize: CGSize = .zero
    var peekOpen = false
    /// The job the peek shows (it doesn't jump to a newer job that becomes first).
    var peekJobID: UUID?
    var peekJob: CapsuleState? { capsules.first { $0.id == peekJobID } }
    /// Bumps when a job finishes, which plays the done nudge.
    var capsuleNudge = 0

    var capsuleVisible: Bool { !capsules.isEmpty }

    /// The job the capsule shows: an unopened finished job first (it's waiting for the
    /// user), otherwise the most recent one.
    var displayedCapsule: CapsuleState? { capsules.first { $0.status == .done } ?? capsules.first }

    /// "+N": other jobs still running.
    var otherRunningJobs: Int {
        capsules.filter { $0.isRunning && $0.id != displayedCapsule?.id }.count
    }

    /// The capsule centred at the top of the visible frame, just under the menu bar (or the
    /// notch). Global top-left.
    var capsuleFrame: CGRect {
        let home = CGRect(x: (capsuleBounds.midX - capsuleSize.width / 2).rounded(), y: capsuleBounds.minY + 6,
                          width: capsuleSize.width, height: capsuleSize.height)
        guard capsuleDrag != .zero else { return home }
        let moved = home.offsetBy(dx: capsuleDrag.width, dy: capsuleDrag.height)
        return CGRect(origin: Self.clamp(moved.origin, size: moved.size, in: capsuleBounds), size: moved.size)
    }

    /// The peek card, centred under the capsule.
    var peekFrame: CGRect {
        let c = capsuleFrame
        return CGRect(x: (c.midX - peekSize.width / 2).rounded(), y: c.maxY + 8, width: peekSize.width, height: peekSize.height)
    }

    func capsuleHitFrames(onDisplay display: CGRect) -> [CGRect] {
        guard capsuleVisible, display == capsuleScreenFrame else { return [] }
        return peekOpen ? [capsuleFrame, peekFrame] : [capsuleFrame]
    }

    // MARK: Progress capsules

    /// The running queries' capsules on screen, top to bottom (`updateProgress`).
    var progress: ProgressStack.Shown = .empty
    /// The display they sit on (global top-left frame) and its visible frame.
    var progressScreenFrame: CGRect = .zero
    var progressBounds: CGRect = .zero
    /// Measured from the view.
    var progressSize: CGSize = .zero
    static let progressGap: CGFloat = 6

    /// Each capsule's frame (global top-left), measured from the view.
    @ObservationIgnored var progressRowFrames: [Int: CGRect] = [:]

    /// The capsules step aside while the switcher strip is open around the pill: the strip shows
    /// the same sessions.
    var progressVisible: Bool { !progress.isEmpty && !switcherOpen }
    /// A capsule needs the user: it takes clicks (the rest stay click-through).
    var progressTakesClicks: Bool { progressVisible && progress.rows.contains(where: \.needsYou) }
    var switcherOpen = false
    /// Who the pill talks to, and that session's origin app icon for its badge.
    var pillTarget = PillTarget.none
    var pillTargetIcon: NSImage?

    /// The needs-you capsules' frames on one display (global top-left).
    func progressHitFrames(onDisplay display: CGRect) -> [CGRect] {
        guard progressTakesClicks, display == progressScreenFrame else { return [] }
        return progress.rows.filter(\.needsYou).compactMap { progressRowFrames[$0.id] }
    }

    /// Centred at the top of the visible frame, under the research capsule when it sits there,
    /// and under the pill when the pill is at the top of this display: the pill (the question
    /// in front) and the stack read as one column. Global top-left.
    var progressOrigin: CGPoint {
        let area = progressBounds.insetBy(dx: Placer.edgeMargin, dy: Placer.edgeMargin)
        var top = area.minY
        let x = (area.midX - progressSize.width / 2).rounded()
        // Under whatever of the column it would cover, wherever a drag left it (65-SURFACE-RULES,
        // rule 2): a pill or research capsule nudged by a few points still has the stack under it.
        var above: [(frame: CGRect, gap: CGFloat)] = []
        if capsuleVisible, capsuleScreenFrame == progressScreenFrame { above.append((capsuleFrame, 8)) }
        if surface.isPill, !folding, screenFrame == progressScreenFrame { above.append((pillFrame, Self.progressGap)) }
        for (frame, gap) in above {
            let stack = CGRect(x: x, y: top, width: max(progressSize.width, 1), height: max(progressSize.height, 1))
            if stack.intersects(frame.insetBy(dx: 0, dy: -gap)) { top = max(top, frame.maxY + gap) }
        }
        return CGPoint(x: x, y: top)
    }

    /// The area the stack covers, for anything placed near the top centre. Empty when hidden.
    var progressFrame: CGRect {
        progressVisible ? CGRect(origin: progressOrigin, size: progressSize) : .null
    }

    // MARK: Toasts and conversation chips

    struct Toast: Equatable {
        let id = UUID()
        var text: String
        var origin: CGPoint
    }

    var toast: Toast?
    /// Measured size; a toast wider than first assumed is pulled back inside the 12 pt margin of
    /// its display.
    var toastSize = CGSize(width: 220, height: 32) {
        didSet { if let t = toast { toast?.origin = Self.clamp(t.origin, size: toastSize, in: toastBounds) } }
    }
    var toastBounds: CGRect = .zero

    // MARK: Rings

    struct ActiveRing: Identifiable, Equatable {
        let id = UUID()
        var ring: Ring
    }

    /// One-shot rings currently shown (each lasts 6 s).
    var rings: [ActiveRing] = []

    /// Whether anything is drawn on a display (global top-left frame).
    func shows(onDisplay display: CGRect) -> Bool {
        (display == screenFrame && surface != .none)
            || (capsuleVisible && display == capsuleScreenFrame)
            || (progressVisible && display == progressScreenFrame)
            || rings.contains { display.intersects($0.ring.rect) }
            || (toast.map { display.contains($0.origin) } ?? false)
    }

    /// Hit frames on one display (global top-left): the pill or answer where it lives, the
    /// capsule (and its peek) on the menu bar display, and needs-you progress capsules. Rings and
    /// toasts don't take clicks.
    func hitFrames(onDisplay display: CGRect) -> [CGRect] {
        (display == screenFrame ? hitFrames : []) + capsuleHitFrames(onDisplay: display)
            + progressHitFrames(onDisplay: display)
    }

    /// The visible surface's frame in global points, for click-through and click-away.
    var hitFrames: [CGRect] {
        switch surface {
        case .none: []
        case .listening, .textBox, .thinking: [pillFrame]
        case .answer(_, let p, let style):
            // No scrim: only the answer takes clicks, so a click beside it
            // reaches the app underneath and closes the answer like any click-away.
            [fullScreen ? fullScreenFrame : Self.outerFrame(p, style: style)]
        }
    }

    static func clamp(_ origin: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        guard bounds.width > 0 else { return origin }
        let area = bounds.insetBy(dx: Placer.edgeMargin, dy: Placer.edgeMargin)
        return CGPoint(x: min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width)),
                       y: min(max(origin.y, area.minY), max(area.minY, area.maxY - size.height)))
    }

    /// Which side carries the tail, if any.
    static func tailSide(_ p: Placement, style: Placer.Style) -> CardShape.Side? {
        style == .card && p.tailOffset != nil ? CardShape.side(for: p.edge) : nil
    }

    /// The answer's frame including the tail band.
    static func outerFrame(_ p: Placement, style: Placer.Style) -> CGRect {
        let l = CardShape.tailLength, b = p.frame
        switch tailSide(p, style: style) {
        case .top: return CGRect(x: b.minX, y: b.minY - l, width: b.width, height: b.height + l)
        case .bottom: return CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height + l)
        case .left: return CGRect(x: b.minX - l, y: b.minY, width: b.width + l, height: b.height)
        case .right: return CGRect(x: b.minX, y: b.minY, width: b.width + l, height: b.height)
        case nil: return b
        }
    }

    /// Converts a global frame into the overlay panel's local space.
    func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }
    func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screenFrame.minX, y: p.y - screenFrame.minY) }
}
