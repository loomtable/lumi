import Testing
@testable import BuddyKeys

/// The dictation key's second, hold-only machine in `BuddyKeyMonitor` (10-ENGINEERING §1.11).
@Suite("BuddyKeyMonitor dictation")
struct DictationMonitorTests {
    let buddy = BuddyKey.rightOption
    let dictationKey = BuddyKey.rightCommand
    let source = FakeKeySource()
    let clock = ManualClock()

    func makeMonitor(dictationKey: BuddyKey? = .rightCommand, mode: DictationMode = .hold) -> (BuddyKeyMonitor, StreamRecorder<BuddyKeyEvent>) {
        let monitor = BuddyKeyMonitor(
            options: .init(key: buddy, dictationKey: dictationKey, dictationMode: mode), source: source, clock: clock,
            stickyKeys: { false })
        return (monitor, StreamRecorder(monitor.events))
    }

    func press(_ key: BuddyKey, at t: UInt64, extra: UInt64 = 0) {
        source.setFlags(key.downFlags | extra)
        source.send(.input(.flagsChanged(keyCode: key.keyCode, flags: key.downFlags | extra, time: ms(t))))
    }

    func release(_ key: BuddyKey, at t: UInt64, flags: UInt64 = upFlags) {
        source.setFlags(flags)
        source.send(.input(.flagsChanged(keyCode: key.keyCode, flags: flags, time: ms(t))))
    }

    func timerArmed(sourceLocation: SourceLocation = #_sourceLocation) async {
        let armed = await eventually { [clock] in clock.sleeperCount > 0 }
        #expect(armed, "no timer armed", sourceLocation: sourceLocation)
    }

    @Test("right ⌘: begins 120 ms into a clean press; release after the threshold ends")
    func hold() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        press(dictationKey, at: 0)
        await timerArmed()
        clock.advance(to: ms(120))
        #expect(await events.next() == [.dictation(.began)])
        await timerArmed()
        clock.advance(to: ms(301))
        let held = await eventually { [clock] in clock.sleeperCount > 0 }  // now polling for a lost release
        #expect(held)
        release(dictationKey, at: 900)
        #expect(await events.next() == [.dictation(.ended)])
        #expect(events.all == [.dictation(.began), .dictation(.ended)])
    }

    @Test("release before the threshold: discarded (after arming) or silent (before), never ended")
    func shortPress() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        press(dictationKey, at: 0)
        release(dictationKey, at: 100)  // inside the arming delay: nothing at all
        press(dictationKey, at: 150)
        release(dictationKey, at: 280)  // armed at 270 by this release's time: began, then discarded
        let short = BuddyKeyEvent.dictation(.discarded(.shortPress(.rightCommand, held: ms(130))))
        #expect(await events.next(2) == [.dictation(.began), short])
        clock.advance(to: ms(2000))
        press(buddy, at: 3000)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        #expect(events.all == [.dictation(.began), short, .gesture(.pressBegan(fresh: false))])
    }

    @Test("a ⌘ shortcut before the threshold never begins; during a hold it cancels, keeping the words")
    func shortcuts() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        press(dictationKey, at: 0)
        source.send(.input(.keyDown(keyCode: 8, time: ms(50))))  // ⌘C: silent, the mic never starts
        release(dictationKey, at: 110)
        clock.advance(to: ms(1000))
        press(dictationKey, at: 2000)
        await timerArmed()
        clock.advance(to: ms(2120))
        #expect(await events.next() == [.dictation(.began)])
        await timerArmed()
        clock.advance(to: ms(2301))
        source.send(.input(.keyDown(keyCode: 8, time: ms(2400))))
        #expect(await events.next() == [.dictation(.cancelled(.interrupted(.otherKey(8))))])
        release(dictationKey, at: 2500)
        #expect(!events.all.contains(.dictation(.ended)))
    }

    @Test("the buddy key during a dictation hold: dictation cancelled (words kept), no buddy gesture")
    func buddyWhileDictating() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        press(dictationKey, at: 0)
        await timerArmed()
        clock.advance(to: ms(120))
        #expect(await events.next() == [.dictation(.began)])
        let both = dictationKey.downFlags | buddy.downFlags
        source.setFlags(both)
        source.send(.input(.flagsChanged(keyCode: buddy.keyCode, flags: both, time: ms(400))))
        #expect(await events.next() == [.dictation(.cancelled(.interrupted(.otherModifier)))])
        #expect(!events.all.contains(.gesture(.pressBegan(fresh: false))))
    }

    @Test("the buddy key's gestures are unchanged with a dictation key set")
    func buddyUnchanged() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        press(buddy, at: 0)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        await timerArmed()
        clock.advance(to: ms(301))
        #expect(await events.next() == [.gesture(.holdBegan)])
        release(buddy, at: 900)
        #expect(await events.next() == [.gesture(.holdEnded)])
    }

    @Test("a dictation key equal to the buddy key is ignored")
    func sameAsBuddy() async throws {
        let (monitor, events) = makeMonitor(dictationKey: .rightOption)
        try await monitor.start()
        press(buddy, at: 0)
        await timerArmed()
        clock.advance(to: ms(301))
        #expect(await events.next(2) == [.gesture(.pressBegan(fresh: false)), .gesture(.holdBegan)])
        release(buddy, at: 900)
        #expect(await events.next() == [.gesture(.holdEnded)])
        #expect(!events.all.contains { if case .dictation = $0 { true } else { false } })
    }

    @Test("update to no dictation key: the key does nothing")
    func updateOff() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        await monitor.update(.init(key: buddy))
        press(dictationKey, at: 0)
        clock.advance(to: ms(1000))
        release(dictationKey, at: 1100)
        press(buddy, at: 2000)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        #expect(events.all == [.gesture(.pressBegan(fresh: false))])
    }

    @Test("a lost release is recovered by the poll")
    func lostRelease() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        press(dictationKey, at: 0)
        await timerArmed()
        clock.advance(to: ms(120))
        #expect(await events.next() == [.dictation(.began)])
        await timerArmed()
        clock.advance(to: ms(301))  // a hold now
        _ = await eventually { [clock] in clock.sleeperCount > 0 }
        source.setFlags(upFlags)  // released, but the tap never said so
        clock.advance(to: ms(600))
        #expect(await events.next() == [.dictation(.ended)])
    }

    @Test("fn as the dictation key begins on the press")
    func fnKey() async throws {
        let (monitor, events) = makeMonitor(dictationKey: .function)
        try await monitor.start()
        press(.function, at: 0)
        #expect(await events.next() == [.dictation(.began)])
        await timerArmed()
        clock.advance(to: ms(301))
        _ = await eventually { [clock] in clock.sleeperCount > 0 }
        release(.function, at: 700)
        #expect(await events.next() == [.dictation(.ended)])
    }

    /// QA U43. The exact fn sequence: flagsChanged 63 with secondaryFn (0x800100), held, then
    /// flagsChanged 63 with it cleared (0x100). The HID state read at the 300 ms tick may lack
    /// the fn bit; that must not discard the dictation.
    @Test("fn held while the hardware flags lack the fn bit: ended on release, not discarded")
    func fnSnapshotWithoutBit() async throws {
        let (monitor, events) = makeMonitor(dictationKey: .function)
        try await monitor.start()
        source.send(.input(.flagsChanged(keyCode: 63, flags: 0x80_0100, time: ms(0))))
        source.setFlags(0x100)  // the snapshot: no secondaryFn
        #expect(await events.next() == [.dictation(.began)])
        await timerArmed()
        clock.advance(to: ms(301))
        _ = await eventually { [clock] in clock.sleeperCount > 0 }  // holding, polling
        clock.advance(to: ms(1200))
        _ = await eventually { [clock] in clock.sleeperCount > 0 }
        source.send(.input(.flagsChanged(keyCode: 63, flags: 0x100, time: ms(1500))))
        #expect(await events.next() == [.dictation(.ended)])
        #expect(events.all == [.dictation(.began), .dictation(.ended)])
    }

    /// The lead's U43 hypothesis, end to end: fn's flagsChanged plus the Globe key's own key-downs.
    @Test("fn with the Globe key's own key-downs: began on the press, ended on release")
    func fnGlobeKeyDowns() async throws {
        let (monitor, events) = makeMonitor(dictationKey: .function)
        try await monitor.start()
        source.setFlags(0x80_0100)
        source.send(.input(.flagsChanged(keyCode: 63, flags: 0x80_0100, time: ms(0))))
        source.send(.input(.keyDown(keyCode: 179, time: ms(1))))
        source.send(.input(.keyDown(keyCode: 179, time: ms(150))))
        #expect(await events.next() == [.dictation(.began)])
        await timerArmed()
        clock.advance(to: ms(301))
        _ = await eventually { [clock] in clock.sleeperCount > 0 }
        source.setFlags(0x100)
        source.send(.input(.flagsChanged(keyCode: 63, flags: 0x100, time: ms(900))))
        #expect(await events.next() == [.dictation(.ended)])
        #expect(events.all == [.dictation(.began), .dictation(.ended)])
    }

    @Test("right ⌘ is unaffected: a lost release is still recovered from the snapshot")
    func rightCommandSnapshotRelease() async throws {
        let (monitor, events) = makeMonitor(dictationKey: .rightCommand)
        try await monitor.start()
        source.send(.input(.flagsChanged(keyCode: 54, flags: 0x10_0110, time: ms(0))))
        source.setFlags(0x10_0110)
        await timerArmed()
        clock.advance(to: ms(120))
        #expect(await events.next() == [.dictation(.began)])
        await timerArmed()
        clock.advance(to: ms(301))
        _ = await eventually { [clock] in clock.sleeperCount > 0 }
        source.setFlags(0x100)
        clock.advance(to: ms(600))
        #expect(await events.next() == [.dictation(.ended)])
    }

    // MARK: Tap to toggle (owner, Oct 29)

    @Test("toggle: a tap starts, scrolls, clicks and other keys don't end it, the next tap stops")
    func toggle() async throws {
        let (monitor, events) = makeMonitor(dictationKey: .function, mode: .toggle)
        try await monitor.start()
        press(.function, at: 0)
        #expect(await events.next() == [.dictation(.began)])
        release(.function, at: 120)
        #expect(await events.next() == [.dictation(.latched)])
        source.send(.input(.scroll(time: ms(2000))))
        source.send(.input(.mouseDown(time: ms(3000))))
        source.send(.input(.keyDown(keyCode: 8, time: ms(4000))))
        source.send(.input(.tapInterrupted(time: ms(5000))))
        press(.function, at: 60_000)
        release(.function, at: 60_100)
        #expect(await events.next() == [.dictation(.ended)])
        #expect(events.all == [.dictation(.began), .dictation(.latched), .dictation(.ended)])
    }

    @Test("toggle: rebinding the key while a dictation runs cancels it (its words are kept)")
    func toggleRebound() async throws {
        let (monitor, events) = makeMonitor(dictationKey: .function, mode: .toggle)
        try await monitor.start()
        press(.function, at: 0)
        release(.function, at: 100)
        #expect(await events.next(2) == [.dictation(.began), .dictation(.latched)])
        await monitor.update(.init(key: buddy, dictationKey: .function, dictationMode: .toggle))
        #expect(await events.next() == [.dictation(.cancelled(.interrupted(.tapInterrupted)))])
    }

    @Test("toggle: endDictation (the app stopped it) makes the next tap start a new one")
    func toggleEndedOutside() async throws {
        let (monitor, events) = makeMonitor(dictationKey: .function, mode: .toggle)
        try await monitor.start()
        press(.function, at: 0)
        release(.function, at: 100)
        #expect(await events.next(2) == [.dictation(.began), .dictation(.latched)])
        await monitor.endDictation()
        press(.function, at: 5000)
        #expect(await events.next() == [.dictation(.began)])
    }
}
