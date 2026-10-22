import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
@testable import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

/// Held recordings, discard confirmation and the live voice adapter's mapping.
@MainActor
struct VoiceFlowTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()

    func make(bridge: any BridgePort = FakeBridge()) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), bridge: bridge,
            overlay: overlay, pointer: FixedPointer())
        c.start()
        return c
    }

    func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    var answers: [String] {
        overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a.block.say } else { nil } }
    }

    @Test func silenceAutoStopKeepsTheRecordingAndATapSendsIt() async {
        let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Ok.", shape: .chip))])
        let c = make(bridge: bridge)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        voice.eventSink.yield(.autoStopped(held: true, message: nil))
        await waitFor { c.phase == .held }
        #expect(answers.last?.hasPrefix("I stopped listening.") == true)

        await c.handle(.gesture(.pressBegan(fresh: false))) // ignored while held
        await c.handle(.gesture(.tap))
        await waitFor { c.phase == .showing && bridge.asked.count == 1 }
        #expect(voice.calls.contains(.sendHeld))
        #expect(bridge.asked.first?.packet.utterance == "what does this mean?")
    }

    @Test func autoStopWithNothingKeptJustCloses() async {
        let c = make()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        voice.eventSink.yield(.autoStopped(held: false, message: nil))
        await waitFor { c.phase == .idle }
        #expect(c.phase == .idle)
        #expect(!voice.calls.contains(.sendHeld))
    }

    @Test func longSpeechAsksBeforeDiscardingThenSecondEscConfirms() async {
        voice.setLongSpeech(45)
        let c = make()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.escapePressed()
        #expect(answers.last?.hasPrefix("Press Esc again to discard 45 s of speech") == true)
        #expect(voice.calls.contains(.interrupt)) // the mic stops before asking
        #expect(c.phase == .held)

        await c.escapePressed()
        #expect(c.phase == .idle)
        #expect(voice.calls.filter { $0 == .discard }.count == 2)
    }

    @Test func heldRecordingEscAlsoAsksWhenLong() async {
        voice.setLongSpeech(40)
        let c = make()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        voice.eventSink.yield(.autoStopped(held: true, message: nil))
        await waitFor { c.phase == .held }
        await c.escapePressed()
        #expect(c.phase == .held)
        await c.escapePressed()
        #expect(c.phase == .idle)
    }

    @Test func tapAfterDiscardConfirmationSendsTheHeldRecording() async {
        voice.setLongSpeech(45)
        let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Ok.", shape: .chip))])
        let c = make(bridge: bridge)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.escapePressed() // stops the mic, holds, asks
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await waitFor { bridge.asked.count == 1 }
        #expect(voice.calls.contains(.sendHeld))
        #expect(bridge.asked.count == 1)
    }

    @Test func revokedMicPermissionEndsTheListenWithALine() async {
        let c = make()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        voice.eventSink.yield(.autoStopped(held: false, message: "Microphone access is off. You can still type."))
        await waitFor { c.phase == .showing }
        #expect(answers.last == "Microphone access is off. You can still type.")
    }

    @Test func micFailureKeepsCapturedSpeech() async {
        let c = make()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        voice.eventSink.yield(.micProblem("The microphone stopped working."))
        voice.eventSink.yield(.autoStopped(held: true, message: "The microphone stopped working."))
        await waitFor { c.phase == .held }
        #expect(!voice.calls.contains(.discard))
        #expect(answers.last?.hasPrefix("The microphone stopped working. Tap") == true)
    }

    @Test func dismissedHeldChipComesBackBeforeAnythingIsSent() async {
        let bridge = FakeBridge()
        let c = make(bridge: bridge)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        voice.eventSink.yield(.autoStopped(held: true, message: nil))
        await waitFor { c.phase == .held }
        overlay.send(.dismissed(.clickAway))
        await waitFor { true }
        for _ in 0..<10 { await Task.yield() }

        await c.handle(.gesture(.pressBegan(fresh: false))) // re-shows the chip
        await c.handle(.gesture(.tap))        // ...and this tap only brought it back
        #expect(!voice.calls.contains(.sendHeld))
        #expect(answers.filter { $0.hasPrefix("I stopped listening.") }.count == 2)

        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))        // now it sends
        #expect(voice.calls.contains(.sendHeld))
    }

    @Test func typingDuringTapToTalkInterruptsAndKeeps() async {
        let c = make()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await c.handle(.gesture(.cancelled(.otherKey(14))))
        #expect(voice.calls.contains(.interrupt))
        #expect(!voice.calls.contains(.discard))
    }

    @Test func pressBeforeModelsLoadSaysStillSettingUp() async {
        voice.setStartError(VoicePortError("Still setting up voice."))
        let c = make()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        #expect(answers == ["Still setting up voice."])
    }

    // MARK: - LiveVoice mapping

    @Test func voiceErrorsBecomeTrueLines() {
        #expect((LiveVoice.portError(VoiceController.VoiceError.stillSettingUp) as? VoicePortError)?.message
            == "Still setting up voice.")
        #expect((LiveVoice.portError(VoiceController.VoiceError.recordingHeld) as? VoicePortError)?.message
            == "A recording is waiting. Tap to send it, or press Esc to discard.")
    }

    @Test func voiceEventsMapWithoutWords() {
        #expect(LiveVoice.map(.autoStopped(.silence, held: true)) == .autoStopped(held: true, message: nil))
        #expect(LiveVoice.map(.autoStopped(.silence, held: false)) == .autoStopped(held: false, message: nil))
        #expect(LiveVoice.map(.autoStopped(.micFailed, held: true))
            == .autoStopped(held: true, message: "The microphone stopped working."))
        #expect(LiveVoice.map(.autoStopped(.confirmingDiscard, held: true)) == nil)
        #expect(LiveVoice.map(.micProblem(.permissionDenied))
            == .autoStopped(held: false, message: "Microphone access is off. You can still type."))
        #expect(LiveVoice.map(.autoStopped(.micFailed, held: true), lastProblem: "The microphone isn't picking anything up.")
            == .autoStopped(held: true, message: "The microphone isn't picking anything up."))
        #expect(LiveVoice.map(.speakingFinished) == .speakingFinished)
        #expect(LiveVoice.map(.nearLimit) == .nearLimit)
        #expect(LiveVoice.map(.transcribing(long: false)) == .transcribing(long: false))
        #expect(LiveVoice.map(.transcribing(long: true)) == .transcribing(long: true))
    }
}
