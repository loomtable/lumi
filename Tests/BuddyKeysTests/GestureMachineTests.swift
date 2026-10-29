import Testing
@testable import BuddyKeys

/// The hold deadline for a press that went down at `t` ms: strictly more than 300 ms.
func holdDeadline(_ t: UInt64) -> Nanos { ms(t) + ms(300) + 1 }

// MARK: - Tap

@Suite("Tap")
struct TapTests {
    @Test("down/up quickly then window expiry gives exactly one tap", arguments: BuddyKey.allCases)
    func tap(key: BuddyKey) {
        var d = Driver(key)
        #expect(d.deadline == nil)
        #expect(d.down(at: 0) == [.pressBegan(fresh: false)])
        #expect(d.state == .firstDown(since: ms(0)))
        #expect(d.deadline == holdDeadline(0))
        #expect(d.advance(to: 50) == [])
        #expect(d.up(at: 80) == [])
        #expect(d.state == .awaitingSecond(until: ms(380)))
        #expect(d.deadline == ms(380))
        #expect(d.advance(to: 379) == [])
        #expect(d.advance(to: 380) == [.tap])
        #expect(d.state == .idle)
        #expect(d.deadline == nil)
        #expect(d.events == [.pressBegan(fresh: false), .tap])
    }

    @Test("an early tick before the window ends does nothing")
    func earlyTick() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 100)
        #expect(d.tick(at: 399) == [])
        #expect(d.tick(at: 400) == [.tap])
    }

    @Test("double-tap disabled: tap on release, second quick press is another tap",
          arguments: BuddyKey.allCases)
    func doubleTapDisabled(key: BuddyKey) {
        var d = Driver(key, doubleTap: false)
        #expect(d.down(at: 0) == [.pressBegan(fresh: false)])
        #expect(d.up(at: 80) == [.tap])
        #expect(d.state == .idle)
        #expect(d.deadline == nil)
        #expect(d.down(at: 120) == [.pressBegan(fresh: false)])
        #expect(d.up(at: 180) == [.tap])
        d.advance(to: 2000)
        #expect(d.events == [.pressBegan(fresh: false), .tap, .pressBegan(fresh: false), .tap])
        #expect(!d.events.contains(.doubleTap))
    }

    @Test("double-tap disabled: hold still works")
    func doubleTapDisabledHold() {
        var d = Driver(doubleTap: false)
        d.down(at: 0)
        #expect(d.advance(to: 300) == [])
        #expect(d.advance(to: 301) == [.holdBegan])
        #expect(d.up(at: 900) == [.holdEnded])
    }
}

// MARK: - Hold

@Suite("Hold")
struct HoldTests {
    @Test("tick past the threshold begins hold, release ends it", arguments: BuddyKey.allCases)
    func hold(key: BuddyKey) {
        var d = Driver(key)
        d.down(at: 0)
        #expect(d.advance(to: 299) == [])
        #expect(d.advance(to: 300) == [])
        #expect(d.advance(to: 301) == [.holdBegan])
        #expect(d.state.isHolding)
        #expect(d.deadline != nil)  // release poll
        #expect(d.advance(to: 5000) == [])  // repeating polls with no flags keep holding
        #expect(d.state.isHolding)
        #expect(d.up(at: 5000) == [.holdEnded])
        #expect(d.state == .idle)
        #expect(d.events == [.pressBegan(fresh: false), .holdBegan, .holdEnded])
    }

    @Test("hold deadline for firstDown is since + 300 ms + 1 ns")
    func firstDownDeadline() {
        var d = Driver()
        d.down(at: 1000)
        #expect(d.deadline == ms(1300) + 1)
        #expect(d.tick(atNanos: ms(1300)) == [])
        #expect(d.tick(atNanos: ms(1300) + 1) == [.holdBegan])
    }

    @Test("release at 299 ms is a tap")
    func release299IsTap() {
        var d = Driver()
        d.down(at: 0)
        #expect(d.up(at: 299) == [])
        #expect(d.advance(to: 599) == [.tap])
    }

    @Test("release at exactly 300 ms without a tick is a tap")
    func release300NoTick() {
        var d = Driver()
        d.down(at: 0)
        #expect(d.up(at: 300) == [])
        #expect(d.state == .awaitingSecond(until: ms(600)))
        #expect(d.advance(to: 600) == [.tap])
        #expect(d.events == [.pressBegan(fresh: false), .tap])
    }

    @Test("release at exactly 300 ms after a tick at 300 ms is a tap")
    func release300WithTick() {
        var d = Driver()
        d.down(at: 0)
        #expect(d.tick(at: 300, flags: d.key.downFlags) == [])
        #expect(d.state == .firstDown(since: 0))
        #expect(d.up(at: 300) == [])
        #expect(d.advance(to: 600) == [.tap])
        #expect(d.events == [.pressBegan(fresh: false), .tap])
    }

    @Test("release at 301 ms without tick (late tick) is a hold")
    func release301NoTick() {
        var d = Driver()
        d.down(at: 0)
        #expect(d.up(at: 301) == [.holdBegan, .holdEnded])
        #expect(d.state == .idle)
        #expect(d.deadline == nil)
    }

    @Test("release at 301 ms with tick is a hold")
    func release301WithTick() {
        var d = Driver()
        d.down(at: 0)
        #expect(d.advance(to: 301) == [.holdBegan])
        #expect(d.up(at: 301) == [.holdEnded])
    }

    @Test("second buddy down while holding means the release was lost: send, then a new press")
    func downWhileHolding() {
        var d = Driver()
        d.down(at: 0)
        d.advance(to: 301)
        #expect(d.down(at: 400) == [.holdEnded, .pressBegan(fresh: false)])
        #expect(d.up(at: 450) == [])
        #expect(d.advance(to: 750) == [.tap])
    }
}

// MARK: - Double tap

@Suite("Double tap")
struct DoubleTapTests {
    @Test("second clean tap inside the window is a double-tap", arguments: BuddyKey.allCases)
    func doubleTap(key: BuddyKey) {
        var d = Driver(key)
        d.down(at: 0)
        d.up(at: 80)
        #expect(d.advance(to: 200) == [])
        #expect(d.down(at: 200) == [])
        #expect(d.state == .secondDown(since: ms(200)))
        #expect(d.deadline == holdDeadline(200))
        #expect(d.up(at: 260) == [.doubleTap])
        #expect(d.state == .cooldown(until: ms(560)))
        #expect(d.advance(to: 2000) == [])
        #expect(d.state == .idle)
        #expect(d.events == [.pressBegan(fresh: false), .doubleTap])
    }

    @Test("second down just inside the window is a double-tap; at the window end it is a new press")
    func secondDownAtWindowEdge() {
        var inside = Driver()
        inside.down(at: 0)
        inside.up(at: 100)     // window until 400
        #expect(inside.down(at: 399) == [])
        #expect(inside.up(at: 450) == [.doubleTap])

        var atEnd = Driver()
        atEnd.down(at: 0)
        atEnd.up(at: 100)
        #expect(atEnd.down(at: 400) == [.tap, .pressBegan(fresh: false)])
    }

    @Test("second down after the window (tick delivered) gives tap then a new press")
    func secondDownAfterWindowTick() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 100)
        #expect(d.advance(to: 400) == [.tap])
        #expect(d.down(at: 450) == [.pressBegan(fresh: false)])
        #expect(d.up(at: 500) == [])
        #expect(d.advance(to: 800) == [.tap])
        #expect(d.events == [.pressBegan(fresh: false), .tap, .pressBegan(fresh: false), .tap])
    }

    @Test("second down after the window with a late tick settles the tap first")
    func secondDownAfterWindowLateTick() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 100)
        #expect(d.down(at: 401) == [.tap, .pressBegan(fresh: false)])
        #expect(d.state == .firstDown(since: ms(401)))
        // the stale tick arrives now: not yet a hold
        #expect(d.tick(at: 402) == [])
        #expect(d.up(at: 450) == [])
        #expect(d.advance(to: 750) == [.tap])
    }

    @Test("late tick path with another modifier held: tap settles, new press suppressed")
    func lateTickNotAlone() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 100)
        #expect(d.down(at: 500, extraFlags: ModifierMask.command | ModifierMask.deviceLeftCmd) == [.tap])
        #expect(d.state.isSuppressed)
        #expect(d.up(at: 600) == [])
        #expect(d.state == .idle)
    }

    @Test("second press held past the threshold inside the window is a hold")
    func secondPressHeldIsHold() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 100)
        d.down(at: 200)
        #expect(d.advance(to: 499) == [])
        #expect(d.advance(to: 500) == [])  // exactly 300 ms: not yet
        #expect(d.advance(to: 501) == [.holdBegan])
        #expect(d.state.isHolding)
        #expect(d.deadline != nil)  // release poll
        #expect(d.up(at: 900) == [.holdEnded])
        #expect(d.state == .idle)
        #expect(d.events == [.pressBegan(fresh: false), .holdBegan, .holdEnded])
    }

    @Test("second press held past the threshold, late tick: hold settled on release")
    func secondPressHeldLateTick() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 100)
        d.down(at: 200)
        #expect(d.up(at: 501) == [.holdBegan, .holdEnded])
        #expect(d.state == .idle)
        #expect(d.events == [.pressBegan(fresh: false), .holdBegan, .holdEnded])
    }

    @Test("second press released at exactly 300 ms is a double-tap")
    func secondPressExactThreshold() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 100)
        d.down(at: 200)
        #expect(d.up(at: 500) == [.doubleTap])
    }

    @Test("second press up at its deadline (release queued behind the timer) is a double-tap")
    func secondPressReleasedFlags() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 100)
        d.down(at: 200)
        #expect(d.advance(to: 501, flags: upFlags) == [.doubleTap])
        #expect(d.state == .cooldown(until: ms(800)))
        #expect(d.up(at: 501) == [])  // the queued release, now ignored
        #expect(d.advance(to: 2000) == [])
        #expect(d.state == .idle)
    }

    @Test("second down with another modifier held cancels")
    func secondDownNotAlone() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 100)
        #expect(d.down(at: 200, extraFlags: ModifierMask.shift | ModifierMask.deviceLeftShift)
                == [.cancelled(.otherModifier)])
        #expect(d.up(at: 250) == [])
        #expect(d.state == .idle)
    }

    @Test("interruption during secondDown cancels, release emits nothing")
    func interruptSecondDown() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 100)
        d.down(at: 200)
        #expect(d.key(kVKE, at: 220) == [.cancelled(.otherKey(kVKE))])
        #expect(d.up(at: 260) == [])
        #expect(d.state == .idle)
    }

    @Test("second press queued behind the window timer: key down at the window end is a second press")
    func secondPressQueuedBehindWindow() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 100)  // window until 400
        #expect(d.tick(at: 400, flags: d.key.downFlags) == [])
        #expect(d.state == .secondDown(since: ms(400)))
        #expect(d.down(at: 399) == [])  // the queued down event is ignored
        #expect(d.state == .secondDown(since: ms(400)))
        #expect(d.up(at: 450) == [.doubleTap])
        #expect(d.events == [.pressBegan(fresh: false), .doubleTap])
    }

    @Test("second press queued behind the window timer with another modifier down cancels")
    func secondPressQueuedNotAlone() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 100)
        let flags = d.key.downFlags | ModifierMask.command | ModifierMask.deviceLeftCmd
        #expect(d.tick(at: 400, flags: flags) == [.cancelled(.otherModifier)])
        #expect(d.state.isSuppressed)
        #expect(d.up(at: 450) == [])
        #expect(d.state == .idle)
        #expect(!d.events.contains(.tap))
    }
}

// MARK: - Cooldown

@Suite("Cooldown after double-tap")
struct CooldownTests {
    /// Double-tap ending at 260 ms: cooldown until 560 ms.
    func afterDoubleTap() -> Driver {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 80)
        d.down(at: 200)
        d.up(at: 260)
        return d
    }

    @Test("a press inside the cooldown is ignored until its release")
    func pressInCooldownSuppressed() {
        var d = afterDoubleTap()
        #expect(d.state == .cooldown(until: ms(560)))
        #expect(d.down(at: 300) == [])
        #expect(d.state == .cooldown(until: ms(560)))  // the window keeps its deadline
        // Still held at the window end: suppressed, and polls keep it so.
        #expect(d.advance(to: 1000, flags: d.key.downFlags) == [])
        #expect(d.state.isSuppressed)
        #expect(d.up(at: 1000) == [])
        #expect(d.state == .idle)
        #expect(d.events == [.pressBegan(fresh: false), .doubleTap])
    }

    @Test("a quick press inside the cooldown produces nothing, even after the window")
    func quickPressInCooldown() {
        var d = afterDoubleTap()
        #expect(d.down(at: 300) == [])
        #expect(d.up(at: 350) == [])
        #expect(d.advance(to: 2000) == [])
        #expect(d.events == [.pressBegan(fresh: false), .doubleTap])
    }

    @Test("a second press in the same cooldown window is also ignored")
    func secondPressInSameCooldown() {
        var d = afterDoubleTap()
        d.down(at: 300)
        d.up(at: 350)
        #expect(d.down(at: 400) == [])
        #expect(d.up(at: 450) == [])
        #expect(d.advance(to: 2000) == [])
        #expect(d.events == [.pressBegan(fresh: false), .doubleTap])
    }

    @Test("interruptions during the cooldown are ignored")
    func interruptInCooldown() {
        var d = afterDoubleTap()
        #expect(d.key(kVKE, at: 300) == [])
        #expect(d.click(at: 310) == [])
        #expect(d.state == .cooldown(until: ms(560)))
    }

    @Test("after the window, presses work again (timer delivered)")
    func pressAfterCooldownTick() {
        var d = afterDoubleTap()
        #expect(d.advance(to: 560) == [])
        #expect(d.state == .idle)
        #expect(d.down(at: 600) == [.pressBegan(fresh: false)])
        #expect(d.up(at: 650) == [])
        #expect(d.advance(to: 950) == [.tap])
    }

    @Test("after the window, presses work again (late timer settled by the press)")
    func pressAfterCooldownLateTick() {
        var d = afterDoubleTap()
        #expect(d.down(at: 560) == [.pressBegan(fresh: false)])
        #expect(d.state == .firstDown(since: ms(560)))
    }

    @Test("key still down at the cooldown end stays suppressed until release")
    func keyDownAtCooldownEnd() {
        var d = afterDoubleTap()
        #expect(d.tick(at: 560, flags: d.key.downFlags) == [])
        #expect(d.state.isSuppressed)
        #expect(d.up(at: 700) == [])
        #expect(d.state == .idle)
        #expect(d.down(at: 800) == [.pressBegan(fresh: false)])
    }
}

// MARK: - Cancel

@Suite("Cancel")
struct CancelTests {
    enum Interruption: String, CaseIterable, CustomTestStringConvertible {
        case keyDown, otherModifier, click, scroll, tapInterrupted
        var testDescription: String { rawValue }

        var reason: CancelReason {
            switch self {
            case .keyDown: .otherKey(kVKE)
            case .otherModifier: .otherModifier
            case .click: .mouseDown
            case .scroll: .scroll
            case .tapInterrupted: .tapInterrupted
            }
        }

        func apply(_ d: inout Driver, at t: UInt64) -> [GestureEvent] {
            switch self {
            case .keyDown: d.key(kVKE, at: t)
            case .otherModifier:
                // Left shift down while buddy (right ⌥) is held.
                d.modifier(kVKShift, flags: d.key.downFlags | ModifierMask.shift | ModifierMask.deviceLeftShift, at: t)
            case .click: d.click(at: t)
            case .scroll: d.scroll(at: t)
            case .tapInterrupted: d.interrupted(at: t)
            }
        }
    }

    @Test("interruption during firstDown cancels; release silent; next press normal",
          arguments: Interruption.allCases)
    func cancelFirstDown(i: Interruption) {
        var d = Driver()
        #expect(d.down(at: 0) == [.pressBegan(fresh: false)])
        #expect(i.apply(&d, at: 50) == [.cancelled(i.reason)])
        #expect(d.state.isSuppressed)
        #expect(d.deadline != nil)  // release poll
        #expect(d.advance(to: 1000) == [])
        #expect(d.up(at: 1000) == [])
        #expect(d.state == .idle)
        // next gesture works normally
        #expect(d.down(at: 1100) == [.pressBegan(fresh: false)])
        #expect(d.up(at: 1150) == [])
        #expect(d.advance(to: 1450) == [.tap])
    }

    @Test("interruption during hold discards; release silent", arguments: Interruption.allCases)
    func discardHold(i: Interruption) {
        var d = Driver()
        d.down(at: 0)
        #expect(d.advance(to: 301) == [.holdBegan])
        #expect(i.apply(&d, at: 500) == [.holdDiscarded(i.reason)])
        #expect(d.state.isSuppressed)
        #expect(d.up(at: 800) == [])
        #expect(d.state == .idle)
        #expect(d.down(at: 900) == [.pressBegan(fresh: false)])
    }

    @Test("interruption during awaitingSecond cancels the pending tap", arguments: Interruption.allCases)
    func cancelAwaiting(i: Interruption) {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 80)
        let other: [GestureEvent]
        if i == .otherModifier {
            other = d.modifier(kVKShift, flags: ModifierMask.shift | ModifierMask.deviceLeftShift | nonCoalesced, at: 150)
        } else {
            other = i.apply(&d, at: 150)
        }
        #expect(other == [.cancelled(i.reason)])
        #expect(d.state == .idle)
        #expect(d.advance(to: 1000) == [])
        #expect(d.events == [.pressBegan(fresh: false), .cancelled(i.reason)])
    }

    @Test("other modifier released (not pressed) during firstDown also cancels")
    func otherModifierRelease() {
        var d = Driver()
        d.down(at: 0)
        #expect(d.modifier(57, flags: d.key.downFlags | ModifierMask.alphaShift, at: 50) == [.cancelled(.otherModifier)])
    }

    @Test("Option-typing: right ⌥ + 'e' is pressBegan then cancelled(.otherKey(14)) only")
    func optionTyping() {
        var d = Driver(.rightOption)
        d.down(at: 0)
        d.key(kVKE, at: 40)
        d.up(at: 90)
        d.advance(to: 2000)
        #expect(d.events == [.pressBegan(fresh: false), .cancelled(.otherKey(14))])
    }

    @Test("buddy pressed while ⌘ already held: no events until release")
    func buddyWithCommandHeld() {
        var d = Driver(.rightOption)
        let cmd = ModifierMask.command | ModifierMask.deviceLeftCmd
        #expect(d.modifier(kVKCommand, flags: cmd | nonCoalesced, at: 0) == [])
        #expect(d.down(at: 50, extraFlags: cmd) == [])
        #expect(d.state.isSuppressed)
        #expect(d.deadline != nil)  // release poll
        #expect(d.key(kVKE, at: 100) == [])
        #expect(d.modifier(kVKCommand, flags: d.key.downFlags, at: 200) == [])
        #expect(d.advance(to: 2000) == [])
        #expect(d.up(at: 2000) == [])
        #expect(d.state == .idle)
        #expect(d.events == [])
        #expect(d.down(at: 2100) == [.pressBegan(fresh: false)])
    }

    @Test("Caps Lock on does not block a gesture")
    func capsLockIgnored() {
        var d = Driver()
        #expect(d.down(at: 0, extraFlags: ModifierMask.alphaShift) == [.pressBegan(fresh: false)])
    }
}

// MARK: - Fresh (⇧ + buddy key: new conversation)

@Suite("Fresh")
struct FreshTests {
    /// Left ⇧ down, as a flagsChanged carries it.
    let shift = ModifierMask.shift | ModifierMask.deviceLeftShift

    @Test("⇧ + buddy key tap is a fresh tap")
    func freshTap() {
        var d = Driver()
        #expect(d.modifier(kVKShift, flags: shift | nonCoalesced, at: 0) == [])
        #expect(d.down(at: 20, extraFlags: shift) == [.pressBegan(fresh: true)])
        #expect(d.up(at: 80, extraFlags: shift) == [])
        #expect(d.modifier(kVKShift, flags: upFlags, at: 120) == [])
        #expect(d.advance(to: 380) == [.tap])
        #expect(d.state == .idle)
        #expect(d.events == [.pressBegan(fresh: true), .tap])
    }

    @Test("⇧ + buddy key hold is a fresh hold")
    func freshHold() {
        var d = Driver()
        d.modifier(kVKShift, flags: shift | nonCoalesced, at: 0)
        #expect(d.down(at: 20, extraFlags: shift) == [.pressBegan(fresh: true)])
        #expect(d.advance(to: 321) == [.holdBegan])
        #expect(d.up(at: 900, extraFlags: shift) == [.holdEnded])
        #expect(d.events == [.pressBegan(fresh: true), .holdBegan, .holdEnded])
    }

    @Test("⇧ released before the buddy key still taps fresh")
    func shiftReleasedFirst() {
        var d = Driver()
        d.modifier(kVKShift, flags: shift | nonCoalesced, at: 0)
        d.down(at: 20, extraFlags: shift)
        #expect(d.modifier(kVKShift, flags: d.key.downFlags, at: 50) == [])
        #expect(d.up(at: 90) == [])
        #expect(d.advance(to: 390) == [.tap])
        #expect(d.events == [.pressBegan(fresh: true), .tap])
    }

    @Test("⇧ released mid-hold keeps holding")
    func shiftReleasedMidHold() {
        var d = Driver()
        d.modifier(kVKShift, flags: shift | nonCoalesced, at: 0)
        d.down(at: 20, extraFlags: shift)
        #expect(d.advance(to: 321) == [.holdBegan])
        #expect(d.modifier(kVKShift, flags: d.key.downFlags, at: 500) == [])
        #expect(d.state.isHolding)
        #expect(d.up(at: 900) == [.holdEnded])
        #expect(d.events == [.pressBegan(fresh: true), .holdBegan, .holdEnded])
    }

    @Test("⇧ + buddy key + a letter (typing ⇧⌥K) is cancelled, never a tap")
    func shiftOptionTyping() {
        var d = Driver(.rightOption)
        d.modifier(kVKShift, flags: shift | nonCoalesced, at: 0)
        d.down(at: 20, extraFlags: shift)
        #expect(d.key(40, at: 60) == [.cancelled(.otherKey(40))])
        d.up(at: 90, extraFlags: shift)
        d.modifier(kVKShift, flags: upFlags, at: 120)
        #expect(d.advance(to: 2000) == [])
        #expect(d.events == [.pressBegan(fresh: true), .cancelled(.otherKey(40))])
    }

    @Test("⇧⌘ + buddy key is still suppressed")
    func shiftCommandSuppressed() {
        var d = Driver()
        let cmd = ModifierMask.command | ModifierMask.deviceLeftCmd
        #expect(d.down(at: 0, extraFlags: shift | cmd) == [])
        #expect(d.state.isSuppressed)
        #expect(d.up(at: 100, extraFlags: shift | cmd) == [])
        #expect(d.events == [])
    }

    @Test("a plain gesture still cancels when ⇧ goes down mid-press, even after a fresh one")
    func plainGestureShiftCancels() {
        var d = Driver(doubleTap: false)
        d.modifier(kVKShift, flags: shift | nonCoalesced, at: 0)
        #expect(d.down(at: 20, extraFlags: shift) == [.pressBegan(fresh: true)])
        #expect(d.up(at: 80, extraFlags: shift) == [.tap])
        d.modifier(kVKShift, flags: upFlags, at: 100)
        #expect(d.down(at: 200) == [.pressBegan(fresh: false)])
        #expect(d.modifier(kVKShift, flags: d.key.downFlags | shift, at: 250) == [.cancelled(.otherModifier)])
        #expect(d.state.isSuppressed)
    }

    @Test("a ⇧ buddy key uses ⌃ as the fresh modifier")
    func shiftBuddyUsesControl() {
        let ctrl = ModifierMask.control | ModifierMask.deviceLeftCtl
        var d = Driver(.rightShift)
        #expect(d.key.freshSymbol == "⌃")
        d.modifier(59, flags: ctrl | nonCoalesced, at: 0)
        #expect(d.down(at: 20, extraFlags: ctrl) == [.pressBegan(fresh: true)])
        #expect(d.modifier(59, flags: d.key.downFlags, at: 50) == [])
        #expect(d.up(at: 90) == [])
        #expect(d.advance(to: 390) == [.tap])
        // Left ⇧ is not its fresh modifier: right ⇧ with it held is suppressed.
        var other = Driver(.rightShift)
        #expect(other.down(at: 0, extraFlags: shift) == [])
        #expect(other.state.isSuppressed)
        #expect(BuddyKey.rightOption.freshSymbol == "⇧")
    }

    @Test("double-tap after a fresh first press, ⇧ held or let go in between")
    func freshDoubleTap() {
        // ⇧ held through both presses.
        var held = Driver()
        held.modifier(kVKShift, flags: shift | nonCoalesced, at: 0)
        held.down(at: 20, extraFlags: shift)
        held.up(at: 80, extraFlags: shift)
        #expect(held.down(at: 200, extraFlags: shift) == [])
        #expect(held.up(at: 260, extraFlags: shift) == [.doubleTap])
        #expect(held.events == [.pressBegan(fresh: true), .doubleTap])
        // ⇧ let go between the presses.
        var released = Driver()
        released.modifier(kVKShift, flags: shift | nonCoalesced, at: 0)
        released.down(at: 20, extraFlags: shift)
        released.up(at: 80, extraFlags: shift)
        #expect(released.modifier(kVKShift, flags: upFlags, at: 120) == [])
        #expect(released.down(at: 200) == [])
        #expect(released.up(at: 260) == [.doubleTap])
        // Second press seen only in the flags at the window end, ⇧ still down.
        var late = Driver()
        late.modifier(kVKShift, flags: shift | nonCoalesced, at: 0)
        late.down(at: 20, extraFlags: shift)
        late.up(at: 80, extraFlags: shift)
        #expect(late.advance(to: 380, flags: late.key.downFlags | shift) == [])
        #expect(late.state == .secondDown(since: ms(380)))
        #expect(late.up(at: 420, extraFlags: shift) == [.doubleTap])
    }
}

// MARK: - Left vs right

@Suite("Left vs right")
struct SideTests {
    @Test("left ⌥ does not start a right-⌥ gesture")
    func leftDoesNotStart() {
        var d = Driver(.rightOption)
        let left = ModifierMask.alternate | ModifierMask.deviceLeftAlt | nonCoalesced
        #expect(d.modifier(kVKOption, flags: left, at: 0) == [])
        #expect(d.state == .idle)
        #expect(d.modifier(kVKOption, flags: nonCoalesced, at: 100) == [])
        #expect(d.advance(to: 1000) == [])
        #expect(d.events == [])
    }

    @Test("right ⌥ then left ⌥ cancels")
    func rightThenLeft() {
        var d = Driver(.rightOption)
        d.down(at: 0)
        let both = d.key.downFlags | ModifierMask.deviceLeftAlt
        #expect(d.modifier(kVKOption, flags: both, at: 50) == [.cancelled(.otherModifier)])
        #expect(d.up(at: 100, extraFlags: ModifierMask.alternate | ModifierMask.deviceLeftAlt) == [])
        #expect(d.state == .idle)
    }

    @Test("left ⌥ held then right ⌥ down is suppressed")
    func leftHeldThenRight() {
        var d = Driver(.rightOption)
        d.modifier(kVKOption, flags: ModifierMask.alternate | ModifierMask.deviceLeftAlt, at: 0)
        #expect(d.down(at: 50, extraFlags: ModifierMask.deviceLeftAlt) == [])
        #expect(d.state.isSuppressed)
    }
}

// MARK: - Fn

@Suite("Fn")
struct FnTests {
    let fnDown = ModifierMask.secondaryFn | nonCoalesced

    @Test("Fn tap")
    func fnTap() {
        var d = Driver(.function)
        #expect(d.modifier(63, flags: fnDown, at: 0) == [.pressBegan(fresh: false)])
        #expect(d.modifier(63, flags: nonCoalesced, at: 60) == [])
        #expect(d.advance(to: 360) == [.tap])
    }

    @Test("Fn hold")
    func fnHold() {
        var d = Driver(.function)
        d.modifier(63, flags: fnDown, at: 0)
        #expect(d.advance(to: 301) == [.holdBegan])
        #expect(d.modifier(63, flags: nonCoalesced, at: 700) == [.holdEnded])
    }

    /// QA U43: the HID state may not carry the fn bit while fn/🌐 is held. Only the tap's own
    /// flagsChanged (keycode 63, secondaryFn cleared) releases fn.
    @Test("Fn held: a hardware snapshot without the fn bit is not a release")
    func fnSnapshotWithoutBit() {
        var d = Driver(.function)
        d.modifier(63, flags: fnDown, at: 0)
        #expect(d.advance(to: 301, flags: nonCoalesced) == [.holdBegan])
        #expect(d.advance(to: 2000, flags: nonCoalesced) == [])  // release polls don't end it
        #expect(d.state.isHolding)
        #expect(d.modifier(63, flags: nonCoalesced, at: 2100) == [.holdEnded])
        #expect(d.events == [.pressBegan(fresh: false), .holdBegan, .holdEnded])
    }

    @Test("Fn: a snapshot showing the bit still counts as down (second press at the window end)")
    func fnSnapshotDown() {
        var d = Driver(.function)
        d.modifier(63, flags: fnDown, at: 0)
        d.modifier(63, flags: nonCoalesced, at: 60)
        #expect(d.advance(to: 360, flags: fnDown) == [])
        #expect(d.state == .secondDown(since: ms(360)))
    }

    @Test("Fn: a cancelled press stays suppressed until the tap reports the release")
    func fnSuppressedUntilRelease() {
        var d = Driver(.function)
        d.modifier(63, flags: fnDown, at: 0)
        #expect(d.click(at: 50) == [.cancelled(.mouseDown)])
        d.advance(to: 1000, flags: nonCoalesced)
        #expect(d.state.isSuppressed)
        #expect(d.modifier(63, flags: nonCoalesced, at: 1100) == [])
        #expect(d.state == .idle)
    }

    @Test("other keys: a snapshot showing the key up at the deadline is still a release",
          arguments: BuddyKey.allCases.filter { $0 != .function })
    func snapshotReleaseOtherKeys(key: BuddyKey) {
        var d = Driver(key, doubleTap: false)
        d.down(at: 0)
        #expect(d.advance(to: 301, flags: upFlags) == [.tap])
        var h = Driver(key)
        h.down(at: 0)
        h.advance(to: 301, flags: key.downFlags)
        #expect(h.advance(to: 600, flags: upFlags) == [.holdEnded])  // the lost-release poll
    }
}

// MARK: - Missing device bits

@Suite("Missing device bits")
struct MissingDeviceBitsTests {
    static let keys: [BuddyKey] = [.rightOption, .rightCommand]

    @Test("shared-bit-only down then flags 0 is a tap", arguments: keys)
    func tap(key: BuddyKey) {
        var d = Driver(key)
        #expect(d.buddy(flags: key.sharedBitOnly, at: 0) == [.pressBegan(fresh: false)])
        #expect(d.state == .firstDown(since: 0))
        #expect(d.buddy(flags: 0, at: 80) == [])
        #expect(d.advance(to: 380) == [.tap])
        #expect(d.events == [.pressBegan(fresh: false), .tap])
    }

    @Test("shared-bit-only down held past the threshold is a hold", arguments: keys)
    func hold(key: BuddyKey) {
        var d = Driver(key)
        #expect(d.buddy(flags: key.sharedBitOnly, at: 0) == [.pressBegan(fresh: false)])
        // The hardware flags carry no device bit either: they cannot tell, so the press holds.
        #expect(d.advance(to: 301, flags: key.sharedBitOnly) == [.holdBegan])
        #expect(d.advance(to: 1000, flags: key.sharedBitOnly) == [])
        #expect(d.state.isHolding)
        #expect(d.buddy(flags: 0, at: 1000) == [.holdEnded])
        #expect(d.events == [.pressBegan(fresh: false), .holdBegan, .holdEnded])
    }

    @Test("each shared-bit-only event toggles the key", arguments: keys)
    func toggles(key: BuddyKey) {
        var d = Driver(key, doubleTap: false)
        #expect(d.buddy(flags: key.sharedBitOnly, at: 0) == [.pressBegan(fresh: false)])
        #expect(d.buddy(flags: key.sharedBitOnly, at: 80) == [.tap])
        #expect(d.buddy(flags: key.sharedBitOnly, at: 200) == [.pressBegan(fresh: false)])
        #expect(d.buddy(flags: key.sharedBitOnly, at: 260) == [.tap])
    }

    @Test("isDown(in:) for right ⌥")
    func isDownRightOption() {
        let k = BuddyKey.rightOption
        #expect(k.isDown(in: ModifierMask.alternate | ModifierMask.deviceRightAlt) == true)
        #expect(k.isDown(in: ModifierMask.deviceRightAlt) == true)
        #expect(k.isDown(in: ModifierMask.alternate) == nil)
        #expect(k.isDown(in: ModifierMask.alternate | nonCoalesced) == nil)
        #expect(k.isDown(in: ModifierMask.alternate | ModifierMask.deviceLeftAlt) == false)
        #expect(k.isDown(in: 0) == false)
        #expect(k.isDown(in: nonCoalesced | ModifierMask.command | ModifierMask.deviceLeftCmd) == false)
    }

    @Test("isDown(in:) for right ⌘")
    func isDownRightCommand() {
        let k = BuddyKey.rightCommand
        #expect(k.isDown(in: ModifierMask.command | ModifierMask.deviceRightCmd) == true)
        #expect(k.isDown(in: ModifierMask.command) == nil)
        #expect(k.isDown(in: ModifierMask.command | ModifierMask.deviceLeftCmd) == false)
        #expect(k.isDown(in: 0) == false)
    }

    @Test("isDown(in:) is never nil for Fn")
    func isDownFn() {
        #expect(BuddyKey.function.isDown(in: ModifierMask.secondaryFn) == true)
        #expect(BuddyKey.function.isDown(in: 0) == false)
        #expect(BuddyKey.function.isDown(in: ModifierMask.alternate) == false)
    }

    @Test("isDown(in:) per key: device bit true, shared bit only nil, opposite side false",
          arguments: BuddyKey.allCases.filter { $0 != .function })
    func isDownAllSided(key: BuddyKey) {
        #expect(key.isDown(in: key.downFlags) == true)
        #expect(key.isDown(in: key.independentMask) == nil)
        #expect(key.isDown(in: key.independentMask | key.oppositeDownMask) == false)
        #expect(key.isDown(in: upFlags) == false)
    }
}

extension BuddyKey {
    /// The shared bit alone, as sent by keyboards and remappers without device bits.
    var sharedBitOnly: UInt64 { independentMask }
}

// MARK: - Recovery (tapInterrupted / tick flags / late timers)

@Suite("Recovery")
struct RecoveryTests {
    @Test("tick with released flags while holding ends the hold")
    func holdingReleasedFlags() {
        var d = Driver()
        d.down(at: 0)
        d.advance(to: 301)
        #expect(d.tick(at: 400, flags: d.key.downFlags) == [])
        #expect(d.state.isHolding)
        #expect(d.tick(at: 500, flags: upFlags) == [.holdEnded])
        #expect(d.state == .idle)
    }

    @Test("key up at the hold deadline (release queued behind the timer) is a tap")
    func firstDownReleasedFlags() {
        var d = Driver()
        d.down(at: 0)
        #expect(d.advance(to: 301, flags: upFlags) == [])
        #expect(d.state == .awaitingSecond(until: ms(600)))
        #expect(d.up(at: 301) == [])   // the queued release, now ignored
        #expect(d.advance(to: 600) == [.tap])
        #expect(d.events == [.pressBegan(fresh: false), .tap])
    }

    @Test("same with double-tap off: tap at the deadline")
    func firstDownReleasedFlagsNoDoubleTap() {
        var d = Driver(doubleTap: false)
        d.down(at: 0)
        #expect(d.advance(to: 301, flags: upFlags) == [.tap])
        #expect(d.up(at: 301) == [])
    }

    @Test("late timer: input after the window does not cancel an expired tap")
    func overdueTapSettledBeforeInput() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 100)          // window until 400; the timer never fired
        #expect(d.key(14, at: 900) == [.tap])
        #expect(d.state == .idle)
    }

    @Test("late timer: input after the hold threshold discards the hold, not a cancel")
    func overdueHoldSettledBeforeInput() {
        var d = Driver()
        d.down(at: 0)
        #expect(d.click(at: 500) == [.holdBegan, .holdDiscarded(.mouseDown)])
    }

    @Test("lost release while holding is recovered by the poll")
    func holdingPollRecovers() {
        var d = Driver()
        d.down(at: 0)
        d.advance(to: 301)
        #expect(d.advance(to: 2000) == [])
        #expect(d.state.isHolding)
        #expect(d.advance(to: 2400, flags: upFlags) == [.holdEnded])
        #expect(d.state == .idle)
        #expect(d.deadline == nil)
    }

    @Test("lost release while suppressed is recovered by the poll")
    func suppressedPollRecovers() {
        var d = Driver()
        d.down(at: 0)
        d.key(kVKE, at: 50)
        #expect(d.state.isSuppressed)
        #expect(d.advance(to: 2000, flags: d.key.downFlags) == [])
        #expect(d.state.isSuppressed)
        #expect(d.advance(to: 2400, flags: upFlags) == [])
        #expect(d.state == .idle)
        #expect(d.deadline == nil)
        #expect(d.down(at: 2500) == [.pressBegan(fresh: false)])
    }

    @Test("firstDown before threshold ignores released flags")
    func firstDownEarlyTick() {
        var d = Driver()
        d.down(at: 0)
        #expect(d.tick(at: 100, flags: upFlags) == [])
        #expect(d.state == .firstDown(since: 0))
    }

    @Test("tick with nil flags while holding keeps holding")
    func holdingNilFlags() {
        var d = Driver()
        d.down(at: 0)
        d.advance(to: 301)
        #expect(d.tick(at: 1000, flags: nil) == [])
        #expect(d.state.isHolding)
    }

    @Test("suppressed + tick with released flags returns to idle")
    func suppressedReleasedFlags() {
        var d = Driver()
        d.down(at: 0)
        d.interrupted(at: 50)
        #expect(d.tick(at: 100, flags: d.key.downFlags) == [])
        #expect(d.state.isSuppressed)
        #expect(d.tick(at: 200, flags: upFlags) == [])
        #expect(d.state == .idle)
        #expect(d.down(at: 300) == [.pressBegan(fresh: false)])
    }

    @Test("second buddy down while suppressed implies the lost release: fresh gesture")
    func downWhileSuppressed() {
        var d = Driver()
        d.down(at: 0)
        d.key(kVKE, at: 50)
        #expect(d.down(at: 400) == [.pressBegan(fresh: false)])
        #expect(d.state == .firstDown(since: ms(400)))
    }

    @Test("tick in idle does nothing")
    func idleTick() {
        var d = Driver()
        #expect(d.tick(at: 100, flags: upFlags) == [])
        #expect(d.state == .idle)
    }

    @Test("buddy up in idle or awaitingSecond is ignored")
    func strayUp() {
        var d = Driver()
        #expect(d.up(at: 0) == [])
        d.down(at: 10)
        d.up(at: 50)
        #expect(d.up(at: 60) == [])
        #expect(d.state == .awaitingSecond(until: ms(350)))
    }

    @Test("lost release after tapInterrupted: next real press is not swallowed")
    func lostReleaseAfterInterrupt() {
        var d = Driver()
        d.down(at: 0)
        d.advance(to: 301)
        #expect(d.interrupted(at: 400) == [.holdDiscarded(.tapInterrupted)])
        // release happens while the tap is disabled: never delivered
        d.advance(to: 5000, flags: upFlags)
        #expect(d.down(at: 5000) == [.pressBegan(fresh: false)])
        #expect(d.up(at: 5050) == [])
        #expect(d.advance(to: 5350) == [.tap])
    }
}

// MARK: - Saturating time

@Suite("Saturating time")
struct SaturatingTimeTests {
    @Test("tick earlier than firstDown's since does not wrap into a hold")
    func earlyTickFirstDown() {
        var d = Driver()
        d.down(at: 1000)
        #expect(d.tick(at: 900) == [])
        #expect(d.tick(atNanos: 0) == [])
        #expect(d.tick(at: 900, flags: upFlags) == [])
        #expect(d.state == .firstDown(since: ms(1000)))
    }

    @Test("tick earlier than secondDown's since does not wrap into a hold")
    func earlyTickSecondDown() {
        var d = Driver()
        d.down(at: 1000)
        d.up(at: 1050)
        d.down(at: 1100)
        #expect(d.tick(at: 1000) == [])
        #expect(d.state == .secondDown(since: ms(1100)))
        #expect(d.up(at: 1150) == [.doubleTap])
    }

    @Test("release stamped earlier than since is a tap, not a hold")
    func earlyRelease() {
        var d = Driver()
        d.down(at: 1000)
        #expect(d.up(at: 900) == [])
        #expect(d.state == .awaitingSecond(until: ms(1200)))
        #expect(d.advance(to: 1200) == [.tap])
    }
}

@Suite("Review regressions")
struct ReviewRegressionTests {
    @Test("third press queued behind the cooldown timer stays ignored")
    func queuedThirdPressInCooldown() {
        var d = Driver()
        d.down(at: 0)
        d.up(at: 80)
        d.down(at: 200)
        #expect(d.up(at: 260) == [.doubleTap])  // cooldown until 560
        // Timer fires at 560 and the flags already show the third press down…
        #expect(d.advance(to: 560, flags: d.key.downFlags) == [])
        #expect(d.state.isSuppressed)
        // …then the queued down (stamped 555) and its release arrive.
        #expect(d.down(at: 555) == [])
        #expect(d.up(at: 620) == [])
        #expect(d.advance(to: 2000) == [])
        #expect(d.events == [.pressBegan(fresh: false), .doubleTap])
    }

    @Test("a genuine second down while suppressed (release lost) still starts fresh")
    func lostReleaseWhileSuppressedStillRecovers() {
        var d = Driver()
        d.down(at: 0)
        #expect(d.key(14, at: 50) == [.cancelled(.otherKey(14))])
        // Release never delivered; next press arrives.
        #expect(d.down(at: 3000) == [.pressBegan(fresh: false)])
    }

    @Test("resync sets key state for events without device bits")
    func resyncForToggleMode() {
        var m = GestureMachine(key: .rightOption)
        // Key held across a reset; hardware says down (device bit present in the snapshot).
        m.resync(flags: BuddyKey.rightOption.downFlags)
        // Device-bit-less release toggles to up: no gesture, and the next press starts one.
        #expect(m.handle(.flagsChanged(keyCode: 61, flags: 0, time: ms(100))) == [])
        #expect(m.handle(.flagsChanged(keyCode: 61, flags: ModifierMask.alternate, time: ms(200))) == [.pressBegan(fresh: false)])
    }
}
