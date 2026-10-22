import Foundation
import Testing
@testable import BuddyVoice

/// Only temporary folders: never the real models or FluidAudio's cache.
struct RemoveModelsTests {
    private struct Install {
        let root = FileManager.default.temporaryDirectory.appending(path: "RemoveModels-\(UUID().uuidString)", directoryHint: .isDirectory)
        var store: ModelStore { ModelStore(root: root.appending(path: "models", directoryHint: .isDirectory)) }
        var lexicon: URL { root.appending(path: "cache/fluidaudio/Models/kokoro", directoryHint: .isDirectory) }

        func fill() throws {
            for (folder, name, bytes) in [(store.parakeetTDTv2, "Encoder.bin", 300), (store.sileroVad, "vad.bin", 10),
                                          (store.kokoroV3English, "Vocoder.bin", 200), (lexicon, "us_lexicon.json", 40)] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(count: bytes).write(to: folder.appending(path: name))
            }
            try Data(count: 5).write(to: root.appending(path: "models/../conversations.sqlite"))
        }
        func bytes(_ part: VoiceModelPart) -> Int64 {
            DiskProgress(folders: VoiceStorage.folders(part, store: store, lexicon: lexicon), expectedBytes: 0).onDisk().bytes
        }
        func controller(mic: FakeMic = FakeMic()) -> VoiceController {
            VoiceController(mic: mic, transcriber: FakeTranscriber(result: "hi"), detector: FakeSpeechDetector(), speaker: FakeSpeaker(),
                            sounds: FakeSoundPlayer(), clock: FakeClock(0), tickInterval: nil, store: store, kokoroLexicon: lexicon)
        }
    }

    @Test func eachPartRemovesOnlyItsOwnFolders() async throws {
        let install = Install()
        defer { try? FileManager.default.removeItem(at: install.root) }
        try install.fill()
        #expect(install.bytes(.speechRecognition) == 300 && install.bytes(.lumiVoice) == 240)

        let voice = install.controller()
        try await voice.removeModels(.lumiVoice)
        #expect(install.bytes(.lumiVoice) == 0 && install.bytes(.speechRecognition) == 300)
        #expect(!FileManager.default.fileExists(atPath: install.lexicon.path))
        try await voice.removeModels(.lumiVoice)   // already gone: fine
        try await voice.removeModels(.speechRecognition)
        #expect(install.bytes(.speechRecognition) == 0)
        #expect(FileManager.default.fileExists(atPath: install.store.sileroVad.path),
                "voice detection stays: the Mac's own hearing needs it too")
        #expect(FileManager.default.fileExists(atPath: install.root.appending(path: "conversations.sqlite").path),
                "nothing outside the model folders")
        #expect(FileManager.default.fileExists(atPath: install.store.root.path), "the models folder itself stays")
    }

    @Test func neverWhileVoiceIsLoadingOrListening() async throws {
        let install = Install()
        defer { try? FileManager.default.removeItem(at: install.root) }
        try install.fill()
        let mic = FakeMic()
        let voice = install.controller(mic: mic)
        mic.prepareGate.close()
        let preparing = Task { try await voice.prepare() }
        while await voice.prepareState != .preparing(.microphone) { try await Task.sleep(for: .milliseconds(2)) }
        await #expect(throws: VoiceController.VoiceError.busy) { try await voice.removeModels(.speechRecognition) }
        mic.prepareGate.open()
        try await preparing.value

        try await voice.startListening()
        await #expect(throws: VoiceController.VoiceError.busy) { try await voice.removeModels(.speechRecognition) }
        _ = await voice.discard(confirmed: true, playSound: false)
        #expect(install.bytes(.speechRecognition) == 300, "a refused removal deletes nothing")
        try await voice.removeModels(.speechRecognition)
        #expect(install.bytes(.speechRecognition) == 0)
    }

    @Test func aControllerWithoutModelFoldersDeletesNothing() async throws {
        let voice = VoiceController(mic: FakeMic(), transcriber: FakeTranscriber(result: ""), detector: FakeSpeechDetector(),
                                    speaker: FakeSpeaker(), sounds: FakeSoundPlayer(), clock: FakeClock(0), tickInterval: nil)
        try await voice.removeModels(.lumiVoice)   // no folders given: a no-op, never the real ones
    }

    /// The files FluidAudio 0.17.7 checks for Parakeet TDT v2 (`AsrModels.modelsExist`, version .v2).
    private static func fakeParakeet(at folder: URL, skipping: String? = nil) throws {
        for name in ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc"] where name != skipping {
            try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
            try Data(count: 50).write(to: folder.appending(path: "\(name)/coremldata.bin"))
        }
        if skipping != "parakeet_vocab.json" { try Data(count: 5).write(to: folder.appending(path: "parakeet_vocab.json")) }
    }

    @Test func parakeetAnotherAppLeftInFluidAudiosFolderIsCopiedInNotDownloaded() throws {
        let install = Install()
        defer { try? FileManager.default.removeItem(at: install.root) }
        let shared = install.root.appending(path: "FluidAudio/Models/parakeet-tdt-0.6b-v2", directoryHint: .isDirectory)
        #expect(!VoiceStorage.isDownloaded(.parakeetTDTv2, store: install.store, shared: shared))
        #expect(!VoiceStorage.adoptParakeetTDTv2(into: install.store, from: shared), "nothing there: the load downloads")

        try Self.fakeParakeet(at: shared, skipping: "parakeet_vocab.json")
        #expect(!VoiceStorage.isDownloaded(.parakeetTDTv2, store: install.store, shared: shared), "a partial copy doesn't count")
        #expect(!VoiceStorage.adoptParakeetTDTv2(into: install.store, from: shared))

        try Data(count: 5).write(to: shared.appending(path: "parakeet_vocab.json"))
        #expect(VoiceStorage.isDownloaded(.parakeetTDTv2, store: install.store, shared: shared), "offered as on this Mac")
        #expect(VoiceStorage.adoptParakeetTDTv2(into: install.store, from: shared))
        #expect(VoiceStorage.hasParakeetTDTv2(at: install.store.parakeetTDTv2))
        #expect(FileManager.default.fileExists(atPath: shared.appending(path: "Encoder.mlmodelc").path), "the other app's copy is untouched")
        #expect(!VoiceStorage.adoptParakeetTDTv2(into: install.store, from: shared), "Lumi has its own now")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: install.store.asrBase.path)
        #expect(leftovers == ["parakeet-tdt-0.6b-v2"], "no staging folder left behind")
        #expect(VoiceStorage.isDownloaded(.appleOnDevice, store: install.store, shared: shared))
        #expect(!VoiceStorage.isDownloaded(.parakeetUnified, store: install.store, shared: shared))
    }

    @Test func sizesReadZeroWhenNothingIsDownloaded() {
        let settings = VoiceSettings(modelsDirectory: FileManager.default.temporaryDirectory.appending(path: "none-\(UUID().uuidString)"))
        #expect(VoiceStorage.bytesOnDisk(.speechRecognition, settings: settings) == 0)
    }
}
