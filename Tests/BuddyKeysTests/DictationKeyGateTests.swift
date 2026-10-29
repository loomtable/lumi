import Testing
@testable import BuddyKeys

/// When the dictation key may start the mic (owner, Oct 28): fn on the press, chord-prone keys
/// after `armingDelay` of a clean press. Hold mode below; tap to toggle (owner, Oct 29) at the end.
@Suite("DictationKeyGate")
struct DictationKeyGateTests {
    struct Gate {
        var gate: DictationKeyGate
        var out: [DictationGesture] = []
        init(_ key: BuddyKey, mode: DictationMode = .hold) { gate = DictationKeyGate(key: key, mode: mode) }
        var key: BuddyKey { gate.key }

        @discardableResult mutating func send(_ input: InputEvent) -> [DictationGesture] {
            let o = gate.handle(input)
            out += o
            return o
        }
        @discardableResult mutating func down(at t: UInt64) -> [DictationGesture] {
            send(.flagsChanged(keyCode: key.keyCode, flags: key.downFlags, time: ms(t)))
        }
        @discardableResult mutating func up(at t: UInt64) -> [DictationGesture] {
            send(.flagsChanged(keyCode: key.keyCode, flags: upFlags, time: ms(t)))
        }
        @discardableResult mutating func keyDown(at t: UInt64) -> [DictationGesture] {
            send(.keyDown(keyCode: 8, time: ms(t)))  // C
        }
        /// Ticks at every deadline up to `t`, with the key still down.
        @discardableResult mutating func advance(to t: UInt64) -> [DictationGesture] {
            var o: [DictationGesture] = []
            var guardCount = 0
            while let d = gate.deadline, d <= ms(t), guardCount < 100 {
                guardCount += 1
                o += send(.tick(time: d, flags: key.downFlags))
            }
            return o
        }
    }

    @Test("the arming delay is 120 ms")
    func delay() {
        #expect(DictationKeyGate.armingDelay == ms(120))
        #expect(DictationKeyGate(key: .function).beginsOnPress)
        for key in BuddyKey.allCases where key != .function {
            #expect(!DictationKeyGate(key: key).beginsOnPress)
        }
    }

    // MARK: fn: on the press

    @Test("fn begins on the press; a release past the threshold ends")
    func fnHold() {
        var g = Gate(.function)
        #expect(g.down(at: 0) == [.began])
        #expect(g.advance(to: 400) == [])
        #expect(g.up(at: 900) == [.ended])
    }

    @Test("fn released early: began, then discarded")
    func fnShort() {
        var g = Gate(.function)
        g.down(at: 0)
        let short = DictationGesture.discarded(.shortPress(.function, held: ms(80)))
        #expect(g.up(at: 80) == [short])
        #expect(g.out == [.began, short])
    }

    @Test("each discard says why: the hold time, or what interrupted it")
    func discardReason() {
        var g = Gate(.function)
        g.down(at: 0)
        #expect(g.keyDown(at: 150) == [.discarded(.interrupted(.otherKey(8)))])
        var h = Gate(.function)
        h.down(at: 0)
        #expect(h.send(.mouseDown(time: ms(50))) == [.discarded(.interrupted(.mouseDown))])
        #expect(DictationDiscard.shortPress(.function, held: ms(142)).logDescription
            == "released after 142 ms, before the hold threshold")
        // The log never carries a key that types text, only keys like fn/🌐 or arrows.
        #expect(DictationDiscard.interrupted(.otherKey(8)).logDescription == "another key")
        #expect(DictationDiscard.interrupted(.otherKey(179)).logDescription == "another key (179)")
        #expect(DictationDiscard.interrupted(.mouseDown).logDescription == "a click")
    }

    @Test("which key codes may be logged")
    func loggableKeyCodes() {
        for text: UInt16 in [0, 8, 0x24, 0x31, 0x33, 0x35, 0x41, 0x52] { #expect(CancelReason.loggableKeyCode(text) == nil) }
        for safe: UInt16 in [0x37, 0x3F, 0x4F, 0x60, 0x7B, 0x7E, 0xB3] { #expect(CancelReason.loggableKeyCode(safe) == safe) }
    }

    /// QA U43 lead hypothesis: the 🌐/fn key sends its own key-downs (63, 179), repeated while
    /// held. They must not count as another key.
    @Test("fn held with the Globe key's own key-downs and repeats: ended, not discarded")
    func fnGlobeKeyDowns() {
        var g = Gate(.function)
        #expect(g.send(.flagsChanged(keyCode: 63, flags: 0x80_0100, time: ms(0))) == [.began])
        #expect(g.send(.keyDown(keyCode: 179, time: ms(1))) == [])
        #expect(g.send(.keyDown(keyCode: 63, time: ms(2))) == [])
        for t in stride(from: UInt64(150), through: 1400, by: 80) {
            g.advance(to: t)
            #expect(g.send(.keyDown(keyCode: 179, time: ms(t))) == [])  // autorepeat
        }
        #expect(g.send(.flagsChanged(keyCode: 63, flags: 0x100, time: ms(1500))) == [.ended])
        #expect(g.out == [.began, .ended])
    }

    @Test("with right ⌘, a 179 key-down is still another key")
    func globeCodeOtherKeys() {
        var g = Gate(.rightCommand)
        g.down(at: 0)
        g.advance(to: 120)
        #expect(g.send(.keyDown(keyCode: 179, time: ms(200))) == [.discarded(.interrupted(.otherKey(179)))])
    }

    @Test("fn held while the hardware flags lack the fn bit: ended, not discarded (QA U43)")
    func fnSnapshotWithoutBit() {
        var g = Gate(.function)
        #expect(g.send(.flagsChanged(keyCode: 63, flags: 0x80_0100, time: ms(0))) == [.began])
        var ticks: [DictationGesture] = []
        while let d = g.gate.deadline, d <= ms(1500) { ticks += g.send(.tick(time: d, flags: 0x100)) }
        #expect(ticks == [])
        #expect(g.send(.flagsChanged(keyCode: 63, flags: 0x100, time: ms(1600))) == [.ended])
    }

    // MARK: chord-prone keys: after 120 ms of a clean press

    @Test("right ⌘ held: nothing on the press, began at 120 ms, ended on release")
    func commandHold() {
        var g = Gate(.rightCommand)
        #expect(g.down(at: 0) == [])
        #expect(g.gate.deadline == ms(120))
        #expect(g.advance(to: 119) == [])
        #expect(g.advance(to: 120) == [.began])
        #expect(g.advance(to: 400) == [])
        #expect(g.up(at: 900) == [.ended])
        #expect(g.out == [.began, .ended])
    }

    @Test("⌘C inside the arming delay: silent, the mic never starts")
    func commandShortcut() {
        var g = Gate(.rightCommand)
        g.down(at: 0)
        #expect(g.keyDown(at: 60) == [])
        g.up(at: 100)
        g.advance(to: 1000)
        #expect(g.out.isEmpty)
    }

    @Test("a tap inside the arming delay: silent")
    func commandTap() {
        var g = Gate(.rightCommand)
        g.down(at: 0)
        #expect(g.up(at: 90) == [])
        #expect(g.gate.deadline == nil)
        #expect(g.out.isEmpty)
    }

    @Test("released after arming but before the hold threshold: began, then discarded")
    func commandShortAfterArming() {
        var g = Gate(.rightCommand)
        g.down(at: 0)
        g.advance(to: 120)
        #expect(g.up(at: 200) == [.discarded(.shortPress(.rightCommand, held: ms(200)))])
        #expect(g.out == [.began, .discarded(.shortPress(.rightCommand, held: ms(200)))])
    }

    @Test("a shortcut after arming but before the threshold discards what was recorded")
    func commandShortcutAfterArming() {
        var g = Gate(.rightCommand)
        g.down(at: 0)
        g.advance(to: 120)
        #expect(g.keyDown(at: 250) == [.discarded(.interrupted(.otherKey(8)))])
    }

    @Test("a late arming timer: input after 120 ms begins first, then counts")
    func lateTimer() {
        var g = Gate(.rightCommand)
        g.down(at: 0)
        #expect(g.keyDown(at: 150) == [.began, .discarded(.interrupted(.otherKey(8)))])
        var h = Gate(.rightCommand)
        h.down(at: 0)
        #expect(h.up(at: 700) == [.began, .ended])  // the hold settles too
    }

    @Test("each press arms afresh")
    func repeated() {
        var g = Gate(.rightCommand)
        g.down(at: 0)
        g.up(at: 50)
        g.down(at: 1000)
        #expect(g.gate.deadline == ms(1120))
        #expect(g.advance(to: 1120) == [.began])
    }

    // MARK: hold mode, once holding (QA U47)

    @Test("a hold: scrolls and clicks never end it; the release types (QA U47)")
    func holdIgnoresPointer() {
        var g = Gate(.function)
        g.down(at: 0)
        g.advance(to: 400)
        #expect(g.send(.scroll(time: ms(500))) == [])
        #expect(g.send(.mouseDown(time: ms(900))) == [])
        g.advance(to: 1200)
        #expect(g.up(at: 1300) == [.ended])
        #expect(g.out == [.began, .ended])
    }

    @Test("another key during a hold cancels, keeping the words; Esc cancels too")
    func holdOtherKeyAndEscape() {
        var g = Gate(.function)
        g.down(at: 0)
        g.advance(to: 400)
        #expect(g.keyDown(at: 500) == [.cancelled(.interrupted(.otherKey(8)))])
        #expect(g.up(at: 600) == [])
        var h = Gate(.function)
        h.down(at: 0)
        h.advance(to: 400)
        #expect(h.send(.keyDown(keyCode: 0x35, time: ms(500))) == [.cancelled(.escape)])
        #expect(h.up(at: 600) == [])
        #expect(h.out == [.began, .cancelled(.escape)])
    }

    // MARK: tap to toggle (owner, Oct 29)

    @Test("toggle is the default mode")
    func toggleDefault() {
        #expect(DictationKeyGate(key: .function).mode == .toggle)
        #expect(BuddyKeyMonitor.Options().dictationMode == .toggle)
    }

    @Test("toggle, fn: began on the press, latched on a clean release, ended by the next tap")
    func toggleFn() {
        var g = Gate(.function, mode: .toggle)
        #expect(g.down(at: 0) == [.began])
        #expect(g.up(at: 150) == [.latched])
        #expect(g.gate.latched)
        #expect(g.send(.scroll(time: ms(5000))) == [])
        #expect(g.send(.mouseDown(time: ms(6000))) == [])
        #expect(g.keyDown(at: 7000) == [])
        #expect(g.send(.tapInterrupted(time: ms(8000))) == [])
        #expect(g.down(at: 600_000) == [])
        #expect(g.up(at: 600_120) == [.ended])
        #expect(!g.gate.isActive)
        #expect(g.out == [.began, .latched, .ended])
    }

    @Test("toggle, right ⌘ tapped faster than the arming delay: starts on the release")
    func toggleQuickCommandTap() {
        var g = Gate(.rightCommand, mode: .toggle)
        #expect(g.down(at: 0) == [])
        #expect(g.up(at: 80) == [.began, .latched])
        #expect(g.gate.deadline == nil)
    }

    @Test("toggle: ⌘C never starts a dictation, before or after the arming delay")
    func toggleShortcut() {
        var g = Gate(.rightCommand, mode: .toggle)
        g.down(at: 0)
        g.keyDown(at: 60)
        g.up(at: 100)
        g.advance(to: 1000)
        #expect(g.out.isEmpty)
        var h = Gate(.rightCommand, mode: .toggle)
        h.down(at: 0)
        h.advance(to: 150)
        #expect(h.keyDown(at: 200) == [.discarded(.interrupted(.otherKey(8)))])
        #expect(h.up(at: 260) == [])
        #expect(!h.gate.isActive)
    }

    @Test("toggle: a click during the tap's press means it wasn't a clean tap")
    func toggleClickDuringTap() {
        var g = Gate(.function, mode: .toggle)
        g.down(at: 0)
        #expect(g.send(.mouseDown(time: ms(50))) == [.discarded(.interrupted(.mouseDown))])
        #expect(g.up(at: 100) == [])
        #expect(!g.gate.isActive)
    }

    @Test("toggle: held past the threshold works as hold-to-talk")
    func toggleHybridHold() {
        var g = Gate(.function, mode: .toggle)
        g.down(at: 0)
        g.advance(to: 2000)
        #expect(g.send(.scroll(time: ms(2100))) == [])
        #expect(g.up(at: 2500) == [.ended])
        #expect(g.out == [.began, .ended])
    }

    @Test("toggle: while latched, the key pressed with another key is a shortcut, not a stop")
    func toggleChordWhileLatched() {
        var g = Gate(.rightCommand, mode: .toggle)
        g.down(at: 0)
        g.up(at: 50)
        #expect(g.gate.latched)
        g.down(at: 3000)
        #expect(g.keyDown(at: 3050) == [])
        #expect(g.up(at: 3100) == [])
        #expect(g.gate.latched)
        g.advance(to: 4000)
        g.down(at: 5000)
        #expect(g.up(at: 5100) == [.ended])
    }

    @Test("toggle: Esc cancels; the next tap starts a new dictation")
    func toggleEscape() {
        var g = Gate(.function, mode: .toggle)
        g.down(at: 0)
        g.up(at: 100)
        #expect(g.send(.keyDown(keyCode: 0x35, time: ms(9000))) == [.cancelled(.escape)])
        #expect(!g.gate.isActive)
        #expect(g.down(at: 10_000) == [.began])
        #expect(g.up(at: 10_100) == [.latched])
    }

    @Test("toggle: endDictation forgets a latched dictation")
    func toggleEndedOutside() {
        var g = Gate(.function, mode: .toggle)
        g.down(at: 0)
        g.up(at: 100)
        g.gate.endDictation()
        #expect(!g.gate.isActive)
        #expect(g.down(at: 1000) == [.began])
    }

    @Test("Esc when no dictation runs is just another key")
    func escapeIdle() {
        var g = Gate(.function, mode: .toggle)
        #expect(g.send(.keyDown(keyCode: 0x35, time: ms(10))) == [])
    }
}
