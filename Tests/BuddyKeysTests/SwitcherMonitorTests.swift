import Testing
@testable import BuddyKeys

/// `BuddyKeyMonitor` arming the switcher tap (10-ENGINEERING §4 S4).
@Suite("BuddyKeyMonitor switcher")
struct SwitcherMonitorTests {
    typealias Code = SwitcherKeyMap.Code
    let key = BuddyKey.rightOption
    let source = FakeKeySource()
    let clock = ManualClock()
    let tap = FakeSwitcherTap()

    func makeMonitor(switcher: Bool = true, tap: FakeSwitcherTap? = nil) -> (BuddyKeyMonitor, StreamRecorder<BuddyKeyEvent>) {
        var options = BuddyKeyMonitor.Options(key: key)
        // Any map: the monitor rebuilds it for the buddy key.
        if switcher { options.gesture.switcher = SwitcherKeyMap(buddy: .function) }
        let monitor = BuddyKeyMonitor(
            options: options, source: source, clock: clock, stickyKeys: { false }, switcherTap: tap ?? self.tap)
        return (monitor, StreamRecorder(monitor.events))
    }

    func down(at t: UInt64, extraFlags: UInt64 = 0) {
        source.send(.input(.flagsChanged(keyCode: key.keyCode, flags: key.downFlags | extraFlags, time: ms(t))))
    }

    func up(at t: UInt64) {
        source.send(.input(.flagsChanged(keyCode: key.keyCode, flags: upFlags, time: ms(t))))
    }

    func armed(_ open: Bool, fresh: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) async {
        let want = SwitcherFilter.Arming(map: SwitcherKeyMap(buddy: key), fresh: fresh, open: open)
        let ok = await eventually { [tap] in tap.arming == want }
        #expect(ok, "arming is \(String(describing: tap.arming)), wanted \(want)", sourceLocation: sourceLocation)
    }

    func disarmed(sourceLocation: SourceLocation = #_sourceLocation) async {
        let ok = await eventually { [tap] in !tap.isActive }
        #expect(ok, "switcher tap still active", sourceLocation: sourceLocation)
    }

    @Test("held: armed for openers at the press, fully once open, off after the release")
    func heldPath() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        #expect(!tap.isActive)
        down(at: 0)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        await armed(false)
        // Openers only: N isn't taken yet.
        #expect(tap.press(keyCode: Code.n, flags: key.downFlags, time: ms(50)) == nil)
        #expect(tap.press(keyCode: Code.tab, flags: key.downFlags, time: ms(100)) == .next)
        #expect(await events.next() == [.gesture(.switcher(.next))])
        await armed(true)
        #expect(tap.press(keyCode: Code.n, flags: key.downFlags, time: ms(150)) == .new)
        #expect(await events.next() == [.gesture(.switcher(.new))])
        up(at: 400)
        #expect(await events.next() == [.gesture(.switcherReleased)])
        await disarmed()
        #expect(tap.activations == 1)
    }

    @Test("Esc inside the strip goes back to openers only, and the release sends")
    func escapeRearms() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        down(at: 0)
        await armed(false)
        tap.press(keyCode: Code.tab, flags: key.downFlags, time: ms(100))
        await armed(true)
        tap.press(keyCode: Code.escape, flags: key.downFlags, time: ms(200))
        #expect(await events.next(3) == [
            .gesture(.pressBegan(fresh: false)), .gesture(.switcher(.next)), .gesture(.switcher(.cancel)),
        ])
        await armed(false)
        up(at: 400)
        #expect(await events.next() == [.gesture(.holdEnded)])
        await disarmed()
    }

    @Test("a fresh press arms with fresh set")
    func freshArming() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        down(at: 0, extraFlags: ModifierMask.shift | ModifierMask.deviceLeftShift)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: true))])
        await armed(false, fresh: true)
    }

    @Test("a cancelled press disarms")
    func cancelDisarms() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        down(at: 0)
        await armed(false)
        source.send(.input(.keyDown(keyCode: kVKE, time: ms(50))))
        #expect(await events.next(2) == [.gesture(.pressBegan(fresh: false)), .gesture(.cancelled(.otherKey(kVKE)))])
        await disarmed()
    }

    @Test("tap mode: armed while listening; keys come out as .switcher; commit closes the strip")
    func tapMode() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        await monitor.setListening(true)
        await armed(false)
        #expect(tap.press(keyCode: Code.returnKey, flags: 0, time: ms(10)) == nil)
        #expect(tap.press(keyCode: Code.tab, flags: 0, time: ms(20)) == .next)
        #expect(await events.next() == [.switcher(.next)])
        await armed(true)
        tap.press(keyCode: Code.tab, flags: ModifierMask.shift, time: ms(30))
        #expect(await events.next() == [.switcher(.prev)])
        tap.press(keyCode: Code.returnKey, flags: 0, time: ms(40))
        #expect(await events.next() == [.switcher(.commit)])
        await armed(false)
        await monitor.setListening(false)
        await disarmed()
    }

    @Test("tap mode: closeSwitcher goes back to openers; listening off disarms")
    func tapModeClose() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        await monitor.setListening(true)
        await armed(false)
        tap.press(keyCode: Code.tab, flags: 0, time: ms(20))
        #expect(await events.next() == [.switcher(.next)])
        await armed(true)
        await monitor.closeSwitcher()
        await armed(false)
        await monitor.setListening(false)
        await disarmed()
    }

    @Test("tap mode then a press: the held arming takes over and tap mode closes")
    func pressDuringTapMode() async throws {
        let (monitor, events) = makeMonitor()
        try await monitor.start()
        await monitor.setListening(true)
        tap.press(keyCode: Code.tab, flags: 0, time: ms(20))
        #expect(await events.next() == [.switcher(.next)])
        await armed(true)
        down(at: 100)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        await armed(false)
        up(at: 150)
        #expect(await events.next() == [.gesture(.tap)])  // listening: the tap sends at once
        await armed(false)  // still listening: tap mode, strip closed
        #expect(tap.activations == 1)
    }

    @Test("no switcher configured: the tap is never armed and Tab cancels as before")
    func inert() async throws {
        let (monitor, events) = makeMonitor(switcher: false)
        try await monitor.start()
        await monitor.setListening(true)
        down(at: 0)
        source.send(.input(.keyDown(keyCode: Code.tab, time: ms(50))))
        #expect(await events.next(2) == [.gesture(.pressBegan(fresh: false)), .gesture(.cancelled(.otherKey(Code.tab)))])
        #expect(tap.activations == 0)
    }

    @Test("no Accessibility: that gesture runs without the switcher; the next one retries")
    func noAccessibility() async throws {
        let failing = FakeSwitcherTap(error: .accessibilityNotGranted)
        let (monitor, events) = makeMonitor(tap: failing)
        try await monitor.start()
        down(at: 0)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        // The listen-only tap sees Tab (nothing armed drops it): a stray key, as today.
        source.send(.input(.keyDown(keyCode: Code.tab, time: ms(50))))
        #expect(await events.next() == [.gesture(.cancelled(.otherKey(Code.tab)))])
        up(at: 100)
        failing.setError(nil)
        down(at: 1000)
        #expect(await events.next() == [.gesture(.pressBegan(fresh: false))])
        let ok = await eventually { failing.isActive }
        #expect(ok)
    }

    @Test("stop disarms; listening while stopped never arms")
    func stopDisarms() async throws {
        let (monitor, _) = makeMonitor()
        try await monitor.start()
        await monitor.setListening(true)
        await armed(false)
        await monitor.stop()
        await disarmed()
        await monitor.setListening(true)
        #expect(!tap.isActive)
    }

    @Test("ignoreDuringSecureInput also drops tap-mode switcher keys")
    func secureInputTapMode() async throws {
        var options = BuddyKeyMonitor.Options(key: key, ignoreDuringSecureInput: true)
        options.gesture.switcher = SwitcherKeyMap(buddy: key)
        let monitor = BuddyKeyMonitor(options: options, source: source, clock: clock, stickyKeys: { false }, switcherTap: tap)
        let events = StreamRecorder(monitor.events)
        try await monitor.start()
        await monitor.setListening(true)
        await armed(false)
        source.send(.secureInput(true))
        #expect(await events.next() == [.secureInput(true)])
        tap.press(keyCode: Code.tab, flags: 0, time: ms(20))
        await armed(true)  // the key was handled (the strip counts as open), just not published
        source.send(.secureInput(false))
        #expect(await events.next() == [.secureInput(false)])
        #expect(!events.all.contains(.switcher(.next)))
    }
}
