import Carbon.HIToolbox
import Testing
@testable import BuddyKeys

@Suite("SwitcherKeyMap")
struct SwitcherKeyMapTests {
    typealias Code = SwitcherKeyMap.Code
    let shift = ModifierMask.shift | ModifierMask.deviceLeftShift

    /// Flags of a real key-down with `buddy` held (plus `extra`).
    func flags(_ buddy: BuddyKey, _ extra: UInt64 = 0) -> UInt64 { buddy.downFlags | extra }

    @Test("key codes match the kVK_* constants", arguments: [
        (Code.tab, kVK_Tab), (Code.grave, kVK_ANSI_Grave), (Code.isoSection, kVK_ISO_Section),
        (Code.returnKey, kVK_Return), (Code.keypadEnter, kVK_ANSI_KeypadEnter), (Code.space, kVK_Space),
        (Code.delete, kVK_Delete), (Code.forwardDelete, kVK_ForwardDelete), (Code.escape, kVK_Escape),
        (Code.period, kVK_ANSI_Period), (Code.n, kVK_ANSI_N), (Code.equal, kVK_ANSI_Equal),
        (Code.t, kVK_ANSI_T), (Code.p, kVK_ANSI_P), (Code.left, kVK_LeftArrow), (Code.right, kVK_RightArrow),
        (Code.down, kVK_DownArrow), (Code.up, kVK_UpArrow), (Code.home, kVK_Home), (Code.end, kVK_End),
        (Code.pageUp, kVK_PageUp), (Code.pageDown, kVK_PageDown),
    ])
    func codes(code: UInt16, vk: Int) {
        #expect(Int(code) == vk)
    }

    @Test("digit codes match kVK_ANSI_1…9 and the keypad")
    func digitCodes() {
        let row = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let pad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                   kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        for (i, vk) in (row + pad).enumerated() {
            #expect(SwitcherKeyMap.digits[UInt16(vk)] == i % 9 + 1)
        }
        #expect(SwitcherKeyMap.shiftKeyCodes == [UInt16(kVK_Shift), UInt16(kVK_RightShift)])
    }

    // MARK: - Next and previous per buddy key (03 §3.4)

    @Test("⌥, ⌃, fn: Tab next, ⇧Tab and ` previous", arguments: [
        BuddyKey.rightOption, .leftOption, .rightControl, .leftControl, .function,
    ])
    func optionLike(buddy: BuddyKey) {
        let map = SwitcherKeyMap(buddy: buddy)
        #expect(map.key(keyCode: Code.tab, flags: flags(buddy)) == .next)
        #expect(map.key(keyCode: Code.tab, flags: flags(buddy, shift)) == .prev)
        #expect(map.key(keyCode: Code.grave, flags: flags(buddy)) == .prev)
        #expect(map.key(keyCode: Code.grave, flags: flags(buddy, shift)) == nil)  // ~
    }

    @Test("⇧: Tab next, ` previous", arguments: [BuddyKey.rightShift, .leftShift])
    func shiftBuddy(buddy: BuddyKey) {
        let map = SwitcherKeyMap(buddy: buddy)
        #expect(map.key(keyCode: Code.tab, flags: flags(buddy)) == .next)
        #expect(map.key(keyCode: Code.grave, flags: flags(buddy)) == .prev)
        // Letters and digits still map: the buddy ⇧ is not an extra modifier.
        #expect(map.key(keyCode: Code.n, flags: flags(buddy)) == .new)
        #expect(map.key(keyCode: 0x12, flags: flags(buddy)) == .index(1))
    }

    @Test("⌘: ` next, ⇧` previous, never ⌘Tab", arguments: [BuddyKey.rightCommand, .leftCommand])
    func commandBuddy(buddy: BuddyKey) {
        let map = SwitcherKeyMap(buddy: buddy)
        #expect(map.key(keyCode: Code.grave, flags: flags(buddy)) == .next)
        #expect(map.key(keyCode: Code.grave, flags: flags(buddy, shift)) == .prev)
        #expect(map.key(keyCode: Code.tab, flags: flags(buddy)) == nil)
        #expect(map.key(keyCode: Code.tab, flags: flags(buddy, shift)) == nil)
    }

    @Test("the shared keys", arguments: BuddyKey.allCases)
    func shared(buddy: BuddyKey) {
        let map = SwitcherKeyMap(buddy: buddy)
        let f = flags(buddy)
        let table: [(UInt16, SwitcherKey)] = [
            (Code.right, .next), (Code.left, .prev), (0x12, .index(1)), (0x19, .index(9)), (0x5C, .index(9)),
            (Code.returnKey, .commit), (Code.keypadEnter, .commit), (Code.space, .peek), (Code.down, .peek),
            (Code.up, .unpeek), (Code.n, .new), (Code.equal, .new), (Code.t, .teammates), (Code.p, .pin),
            (Code.delete, .archive), (Code.escape, .cancel), (Code.period, .cancel),
        ]
        for (code, key) in table {
            #expect(map.key(keyCode: code, flags: f) == key, "code \(code)")
        }
        #expect(map.key(keyCode: 0x1D, flags: f) == nil)  // 0
        #expect(map.key(keyCode: 0x0E, flags: f) == nil)  // E
        #expect(map.key(keyCode: 0x0C, flags: f) == nil)  // Q: dropped (stop lives in peek)
    }

    @Test("arrows carry the fn bit and still map")
    func arrowsWithFnBit() {
        let map = SwitcherKeyMap(buddy: .rightOption)
        let arrow = flags(.rightOption, ModifierMask.secondaryFn | ModifierMask.numericPad)
        #expect(map.key(keyCode: Code.right, flags: arrow) == .next)
        #expect(map.key(keyCode: Code.down, flags: arrow) == .peek)
        // …but the fn bit on a letter is a real extra modifier.
        #expect(map.key(keyCode: Code.n, flags: flags(.rightOption, ModifierMask.secondaryFn)) == nil)
    }

    @Test("fn buddy: the keys fn makes of arrows and ⌫")
    func fnNavigation() {
        let map = SwitcherKeyMap(buddy: .function)
        let f = flags(.function)
        #expect(map.key(keyCode: Code.end, flags: f) == .next)
        #expect(map.key(keyCode: Code.home, flags: f) == .prev)
        #expect(map.key(keyCode: Code.pageDown, flags: f) == .peek)
        #expect(map.key(keyCode: Code.pageUp, flags: f) == .unpeek)
        #expect(map.key(keyCode: Code.forwardDelete, flags: f) == .archive)
        #expect(SwitcherKeyMap(buddy: .rightOption).key(keyCode: Code.end, flags: flags(.rightOption)) == nil)
    }

    @Test("an extra modifier other than ⇧ leaves every key unmapped")
    func extraModifier() {
        let map = SwitcherKeyMap(buddy: .rightOption)
        let cmd = ModifierMask.command | ModifierMask.deviceLeftCmd
        let ctl = ModifierMask.control | ModifierMask.deviceLeftCtl
        let leftOption = ModifierMask.deviceLeftAlt
        for extra in [cmd, ctl, leftOption] {
            #expect(map.key(keyCode: Code.tab, flags: flags(.rightOption, extra)) == nil)
            #expect(map.key(keyCode: Code.returnKey, flags: flags(.rightOption, extra)) == nil)
        }
        // ⇧ only counts on Tab and `: ⇧Return, ⇧1 pass.
        #expect(map.key(keyCode: Code.returnKey, flags: flags(.rightOption, shift)) == nil)
        #expect(map.key(keyCode: 0x12, flags: flags(.rightOption, shift)) == nil)
    }

    @Test("a fresh gesture's ⇧ is ignored: fresh ⌥ + Tab is still next")
    func freshShift() {
        let map = SwitcherKeyMap(buddy: .rightOption)
        #expect(map.key(keyCode: Code.tab, flags: flags(.rightOption, shift), fresh: true) == .next)
        #expect(map.key(keyCode: Code.n, flags: flags(.rightOption, shift), fresh: true) == .new)
        // A ⇧ buddy's fresh modifier is ⌃.
        let ctl = ModifierMask.control | ModifierMask.deviceLeftCtl
        let shiftMap = SwitcherKeyMap(buddy: .rightShift)
        #expect(shiftMap.key(keyCode: Code.tab, flags: flags(.rightShift, ctl), fresh: true) == .next)
        #expect(shiftMap.key(keyCode: Code.tab, flags: flags(.rightShift, ctl)) == nil)
    }

    @Test("only next and previous open the strip")
    func openers() {
        #expect(SwitcherKeyMap.opens(.next))
        #expect(SwitcherKeyMap.opens(.prev))
        for key: SwitcherKey in [.index(1), .commit, .cancel, .peek, .unpeek, .new, .teammates, .pin, .archive] {
            #expect(!SwitcherKeyMap.opens(key))
        }
    }
}
