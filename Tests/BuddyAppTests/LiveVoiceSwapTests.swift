@testable import BuddyApp
import BuddyCompanion
import BuddyVoice
import Foundation
import Synchronization
import Testing

/// Settings › Voice: a new speech model swaps the controller under the same streams.
struct LiveVoiceSwapTests {
    final class Built: Sendable {
        let settings = Mutex<[VoiceSettings]>([])
        let controllers = Mutex<[VoiceController]>([])
    }

    private static func fakeController(_ settings: VoiceSettings) -> VoiceController {
        VoiceController(mic: FakeMic(), transcriber: FakeTranscriber(), detector: FakeSpeechDetector(),
                        speaker: FakeSpeaker(), sounds: FakeSoundPlayer(), clock: FakeClock(), tickInterval: nil,
                        soundsEnabled: settings.soundsEnabled)
    }

    private func voice(_ built: Built) -> LiveVoice {
        LiveVoice(settings: VoiceSettings(voiceProcessing: false, soundsEnabled: false)) { settings in
            let c = Self.fakeController(settings)
            built.settings.withLock { $0.append(settings) }
            built.controllers.withLock { $0.append(c) }
            return c
        }
    }

    @Test func aNewSpeechModelBuildsAndPreparesANewControllerKeepingTheOtherSettings() async throws {
        let built = Built()
        let voice = voice(built)
        var states = voice.prepareStates.makeAsyncIterator()
        try await voice.prepare()
        #expect(await states.next() == .preparing(.speechModel(nil)), "the first controller's steps come through")

        await voice.setSpeechModel(.parakeetUnified)
        let settings = built.settings.withLock { $0 }
        #expect(settings.count == 2)
        #expect(settings.last?.speechModel == .parakeetUnified)
        #expect(settings.last?.voiceProcessing == false && settings.last?.soundsEnabled == false, "nothing else changes")
        let second = built.controllers.withLock { $0[1] }
        var prepared = false
        for _ in 0..<200 where !prepared {
            prepared = await second.prepareState == .ready
            if !prepared { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(prepared, "the new model prepares in the background")

        await voice.setSpeechModel(.parakeetUnified)
        #expect(built.settings.withLock { $0.count } == 2, "the model in use isn't rebuilt")
    }

    @Test func prepareProgressFromTheNewControllerReachesThePane() async throws {
        let built = Built()
        let voice = voice(built)
        try await voice.prepare()
        await voice.setSpeechModel(.parakeetUnified)
        var seen: [VoiceController.PrepareState] = []
        for await state in voice.prepareStates {
            seen.append(state)
            if seen.filter({ $0 == .ready }).count == 2 { break }
        }
        #expect(seen.first == .preparing(.speechModel(nil)) && seen.last == .ready)
        #expect(seen.filter { $0 == .preparing(.speechModel(nil)) }.count == 2, "both controllers' preparation is shown")
    }

    @Test func voiceIsolationIsRememberedForTheNextController() async throws {
        let built = Built()
        let voice = voice(built)
        try await voice.setVoiceProcessing(true)
        await voice.setSpeechModel(.parakeetUnified)
        #expect(built.settings.withLock { $0.last?.voiceProcessing } == true)
    }

    @Test func aSwapDuringAListenEndsItWithATrueLine() async throws {
        let built = Built()
        let voice = voice(built)
        try await voice.prepare()
        try await voice.startListening()
        await voice.setSpeechModel(.parakeetUnified)
        var ended: VoiceEvent?
        for await event in voice.events {
            if case .autoStopped = event { ended = event; break }
        }
        #expect(ended == .autoStopped(held: false, message: LiveVoice.speechModelChanged))
        await #expect(throws: (any Error).self, "the old listen is over; the new controller isn't listening") {
            _ = try await voice.finishListening()
        }
    }

    @Test func removingModelsReachesTheControllerInUseAndRefusesWhileItListens() async throws {
        let built = Built()
        let voice = voice(built)
        try await voice.prepare()
        try await voice.removeModels(.lumiVoice)            // idle: nothing to wait for
        await voice.setSpeechModel(.parakeetUnified)
        let second = built.controllers.withLock { $0[1] }
        for _ in 0..<200 where await second.prepareState != .ready { try? await Task.sleep(for: .milliseconds(5)) }
        try await voice.startListening()
        await #expect(throws: VoiceController.VoiceError.busy) { try await voice.removeModels(.speechRecognition) }
        _ = await voice.discard(confirmed: true, playSound: false)
    }

    @Test func settingsGetsEveryVoiceActionIncludingRemove() async throws {
        let built = Built()
        let voice = voice(built)
        let actions = await MainActor.run { voice.actions { .system } }
        #expect(actions.prepare != nil && actions.elevenLabsKeyChanged != nil)
        let remove = try #require(actions.removeModels, "nil hides Remove")
        try await voice.startListening()
        await #expect(throws: VoiceController.VoiceError.busy) { try await remove(.lumiVoice) }
        _ = await voice.discard(confirmed: true, playSound: false)
    }

    @Test func removingModelsWaitsForAReplacedControllersDownload() async throws {
        let mics = Mutex<[FakeMic]>([])
        let voice = LiveVoice(settings: VoiceSettings(voiceProcessing: false, soundsEnabled: false)) { settings in
            let mic = FakeMic()
            mics.withLock { $0.append(mic) }
            return VoiceController(mic: mic, transcriber: FakeTranscriber(), detector: FakeSpeechDetector(),
                                   speaker: FakeSpeaker(), sounds: FakeSoundPlayer(), clock: FakeClock(), tickInterval: nil,
                                   soundsEnabled: false)
        }
        let first = mics.withLock { $0[0] }
        first.prepareGate.close()
        let launch = Task { try? await voice.prepare() }   // the first controller, still preparing
        for _ in 0..<100 { await Task.yield() }
        await voice.setSpeechModel(.parakeetUnified)        // swapped: the new one may be idle
        await #expect(throws: VoiceController.VoiceError.busy) { try await voice.removeModels(.lumiVoice) }
        first.prepareGate.open()
        await launch.value
        for _ in 0..<400 {
            if (try? await voice.removeModels(.lumiVoice)) != nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Remove never became possible once the downloads ended")
    }
}
