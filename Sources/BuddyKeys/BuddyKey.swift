/// Modifier keys that can serve as the buddy key, with left and right told apart.
///
/// Values are copied from the macOS 26 SDK so this module stays free of Carbon/IOKit imports:
/// - key codes: `HIToolbox/Events.h` (`kVK_RightOption = 0x3D`, ...)
/// - device-dependent flag bits: `IOKit/hidsystem/IOLLEvent.h` (`NX_DEVICERALTKEYMASK = 0x40`, ...)
/// - device-independent flag bits: `IOLLEvent.h` (`NX_ALTERNATEMASK = 0x80000`, ...), which equal
///   the `CGEventFlags` masks (`kCGEventFlagMaskAlternate`, ...).
/// `BuddyKeyTests` asserts these against the real SDK symbols.
public enum BuddyKey: String, Sendable, Hashable, CaseIterable {
    case rightOption, leftOption
    case rightCommand, leftCommand
    case rightShift, leftShift
    case rightControl, leftControl
    case function

    public var keyCode: UInt16 {
        switch self {
        case .rightOption: 0x3D   // 61 kVK_RightOption
        case .leftOption: 0x3A    // 58 kVK_Option
        case .rightCommand: 0x36  // 54 kVK_RightCommand
        case .leftCommand: 0x37   // 55 kVK_Command
        case .rightShift: 0x3C    // 60 kVK_RightShift
        case .leftShift: 0x38     // 56 kVK_Shift
        case .rightControl: 0x3E  // 62 kVK_RightControl
        case .leftControl: 0x3B   // 59 kVK_Control
        case .function: 0x3F      // 63 kVK_Function
        }
    }

    /// The bit in `CGEventFlags.rawValue` that is set while this exact key is down.
    /// Fn has no device-dependent bit, so it uses the device-independent `NX_SECONDARYFNMASK`.
    public var downMask: UInt64 {
        switch self {
        case .rightOption: ModifierMask.deviceRightAlt
        case .leftOption: ModifierMask.deviceLeftAlt
        case .rightCommand: ModifierMask.deviceRightCmd
        case .leftCommand: ModifierMask.deviceLeftCmd
        case .rightShift: ModifierMask.deviceRightShift
        case .leftShift: ModifierMask.deviceLeftShift
        case .rightControl: ModifierMask.deviceRightCtl
        case .leftControl: ModifierMask.deviceLeftCtl
        case .function: ModifierMask.secondaryFn
        }
    }

    /// The device bit of the same modifier on the other side (0 for Fn).
    public var oppositeDownMask: UInt64 {
        switch self {
        case .rightOption: ModifierMask.deviceLeftAlt
        case .leftOption: ModifierMask.deviceRightAlt
        case .rightCommand: ModifierMask.deviceLeftCmd
        case .leftCommand: ModifierMask.deviceRightCmd
        case .rightShift: ModifierMask.deviceLeftShift
        case .leftShift: ModifierMask.deviceRightShift
        case .rightControl: ModifierMask.deviceLeftCtl
        case .leftControl: ModifierMask.deviceRightCtl
        case .function: 0
        }
    }

    /// Whether `flags` show this key down: true or false when the flags say so, nil when they
    /// can't tell. That happens when the shared bit (⌥, ⌘, ⇧, ⌃) is set but neither side's device
    /// bit is: some third-party keyboards, remappers, Universal Control and Screen Sharing send
    /// no device bits.
    public func isDown(in flags: UInt64) -> Bool? {
        if flags & downMask != 0 { return true }
        if flags & independentMask == 0 { return false }
        if flags & oppositeDownMask != 0 { return false }
        return nil
    }

    /// Device-independent bit this key also sets (both sides share it).
    public var independentMask: UInt64 {
        switch self {
        case .rightOption, .leftOption: ModifierMask.alternate
        case .rightCommand, .leftCommand: ModifierMask.command
        case .rightShift, .leftShift: ModifierMask.shift
        case .rightControl, .leftControl: ModifierMask.control
        case .function: ModifierMask.secondaryFn
        }
    }

    /// The key's name in hints ("tap ⌥ to send"). Sides are left out, as on the keycaps.
    public var symbol: String {
        switch self {
        case .rightOption, .leftOption: "⌥"
        case .rightCommand, .leftCommand: "⌘"
        case .rightShift, .leftShift: "⇧"
        case .rightControl, .leftControl: "⌃"
        case .function: "Fn"
        }
    }

    /// Held as this key goes down, the "fresh" modifier starts the gesture in a new
    /// conversation: ⇧, or ⌃ when this key is itself a ⇧. Both sides' device bits and the
    /// shared bit, so a keyboard without device bits still counts.
    public var freshMask: UInt64 {
        switch self {
        case .rightShift, .leftShift:
            ModifierMask.control | ModifierMask.deviceLeftCtl | ModifierMask.deviceRightCtl
        default:
            ModifierMask.shift | ModifierMask.deviceLeftShift | ModifierMask.deviceRightShift
        }
    }

    /// Key codes of the fresh modifier, left and right.
    public var freshKeyCodes: Set<UInt16> {
        switch self {
        case .rightShift, .leftShift: [0x3B, 0x3E]  // kVK_Control, kVK_RightControl
        default: [0x38, 0x3C]                      // kVK_Shift, kVK_RightShift
        }
    }

    /// The fresh modifier's name in hints ("⇧ + ⌥").
    public var freshSymbol: String {
        switch self {
        case .rightShift, .leftShift: "⌃"
        default: "⇧"
        }
    }

    public init?(keyCode: UInt16) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }
}

public enum ModifierMask {
    // Device-independent (IOLLEvent.h, equal to CGEventFlags masks).
    public static let alphaShift: UInt64 = 0x0001_0000   // NX_ALPHASHIFTMASK (Caps Lock)
    public static let shift: UInt64 = 0x0002_0000        // NX_SHIFTMASK
    public static let control: UInt64 = 0x0004_0000      // NX_CONTROLMASK
    public static let alternate: UInt64 = 0x0008_0000    // NX_ALTERNATEMASK
    public static let command: UInt64 = 0x0010_0000      // NX_COMMANDMASK
    public static let numericPad: UInt64 = 0x0020_0000   // NX_NUMERICPADMASK
    public static let help: UInt64 = 0x0040_0000         // NX_HELPMASK
    public static let secondaryFn: UInt64 = 0x0080_0000  // NX_SECONDARYFNMASK

    // Device-dependent (IOLLEvent.h).
    public static let deviceLeftCtl: UInt64 = 0x0000_0001    // NX_DEVICELCTLKEYMASK
    public static let deviceLeftShift: UInt64 = 0x0000_0002  // NX_DEVICELSHIFTKEYMASK
    public static let deviceRightShift: UInt64 = 0x0000_0004 // NX_DEVICERSHIFTKEYMASK
    public static let deviceLeftCmd: UInt64 = 0x0000_0008    // NX_DEVICELCMDKEYMASK
    public static let deviceRightCmd: UInt64 = 0x0000_0010   // NX_DEVICERCMDKEYMASK
    public static let deviceLeftAlt: UInt64 = 0x0000_0020    // NX_DEVICELALTKEYMASK
    public static let deviceRightAlt: UInt64 = 0x0000_0040   // NX_DEVICERALTKEYMASK
    public static let deviceRightCtl: UInt64 = 0x0000_2000   // NX_DEVICERCTLKEYMASK

    /// Every bit that means "some modifier key is physically down".
    /// Caps Lock, numeric pad, help and the non-coalesced bit are deliberately excluded.
    public static let anyModifier: UInt64 =
        shift | control | alternate | command | secondaryFn
        | deviceLeftCtl | deviceLeftShift | deviceRightShift | deviceLeftCmd
        | deviceRightCmd | deviceLeftAlt | deviceRightAlt | deviceRightCtl
}

extension BuddyKey {
    /// True when any modifier other than this key (and the bits in `allowed`) is down. The shared
    /// device-independent bit is ignored; the opposite side (right ⌥ + left ⌥) is still caught by
    /// its own device bit.
    func othersDown(in flags: UInt64, allowing allowed: UInt64 = 0) -> Bool {
        flags & (ModifierMask.anyModifier & ~downMask & ~independentMask & ~allowed) != 0
    }
}
