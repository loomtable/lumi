import Foundation

/// Whether the user is at the Mac (03 §5.3). Present means HID input in the last 120 s, the
/// screen unlocked and the display awake; it comes only from the system idle timer and the
/// lock and sleep notifications. Nothing is read from the screen.
public enum Presence: Sendable, Equatable {
    case present
    case away

    public static let idleAfter: TimeInterval = 120

    public static func of(secondsSinceInput: TimeInterval, locked: Bool, displayAsleep: Bool) -> Presence {
        locked || displayAsleep || secondsSinceInput >= idleAfter ? .away : .present
    }
}

/// Presence over time: reports the moment the user comes back, so Lumi can wake (no catch-up
/// card).
public struct PresenceTracker: Sendable, Equatable {
    public enum Change: Sendable, Equatable { case wentAway, cameBack }

    public private(set) var presence: Presence

    public init(_ presence: Presence = .present) { self.presence = presence }

    public mutating func update(_ new: Presence) -> Change? {
        defer { presence = new }
        switch (presence, new) {
        case (.present, .away): return .wentAway
        case (.away, .present): return .cameBack
        default: return nil
        }
    }
}
