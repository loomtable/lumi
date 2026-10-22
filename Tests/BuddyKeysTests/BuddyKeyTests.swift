import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import BuddyKeys

@Suite("BuddyKey")
struct BuddyKeyTests {
    static let expectedKeyCodes: [(BuddyKey, UInt16)] = [
        (.rightOption, 61), (.leftOption, 58),
        (.rightCommand, 54), (.leftCommand, 55),
        (.rightShift, 60), (.leftShift, 56),
        (.rightControl, 62), (.leftControl, 59),
        (.function, 63),
    ]

    @Test("keyCode matches the SDK value", arguments: expectedKeyCodes)
    func keyCodeValue(key: BuddyKey, code: UInt16) {
        #expect(key.keyCode == code)
    }

    @Test("keyCode matches the kVK_* constant", arguments: [
        (BuddyKey.rightOption, kVK_RightOption), (.leftOption, kVK_Option),
        (.rightCommand, kVK_RightCommand), (.leftCommand, kVK_Command),
        (.rightShift, kVK_RightShift), (.leftShift, kVK_Shift),
        (.rightControl, kVK_RightControl), (.leftControl, kVK_Control),
        (.function, kVK_Function),
    ])
    func keyCodeMatchesCarbon(key: BuddyKey, vk: Int) {
        #expect(Int(key.keyCode) == vk)
    }

    @Test("init(keyCode:) round-trips every case", arguments: BuddyKey.allCases)
    func initRoundTrip(key: BuddyKey) {
        #expect(BuddyKey(keyCode: key.keyCode) == key)
    }

    @Test("init(keyCode:) rejects non-modifier key codes", arguments: [UInt16(0), 14, 36, 49, 57, 64, 0xFFFF])
    func initRejects(code: UInt16) {
        #expect(BuddyKey(keyCode: code) == nil)
    }

    @Test("key codes are unique")
    func uniqueKeyCodes() {
        #expect(Set(BuddyKey.allCases.map(\.keyCode)).count == BuddyKey.allCases.count)
    }

    @Test("downMask values", arguments: [
        (BuddyKey.rightOption, UInt64(0x40)), (.leftOption, 0x20),
        (.rightCommand, 0x10), (.leftCommand, 0x08),
        (.rightShift, 0x04), (.leftShift, 0x02),
        (.rightControl, 0x2000), (.leftControl, 0x01),
        (.function, 0x80_0000),
    ])
    func downMaskValue(key: BuddyKey, mask: UInt64) {
        #expect(key.downMask == mask)
    }

    @Test("downMask bits are unique")
    func uniqueDownMasks() {
        #expect(Set(BuddyKey.allCases.map(\.downMask)).count == BuddyKey.allCases.count)
    }

    @Test("oppositeDownMask is the other side's downMask", arguments: [
        (BuddyKey.rightOption, BuddyKey.leftOption), (.rightCommand, .leftCommand),
        (.rightShift, .leftShift), (.rightControl, .leftControl),
    ])
    func oppositeMasks(right: BuddyKey, left: BuddyKey) {
        #expect(right.oppositeDownMask == left.downMask)
        #expect(left.oppositeDownMask == right.downMask)
        #expect(BuddyKey.function.oppositeDownMask == 0)
    }

    @Test("independentMask matches the CGEventFlags mask", arguments: [
        (BuddyKey.rightOption, CGEventFlags.maskAlternate), (.leftOption, .maskAlternate),
        (.rightCommand, .maskCommand), (.leftCommand, .maskCommand),
        (.rightShift, .maskShift), (.leftShift, .maskShift),
        (.rightControl, .maskControl), (.leftControl, .maskControl),
        (.function, .maskSecondaryFn),
    ])
    func independentMask(key: BuddyKey, flag: CGEventFlags) {
        #expect(key.independentMask == flag.rawValue)
    }

    @Test("ModifierMask device-independent constants equal CGEventFlags")
    func modifierMaskMatchesCGEventFlags() {
        #expect(ModifierMask.alternate == CGEventFlags.maskAlternate.rawValue)
        #expect(ModifierMask.command == CGEventFlags.maskCommand.rawValue)
        #expect(ModifierMask.shift == CGEventFlags.maskShift.rawValue)
        #expect(ModifierMask.control == CGEventFlags.maskControl.rawValue)
        #expect(ModifierMask.secondaryFn == CGEventFlags.maskSecondaryFn.rawValue)
        #expect(ModifierMask.alphaShift == CGEventFlags.maskAlphaShift.rawValue)
        #expect(ModifierMask.numericPad == CGEventFlags.maskNumericPad.rawValue)
        #expect(ModifierMask.help == CGEventFlags.maskHelp.rawValue)
    }

    @Test("anyModifier excludes Caps Lock, numeric pad, help and the non-coalesced bit")
    func anyModifierExclusions() {
        #expect(ModifierMask.anyModifier & ModifierMask.alphaShift == 0)
        #expect(ModifierMask.anyModifier & ModifierMask.numericPad == 0)
        #expect(ModifierMask.anyModifier & ModifierMask.help == 0)
        #expect(ModifierMask.anyModifier & CGEventFlags.maskNonCoalesced.rawValue == 0)
        for key in BuddyKey.allCases {
            #expect(ModifierMask.anyModifier & key.downMask != 0)
        }
    }

    @Test("othersDown", arguments: BuddyKey.allCases)
    func othersDown(key: BuddyKey) {
        let down = key.downFlags
        #expect(!key.othersDown(in: down))
        #expect(!key.othersDown(in: down | ModifierMask.alphaShift))
        #expect(!key.othersDown(in: key.independentMask))  // shared bit only
        let other = BuddyKey.allCases.first { $0.independentMask != key.independentMask }!
        #expect(key.othersDown(in: down | other.downMask | other.independentMask))
    }

    @Test("opposite side of the same modifier counts as another modifier")
    func oppositeSide() {
        let both = ModifierMask.alternate | ModifierMask.deviceRightAlt | ModifierMask.deviceLeftAlt
        #expect(BuddyKey.rightOption.othersDown(in: both))
        #expect(BuddyKey.leftOption.othersDown(in: both))
    }

    @Test("symbol leaves out the side", arguments: [
        (BuddyKey.rightOption, "⌥"), (.leftOption, "⌥"), (.rightCommand, "⌘"),
        (.leftShift, "⇧"), (.rightControl, "⌃"), (.function, "Fn"),
    ])
    func symbol(key: BuddyKey, expected: String) {
        #expect(key.symbol == expected)
    }
}
