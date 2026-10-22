import BuddyCore
import Foundation

// The seams of BuddyVoice. Each sensor or effect has a real implementation and a fake (Fakes/), and
// `VoiceController` only talks to these protocols.
//
// Privacy rule: words the user speaks never leave this module except as the final transcript returned
// by `VoiceController.finishListening()`. There is no partial-transcript stream.

/// 16 kHz mono Float32 samples straight from the mic, in capture order.
public struct AudioChunk: Sendable, Equatable {
    public static let sampleRate: Double = 16_000

    public var samples: [Float]
    /// `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` when the chunk was captured.
    public var capturedAt: UInt64

    public init(samples: [Float], capturedAt: UInt64) {
        self.samples = samples
        self.capturedAt = capturedAt
    }

    public var duration: Double { Double(samples.count) / Self.sampleRate }
}

/// Something wrong with the input that the UI should explain ("Mic denied").
public enum MicProblem: Sendable, Equatable {
    /// Microphone permission is missing or was revoked. Capture then delivers exact zeros with no error.
    case permissionDenied
    /// Audio keeps arriving but every sample is zero, with permission granted.
    case silentInput
    /// The engine could not start or recover after a device or format change.
    case engineFailed(String)
}

public enum MicEvent: Sendable, Equatable {
    case audio(AudioChunk)
    /// The engine was rebuilt after a device, sample-rate or default-input change. Audio continues.
    case rebuilt
    case problem(MicProblem)
}

/// Mic capture: 16 kHz mono. With voice processing, first real audio about 450 ms after `start()`
/// (VP is switched on per listen so other apps aren't ducked at idle); without it, under 100 ms.
public protocol MicCapture: AnyObject, Sendable {
    /// Builds the engine (prepared only when voice processing is off). Doesn't run the mic hardware (no
    /// privacy indicator) and doesn't duck other apps' audio.
    func prepare() async throws
    /// Starts capture. The stream ends when `stop()` is called. A missing or revoked mic permission is
    /// reported as `.problem(.permissionDenied)` followed by the end of the stream, not as a throw.
    func start() async throws -> AsyncStream<MicEvent>
    /// Returns once the capture has real (non-zero) audio, or it stopped, or a short cap passed, so the
    /// "listening" cue that follows is honest. Never call it while holding anything `stop()` needs.
    func untilLive() async
    func stop() async
    /// Settings › Voice Isolation. Takes effect on the next `start()`; no app restart.
    func setVoiceProcessing(_ enabled: Bool) async throws
}

extension MicCapture {
    /// Live as soon as `start()` returns.
    public func untilLive() async {}
}

/// Real progress from the model downloader, for the setup chip. Never estimated:
/// `fraction` is what the downloader reports.
public struct ModelLoadProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case listing
        case downloading(completedFiles: Int, totalFiles: Int)
        case compiling
    }

    public var fraction: Double
    public var phase: Phase

    public init(fraction: Double, phase: Phase) {
        self.fraction = fraction
        self.phase = phase
    }
}

/// Speech-to-text for one utterance at a time. Partials stay inside the implementation.
public protocol SpeechTranscriber: AnyObject, Sendable {
    /// Loads (and on first run downloads and compiles) the model, reporting real progress. Safe to
    /// call again after a failure.
    func load(progress: @escaping @Sendable (ModelLoadProgress) -> Void) async throws
    func begin() async throws
    func append(_ samples: [Float]) async throws
    /// Flushes the tail and returns the final transcript. About 30 ms after the last sample (S5).
    func finish() async throws -> String
    func cancel() async
}

public enum SpeechActivity: Sendable, Equatable {
    case started
    case ended
}

extension SpeechTranscriber {
    public func load() async throws { try await load(progress: { _ in }) }
}

/// Voice activity detection. Used only for the silence safeguard, never to decide when to send (S5).
public protocol SpeechActivityDetector: AnyObject, Sendable {
    func load() async throws
    func reset() async
    /// Feeds 16 kHz samples; returns a transition when one happened inside them.
    func process(_ samples: [Float]) async throws -> SpeechActivity?
}

/// Text-to-speech output.
public protocol SpeechSpeaker: AnyObject, Sendable {
    /// Loads the voice and runs a throwaway synthesis so the first real reply is fast.
    func warmUp() async
    /// Starts speaking. The stream yields the reply's RMS level (0…1) about every 20 ms and finishes
    /// when playback ends or `stop()` is called.
    func speak(_ text: String) async throws -> AsyncStream<Float>
    /// Speaks `text` after the reply in flight, on the same level stream, instead of cutting it.
    /// Returns false when there's no reply to continue (it played out, was stopped, or this voice
    /// can't append); the caller then speaks it as a new reply.
    func continueReply(_ text: String) async -> Bool
    /// Silences playback within 150 ms.
    func stop() async
}

public extension SpeechSpeaker {
    /// A voice that can't append to a reply always starts a new one.
    func continueReply(_ text: String) async -> Bool { false }
}

/// The four interface sounds.
public enum BuddySound: String, Sendable, CaseIterable {
    case summon, ready, discard, researchDone

    /// Sine notes as (frequency in Hz, duration in seconds), played back to back at gain 0.05.
    public var notes: [(hz: Double, seconds: Double)] {
        switch self {
        case .summon: [(523, 0.070), (784, 0.070)]
        case .ready: [(1046, 0.060)]
        case .discard: [(330, 0.090)]
        case .researchDone: [(659, 0.090), (988, 0.090)]
        }
    }

    public static let gain: Float = 0.05
}

public protocol SoundPlayer: AnyObject, Sendable {
    func play(_ sound: BuddySound) async
}

/// Which speech-to-text model to run (Settings › Voice).
public enum SpeechModel: String, Sendable, CaseIterable, Codable {
    /// macOS's own on-device speech recognition (`AppleSpeechTranscriber`): no Parakeet download.
    /// Fresh installs start here; Parakeet is the downloadable upgrade.
    case appleOnDevice
    /// Parakeet Unified EN 0.6B, streaming. NVIDIA Open Model License.
    case parakeetUnified
    /// Parakeet TDT 0.6B v2, batch on finish. CC-BY-4.0.
    case parakeetTDTv2

    /// The Parakeet model to download. Decided after S5: TDT v2. It finalises faster than
    /// Unified at every length (about 50 ms for 8 s, 280 ms for 2 min) with the same accuracy, and
    /// partials are never shown anyway. Also what a stored setting from before `appleOnDevice` reads as.
    public static let `default`: SpeechModel = .parakeetTDTv2

    public var isParakeet: Bool { self != .appleOnDevice }
}

public struct VoiceSettings: Sendable, Equatable {
    /// Settings › Voice Isolation: on (default) uses it when needed, i.e. when another app is playing
    /// audio at the press; off never uses it. Every other capture is plain, so the first word is kept.
    public var voiceProcessing: Bool
    /// Settings › Sounds. Off silences every sound BuddyVoice plays.
    public var soundsEnabled: Bool
    public var speechModel: SpeechModel
    public var kokoroVoice: String
    /// Which voice speaks replies: on-device (Kokoro) by default, the Mac's voice, or ElevenLabs.
    public var replyVoice: ReplyVoice
    /// The user picked a voice setup (onboarding's voice step). Until then `prepare()` only readies the
    /// mic and downloads nothing, and listening throws `VoiceError.notSetUp`.
    public var setupChosen: Bool
    /// Where FluidAudio keeps every model. One folder we own, not the library's two defaults.
    public var modelsDirectory: URL

    public init(
        voiceProcessing: Bool = true,
        soundsEnabled: Bool = true,
        speechModel: SpeechModel = .default,
        kokoroVoice: String = "af_heart",
        replyVoice: ReplyVoice = .onDevice,
        setupChosen: Bool = true,
        modelsDirectory: URL = VoiceSettings.defaultModelsDirectory
    ) {
        self.voiceProcessing = voiceProcessing
        self.soundsEnabled = soundsEnabled
        self.speechModel = speechModel
        self.kokoroVoice = kokoroVoice
        self.replyVoice = replyVoice
        self.setupChosen = setupChosen
        self.modelsDirectory = modelsDirectory
    }

    /// `~/Library/Application Support/com.loomtable.lumi/models`
    public static var defaultModelsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "\(BuddyCore.folderName)/models", directoryHint: .isDirectory)
    }
}

/// What each voice setup downloads, in bytes (measured with FluidAudio 0.17.7), for the setup step's copy.
public enum VoiceDownloadSize {
    /// Parakeet TDT v2 (464 MB) and Silero (1 MB): needed for listening.
    public static let listening: Int64 = 466_000_000
    /// Kokoro (394 MB) and its G2P cache in `~/.cache/fluidaudio` (43 MB): only for the Lumi voice.
    public static let lumiVoice: Int64 = 437_000_000
}

/// Monotonic time source, so safeguards and meters can be tested without waiting.
public protocol VoiceClock: Sendable {
    /// Seconds on a monotonic clock.
    func now() -> Double
}

public struct SystemVoiceClock: VoiceClock {
    public init() {}
    public func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
}

/// Which voice speaks replies (Settings › Voice, onboarding). Stored as-is in preferences, so decoding
/// is lenient: anything unknown, or ElevenLabs without a voice, reads as on-device.
public enum ReplyVoice: Sendable, Equatable, Codable {
    /// Kokoro, downloaded on first use.
    case onDevice
    /// The Mac's own voice (AVSpeechSynthesizer): no download.
    case system
    case elevenLabs(voiceID: String)

    private enum Keys: String, CodingKey { case kind, voiceID }

    public init(from decoder: any Decoder) throws {
        let c = try? decoder.container(keyedBy: Keys.self)
        let kind = (try? c?.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        let voiceID = ((try? c?.decodeIfPresent(String.self, forKey: .voiceID)) ?? nil)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        self = switch kind {
        case "elevenLabs" where !voiceID.isEmpty: .elevenLabs(voiceID: voiceID)
        case "system": .system
        default: .onDevice
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .onDevice:
            try c.encode("onDevice", forKey: .kind)
        case .system:
            try c.encode("system", forKey: .kind)
        case .elevenLabs(let voiceID):
            try c.encode("elevenLabs", forKey: .kind)
            try c.encode(voiceID, forKey: .voiceID)
        }
    }
}
