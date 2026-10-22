import Foundation
import Testing
@testable import BuddyVoice
@testable import FluidAudio

struct KokoroPinTests {
    /// A FluidAudio update that moves Kokoro's pinned revision must update ours, or the token guard
    /// would read no vocab (or a stale one).
    @Test func ourRevisionIsFluidAudios() throws {
        #expect(ModelStore.kokoroV3Revision == KokoroAneV3Assets.revision)
        let store = ModelStore(root: URL(fileURLWithPath: "/tmp/sb-models"))
        let theirs = try KokoroAneV3Assets.cacheDirectory(variant: .english, directory: store.kokoroBase)
        #expect(store.kokoroV3English.standardizedFileURL.path == theirs.standardizedFileURL.path)
    }

    @Test func aMissingVocabIsNilNotAnotherRevision() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sb-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelStore(root: root)
        let old = store.kokoroBase.appending(path: "kokoro-82m-coreml/ANE-v3/oldrevision/en")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(#"{"a": 1, " ": 2}"#.utf8).write(to: old.appending(path: "vocab.json"))
        #expect(KokoroAneTrap.vocab(for: store) == nil, "an old revision's vocab is never used")
        try FileManager.default.createDirectory(at: store.kokoroV3English, withIntermediateDirectories: true)
        try Data(#"{"b": 1, " ": 2}"#.utf8).write(to: store.kokoroV3English.appending(path: "vocab.json"))
        #expect(KokoroAneTrap.vocab(for: store)?.map["b"] == 1)
    }

    /// The agreed rule without a vocab: pad only when every scalar counted is 48.
    @Test func withoutAVocabOnlyAnExact48IsPadded() {
        let trapped = String(repeating: "a", count: 46)
        #expect(KokoroAneTrap.avoiding(trapped, vocab: nil) == trapped + " ")
        for n in [44, 45, 47, 48] {
            let p = String(repeating: "a", count: n)
            #expect(KokoroAneTrap.avoiding(p, vocab: nil) == p, "\(n + 2) tokens: no band padding")
        }
    }
}
