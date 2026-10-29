/// Decides which key events the switcher tap consumes, and pairs every consumed key-down with
/// its key-up, so no app ever sees half a key press (the `EscapeFilter` rule, for several keys).
///
/// Armed with `openers` only Tab/` (and → ←) are taken: a plain hold or a tap-mode listen.
/// Armed `open`, the whole `SwitcherKeyMap` is taken: the strip is showing.
public struct SwitcherFilter: Sendable, Equatable {
    public enum Kind: Sendable { case keyDown, keyUp }

    public struct Arming: Sendable, Equatable {
        public var map: SwitcherKeyMap
        /// The gesture began with the fresh modifier, which is ignored for mapping.
        public var fresh: Bool
        /// The strip is open: every mapped key counts, not just the openers.
        public var open: Bool

        public init(map: SwitcherKeyMap, fresh: Bool = false, open: Bool = false) {
            self.map = map
            self.fresh = fresh
            self.open = open
        }
    }

    public struct Decision: Sendable, Equatable {
        public var consume: Bool
        /// What the consumed key-down means; nil for key-ups and for silent autorepeats.
        public var key: SwitcherKey?

        public static let pass = Decision(consume: false, key: nil)
    }

    /// nil: disarmed; nothing new is taken, pending key-ups still are.
    public var arming: Arming?
    /// Key codes whose key-down was consumed and whose key-up hasn't come yet.
    public private(set) var held: Set<UInt16> = []

    public init(arming: Arming? = nil) {
        self.arming = arming
    }

    /// A consumed key-down is still waiting for its key-up.
    public var awaitingKeyUp: Bool { !held.isEmpty }

    /// What `keyCode` with `flags` means under the current arming, or nil if it passes.
    public func lookup(keyCode: UInt16, flags: UInt64) -> SwitcherKey? {
        guard let arming,
              let key = arming.map.key(keyCode: keyCode, flags: flags, fresh: arming.fresh),
              arming.open || SwitcherKeyMap.opens(key)
        else { return nil }
        return key
    }

    public mutating func consume(_ kind: Kind, keyCode: UInt16, flags: UInt64, isRepeat: Bool = false) -> Decision {
        switch kind {
        case .keyUp:
            return held.remove(keyCode) == nil ? .pass : Decision(consume: true, key: nil)
        case .keyDown where held.contains(keyCode):
            // Autorepeat of a consumed key (or a key-down whose key-up was lost): still ours.
            // Holding Tab or an arrow keeps moving; other keys repeat silently.
            guard isRepeat, let key = lookup(keyCode: keyCode, flags: flags),
                  key == .next || key == .prev
            else { return Decision(consume: true, key: nil) }
            return Decision(consume: true, key: key)
        case .keyDown:
            // A repeat of a key-down that passed (pressed before arming) keeps passing.
            guard !isRepeat, let key = lookup(keyCode: keyCode, flags: flags) else { return .pass }
            held.insert(keyCode)
            return Decision(consume: true, key: key)
        }
    }

    /// For the listen-only tap: drop this key-down because the switcher tap takes it (or already
    /// took its press), so the gesture never sees it twice or as a stray key.
    public func drops(keyCode: UInt16, flags: UInt64) -> Bool {
        held.contains(keyCode) || lookup(keyCode: keyCode, flags: flags) != nil
    }
}
