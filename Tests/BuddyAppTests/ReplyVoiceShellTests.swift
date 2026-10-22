@testable import BuddyApp
import BuddyCompanion
import BuddyConversations
import BuddyOverlay
import BuddyVoice
import Foundation
import Synchronization
import Testing

struct ReplyVoiceShellTests {
    @Test func theReplyVoiceSurvivesASpeechModelSwap() async {
        let built = Mutex<[VoiceSettings]>([])
        let voice = LiveVoice(settings: VoiceSettings(soundsEnabled: false)) { settings in
            built.withLock { $0.append(settings) }
            return VoiceController(mic: FakeMic(), transcriber: FakeTranscriber(), detector: FakeSpeechDetector(),
                                   speaker: FakeSpeaker(), sounds: FakeSoundPlayer(), clock: FakeClock(), tickInterval: nil,
                                   soundsEnabled: settings.soundsEnabled)
        }
        await voice.setReplyVoice(.elevenLabs(voiceID: "rachel"))
        await voice.setSpeechModel(.parakeetUnified)
        #expect(built.withLock { $0.last?.replyVoice } == .elevenLabs(voiceID: "rachel"))
        // The old controller's problem line can't be cleared by the new one, so the swap clears it.
        var problems = voice.replyVoiceProblems.makeAsyncIterator()
        let first = await problems.next()
        #expect(first == .some(nil), "the swap ends any reply-voice line")
    }

    @MainActor
    @Test func oneTrueReplyVoiceLineThatClears() {
        let runtime = AppRuntime(voice: UnavailableVoice(), conversationIndex: { try ConversationIndex(url: nil) },
                                 overlay: { FakeOverlay() },
                                 traceDirectory: FileManager.default.temporaryDirectory.appending(path: "t-\(UUID().uuidString)"))
        runtime.setReplyVoiceProblem("ElevenLabs couldn't be reached; using the on-device voice.")
        #expect(runtime.problems.map(\.text) == ["ElevenLabs couldn't be reached; using the on-device voice."])
        #expect(runtime.problems.first?.fix == .voice)
        runtime.setReplyVoiceProblem("ElevenLabs rejected the API key; using the on-device voice.")
        #expect(runtime.problems.map(\.text) == ["ElevenLabs rejected the API key; using the on-device voice."], "replaced, not stacked")
        runtime.setReplyVoiceProblem(nil)
        #expect(runtime.problems.isEmpty, "recovered: nothing stale left")
    }
}
