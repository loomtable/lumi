import AVFoundation
import Foundation
import Speech
import Testing
@testable import BuddyVoice

/// The Mac's own speech recognition. Nothing here downloads or recognises anything: the analyzer
/// itself needs macOS's language files, so it's a manual check.
struct AppleSpeechTranscriberTests {
    @Test func theSpeechModelPicksTheTranscriber() {
        let store = ModelStore(root: URL(filePath: "/tmp/sb-models", directoryHint: .isDirectory))
        #expect(VoiceController.transcriber(for: .appleOnDevice, store: store) is AppleSpeechTranscriber)
        #expect(VoiceController.transcriber(for: .parakeetTDTv2, store: store) is ParakeetTranscriber)
        #expect(VoiceController.transcriber(for: .parakeetUnified, store: store) is ParakeetTranscriber)
        #expect(!SpeechModel.appleOnDevice.isParakeet && SpeechModel.default.isParakeet)
    }

    @Test func macOSAssetStatusReadsAsAvailability() {
        #expect(AppleSpeechTranscriber.availability(.installed) == .installed)
        #expect(AppleSpeechTranscriber.availability(.supported) == .needsLanguageFiles)
        #expect(AppleSpeechTranscriber.availability(.downloading) == .needsLanguageFiles)
        #expect(AppleSpeechTranscriber.availability(.unsupported) == .unsupported)
    }

    @Test func listeningBeforeLoadSaysStillSettingUp() async throws {
        let transcriber = AppleSpeechTranscriber()
        await #expect(throws: VoiceModelError.notLoaded) { try await transcriber.begin() }
        try? await transcriber.append([0.1, 0.2])  // dropped: nothing began
        #expect(try await transcriber.finish() == "")
        await transcriber.cancel()
    }

    @Test func samplesConvertToTheAnalyzerFormatWithoutLosingTime() throws {
        let samples = (0..<1600).map { Float(sin(Double($0) / 10)) * 0.5 }
        let float16k = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let same = try AppleSpeechTranscriber.convert(samples, to: float16k, using: nil)
        #expect(same.frameLength == 1600)

        let int16k = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let toInt = try #require(AVAudioConverter(from: float16k, to: int16k))
        let converted = try AppleSpeechTranscriber.convert(samples, to: int16k, using: toInt)
        #expect(converted.format.commonFormat == .pcmFormatInt16 && converted.frameLength == 1600)

        let float48k = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let up = try #require(AVAudioConverter(from: float16k, to: float48k))
        var frames: AVAudioFrameCount = 0
        for _ in 0..<5 { frames += try AppleSpeechTranscriber.convert(samples, to: float48k, using: up).frameLength }
        // Resampling holds a few frames back between chunks; over 0.5 s it stays within a few ms.
        #expect(abs(Int(frames) - 5 * 4800) < 480)
    }

    @Test func onlyAModelsOwnFilesCountAsDownloaded() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sb-downloaded-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelStore(root: root)
        #expect(!VoiceStorage.isDownloaded(.speechRecognition, store: store) && !VoiceStorage.isDownloaded(.lumiVoice, store: store))
        try FileManager.default.createDirectory(at: store.sileroVad, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: store.sileroVad.appending(path: "silero.bin"))
        #expect(!VoiceStorage.isDownloaded(.speechRecognition, store: store), "Silero alone isn't Parakeet")
        try FileManager.default.createDirectory(at: store.parakeetTDTv2, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: store.parakeetTDTv2.appending(path: "encoder.bin"))
        #expect(VoiceStorage.isDownloaded(.speechRecognition, store: store) && !VoiceStorage.isDownloaded(.lumiVoice, store: store))
    }
}
