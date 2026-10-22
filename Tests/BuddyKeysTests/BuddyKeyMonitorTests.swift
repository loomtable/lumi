import Testing
@testable import BuddyKeys

@Suite("BuddyKeyMonitor")
struct BuddyKeyMonitorTests {
    let key = BuddyKey.rightOption
    let source = FakeKeySource()
    let clock = ManualClock()

    func makeMonitor(
        options: BuddyKeyMonitor.Options = .init(),
        source: FakeKeySource? = nil,
        stickyKeys: @escaping @Sendable () -> Bool = { false }
    ) -> (BuddyKeyMonitor, StreamRecorder<BuddyKeyEvent>) {
        let monitor = BuddyKeyMonitor(
            options: options, source: source ?? self.source, clock: clock, stickyKeys: stickyKeys)
        return (monitor, StreamRecorder(monitor.events))
    }

    func down(at t: UInt64, extraFlags: UInt64 = 0) {
        source.send(.input(.flagsChanged(keyCode: key.keyCode, flags: key.downFlags | extraFlags, time: ms(t))))
    }

    func up(at t: UInt64) {
        source.send(.input(.flagsChanged(keyCode: key.keyCode, flags: upFlags, time: ms(t))))
    }

    /// Waits until the monitor has armed a timer on the manual clock.
    func timerArmed(sourceLocation: SourceLocation = #_sourceLocation) async {
        let armed = await eventually { [clock] in clock.sleeperCount > 0 }
        #expect(armed, "no timer armed", sourceLocation: sourceLocation)
    }

    @Test("tap end to end: emitted when the double-tap window expires")
    func tap() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        #expect(source.isStarted)
        down(at: 0)
        up(at: 80)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        await timerArmed()
        clock.advance(to: ms(1000))
        #expect(await events.next() == [.gesture(.tap)])
        #expect(events.all == [.gesture(.pressBegan(fresh: false)), .gesture(.tap)])
    }

    @Test("double-tap end to end")
    func doubleTap() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        down(at: 0)
        up(at: 80)
        down(at: 150)
        up(at: 200)
        #expect(await events.next(2) == [.gesture(.pressBegan(fresh: false)), .gesture(.doubleTap)])
    }

    @Test("hold via clock advance")
    func hold() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        down(at: 0)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        await timerArmed()
        source.setFlags(key.downFlags)  // the hardware still shows the key down at the deadline
        clock.advance(to: ms(301))
        #expect(await events.next() == [.gesture(.holdBegan)])
        source.setFlags(0)
        up(at: 400)
        #expect(await events.next() == [.gesture(.holdEnded)])
    }

    @Test("lost release while holding is recovered by the release poll")
    func holdPoll() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        source.setFlags(key.downFlags)
        down(at: 0)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        await timerArmed()
        clock.advance(to: ms(301))
        #expect(await events.next() == [.gesture(.holdBegan)])
        await timerArmed()
        source.setFlags(0)  // the release never reaches the tap
        clock.advance(to: ms(1000))
        #expect(await events.next() == [.gesture(.holdEnded)])
    }

    @Test("while listening, a tap is emitted on release without advancing the clock")
    func listening() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        await monitor.setListening(true)
        down(at: 0)
        up(at: 80)
        #expect(await events.next(2) == [.gesture(.pressBegan(fresh: false)), .gesture(.tap)])
        #expect(clock.now() == 0)
    }

    @Test("Sticky Keys on disables double-tap")
    func stickyKeys() async throws {
        let (monitor, events) = makeMonitor(stickyKeys: { true })
        try await monitor.start()
        down(at: 0)
        up(at: 80)
        down(at: 150)
        up(at: 200)
        #expect(await events.next(4) == [
            .gesture(.pressBegan(fresh: false)), .gesture(.tap), .gesture(.pressBegan(fresh: false)), .gesture(.tap),
        ])
        #expect(clock.now() == 0)
    }

    @Test("secure input from the source is published and cancels an in-flight press")
    func secureInputCancels() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        down(at: 0)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        source.send(.secureInput(true))
        #expect(await events.next(2) == [.secureInput(true), .gesture(.cancelled(.tapInterrupted))])
        source.send(.secureInput(true))  // unchanged: not published again
        source.send(.secureInput(false))
        #expect(await events.next() == [.secureInput(false)])
    }

    @Test("ignoreDuringSecureInput drops gestures but still publishes secure input changes")
    func ignoreDuringSecureInput() async throws {
        let (monitor, events) = makeMonitor(options: .init(ignoreDuringSecureInput: true))
        try await monitor.start()
        await monitor.setListening(true)
        source.send(.secureInput(true))
        #expect(await events.next() == [.secureInput(true)])
        down(at: 0)
        up(at: 80)
        source.send(.secureInput(false))
        // The press and tap in between were dropped: the next event is the secure input change.
        #expect(await events.next() == [.secureInput(false)])
        down(at: 200)
        up(at: 260)
        #expect(await events.next(2) == [.gesture(.pressBegan(fresh: false)), .gesture(.tap)])
    }

    @Test("start twice throws alreadyStarted")
    func startTwice() async throws {
        let (monitor, _) = makeMonitor()
        try await monitor.start()
        await #expect(throws: KeySourceError.alreadyStarted) { try await monitor.start() }
    }

    @Test("start rethrows the source's error")
    func startError() async {
        let failing = FakeKeySource(startError: .inputMonitoringNotGranted)
        let (monitor, _) = makeMonitor(source: failing)
        await #expect(throws: KeySourceError.inputMonitoringNotGranted) { try await monitor.start() }
        #expect(!failing.isStarted)
    }

    @Test("stop stops the source, cancels the timer and resets the gesture")
    func stopResets() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        source.setFlags(key.downFlags)
        down(at: 0)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        await timerArmed()
        clock.advance(to: ms(301))
        #expect(await events.next() == [.gesture(.holdBegan)])
        await timerArmed()

        await monitor.stop()
        #expect(!source.isStarted)
        let settled = await eventually { [clock] in clock.sleeperCount == 0 }
        #expect(settled)

        // Restartable, with a fresh machine: the old hold's release is not a holdEnded.
        try await monitor.start()
        source.setFlags(0)
        up(at: 500)
        down(at: 600)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        #expect(!events.all.contains(.gesture(.holdEnded)))
    }

    @Test("update rebinds the key and drops the gesture in progress")
    func updateRebinds() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        await monitor.setListening(true)
        await monitor.update(.init(key: .rightCommand))
        down(at: 0)  // right ⌥ is now just another modifier
        up(at: 50)
        let cmd = BuddyKey.rightCommand
        source.send(.input(.flagsChanged(keyCode: cmd.keyCode, flags: cmd.downFlags, time: ms(100))))
        source.send(.input(.flagsChanged(keyCode: cmd.keyCode, flags: upFlags, time: ms(150))))
        #expect(await events.next(2) == [.gesture(.pressBegan(fresh: false)), .gesture(.tap)])
    }

    @Test("events buffered when stop() is called are dropped, not fed to the reset machine")
    func bufferedEventsDroppedAfterStop() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        for i in 0..<50 { down(at: UInt64(i) * 1000); up(at: UInt64(i) * 1000 + 50) }
        await monitor.stop()
        let countAtStop = events.all.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(events.all.count == countAtStop)
        #expect(clock.sleeperCount == 0)
    }

    @Test("listening turned on during the window applies to the next gesture after a late timer")
    func listeningAppliesAfterSettle() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        down(at: 0)
        up(at: 50)  // window until 350; the timer is not advanced
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        await monitor.setListening(true)
        down(at: 1000)  // settles the old tap, then starts a press
        up(at: 1050)    // listening: tap at once
        #expect(await events.next(3) == [.gesture(.tap), .gesture(.pressBegan(fresh: false)), .gesture(.tap)])
    }
}
