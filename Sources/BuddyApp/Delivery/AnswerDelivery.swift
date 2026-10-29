import BuddyCore
import BuddyOverlay
import Foundation

/// Where a finished answer is shown.
public enum AnswerSurface: Sendable, Equatable {
    /// The overlay's card or chip next to the anchor (today's path).
    case glance
    /// Appended in the Lumi page that shows the conversation; no card (04 §3.4 rule 1).
    case page(PageKind)
    /// The user moved on: no card and no speech; the session's tile goes ready-unread.
    case ambient
}

/// Decides the surface for each finished answer. The coordinator shows it there.
@MainActor public protocol AnswerDelivery: AnyObject {
    func surface(for answer: Answer, conversationID: String, kind: TurnKind) -> AnswerSurface
}

/// Every answer in the Glance, as today.
@MainActor public final class GlanceDelivery: AnswerDelivery {
    public init() {}

    public func surface(for answer: Answer, conversationID: String, kind: TurnKind) -> AnswerSurface { .glance }
}
