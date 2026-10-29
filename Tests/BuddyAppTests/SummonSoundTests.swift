import CoreGraphics
import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

/// The summon sound means "I'm listening": it waits for a live mic, and 300 ms after the press.
@MainActor
struct SummonSoundTests {
    func make(_ voice: any VoicePort) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = true
        let c = BuddyCoordinator(settings: settings, voice: voice, context: FakeContext.packet(), turns: FakeBridge(),
                                 overlay: FakeOverlay(), pointer: FixedPointer())
        c.start()
        return c
    }

    func summoned(_ calls: [FakeVoice.Call]) -> Bool { calls.contains(.play(.summon)) }

    @Test func itWaitsForTheMic() async throws {
        let voice = GatedVoice(gateStart: true) // the mic takes a while to give real audio
        let c = make(voice)
        let press = Task { await c.handle(.gesture(.pressBegan(fresh: false))) }
        try await Task.sleep(for: .milliseconds(450))
        #expect(!summoned(voice.calls)) // past 300 ms, but the mic isn't live yet

        voice.release()
        await press.value
        let deadline = ContinuousClock.now + waitCeiling
        while !summoned(voice.calls), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(summoned(voice.calls)) // at once: 300 ms have passed
    }

    /// The mic is live at once, so the sound waits out the rest of the 300 ms. The wait goes
    /// through a sleeper the test releases, so no wall-clock budget can be missed under load.
    @Test func aFastMicStillWaits300ms() async throws {
        let voice = FakeVoice()
        let c = make(voice)
        let sleeper = ManualSleeper()
        c.sleep = sleeper.sleep
        await c.handle(.gesture(.pressBegan(fresh: false)))
        let deadline = ContinuousClock.now + waitCeiling
        while sleeper.waitingCount == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let wait = try #require(sleeper.requested.first)
        #expect(wait > .zero && wait <= BuddyCoordinator.summonSoundDelay, "the rest of the 300 ms")
        #expect(!summoned(voice.calls), "not before the wait ends")
        sleeper.release()
        while !summoned(voice.calls), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(summoned(voice.calls))
    }

    @Test func aMicThatFailsToStartIsSilent() async throws {
        let voice = FakeVoice()
        voice.setStartError(VoicePortError("The microphone didn't start."))
        let c = make(voice)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        try await Task.sleep(for: .milliseconds(450))
        #expect(!summoned(voice.calls))
    }

    @Test func aDoubleTapIsSilent() async throws {
        let voice = FakeVoice()
        let c = make(voice)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.doubleTap))
        try await Task.sleep(for: .milliseconds(450))
        #expect(!summoned(voice.calls))
    }
}
