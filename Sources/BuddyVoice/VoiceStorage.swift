import BuddyCore
import FluidAudio
import Foundation

/// What BuddyVoice keeps on disk, for Settings › Privacy's "what is stored" list. Audio and transcripts
/// live only in memory; nothing the user says is written anywhere.
public struct VoiceStorageLocation: Sendable, Equatable {
    public let title: String
    public let url: URL
    public let detail: String
}

public enum VoiceStorage {
    /// FluidAudio keeps Kokoro's English pronunciation lexicon here whatever directory we pass
    /// (`G2PModel.shared` hard-codes it in 0.17.7). Accepted for now; FluidAudio#1023 asks for a
    /// configurable path.
    public static var kokoroLexicon: URL { ModelStore.unredirectableKokoroG2P }

    public static func locations(settings: VoiceSettings = VoiceSettings()) -> [VoiceStorageLocation] {
        [
            VoiceStorageLocation(
                title: "Voice models",
                url: settings.modelsDirectory,
                detail: "Speech recognition, voice detection and the Kokoro voice. Downloaded once."
            ),
            VoiceStorageLocation(
                title: "Pronunciation lexicon",
                url: kokoroLexicon,
                detail: "About 41 MB, used by the Kokoro voice. Its speech library keeps it in this folder."
            ),
        ]
    }

    /// The folders each downloadable part lives in. Nothing else is ever removed. Silero (1 MB) isn't
    /// part of either: the Mac's own hearing needs it too.
    /// `lexicon` is FluidAudio's fixed cache folder; tests pass their own.
    /// `sharedLexicon` false (a copy with another bundle ID): FluidAudio's own lexicon folder
    /// (`~/.cache/fluidaudio`, shared with the release app and other apps) isn't Lumi's to delete.
    static func folders(_ part: VoiceModelPart, store: ModelStore, lexicon: URL = kokoroLexicon,
                        sharedLexicon: Bool = BuddyCore.paths.isRelease) -> [URL] {
        switch part {
        case .speechRecognition: [store.asrBase]
        case .lumiVoice: sharedLexicon ? [store.kokoroBase, lexicon] : [store.kokoroBase]
        }
    }

    /// What `part` takes on disk now, for Settings › Voice's "Downloaded on this Mac". 0 when it isn't there.
    public static func bytesOnDisk(_ part: VoiceModelPart, settings: VoiceSettings = VoiceSettings()) -> Int64 {
        DiskProgress(folders: folders(part, store: ModelStore(settings: settings)), expectedBytes: 0).onDisk().bytes
    }

    /// Whether `part`'s model is on disk: Parakeet for listening (Silero's 1 MB alone doesn't count),
    /// Kokoro for the voice. Onboarding then offers it as a plain choice, without a Download button.
    public static func isDownloaded(_ part: VoiceModelPart, settings: VoiceSettings = VoiceSettings()) -> Bool {
        isDownloaded(part, store: ModelStore(settings: settings))
    }

    static func isDownloaded(_ part: VoiceModelPart, store: ModelStore) -> Bool {
        let folder = part == .speechRecognition ? store.asrBase : store.kokoroBase
        return DiskProgress(folders: [folder], expectedBytes: 0).onDisk().bytes > 0
    }

    /// Whether `model` can listen without downloading anything: the Mac's own recognition always
    /// (macOS adds its speech files itself), Parakeet once it's complete on this Mac. TDT v2 also counts
    /// when another app left it complete in FluidAudio's own folder (`sharedParakeetTDTv2`): loading
    /// it copies it in instead of downloading.
    public static func isDownloaded(_ model: SpeechModel, settings: VoiceSettings = VoiceSettings()) -> Bool {
        isDownloaded(model, store: ModelStore(settings: settings))
    }

    static func isDownloaded(_ model: SpeechModel, store: ModelStore, shared: URL = sharedParakeetTDTv2) -> Bool {
        switch model {
        case .appleOnDevice: true
        case .parakeetTDTv2: hasParakeetTDTv2(at: store.parakeetTDTv2) || hasParakeetTDTv2(at: shared)
        case .parakeetUnified: DiskProgress(folders: [store.parakeetUnified], expectedBytes: 0).onDisk().bytes > 0
        }
    }

    /// FluidAudio's default folder for Parakeet TDT v2 (`~/Library/Application Support/FluidAudio/Models/
    /// parakeet-tdt-0.6b-v2`), where other apps built on FluidAudio keep it. Read, never changed.
    static var sharedParakeetTDTv2: URL { AsrModels.defaultCacheDirectory(for: .v2) }

    /// Every file FluidAudio needs for TDT v2 is there (its own check, so a partial download doesn't count).
    static func hasParakeetTDTv2(at folder: URL) -> Bool { AsrModels.modelsExist(at: folder, version: .v2) }

    /// Copies a complete Parakeet TDT v2 from `shared` into Lumi's folder when Lumi has none, so the
    /// load finds it and downloads nothing. On APFS the copy is a clone: no extra space, about instant.
    /// Returns whether it copied. Any failure leaves Lumi's folder as it was, and the load downloads.
    /// `canReplace` false (a copy with another bundle ID, which shares the release app's models):
    /// an incomplete folder already there is left alone, since the copy only ever adds files.
    @discardableResult
    static func adoptParakeetTDTv2(into store: ModelStore, from shared: URL = sharedParakeetTDTv2,
                                   fileManager: FileManager = .default, canReplace: Bool = BuddyCore.paths.isRelease) -> Bool {
        let target = store.parakeetTDTv2
        guard !hasParakeetTDTv2(at: target), hasParakeetTDTv2(at: shared) else { return false }
        if !canReplace, fileManager.fileExists(atPath: target.path) { return false }
        let staging = target.deletingLastPathComponent().appending(path: ".adopting-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: shared, to: staging)
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.moveItem(at: staging, to: target)
            return true
        } catch {
            try? fileManager.removeItem(at: staging)
            return false
        }
    }

    /// Deletes `part`'s folders. A folder that isn't there is fine.
    static func remove(_ part: VoiceModelPart, store: ModelStore, lexicon: URL = kokoroLexicon,
                       sharedLexicon: Bool = BuddyCore.paths.isRelease, fileManager: FileManager = .default) throws {
        for folder in folders(part, store: store, lexicon: lexicon, sharedLexicon: sharedLexicon)
        where fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
    }
}

/// A part of the voice that's downloaded, and can be removed to free the space.
public enum VoiceModelPart: Sendable, CaseIterable, Equatable {
    /// Parakeet (`VoiceDownloadSize.listening`), both variants.
    case speechRecognition
    /// Kokoro and its pronunciation files (`VoiceDownloadSize.lumiVoice`): only the Lumi voice uses them.
    case lumiVoice
}
