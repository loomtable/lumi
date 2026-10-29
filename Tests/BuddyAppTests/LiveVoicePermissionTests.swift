@testable import BuddyApp
import BuddyVoice
import Foundation
import Testing

/// LiveVoice turns BuddyVoice's typed mic-permission problem into the port's `.permissionDenied`
/// (the coordinator only sees message strings otherwise), followed by the listen's end.
struct LiveVoicePermissionTests {
    @Test func aRevokedMicrophoneIsReportedAsPermissionDenied() async throws {
        let mic = FakeMic()
        let voice = LiveVoice(settings: VoiceSettings(soundsEnabled: false)) { settings in
            VoiceController(mic: mic, transcriber: FakeTranscriber(), detector: FakeSpeechDetector(),
                            speaker: FakeSpeaker(), sounds: FakeSoundPlayer(), clock: FakeClock(), tickInterval: nil,
                            soundsEnabled: settings.soundsEnabled)
        }
        try await voice.prepare()
        try await voice.startListening()
        _ = mic.send(.problem(.permissionDenied))
        // A deadline, so a broken mapping fails instead of hanging.
        let events = voice.events
        let collector = Task {
            var seen: [VoiceEvent] = []
            for await event in events {
                seen.append(event)
                if case .autoStopped = event { break }
            }
            return seen
        }
        let deadline = Task { try? await Task.sleep(for: waitCeiling); collector.cancel() }
        let seen = await collector.value
        deadline.cancel()
        let denied = seen.firstIndex(of: .permissionDenied)
        let ended = seen.firstIndex { if case .autoStopped = $0 { true } else { false } }
        #expect(denied != nil && ended != nil && denied! < ended!, "reported before the listen ends")
        #expect(seen.filter { $0 == .permissionDenied }.count == 1)
        #expect(seen.contains(.autoStopped(held: false, message: "Microphone access is off. You can still type.")))
    }
}
