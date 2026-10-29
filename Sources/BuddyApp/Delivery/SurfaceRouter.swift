import BuddyCore
import BuddyOverlay
import Foundation

/// What `SurfaceRouter` knows when a turn finishes.
public struct DeliveryInput: Sendable {
    public var session: SessionID
    public var kind: TurnKind
    public var failed: Bool
    /// The Lumi pages on screen and the session each shows.
    public var visiblePages: [SessionID: PageKind]
    /// The window number of the frontmost window, when known.
    public var frontWindow: Int?
    public var origin: SessionOrigin?
    /// The user is at the Mac (recent input, screen awake).
    public var present: Bool
    public var ranFor: TimeInterval
    /// The user is holding the talk key or typing in Lumi for another ask.
    public var userIsComposingOrHolding: Bool
    /// The user minimised or closed this session's page during the turn: never reopen it.
    public var pageDismissed: Bool

    public init(
        session: SessionID, kind: TurnKind, failed: Bool = false, visiblePages: [SessionID: PageKind] = [:],
        frontWindow: Int? = nil, origin: SessionOrigin? = nil, present: Bool = true, ranFor: TimeInterval = 0,
        userIsComposingOrHolding: Bool = false, pageDismissed: Bool = false
    ) {
        self.session = session
        self.kind = kind
        self.failed = failed
        self.visiblePages = visiblePages
        self.frontWindow = frontWindow
        self.origin = origin
        self.present = present
        self.ranFor = ranFor
        self.userIsComposingOrHolding = userIsComposingOrHolding
        self.pageDismissed = pageDismissed
    }
}

/// The delivery settings, from `SessionSettings`.
public struct DeliverySettings: Sendable, Equatable {
    /// Speak answers to typed and voice-in-page turns (default off).
    public var speakTypedAnswers: Bool
    public var notifyWhenAway: Bool

    public init(speakTypedAnswers: Bool = false, notifyWhenAway: Bool = true) {
        self.speakTypedAnswers = speakTypedAnswers
        self.notifyWhenAway = notifyWhenAway
    }

    public init(_ s: SessionSettings) {
        self.init(speakTypedAnswers: s.speakTypedAnswers, notifyWhenAway: s.notifyWhenAway)
    }
}

public enum NotifyKind: Sendable, Equatable {
    /// One macOS banner: the user is away and the turn ran at least 30 s.
    case banner
}

/// The one surface a finished turn's answer goes to.
public enum Delivery: Sendable, Equatable {
    /// Appended in the page that shows the session. `speak` follows "Speak answers" for typed and
    /// voice-in-page turns.
    case appendInPage(PageKind, speak: Bool)
    /// A typed ask from the text box: the Panel opens and stays.
    case openPanel
    /// A voice turn on the origin window: voice plus Glance (today's path).
    case glance(speak: Bool)
    /// The user moved on: a ready-unread tile, a banner only when they're away and it ran ≥ 30 s.
    /// No card, no speech.
    case ambient(notify: NotifyKind?)
    /// The error state. `ambient`: shown as a rose tile, not on the spot.
    case failure(ambient: Bool)
}

/// Picks exactly one answer surface per finished turn (04 §3.3–§3.4, with the owner's rules).
/// Pure.
public enum SurfaceRouter {
    public static let notifyAfter: TimeInterval = 30

    public static func deliver(_ input: DeliveryInput, settings: DeliverySettings) -> Delivery {
        // 1. A page shows the session: the answer (or the failure) lands there, nothing else opens.
        if let page = input.visiblePages[input.session] {
            return .appendInPage(page, speak: !input.failed && speaks(input.kind, settings))
        }
        let onOrigin = isOnOrigin(input)
        if input.failed { return .failure(ambient: !onOrigin) }
        switch input.kind {
        case .typed, .steer, .relay:
            // A typed ask opens the Panel and it stays, unless the user put it away meanwhile.
            if input.kind == .typed, !input.pageDismissed, input.present, !input.userIsComposingOrHolding {
                return .openPanel
            }
            return ambient(input, settings)
        case .voice, .action, .voiceInPage:
            // 2. On the origin window: deliver on the spot. A voice-in-page turn whose page went
            // away is treated as voice.
            return onOrigin ? .glance(speak: true) : ambient(input, settings)
        }
    }

    /// Typed and voice-in-page answers speak only with "Speak answers" on; voice always does.
    static func speaks(_ kind: TurnKind, _ settings: DeliverySettings) -> Bool {
        switch kind {
        case .voice, .action: true
        case .voiceInPage, .typed, .steer, .relay: settings.speakTypedAnswers
        }
    }

    /// Present, not busy with another ask, and on the window the session started from. With no
    /// window number on either side, the front app is taken as the origin (today's behaviour).
    static func isOnOrigin(_ input: DeliveryInput) -> Bool {
        guard input.present, !input.userIsComposingOrHolding else { return false }
        guard let origin = input.origin?.windowNumber, let front = input.frontWindow else { return true }
        return origin == front
    }

    static func ambient(_ input: DeliveryInput, _ settings: DeliverySettings) -> Delivery {
        let notify = !input.present && settings.notifyWhenAway && input.ranFor >= notifyAfter
        return .ambient(notify: notify ? .banner : nil)
    }
}

/// `AnswerDelivery` through `SurfaceRouter`, for answers that come through the coordinator's
/// Glance path (cascade turns, voice session turns). Behind `LumiFeatures.panel`.
@MainActor public final class RoutedDelivery: AnswerDelivery {
    private let visiblePages: @MainActor () -> [SessionID: PageKind]
    public var settings: () -> DeliverySettings

    /// `visiblePages`: every Lumi page on screen (the Panel and the Studio column).
    public init(visiblePages: @escaping @MainActor () -> [SessionID: PageKind],
                settings: @escaping () -> DeliverySettings = { DeliverySettings() }) {
        self.visiblePages = visiblePages
        self.settings = settings
    }

    public convenience init(pages: any PageSurfaces, settings: @escaping () -> DeliverySettings = { DeliverySettings() }) {
        self.init(visiblePages: { pages.visiblePage.map { [$0.id: $0.kind] } ?? [:] }, settings: settings)
    }

    public func surface(for answer: Answer, conversationID: String, kind: TurnKind) -> AnswerSurface {
        let input = DeliveryInput(session: SessionID(rawValue: conversationID), kind: kind, visiblePages: visiblePages())
        return Self.surface(SurfaceRouter.deliver(input, settings: settings()))
    }

    /// The coordinator just finished the turn in front of the user, so anything not in a page is
    /// the Glance; only an ambient delivery stays off screen.
    nonisolated static func surface(_ d: Delivery) -> AnswerSurface {
        switch d {
        case .appendInPage(let kind, _): .page(kind)
        case .ambient, .failure(ambient: true): .ambient
        case .glance, .openPanel, .failure(ambient: false): .glance
        }
    }
}
