import Foundation

/// Where each FluidAudio model lives under `VoiceSettings.modelsDirectory`
/// (`~/Library/Application Support/<bundle id>/models`), so models don't land in FluidAudio's
/// default `Application Support/FluidAudio` folder.
///
/// One path can't be redirected: Kokoro's English G2P assets and lexicon always go to
/// `~/.cache/fluidaudio/Models/kokoro`, because FluidAudio's `G2PModel.shared` singleton hardcodes
/// that path (KokoroAneManager.prepareEnglishFrontend, FluidAudio 0.17.7). About 41 MB.
public struct ModelStore: Sendable, Equatable {
    public let root: URL

    public init(root: URL = VoiceSettings.defaultModelsDirectory) {
        self.root = root
    }

    public init(settings: VoiceSettings) {
        self.init(root: settings.modelsDirectory)
    }

    /// Base passed to `StreamingUnifiedAsrManager.loadModels(to:)`; FluidAudio adds
    /// `parakeet-unified-en-0.6b/` under it.
    public var asrBase: URL { root.appending(path: "asr", directoryHint: .isDirectory) }

    /// The Unified model folder FluidAudio creates under `asrBase`.
    public var parakeetUnified: URL { asrBase.appending(path: "parakeet-unified-en-0.6b", directoryHint: .isDirectory) }

    /// Exact target for `AsrModels.download(to:version: .v2)`; FluidAudio uses it as is.
    public var parakeetTDTv2: URL { asrBase.appending(path: "parakeet-tdt-0.6b-v2", directoryHint: .isDirectory) }

    /// Base passed to `VadManager(modelDirectory:)`; FluidAudio adds `Models/silero-vad/` under it.
    public var vadBase: URL { root.appending(path: "vad", directoryHint: .isDirectory) }

    /// The Silero folder FluidAudio creates under `vadBase`.
    public var sileroVad: URL { vadBase.appending(path: "Models/silero-vad", directoryHint: .isDirectory) }

    /// Root passed to `KokoroAneManager(directory:)`; FluidAudio adds
    /// `kokoro-82m-coreml/ANE-v3/<revision>/en/` under it.
    public var kokoroBase: URL { root.appending(path: "tts", directoryHint: .isDirectory) }

    /// The Kokoro ANE-v3 revision FluidAudio 0.17.7 pins (`KokoroAneV3Assets.revision`, internal there).
    /// `KokoroPinTests` fails if a FluidAudio update moves it, so this can't silently point at old files.
    public static let kokoroV3Revision = "6c0750dd02ef9d981fb82f147d784a3f171755ee"

    /// The English v3 folder FluidAudio downloads under `kokoroBase` for that revision.
    public var kokoroV3English: URL {
        kokoroBase.appending(path: "kokoro-82m-coreml/ANE-v3/\(Self.kokoroV3Revision)/en", directoryHint: .isDirectory)
    }

    /// The G2P cache FluidAudio pins outside our folder (see the type comment). The one definition of
    /// this path: `VoiceStorage` and Settings › Privacy read it from here. Stable API.
    public static var unredirectableKokoroG2P: URL {
        URL.homeDirectory.appending(path: ".cache/fluidaudio/Models/kokoro", directoryHint: .isDirectory)
    }

    /// Creates the folders FluidAudio expects to exist before it downloads.
    public func ensureDirectories() throws {
        for url in [asrBase, vadBase, kokoroBase] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
