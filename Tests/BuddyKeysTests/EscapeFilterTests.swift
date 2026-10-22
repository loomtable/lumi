import Testing
@testable import BuddyKeys

@Suite("EscapeFilter")
struct EscapeFilterTests {
    let esc = EscapeFilter.escapeKeyCode

    @Test("Esc key code is kVK_Escape")
    func keyCode() {
        #expect(EscapeFilter.escapeKeyCode == 53)
    }

    @Test("plain Esc down is consumed and reported; its up is consumed")
    func plainEsc() {
        var f = EscapeFilter()
        #expect(!f.awaitingKeyUp)
        let down = f.consume(.keyDown, keyCode: esc, flags: 0)
        #expect(down.consume)
        #expect(down.isEscape)
        #expect(f.awaitingKeyUp)
        let up = f.consume(.keyUp, keyCode: esc, flags: 0)
        #expect(up.consume)
        #expect(!up.isEscape)
        #expect(!f.awaitingKeyUp)
    }

    @Test("plain Esc with the non-coalesced bit (real events) is consumed")
    func nonCoalescedBit() {
        var f = EscapeFilter()
        #expect(f.consume(.keyDown, keyCode: esc, flags: nonCoalesced) == (true, true))
        #expect(f.consume(.keyUp, keyCode: esc, flags: nonCoalesced) == (true, false))
    }

    enum Modifier: String, CaseIterable, CustomTestStringConvertible {
        case command, option, control, shift, fn
        var testDescription: String { rawValue }
        var flags: UInt64 {
            switch self {
            case .command: ModifierMask.command | ModifierMask.deviceLeftCmd
            case .option: ModifierMask.alternate | ModifierMask.deviceLeftAlt
            case .control: ModifierMask.control | ModifierMask.deviceLeftCtl
            case .shift: ModifierMask.shift | ModifierMask.deviceLeftShift
            case .fn: ModifierMask.secondaryFn
            }
        }
    }

    @Test("Esc with a modifier passes, down and up", arguments: Modifier.allCases)
    func modifiedEscPasses(modifier: Modifier) {
        var f = EscapeFilter()
        #expect(f.consume(.keyDown, keyCode: esc, flags: modifier.flags) == (false, false))
        #expect(!f.awaitingKeyUp)
        #expect(f.consume(.keyUp, keyCode: esc, flags: modifier.flags) == (false, false))
    }

    @Test("⌘⌥Esc (Force Quit) passes")
    func forceQuit() {
        var f = EscapeFilter()
        let flags = Modifier.command.flags | Modifier.option.flags
        #expect(f.consume(.keyDown, keyCode: esc, flags: flags) == (false, false))
        #expect(f.consume(.keyUp, keyCode: esc, flags: flags) == (false, false))
    }

    @Test("⌘ down, Esc down passes, ⌘ up, Esc up is not consumed (no unpaired up)")
    func noPairingAfterModifierReleased() {
        var f = EscapeFilter()
        #expect(f.consume(.keyDown, keyCode: esc, flags: Modifier.command.flags) == (false, false))
        // ⌘ released before Esc: the key-up arrives with no modifiers.
        #expect(f.consume(.keyUp, keyCode: esc, flags: 0) == (false, false))
        #expect(!f.awaitingKeyUp)
    }

    @Test("non-Esc keys are never consumed", arguments: [UInt16(0), 36, 48, 49, 14, 122])
    func otherKeysPass(code: UInt16) {
        var f = EscapeFilter()
        for flags in [UInt64(0), Modifier.command.flags, ModifierMask.alphaShift] {
            #expect(f.consume(.keyDown, keyCode: code, flags: flags) == (false, false))
            #expect(f.consume(.keyUp, keyCode: code, flags: flags) == (false, false))
        }
        #expect(!f.awaitingKeyUp)
    }

    @Test("a non-Esc key-up does not end a pending Esc")
    func otherKeyUpKeepsPending() {
        var f = EscapeFilter()
        _ = f.consume(.keyDown, keyCode: esc, flags: 0)
        #expect(f.consume(.keyUp, keyCode: 0, flags: 0) == (false, false))
        #expect(f.awaitingKeyUp)
        #expect(f.consume(.keyUp, keyCode: esc, flags: 0) == (true, false))
    }

    @Test("Caps Lock on: plain Esc still consumed")
    func capsLock() {
        var f = EscapeFilter()
        #expect(f.consume(.keyDown, keyCode: esc, flags: ModifierMask.alphaShift) == (true, true))
        #expect(f.consume(.keyUp, keyCode: esc, flags: ModifierMask.alphaShift) == (true, false))
    }

    @Test("stray Esc up with nothing pending passes")
    func strayUp() {
        var f = EscapeFilter()
        #expect(f.consume(.keyUp, keyCode: esc, flags: 0) == (false, false))
    }

    @Test("draining: a new Esc down is not consumed")
    func drainingNewDown() {
        var f = EscapeFilter()
        #expect(f.consume(.keyDown, keyCode: esc, flags: 0, draining: true) == (false, false))
        #expect(!f.awaitingKeyUp)
        #expect(f.consume(.keyUp, keyCode: esc, flags: 0, draining: true) == (false, false))
    }

    @Test("draining: the pending Esc up is still consumed and awaitingKeyUp clears")
    func drainingPendingUp() {
        var f = EscapeFilter()
        #expect(f.consume(.keyDown, keyCode: esc, flags: 0) == (true, true))
        #expect(f.awaitingKeyUp)
        #expect(f.consume(.keyUp, keyCode: esc, flags: 0, draining: true) == (true, false))
        #expect(!f.awaitingKeyUp)
    }

    @Test("draining: autorepeat Esc down while the up is pending is not consumed")
    func drainingRepeatDown() {
        var f = EscapeFilter()
        _ = f.consume(.keyDown, keyCode: esc, flags: 0)
        #expect(f.consume(.keyDown, keyCode: esc, flags: 0, draining: true) == (false, false))
        #expect(f.awaitingKeyUp)
        #expect(f.consume(.keyUp, keyCode: esc, flags: 0, draining: true) == (true, false))
    }
}

@Suite("EscapeFilter autorepeat")
struct EscapeFilterAutorepeatTests {
    @Test("repeats of a consumed Esc are consumed without a new press, also while draining")
    func repeats() {
        var f = EscapeFilter()
        #expect(f.consume(.keyDown, keyCode: 0x35, flags: 0) == (true, true))
        #expect(f.consume(.keyDown, keyCode: 0x35, flags: 0, isRepeat: true) == (true, false))
        #expect(f.consume(.keyDown, keyCode: 0x35, flags: 0, isRepeat: true, draining: true) == (true, false))
        #expect(f.consume(.keyUp, keyCode: 0x35, flags: 0, draining: true) == (true, false))
        #expect(!f.awaitingKeyUp)
    }

    @Test("repeats of an Esc we did not consume pass through")
    func repeatsOfPassedEsc() {
        var f = EscapeFilter()
        #expect(f.consume(.keyDown, keyCode: 0x35, flags: 0x100000 | 0x8) == (false, false))
        #expect(f.consume(.keyDown, keyCode: 0x35, flags: 0, isRepeat: true) == (false, false))
    }
}
