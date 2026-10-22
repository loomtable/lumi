import CoreGraphics
import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

/// Screen lock, sleep and remote screen sharing stop listening and keep the speech.
@MainActor
struct InterruptionTests {
    let voice = FakeVoice()
    let bridge = FakeBridge()
    let overlay = FakeOverlay()

    func make(_ system: FakeSystemInterruptions) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let coordinator = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), bridge: bridge,
            overlay: overlay, pointer: FixedPointer(), interruptions: system)
        coordinator.start()
        return coordinator
    }

    func settle(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func drain() async { for _ in 0..<100 { await Task.yield() } }

    /// Tap-to-talk, listening and confirmed.
    func listen(_ coordinator: BuddyCoordinator) async {
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
    }

    @Test(arguments: [
        (SystemInterruption.screenLocked, ListenInterruption.screenLocked),
        (.systemWillSleep, .systemSleep),
    ])
    func lockAndSleepStopListening(event: SystemInterruption, reason: ListenInterruption) async {
        let system = FakeSystemInterruptions()
        let coordinator = make(system)
        await settle(until: { system.openStreams == 1 }) // the lifetime events() stream
        await listen(coordinator)

        system.send(event)
        await settle(until: { !voice.interruptReasons.isEmpty })
        #expect(voice.interruptReasons == [reason])
        #expect(bridge.asked.isEmpty) // kept, never sent
    }

    @Test func lockWhileNotListeningDoesNothing() async {
        let system = FakeSystemInterruptions()
        _ = make(system)
        await settle(until: { system.openStreams == 1 })
        system.send(.screenLocked)
        system.send(.systemWillSleep)
        await drain()
        #expect(voice.interruptReasons.isEmpty)
    }

    @Test func wakeAndUnlockDoNotInterrupt() async {
        let system = FakeSystemInterruptions()
        let coordinator = make(system)
        await settle(until: { system.openStreams == 1 })
        await listen(coordinator)
        system.send(.screenUnlocked)
        system.send(.systemDidWake)
        system.send(.displaysDidSleep) // the user may still be talking
        system.send(.displaysDidWake)
        await drain()
        #expect(voice.interruptReasons.isEmpty)
        #expect(coordinator.phase == .listening(confirmedTap: true, holding: false))
    }

    @Test func sharingIsWatchedOnlyWhileListening() async {
        bridge.setScript([BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .chip))])
        let system = FakeSystemInterruptions()
        let coordinator = make(system)
        await settle(until: { system.openStreams == 1 })

        await listen(coordinator)
        await settle(until: { system.openStreams == 2 })
        #expect(system.openStreams == 2)

        // Sending ends the listen, and with it the watch.
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        await settle(until: { system.openStreams == 1 })
        #expect(system.openStreams == 1)

        // A session starting now isn't a listen to stop.
        system.send(.remoteScreenSharingStarted)
        await drain()
        #expect(voice.interruptReasons.isEmpty)
    }

    @Test func sharingStartingMidListenStopsIt() async {
        let system = FakeSystemInterruptions()
        let coordinator = make(system)
        await listen(coordinator)
        await settle(until: { system.openStreams == 2 })

        system.send(.remoteScreenSharingStarted)
        await settle(until: { !voice.interruptReasons.isEmpty })
        #expect(voice.interruptReasons == [.screenSharing])
    }

    @Test func sharingAlreadyRunningStopsTheListenAtOnce() async {
        let system = FakeSystemInterruptions(sharing: true)
        let coordinator = make(system)
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await settle(until: { !voice.interruptReasons.isEmpty })
        #expect(voice.interruptReasons == [.screenSharing])
    }

    @Test func discardEndsTheWatch() async {
        let system = FakeSystemInterruptions()
        let coordinator = make(system)
        await settle(until: { system.openStreams == 1 })
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await settle(until: { system.openStreams == 2 })
        await coordinator.escapePressed()
        await settle(until: { system.openStreams == 1 })
        #expect(system.openStreams == 1)
    }

    @Test func stopEndsEveryStream() async {
        let system = FakeSystemInterruptions()
        let coordinator = make(system)
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await settle(until: { system.openStreams == 2 })
        coordinator.stop()
        await settle(until: { system.openStreams == 0 })
        #expect(system.openStreams == 0)
    }

    @Test func lockBeforeTheMicIsUpEndsTheListen() async {
        let gated = GatedVoice(gateStart: true)
        let system = FakeSystemInterruptions()
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let coordinator = BuddyCoordinator(
            settings: settings, voice: gated, context: FakeContext.packet(), bridge: bridge,
            overlay: overlay, pointer: FixedPointer(), interruptions: system)
        coordinator.start()
        await settle(until: { system.openStreams == 1 })

        let press = Task { await coordinator.handle(.gesture(.pressBegan(fresh: false))) }
        await settle(until: { gated.waiting == 1 })
        system.send(.screenLocked)
        await settle(until: { coordinator.phase == .idle })
        gated.release()
        await press.value
        #expect(coordinator.phase == .idle)
        #expect(gated.calls.contains(.discard))
        #expect(!gated.calls.contains(.interrupt)) // nothing was recording yet
        #expect(system.openStreams == 1) // no sharing watch for a listen that ended
    }

    @Test func releaseOfAnInterruptedPressDoesNotSendTheSpeech() async {
        let system = FakeSystemInterruptions()
        let coordinator = make(system)
        await settle(until: { system.openStreams == 1 })
        await coordinator.handle(.gesture(.pressBegan(fresh: false))) // key still down
        await coordinator.handle(.gesture(.holdBegan))

        system.send(.screenLocked)
        await settle(until: { voice.interruptReasons == [.screenLocked] })
        voice.eventSink.yield(.autoStopped(held: true, message: nil)) // the voice kept the speech
        await settle(until: { coordinator.phase == .held })

        await coordinator.handle(.gesture(.holdEnded)) // the release
        for _ in 0..<100 { await Task.yield() }
        #expect(coordinator.phase == .held)
        #expect(!voice.calls.contains(.sendHeld))
        #expect(bridge.asked.isEmpty)

        // A fresh tap after seeing the chip sends it.
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        #expect(voice.calls.contains(.sendHeld))
    }

    @Test func oneLidCloseInterruptsOnce() async {
        let system = FakeSystemInterruptions()
        let coordinator = make(system)
        await settle(until: { system.openStreams == 1 })
        await listen(coordinator)
        system.send(.systemWillSleep)
        system.send(.screenLocked)
        await settle(until: { !voice.interruptReasons.isEmpty })
        for _ in 0..<100 { await Task.yield() }
        #expect(voice.interruptReasons == [.systemSleep])
    }

    @Test func lockStopsAReplyReadingOut() async {
        bridge.setScript([BuddyCoordinatorTests.done(BuddyBlock(say: "It's the totals row.", shape: .card))])
        let system = FakeSystemInterruptions()
        let coordinator = make(system)
        await settle(until: { system.openStreams == 1 })
        await listen(coordinator)
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        await settle(until: { coordinator.phase == .showing })
        let stops = voice.calls.count { $0 == .stopSpeaking }

        system.send(.screenLocked)
        await settle(until: { voice.calls.count { $0 == .stopSpeaking } > stops })
        #expect(voice.calls.count { $0 == .stopSpeaking } == stops + 1)
    }
}
