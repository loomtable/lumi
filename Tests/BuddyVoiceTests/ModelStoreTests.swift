import Foundation
import Testing
@testable import BuddyVoice

struct ModelStoreTests {
    @Test func defaultRootIsOurApplicationSupportFolder() {
        let root = ModelStore().root.path(percentEncoded: false)
        #expect(root.hasSuffix("Library/Application Support/com.loomtable.lumi/models/"))
        #expect(!root.contains("FluidAudio"))
    }

    @Test func everyModelSitsUnderTheRoot() {
        let root = URL(filePath: "/tmp/sb-models", directoryHint: .isDirectory)
        let store = ModelStore(root: root)
        for url in [store.asrBase, store.parakeetUnified, store.parakeetTDTv2, store.vadBase, store.sileroVad, store.kokoroBase] {
            #expect(url.path(percentEncoded: false).hasPrefix("/tmp/sb-models/"))
        }
        #expect(store.parakeetUnified.path(percentEncoded: false) == "/tmp/sb-models/asr/parakeet-unified-en-0.6b/")
        #expect(store.sileroVad.path(percentEncoded: false) == "/tmp/sb-models/vad/Models/silero-vad/")
    }

    @Test func followsSettings() {
        let custom = URL(filePath: "/tmp/elsewhere", directoryHint: .isDirectory)
        #expect(ModelStore(settings: VoiceSettings(modelsDirectory: custom)).root == custom)
    }

    /// FluidAudio 0.17.7 pins Kokoro's G2P lexicon here; Settings › Privacy shows this exact path.
    @Test func kokoroG2PCacheIsTheOneFluidAudioHardcodes() {
        #expect(ModelStore.unredirectableKokoroG2P.path(percentEncoded: false)
            == URL.homeDirectory.path(percentEncoded: false) + ".cache/fluidaudio/Models/kokoro/")
    }
}
