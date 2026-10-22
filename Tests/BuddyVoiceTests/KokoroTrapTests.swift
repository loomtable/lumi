import FluidAudio
import Foundation
import Testing
@testable import BuddyVoice

struct KokoroTrapTests {
    /// A vocab of single letters, plus space; "!" and "?" unknown (dropped by the encoder).
    static let vocab = KokoroAneVocab(map: Dictionary(uniqueKeysWithValues:
        (Array("abcdefghijklmnopqrstuvwxyz ") ).enumerated().map { ($0.element, Int32($0.offset + 1)) }))

    @Test func tokensAreBosKnownScalarsAndEos() {
        #expect(KokoroAneTrap.tokenCount("abc", vocab: Self.vocab) == 5)
        #expect(KokoroAneTrap.tokenCount("ab!c?", vocab: Self.vocab) == 5, "unknown scalars are dropped, as encode does")
        #expect(KokoroAneTrap.tokenCount("ab!c?", vocab: nil) == 7, "without a vocab, every scalar counts")
    }

    @Test func aSentenceOf48TokensIsPaddedToASafeCount() {
        let trapped = String(repeating: "a", count: 46)   // + BOS + EOS = 48
        let safe = KokoroAneTrap.avoiding(trapped, vocab: Self.vocab)
        #expect(safe == trapped + " ")
        #expect(KokoroAneTrap.tokenCount(safe, vocab: Self.vocab) == 49)
        // Unknown scalars don't count, so this is 48 tokens too.
        #expect(KokoroAneTrap.avoiding(trapped + "!!", vocab: Self.vocab) == trapped + "!! ")
    }

    @Test func aVocabWithoutTheSpaceGetsAFullStopAndNeverLoops() {
        let noSpace = KokoroAneVocab(map: Dictionary(uniqueKeysWithValues:
            Array("abcdefghijklmnopqrstuvwxyz.").enumerated().map { ($0.element, Int32($0.offset + 1)) }))
        let trapped = String(repeating: "a", count: 46)
        #expect(KokoroAneTrap.avoiding(trapped, vocab: noSpace) == trapped + ".")
    }

    @Test func longPhonemesAreSplitAtSpacesIntoCheckedChunks() {
        let word = String(repeating: "a", count: 9)
        let long = Array(repeating: word, count: 60).joined(separator: " ")   // 599 scalars
        let chunks = KokoroAneTrap.chunks(long, max: 509)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.unicodeScalars.count <= 509 && !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
        #expect(chunks.joined(separator: " ") == long, "nothing lost")
        #expect(KokoroAneTrap.chunks("short", max: 509) == ["short"])
        let unbroken = String(repeating: "b", count: 1100)
        #expect(KokoroAneTrap.chunks(unbroken, max: 509).map(\.count) == [509, 509, 82])
    }

    @Test func otherCountsAreUntouched() {
        for n in [1, 30, 45, 47, 48, 100] where n != 46 {
            let phonemes = String(repeating: "a", count: n)
            #expect(KokoroAneTrap.avoiding(phonemes, vocab: Self.vocab) == phonemes)
        }
    }
}

/// The sentence that crashed Lumi three times (via the 48-token Alignment trap), synthesized
/// for real, never played:
///   BUDDYVOICE_KOKORO_TRAP=1 BUDDYVOICE_MODELS_DIR=<models root> Scripts/test.sh --filter KokoroTrapLive
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUDDYVOICE_KOKORO_TRAP"] == "1"), .serialized)
struct KokoroTrapLiveTests {
    @Test func theSentenceThatCrashedIsSpokenNow() async throws {
        let root = ProcessInfo.processInfo.environment["BUDDYVOICE_MODELS_DIR"].map { URL(fileURLWithPath: $0) }
        let kokoro = KokoroSpeaker(store: root.map { ModelStore(root: $0) } ?? ModelStore(), playback: AudioPlayback())
        try await kokoro.load()
        for text in ["the list looks empty change it to thirty days.", "the list looks empty change it to forty days.",
                     "the list seems empty change it to thirty days."] {
            let (samples, rate) = try await kokoro.synthesize(text)
            #expect(Double(samples.count) / rate > 1.5, "\\(text)")
            #expect(samples.contains { abs($0) > 0.05 }, "not silent")
        }
        // One sentence over 510 phonemes: split at spaces here, each piece checked.
        let long = Array(repeating: "the date filter drops last week so the list looks empty", count: 9).joined(separator: " and ") + "."
        let (samples, rate) = try await kokoro.synthesize(long)
        #expect(Double(samples.count) / rate > 20, "all of it spoken")
    }
}

/// Staged warm-up, for real: the longer lines wait until Kokoro has been quiet, never during use.
///   BUDDYVOICE_KOKORO_TRAP=1 BUDDYVOICE_MODELS_DIR=… Scripts/test.sh --filter KokoroStagedWarmUpLive
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUDDYVOICE_KOKORO_TRAP"] == "1"), .serialized)
struct KokoroStagedWarmUpLiveTests {
    @Test func deferredWarmUpsWaitForQuiet() async throws {
        let root = ProcessInfo.processInfo.environment["BUDDYVOICE_MODELS_DIR"].map { URL(fileURLWithPath: $0) }
        let kokoro = KokoroSpeaker(store: root.map { ModelStore(root: $0) } ?? ModelStore(), playback: AudioPlayback())
        try await kokoro.load()
        #expect(await kokoro.deferredWarmUpsRun == 0, "only the short line at load")
        for _ in 0..<7 {   // in use for about 14 s
            _ = try await kokoro.synthesize("Still talking to you.")
            try await Task.sleep(for: .seconds(2))
        }
        #expect(await kokoro.deferredWarmUpsRun == 0, "never while in use")
        // Quiet from here: 10 s, then both lines (about a second each).
        for _ in 0..<40 where await kokoro.deferredWarmUpsRun < 2 { try await Task.sleep(for: .milliseconds(500)) }
        #expect(await kokoro.deferredWarmUpsRun == 2, "both once quiet")
    }
}
