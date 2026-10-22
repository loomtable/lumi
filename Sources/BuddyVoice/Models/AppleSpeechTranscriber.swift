import AVFoundation
import Foundation
import Speech

/// Speech-to-text with macOS's own on-device recognition (`SpeechAnalyzer`, macOS 26), US English.
/// There is no model for Lumi to download. macOS keeps the language files (`AssetInventory`), and
/// when they aren't on this Mac yet, `load()` asks macOS to add them. `load()` only runs once the user
/// has chosen to set up voice (nothing downloads unasked).
///
/// One analyzer per utterance. `begin()` returns at once, so the mic isn't held up, and hands the
/// utterance to an analyzer prepared in the background after the last one. `append` feeds converted
/// audio as the user speaks, and `finish()` ends the input and returns the finalised text.
public actor AppleSpeechTranscriber: BuddyVoice.SpeechTranscriber {
    public enum Availability: Sendable, Equatable {
        /// The language files are on this Mac: nothing to add.
        case installed
        /// macOS can add the language files (on the user's click, through `load()`).
        case needsLanguageFiles
        /// No on-device US English recognition on this Mac.
        case unsupported
    }

    public enum AppleSpeechError: Error, Equatable, LocalizedError {
        case unsupported

        public var errorDescription: String? {
            "This Mac's speech recognition doesn't support US English. Choose Parakeet in Settings › Voice."
        }
    }

    public static let locale = Locale(identifier: "en-US")

    /// Without prompting or downloading: whether the Mac's speech recognition is ready for US English.
    public static func availability() async -> Availability {
        guard Speech.SpeechTranscriber.isAvailable,
              let locale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: Self.locale)
        else { return .unsupported }
        let status = await AssetInventory.status(forModules: [Self.module(locale)])
        return availability(status)
    }

    static func availability(_ status: AssetInventory.Status) -> Availability {
        switch status {
        case .installed: .installed
        case .supported, .downloading: .needsLanguageFiles
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    private struct Prepared: Sendable {
        let analyzer: SpeechAnalyzer
        let module: Speech.SpeechTranscriber
    }

    private struct Utterance {
        let session: Int
        let input: AsyncStream<AnalyzerInput>.Continuation
        let started: Task<SpeechAnalyzer, any Error>
        let text: Task<String, any Error>
    }

    private var locale: Locale?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var spare: Task<Prepared, any Error>?
    private var utterance: Utterance?
    private var session = 0

    public init() {}

    public func load(progress: @escaping @Sendable (ModelLoadProgress) -> Void) async throws {
        guard locale == nil else { return }
        guard Speech.SpeechTranscriber.isAvailable,
              let locale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: Self.locale)
        else { throw AppleSpeechError.unsupported }
        let module = Self.module(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            // macOS's own download; its Progress is polled, since nothing else reports it.
            let poll = Task {
                while !Task.isCancelled {
                    progress(ModelLoadProgress(fraction: request.progress.fractionCompleted,
                                               phase: .downloading(completedFiles: 0, totalFiles: 0)))
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { poll.cancel() }
            try await request.downloadAndInstall()
        }
        guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw VoiceModelError.badAudioFormat
        }
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate,
                                         channels: 1, interleaved: false)
        else { throw VoiceModelError.badAudioFormat }
        format = best
        converter = source == best ? nil : AVAudioConverter(from: source, to: best)
        self.locale = locale
        spare = Self.prepare(locale: locale, format: best)
    }

    /// Throws `VoiceModelError.notLoaded` until `load()` has finished ("Still setting up voice").
    public func begin() async throws {
        session += 1
        endUtterance()
        guard let locale, let format else { throw VoiceModelError.notLoaded }
        let prepared = spare ?? Self.prepare(locale: locale, format: format)
        spare = nil
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let started = Task {
            let ready = try await prepared.value
            try await ready.analyzer.start(inputSequence: stream)
            return ready.analyzer
        }
        let text = Task {
            let module = try await prepared.value.module
            var text = ""
            for try await result in module.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        utterance = Utterance(session: session, input: input, started: started, text: text)
    }

    public func append(_ samples: [Float]) async throws {
        guard !samples.isEmpty, let utterance, utterance.session == session, let format else { return }
        utterance.input.yield(AnalyzerInput(buffer: try Self.convert(samples, to: format, using: converter)))
    }

    public func finish() async throws -> String {
        guard let current = utterance, current.session == session else { return "" }
        utterance = nil
        current.input.finish()
        defer { prepareNext() }
        do {
            let analyzer = try await current.started.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            current.text.cancel()
            throw error
        }
        return try await current.text.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancel() async {
        session += 1
        endUtterance()
    }

    /// Stops the utterance in flight, if any, without waiting for its text.
    private func endUtterance() {
        guard let current = utterance else { return }
        utterance = nil
        current.input.finish()
        current.text.cancel()
        Task { await (try? current.started.value)?.cancelAndFinishNow() }
        prepareNext()
    }

    private func prepareNext() {
        guard spare == nil, let locale, let format else { return }
        spare = Self.prepare(locale: locale, format: format)
    }

    /// A new analyzer with its model loaded, so the next question starts warm.
    private static func prepare(locale: Locale, format: AVAudioFormat) -> Task<Prepared, any Error> {
        Task {
            let module = Self.module(locale)
            let analyzer = SpeechAnalyzer(modules: [module])
            try await analyzer.prepareToAnalyze(in: format)
            return Prepared(analyzer: analyzer, module: module)
        }
    }

    private static func module(_ locale: Locale) -> Speech.SpeechTranscriber {
        Speech.SpeechTranscriber(locale: locale, preset: .transcription)
    }

    /// 16 kHz mono Float32 samples in the analyzer's format. The converter keeps its state between
    /// calls, so a resampled stream has no seams.
    static func convert(_ samples: [Float], to format: AVAudioFormat, using converter: AVAudioConverter?) throws -> AVAudioPCMBuffer {
        let input = try ParakeetTranscriber.buffer(samples)
        guard let converter else { return input }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw VoiceModelError.badAudioFormat
        }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error || error != nil { throw VoiceModelError.badAudioFormat }
        return output
    }
}
