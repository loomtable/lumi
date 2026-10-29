/// Which physical keys mean what while the switcher is armed, for one buddy key (03 §3.4).
///
/// | Buddy key  | Next | Previous            |
/// |------------|------|---------------------|
/// | ⌥, ⌃, fn   | Tab  | ⇧Tab, `             |
/// | ⇧          | Tab  | `                   |
/// | ⌘          | `    | ⇧` (never ⌘Tab)     |
///
/// Plus, for every buddy key: → next, ← previous, 1–9 a tile, Return commit, Space or ↓ peek,
/// ↑ close the peek, N or = new, T teammates, P pin, ⌫ archive, Esc or . cancel. With fn as the
/// buddy key, the keys fn turns arrows and ⌫ into (End, Home, Page Down, Page Up, ⌦) mean the
/// same as the arrows and ⌫.
///
/// Key codes are physical positions (`HIToolbox/Events.h`, ANSI), so N, T and P follow the US
/// layout. Only ⇧ may be added on top of the buddy key, and only for ⇧Tab and ⇧`; any other
/// extra modifier (⌘ with an ⌥ buddy key, say) leaves the key unmapped, so it reaches the app and
/// cancels as today.
public struct SwitcherKeyMap: Sendable, Equatable, Hashable {
    public let buddy: BuddyKey

    public init(buddy: BuddyKey) {
        self.buddy = buddy
    }

    /// The meaning of a key-down with these flags, or nil if the switcher doesn't take it.
    /// `fresh`: the gesture began with the fresh modifier held, which may still be down; it is
    /// then ignored, so a fresh ⌥ + Tab is still "next".
    public func key(keyCode: UInt16, flags: UInt64, fresh: Bool = false) -> SwitcherKey? {
        var extra = flags & ModifierMask.anyModifier & ~buddy.downMask & ~buddy.independentMask
        if fresh { extra &= ~buddy.freshMask }
        // Arrows and the keys fn makes of them carry the fn bit themselves.
        if Self.navigation.contains(keyCode) { extra &= ~ModifierMask.secondaryFn }
        let shifted = extra & Self.shiftBits != 0
        guard extra & ~Self.shiftBits == 0 else { return nil }

        switch keyCode {
        case Code.tab:
            switch buddy {
            case .rightCommand, .leftCommand: return nil  // ⌘Tab stays the app switcher
            case .rightShift, .leftShift: return shifted ? nil : .next
            default: return shifted ? .prev : .next
            }
        case Code.grave, Code.isoSection:
            switch buddy {
            case .rightCommand, .leftCommand: return shifted ? .prev : .next
            default: return shifted ? nil : .prev
            }
        default:
            guard !shifted else { return nil }
            return plain(keyCode)
        }
    }

    /// Keys that open the strip from a plain hold or a tap-mode listen. Other mapped keys count
    /// only once it is open, so ⌥1 or ⌥N still cancel a hold as they do today.
    public static func opens(_ key: SwitcherKey) -> Bool {
        key == .next || key == .prev
    }

    private func plain(_ keyCode: UInt16) -> SwitcherKey? {
        if let n = Self.digits[keyCode] { return .index(n) }
        switch keyCode {
        case Code.right: return .next
        case Code.left: return .prev
        case Code.returnKey, Code.keypadEnter: return .commit
        case Code.space, Code.down: return .peek
        case Code.up: return .unpeek
        case Code.n, Code.equal: return .new
        case Code.t: return .teammates
        case Code.p: return .pin
        case Code.delete: return .archive
        case Code.escape, Code.period: return .cancel
        default: break
        }
        guard buddy == .function else { return nil }
        switch keyCode {
        case Code.end: return .next
        case Code.home: return .prev
        case Code.pageDown: return .peek
        case Code.pageUp: return .unpeek
        case Code.forwardDelete: return .archive
        default: return nil
        }
    }

    static let shiftBits: UInt64 = ModifierMask.shift | ModifierMask.deviceLeftShift | ModifierMask.deviceRightShift
    /// kVK_Shift, kVK_RightShift: tolerated during a hold while the switcher is on, for ⇧Tab.
    public static let shiftKeyCodes: Set<UInt16> = [0x38, 0x3C]

    static let navigation: Set<UInt16> = [
        Code.left, Code.right, Code.up, Code.down,
        Code.home, Code.end, Code.pageUp, Code.pageDown, Code.forwardDelete,
    ]

    /// 1–9 on the main row and the keypad.
    static let digits: [UInt16: Int] = [
        0x12: 1, 0x13: 2, 0x14: 3, 0x15: 4, 0x17: 5, 0x16: 6, 0x1A: 7, 0x1C: 8, 0x19: 9,
        0x53: 1, 0x54: 2, 0x55: 3, 0x56: 4, 0x57: 5, 0x58: 6, 0x59: 7, 0x5B: 8, 0x5C: 9,
    ]

    /// `HIToolbox/Events.h` values; `SwitcherKeyMapTests` checks them against the SDK.
    enum Code {
        static let tab: UInt16 = 0x30            // kVK_Tab
        static let grave: UInt16 = 0x32          // kVK_ANSI_Grave
        static let isoSection: UInt16 = 0x0A     // kVK_ISO_Section (` on some ISO boards)
        static let returnKey: UInt16 = 0x24      // kVK_Return
        static let keypadEnter: UInt16 = 0x4C    // kVK_ANSI_KeypadEnter
        static let space: UInt16 = 0x31          // kVK_Space
        static let delete: UInt16 = 0x33         // kVK_Delete (⌫)
        static let forwardDelete: UInt16 = 0x75  // kVK_ForwardDelete
        static let escape: UInt16 = 0x35         // kVK_Escape
        static let period: UInt16 = 0x2F         // kVK_ANSI_Period
        static let n: UInt16 = 0x2D              // kVK_ANSI_N
        static let equal: UInt16 = 0x18          // kVK_ANSI_Equal
        static let t: UInt16 = 0x11              // kVK_ANSI_T
        static let p: UInt16 = 0x23              // kVK_ANSI_P
        static let left: UInt16 = 0x7B           // kVK_LeftArrow
        static let right: UInt16 = 0x7C          // kVK_RightArrow
        static let down: UInt16 = 0x7D           // kVK_DownArrow
        static let up: UInt16 = 0x7E             // kVK_UpArrow
        static let home: UInt16 = 0x73           // kVK_Home
        static let end: UInt16 = 0x77            // kVK_End
        static let pageUp: UInt16 = 0x74         // kVK_PageUp
        static let pageDown: UInt16 = 0x79       // kVK_PageDown
    }
}
