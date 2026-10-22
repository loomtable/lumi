@testable import BuddyApp
import BuddyVoice
import Foundation
import Synchronization
import Testing

/// Onboarding's voice choice reaching the voice stack: nothing downloads before it, the choice
/// starts the download, and a mic-only "ready" never stands in for it.
struct VoiceSetupWiringTests {
    final class Built: Sendable {
        let settings = Mutex<[VoiceSettings]>([])
        let controllers = Mutex<[VoiceController]>([])
    }

    private func voice(_ built: Built, chosen: Bool) -> (LiveVoice, VoiceSettings) {
        let initial = VoiceSettings(voiceProcessing: false, soundsEnabled: false, setupChosen: chosen)
        let voice = LiveVoice(settings: initial) { settings in
            let c = VoiceController(mic: FakeMic(), transcriber: FakeTranscriber(), detector: FakeSpeechDetector(),
                                    speaker: FakeSpeaker(), sounds: FakeSoundPlayer(), clock: FakeClock(), tickInterval: nil,
                                    soundsEnabled: false, setupChosen: settings.setupChosen)
            built.settings.withLock { $0.append(settings) }
            built.controllers.withLock { $0.append(c) }
            return c
        }
        return (voice, initial)
    }

    @Test func beforeAChoiceOnlyTheMicIsReadiedAndListeningSaysHowToSetUp() async throws {
        let built = Built()
        let (voice, _) = voice(built, chosen: false)
        var states = voice.prepareStates.makeAsyncIterator()
        try await voice.prepare()
        #expect(await states.next() == .preparing(.microphone), "no model step: nothing downloads")
        await #expect(throws: VoicePortError("Voice isn't set up.", notSetUp: true)) { try await voice.startListening() }
    }

    @Test(.timeLimit(.minutes(1))) func theChoiceStartsTheDownloadAndNoMicOnlyReadyLingers() async throws {
        let built = Built()
        let (voice, applied) = voice(built, chosen: false)
        try await voice.prepare()
        var states = voice.prepareStates.makeAsyncIterator()
        _ = await states.next() // mic
        _ = await states.next() // ready (mic only)
        var wanted = applied
        wanted.setupChosen = true
        await voice.apply(wanted, over: applied)
        var seen: [VoiceController.PrepareState] = []
        while let state = await states.next() {
            seen.append(state)
            if state == .ready { break }
        }
        #expect(seen.first == .notStarted, "the choice drops the mic-only ready at once")
        #expect(seen.contains(.preparing(.speechModel(nil))), "then the models load")
    }

    @Test func aRebuiltControllerKeepsTheChoice() async {
        let built = Built()
        let (voice, applied) = voice(built, chosen: false)
        var wanted = applied
        wanted.setupChosen = true
        await voice.apply(wanted, over: applied)
        await voice.setSpeechModel(.parakeetUnified)
        #expect(built.settings.withLock { $0.last?.setupChosen } == true)
    }

    @Test func nothingChangedPreparesNothing() async {
        let built = Built()
        let (voice, applied) = voice(built, chosen: false)
        await voice.apply(applied, over: applied)
        for _ in 0..<50 { await Task.yield() }
        #expect(await built.controllers.withLock { $0[0] }.prepareState == .notStarted)
    }
}
