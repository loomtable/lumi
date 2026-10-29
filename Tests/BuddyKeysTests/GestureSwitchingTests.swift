import Testing
@testable import BuddyKeys

/// The `switching` state (10-ENGINEERING §4 S4, 03 §3.4 A).
@Suite("GestureMachine switching")
struct GestureSwitchingTests {
    typealias Code = SwitcherKeyMap.Code

    func driver(_ key: BuddyKey = .rightOption, switcher: Bool = true) -> Driver {
        var d = Driver(key)
        if switcher { d.machine.config.switcher = SwitcherKeyMap(buddy: key) }
        return d
    }

    @Test("Tab after the hold threshold opens the switcher; release commits")
    func tabAfterHold() {
        var d = driver()
        d.down(at: 0)
        d.advance(to: 400, flags: d.key.downFlags)
        #expect(d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(500))) == [.switcher(.next)])
        #expect(d.state.isSwitching)
        #expect(d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(600))) == [.switcher(.next)])
        #expect(d.up(at: 900) == [.switcherReleased])
        #expect(d.state == .idle)
        #expect(d.events == [.pressBegan(fresh: false), .holdBegan, .switcher(.next), .switcher(.next), .switcherReleased])
    }

    @Test("Tab before the hold threshold opens the switcher without a holdBegan")
    func tabBeforeHold() {
        var d = driver()
        d.down(at: 0)
        #expect(d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(100))) == [.switcher(.next)])
        #expect(d.advance(to: 1000, flags: d.key.downFlags) == [])
        #expect(d.up(at: 1200) == [.switcherReleased])
        #expect(d.events == [.pressBegan(fresh: false), .switcher(.next), .switcherReleased])
    }

    @Test("a late hold deadline settles before the Tab")
    func lateDeadline() {
        var d = driver()
        d.down(at: 0)
        #expect(d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(500))) == [.holdBegan, .switcher(.next)])
    }

    @Test("Tab on the second press of a double-tap window opens the switcher")
    func secondPress() {
        var d = driver()
        d.down(at: 0)
        d.up(at: 80)
        d.down(at: 150)
        #expect(d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(200))) == [.switcher(.next)])
        #expect(d.up(at: 700) == [.switcherReleased])
    }

    @Test("inside the strip every mapped key passes through")
    func mappedKeysInside() {
        var d = driver()
        d.down(at: 0)
        d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(100)))
        for (i, key) in [SwitcherKey.prev, .index(3), .peek, .unpeek, .new, .teammates, .pin, .archive, .commit].enumerated() {
            #expect(d.send(.switcherKeyDown(key, keyCode: 0, time: ms(200 + UInt64(i)))) == [.switcher(key)])
            #expect(d.state.isSwitching)
        }
    }

    @Test("Esc closes the strip but keeps the hold: release then sends as a plain hold")
    func escapeKeepsHold() {
        var d = driver()
        d.down(at: 0)
        d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(400)))
        #expect(d.send(.switcherKeyDown(.cancel, keyCode: Code.escape, time: ms(500))) == [.switcher(.cancel)])
        #expect(d.state.isHolding)
        // Tab again reopens it.
        #expect(d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(600))) == [.switcher(.next)])
        d.send(.switcherKeyDown(.cancel, keyCode: Code.escape, time: ms(700)))
        #expect(d.up(at: 900) == [.holdEnded])
    }

    @Test("a stray key inside the strip discards the recording, as during a hold")
    func strayKeyDiscards() {
        var d = driver()
        d.down(at: 0)
        d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(400)))
        #expect(d.key(kVKE, at: 500) == [.holdDiscarded(.otherKey(kVKE))])
        #expect(d.state.isSuppressed)
        #expect(d.up(at: 600) == [])
    }

    @Test("click, scroll and another modifier inside the strip discard")
    func otherInterruptions() {
        var a = driver()
        a.down(at: 0)
        a.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(100)))
        #expect(a.click(at: 200) == [.holdDiscarded(.mouseDown)])
        var b = driver()
        b.down(at: 0)
        b.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(100)))
        #expect(b.scroll(at: 200) == [.holdDiscarded(.scroll)])
        var c = driver()
        c.down(at: 0)
        c.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(100)))
        let cmd = ModifierMask.command | ModifierMask.deviceLeftCmd
        #expect(c.modifier(kVKCommand, flags: c.key.downFlags | cmd, at: 200) == [.holdDiscarded(.otherModifier)])
    }

    @Test("⇧ is tolerated while the key is down, so ⇧Tab can open and move back")
    func shiftTolerated() {
        var d = driver()
        let shift = ModifierMask.shift | ModifierMask.deviceLeftShift
        d.down(at: 0)
        d.advance(to: 400, flags: d.key.downFlags)
        #expect(d.modifier(kVKShift, flags: d.key.downFlags | shift, at: 450) == [])
        #expect(d.send(.switcherKeyDown(.prev, keyCode: Code.tab, time: ms(500))) == [.switcher(.prev)])
        #expect(d.modifier(kVKShift, flags: d.key.downFlags, at: 550) == [])
        #expect(d.up(at: 900) == [.switcherReleased])
    }

    @Test("without a switcher ⇧ during a hold still discards (unchanged)")
    func shiftWithoutSwitcher() {
        var d = driver(switcher: false)
        d.down(at: 0)
        d.advance(to: 400, flags: d.key.downFlags)
        let shift = ModifierMask.shift | ModifierMask.deviceLeftShift
        #expect(d.modifier(kVKShift, flags: d.key.downFlags | shift, at: 450) == [.holdDiscarded(.otherModifier)])
    }

    @Test("without a switcher a switcher key is a stray key")
    func noSwitcherConfigured() {
        var d = driver(switcher: false)
        d.down(at: 0)
        d.advance(to: 400, flags: d.key.downFlags)
        #expect(d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(500))) == [.holdDiscarded(.otherKey(Code.tab))])
    }

    @Test("only next and previous open the strip; other mapped keys cancel a plain hold")
    func nonOpenerCancels() {
        var d = driver()
        d.down(at: 0)
        d.advance(to: 400, flags: d.key.downFlags)
        #expect(d.send(.switcherKeyDown(.new, keyCode: Code.n, time: ms(500))) == [.holdDiscarded(.otherKey(Code.n))])
        var e = driver()
        e.down(at: 0)
        #expect(e.send(.switcherKeyDown(.commit, keyCode: Code.returnKey, time: ms(50))) == [.cancelled(.otherKey(Code.returnKey))])
    }

    @Test("a switcher key with the key up is ignored by the machine (tap mode is the monitor's)")
    func keyUpStates() {
        var d = driver()
        #expect(d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(10))) == [])
        d.down(at: 100)
        d.up(at: 150)
        // awaitingSecond: the key is up, so this cancels the pending tap like any key.
        #expect(d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(200))) == [.cancelled(.otherKey(Code.tab))])
    }

    @Test("a lost release is recovered by the poll while switching")
    func pollRecovers() {
        var d = driver()
        d.down(at: 0)
        d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(100)))
        #expect(d.deadline == ms(100) + d.machine.config.releasePollInterval)
        #expect(d.advance(to: 300, flags: d.key.downFlags) == [])
        #expect(d.advance(to: 600, flags: upFlags) == [.switcherReleased])
        #expect(d.state == .idle)
    }

    @Test("a second buddy-key down while switching implies the lost release")
    func secondDownImpliesRelease() {
        var d = driver()
        d.down(at: 0)
        d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(100)))
        #expect(d.down(at: 300) == [.switcherReleased, .pressBegan(fresh: false)])
    }

    @Test("tap interrupted while switching discards")
    func tapInterrupted() {
        var d = driver()
        d.down(at: 0)
        d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(100)))
        #expect(d.interrupted(at: 200) == [.holdDiscarded(.tapInterrupted)])
    }

    @Test("a fresh gesture stays fresh while switching")
    func freshKept() {
        var d = driver()
        let shift = ModifierMask.shift | ModifierMask.deviceLeftShift
        d.down(at: 0, extraFlags: shift)
        #expect(d.machine.isFresh)
        d.send(.switcherKeyDown(.next, keyCode: Code.tab, time: ms(100)))
        #expect(d.machine.isFresh)
        d.up(at: 500)
        #expect(!d.machine.isFresh)
    }

    @Test("other buddy keys open the switcher the same way", arguments: [BuddyKey.rightCommand, .leftShift, .function])
    func otherBuddyKeys(key: BuddyKey) {
        var d = driver(key)
        d.down(at: 0)
        #expect(d.send(.switcherKeyDown(.next, keyCode: Code.grave, time: ms(100))) == [.switcher(.next)])
        #expect(d.up(at: 500) == [.switcherReleased])
    }
}
