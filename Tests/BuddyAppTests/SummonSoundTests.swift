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
        let c = BuddyCoordinator(settings: settings, voice: voice, context: FakeContext.packet(), bridge: FakeBridge(),
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
        let deadline = ContinuousClock.now + .seconds(1)
        while !summoned(voice.calls), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(summoned(voice.calls)) // at once: 300 ms have passed
    }

    @Test func aFastMicStillWaits300ms() async throws {
        let voice = FakeVoice()
        let c = make(voice)
        let pressed = ContinuousClock.now
        await c.handle(.gesture(.pressBegan(fresh: false)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(!summoned(voice.calls))
        let deadline = ContinuousClock.now + .seconds(1)
        while !summoned(voice.calls), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(summoned(voice.calls))
        #expect(ContinuousClock.now - pressed >= BuddyCoordinator.summonSoundDelay)
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
