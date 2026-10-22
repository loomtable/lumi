import BuddyVoice
import Foundation
import Testing
@testable import BuddyCompanion

@Suite("Settings › Voice")
@MainActor
struct VoicePaneTests {
    private func decode(_ json: String) throws -> VoicePreferences {
        try JSONDecoder().decode(VoicePreferences.self, from: Data(json.utf8))
    }

    @Test("Fresh installs use the Mac's recognition; a stored unknown model reads as Parakeet TDT v2")
    func speechModelDefault() throws {
        #expect(VoicePreferences().speechModel == .appleOnDevice)
        #expect(try decode(#"{"speechModel": "appleOnDevice"}"#).speechModel == .appleOnDevice)
        let p = try decode(#"{"speechModel": "whisper", "voiceReplies": "always"}"#)
        #expect(p.speechModel == .parakeetTDTv2)
        #expect(p.voiceReplies == .always, "other fields survive a bad one")
        #expect(p.voiceIsolation)
    }

    @Test("A value stored before the Oct 17 defaults keeps Parakeet and Kokoro")
    func oldValueLoads() throws {
        let p = try decode(#"{"voiceReplies": "off", "voiceIsolation": false}"#)
        #expect(p.voiceReplies == .off && !p.voiceIsolation)
        #expect(p.speechModel == .default && p.replyVoice == .onDevice, "stored settings never change under the user")
        let chosen = try decode(#"{"speechModel": "parakeetTDTv2", "replyVoice": {"kind": "onDevice"}, "setup": "voice"}"#)
        #expect(chosen.speechModel == .parakeetTDTv2 && chosen.replyVoice == .onDevice && chosen.setup == .voice)
    }

    @Test("Choosing Unified persists through the store")
    func persists() {
        let defaults = TestDefaults().defaults
        SettingsStore(defaults: defaults).voice.speechModel = .parakeetUnified
        #expect(SettingsStore(defaults: defaults).voice.speechModel == .parakeetUnified)
    }

    @Test("Only Unified is labelled experimental")
    func titles() {
        for model in SpeechModel.allCases {
            #expect(VoicePane.title(model).contains("experimental") == (model == .parakeetUnified))
        }
    }

    @Test("Setup status: start, retry and progress only from what BuddyVoice reported")
    func setupStatus() {
        typealias S = VoiceSetupRow
        let notStarted = S.status(.notStarted)
        #expect(notStarted.canStart && !notStarted.isWorking && !notStarted.isFailure)

        let ready = S.status(.ready)
        #expect(ready.label == "Ready" && !ready.canStart && !ready.isWorking)

        let failed = S.status(.failed("offline"))
        #expect(failed.canStart && failed.isFailure && failed.detail == "offline")

        let waiting = S.status(.preparing(.speechModel(nil)))
        #expect(waiting.isWorking && waiting.fraction == nil && !waiting.canStart)

        let downloading = S.status(.preparing(.speechModel(ModelLoadProgress(
            fraction: 0.4, phase: .downloading(completedFiles: 2, totalFiles: 5)))))
        #expect(downloading.fraction == 0.4 && downloading.detail == "2 of 5 files")

        let over = S.status(.preparing(.speechModel(ModelLoadProgress(
            fraction: 1.3, phase: .downloading(completedFiles: 5, totalFiles: 5)))))
        #expect(over.fraction == 1, "clamped for ProgressView")

        // FluidAudio: download is the first half of the load, compile the second. One bar spans both.
        let downloaded = S.status(.preparing(.speechModel(ModelLoadProgress(
            fraction: 0.5, phase: .downloading(completedFiles: 7, totalFiles: 7)))))
        #expect(downloaded.fraction == 0.5, "the raw whole-load fraction, not rescaled")
        let compiling = S.status(.preparing(.speechModel(ModelLoadProgress(fraction: 0.75, phase: .compiling))))
        #expect(compiling.isWorking && compiling.fraction == 0.75, "the bar keeps going while compiling")
        #expect(compiling.detail == nil, "no time estimate")

        for step in [VoiceController.PrepareStep.voiceActivity, .voice(nil), .microphone] {
            let s = S.status(.preparing(step))
            #expect(s.isWorking && s.fraction == nil && !s.canStart)
        }
        // The voice's download reports bytes, with no file total: the bar alone.
        let voice = S.status(.preparing(.voice(ModelLoadProgress(
            fraction: 0.3, phase: .downloading(completedFiles: 3, totalFiles: 0)))))
        #expect(voice.label == "Downloading the voice" && voice.fraction == 0.3 && voice.detail == nil)
    }

    @Test("Set Up Voice says what it downloads")
    func setUpSize() {
        let listening = VoicePane.size(VoiceDownloadSize.listening)
        let both = VoicePane.size(VoiceDownloadSize.listening + VoiceDownloadSize.lumiVoice)
        #expect(VoicePane.setUpSize(.onDevice).contains(both))
        #expect(VoicePane.setUpSize(.system).contains(listening))
        #expect(VoicePane.setUpSize(.elevenLabs(voiceID: "v")).contains(listening))
        let kokoro = VoicePane.size(VoiceDownloadSize.lumiVoice)
        #expect(VoicePane.setUpSize(.onDevice, speechModel: .appleOnDevice).contains(kokoro))
        #expect(!VoicePane.setUpSize(.system, speechModel: .appleOnDevice).contains("Downloads"),
                "the Mac's own hearing and voice: nothing for Lumi to download")
    }

    @Test("The speech-to-text picker lists the Mac's recognition first, with its own help")
    func macRecognitionEntry() {
        #expect(SpeechModel.allCases.first == .appleOnDevice)
        #expect(VoicePane.title(.appleOnDevice) == "Mac speech recognition")
        #expect(VoicePane.speechModelHelp(.appleOnDevice).contains("nothing for Lumi to download"))
        #expect(VoicePane.speechModelHelp(.parakeetTDTv2).contains(VoicePane.size(VoiceDownloadSize.listening)))
    }

    @Test("Only a part not in use can be removed, so removing never changes a setting or stops voice")
    func removableOnlyWhenNotInUse() {
        var v = VoicePreferences()
        v.setup = .voice
        #expect(!DownloadedModelRows.inUse(.speechRecognition, v) && !DownloadedModelRows.inUse(.lumiVoice, v),
                "the Mac's hearing and voice: both Parakeet and Kokoro can go")
        v.speechModel = .parakeetTDTv2
        v.replyVoice = .onDevice
        #expect(DownloadedModelRows.inUse(.speechRecognition, v) && DownloadedModelRows.inUse(.lumiVoice, v))
        v.speechModel = .parakeetUnified
        v.replyVoice = .elevenLabs(voiceID: "a")
        #expect(DownloadedModelRows.inUse(.speechRecognition, v) && !DownloadedModelRows.inUse(.lumiVoice, v))
    }

    @Test("Remove asks first and says what it frees")
    func removeCopy() {
        #expect(DownloadedModelRows.question(.speechRecognition) == "Remove the Parakeet listening model?")
        #expect(DownloadedModelRows.question(.lumiVoice) == "Remove the Kokoro voice?")
        #expect(DownloadedModelRows.consequence(.speechRecognition, size: "466 MB") == "Frees 466 MB. Choosing Parakeet again downloads it.")
        #expect(DownloadedModelRows.consequence(.lumiVoice, size: "437 MB").contains("Kokoro"))
        #expect(VoiceActions().removeModels == nil, "no Remove until the shell wires it")
    }

    @Test("Switching to a model that isn't on this Mac waits for its Download button")
    func switchingNeverDownloadsUnasked() {
        typealias P = VoicePane
        var v = VoicePreferences()
        v.setup = .voice
        let bare = P.OnMac()
        var (after, pending) = P.choose(speechModel: .parakeetTDTv2, in: v, onMac: bare)
        #expect(after == v && pending == .parakeetTDTv2, "the setting stays: nothing loads until Download")
        (after, pending) = P.choose(speechModel: .parakeetTDTv2, in: v, onMac: P.OnMac(speechModels: [.appleOnDevice, .parakeetTDTv2]))
        #expect(after.speechModel == .parakeetTDTv2 && pending == nil, "on this Mac: switches at once")
        (after, pending) = P.choose(speechModel: .appleOnDevice, in: after, onMac: bare)
        #expect(after.speechModel == .appleOnDevice && pending == nil, "the Mac's own: nothing to download")
        var notSetUp = v
        notSetUp.setup = .notChosen
        (after, pending) = P.choose(speechModel: .parakeetUnified, in: notSetUp, onMac: bare)
        #expect(after.speechModel == .parakeetUnified && pending == nil, "nothing loads before Set Up Voice")

        var (voice, waiting) = P.choose(replyVoice: .onDevice, in: v, onMac: bare)
        #expect(voice.replyVoice == .system && waiting == .onDevice, "Kokoro waits for its Download")
        (voice, waiting) = P.choose(replyVoice: .onDevice, in: v, onMac: P.OnMac(kokoro: true))
        #expect(voice.replyVoice == .onDevice && waiting == nil)
        (voice, waiting) = P.choose(replyVoice: .elevenLabs(voiceID: "a"), in: v, onMac: bare)
        #expect(voice.replyVoice == .elevenLabs(voiceID: "a") && waiting == nil)
    }

}
