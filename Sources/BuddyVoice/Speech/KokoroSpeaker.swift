import BuddyCore
import FluidAudio
import Foundation
import os

/// The default voice: Kokoro 82M on the device through FluidAudio (ANE v3 pipeline). Kokoro doesn't
/// stream, so replies are spoken sentence by sentence: playback starts once the first sentence is
/// synthesized, and the rest are synthesized while it plays (Kokoro runs about 30× real time).
public actor KokoroSpeaker: SpeechSpeaker {
    private let manager: KokoroAneManager
    private let voice: String
    private let store: ModelStore
    /// The v3 chain's phoneme → token map, to count tokens exactly as it does (`KokoroAneTrap`).
    private var vocab: KokoroAneVocab?
    private let playback: AudioPlayback
    /// One load shared by every caller, so a `speak` during `warmUp` doesn't initialize twice.
    private var loading: Task<Void, any Error>?
    private var ready = false
    /// Bumped by `stop()` so a reply still synthesizing when stopped is never played.
    private var generation = 0
    /// The reply in flight, by generation, for `continueReply`.
    private var reply: (generation: Int, opening: Task<AudioPlayback.ReplyHandle, any Error>)?
    /// The last queued run of sentences; a continuation runs after it, so sentences keep their order.
    private var tail: Task<Void, Never>?
    private let log = Logger(subsystem: BuddyCore.bundleIdentifier, category: "voice")
    private let pressure: SystemPressure
    /// Syntheses in flight, and when the last one started or ended: deferred warm-ups run only when
    /// none is in flight and none has run for `quietBeforeWarmUp` (between turns, not during one).
    private var syntheses = 0
    private var lastSynthesis = ContinuousClock.now
    static let quietBeforeWarmUp: Duration = .seconds(10)
    /// Deferred warm-ups that have run, for tests.
    private(set) var deferredWarmUpsRun = 0

    public init(voice: String = "af_heart", store: ModelStore = ModelStore(), playback: AudioPlayback,
                pressure: SystemPressure = .shared) {
        self.pressure = pressure
        self.voice = voice
        self.store = store
        self.playback = playback
        manager = KokoroAneManager(variant: .english, defaultVoice: voice, directory: store.kokoroBase, version: .v3)
    }

    /// Loads the models and voice, then synthesizes a throwaway line: the first synthesis after loading
    /// costs about 825 ms (S5). Throws `VoiceUnavailable.loadFailed` so `FallbackSpeaker` can switch.
    public func load() async throws {
        if ready { return }
        let task = loading ?? Task { try await self.loadNow() }
        loading = task
        do {
            try await task.value
            ready = true
        } catch {
            if loading == task { loading = nil }   // let a later warm-up retry
            throw VoiceUnavailable.loadFailed(String(describing: error))
        }
    }

    public func warmUp() async {
        try? await load()
        await playback.prewarm()
    }

    public func speak(_ text: String) async throws -> AsyncStream<Float> {
        lastSynthesis = .now   // a reply is starting: no deferred warm-up now
        generation += 1
        let id = generation
        tail?.cancel()
        tail = nil
        reply = nil
        // Taken before synthesis: if stop()'s stopVoice reaches the playback actor first, this reply is
        // refused there, even if it arrives after our own generation check.
        let ticket = await playback.reserveReply()
        try await load()
        let sentences = SentenceSplitter.split(text)
        guard let first = sentences.first, id == generation else { return AsyncStream { $0.finish() } }
        // Open the reply (and start output if it was idle) while the first sentence is synthesized.
        let playback = self.playback
        let opening = Task { try await playback.beginReply(sampleRate: Double(KokoroAneConstants.sampleRate), ticket: ticket) }
        reply = (id, opening)
        let head = Task { () async throws -> Void in
            do {
                let samples = try await self.synthesize(first).0
                try await opening.value.append(samples)
            } catch {
                // Release the reply, or it stays open and output never idles.
                await (try? await opening.value)?.finish()
                throw error
            }
        }
        let rest = Array(sentences.dropFirst())
        tail = Task {
            guard (try? await head.value) != nil, let handle = try? await opening.value else { return }
            await self.speakSentences(rest, into: handle, generation: id)
        }
        // A failure in the first sentence throws, so FallbackSpeaker can say the reply with the system voice.
        // Not a stop: a reply stopped or replaced while its first sentence synthesized just ends.
        do { try await head.value } catch {
            guard id == generation else { return AsyncStream { $0.finish() } }
            throw error
        }
        let handle = try await opening.value
        guard id == generation else { return AsyncStream { $0.finish() } }
        return handle.levels
    }

    /// Queues `text` behind the reply in flight (its sentences after the ones already queued), so a
    /// follow-on line doesn't cut the one playing.
    public func continueReply(_ text: String) async -> Bool {
        lastSynthesis = .now
        guard let (id, opening) = reply, id == generation else { return false }
        let sentences = SentenceSplitter.split(text)
        guard !sentences.isEmpty else { return true }
        // Holds the reply before anything awaits, so it can't end between this call and its sentences.
        let attach = Task { () -> AudioPlayback.ReplyHandle? in
            guard let handle = try? await opening.value, await handle.hold() else { return nil }
            return handle
        }
        let previous = tail
        tail = Task {
            await previous?.value
            guard let handle = await attach.value else { return }
            await self.speakSentences(sentences, into: handle, generation: id)
        }
        return await attach.value != nil
    }

    /// Synthesizes sentences in order and queues each behind the one playing, then releases its hold on
    /// the reply. Stops when the reply is stopped or replaced. A synthesis error mid-reply ends it after
    /// what already played; switching voices half way through would sound worse than stopping.
    private func speakSentences(_ sentences: [String], into reply: AudioPlayback.ReplyHandle, generation id: Int) async {
        for sentence in sentences {
            guard id == generation, !Task.isCancelled else { break }
            do {
                let (samples, _) = try await synthesize(sentence)
                guard id == generation, try await reply.append(samples) else { break }
            } catch {
                // Stopped or replaced (a new summon, Esc, the switcher): ended on purpose, not a failure.
                guard id == generation, !Task.isCancelled else { break }
                log.error("Kokoro failed mid-reply, ending it early: \(String(describing: error), privacy: .private)")
                break
            }
        }
        await reply.finish()
    }

    public func stop() async {
        generation += 1
        tail?.cancel()
        tail = nil
        reply = nil
        await playback.stopVoice()
    }

    /// Synthesized samples and their rate. Throws `VoiceUnavailable.synthesisFailed`.
    func synthesize(_ text: String) async throws -> ([Float], Double) {
        syntheses += 1
        lastSynthesis = .now
        defer { syntheses -= 1; lastSynthesis = .now }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], 24_000) }
        do {
            return try await synthesizeGuarded(trimmed)
        } catch {
            throw VoiceUnavailable.synthesisFailed(String(describing: error))
        }
    }

    /// Text → phonemes → audio, as `synthesizeDetailed(text:)` does, but with the phonemes checked
    /// against `KokoroAneTrap` first: one token count makes Core ML trap inside the Alignment model,
    /// which kills the app (no Swift error to catch, so `FallbackSpeaker` never runs). Phonemes too long
    /// for one pass are split at spaces here, not by FluidAudio, so every chunk is checked too.
    private func synthesizeGuarded(_ text: String) async throws -> ([Float], Double) {
        let phonemes = try await manager.phonemes(for: text)
        var samples: [Float] = []
        var rate = Double(KokoroAneConstants.sampleRate)
        for chunk in KokoroAneTrap.chunks(phonemes, max: KokoroAneConstants.maxPhonemeLength - 1) {
            let result = try await synthesizeChecked(chunk)
            samples += result.samples
            rate = Double(result.sampleRate)
        }
        return (samples, rate)
    }

    private func synthesizeChecked(_ phonemes: String) async throws -> KokoroAneSynthesisResult {
        let safe = KokoroAneTrap.avoiding(phonemes, vocab: vocab)
        // Counts only, never the text: if Core ML ever traps again, the last line names the input size.
        let tokens = KokoroAneTrap.tokenCount(safe, vocab: vocab)
        log.info("Kokoro: synthesizing \(tokens, privacy: .public) tokens\(safe == phonemes ? "" : " (padded)", privacy: .public)")
        let result = try await manager.synthesizeFromPhonemesDetailed(safe, voice: voice)
        log.info("Kokoro: \(tokens, privacy: .public) tokens → \(result.acousticFrames, privacy: .public) frames")
        return result
    }

    /// Throwaway lines for warm-up. The v3 pipeline picks static ANE models by length (Albert 32/64
    /// tokens, decoder 120/200 frames, about 3 s/5 s of audio) and falls back to dynamic models above
    /// that; each model pays a one-time specialization on its first prediction (seconds). One line per
    /// path keeps that cost off the user's first long reply.
    static let warmUpLines = [
        "Ready when you are.",
        "Your new date filter drops last week's data, so the list is empty.",
        "The build failed because the signing identity expired yesterday, so the release job stopped before upload. Want me to renew it?",
    ]

    private func loadNow() async throws {
        try await manager.initialize(preloadVoices: [voice])
        vocab = KokoroAneTrap.vocab(for: store)
        if vocab == nil { log.error("Kokoro: no vocab.json at the pinned revision; counting every phoneme as a token") }
        // Only the short line now: it's the first reply's path.
        _ = try await synthesizeGuarded(Self.warmUpLines[0])
        // The longer paths' one-time specialisation happens later, at idle, and not on a Mac short
        // of memory or hot; skipped, the first long reply pays it as before.
        IdleWarmUp.schedule(
            Self.warmUpLines.dropFirst().map { line in { await self.deferredWarmUp(line) } },
            after: Self.quietBeforeWarmUp,
            isQuiet: { await self.isQuiet }, skip: { self.pressure.isHigh })
    }

    private func deferredWarmUp(_ line: String) async {
        _ = try? await synthesizeGuarded(line)
        deferredWarmUpsRun += 1
    }

    /// No synthesis in flight, and none for `quietBeforeWarmUp`.
    private var isQuiet: Bool { syntheses == 0 && ContinuousClock.now - lastSynthesis >= Self.quietBeforeWarmUp }
}

/// A Core ML trap in Kokoro's v3 Alignment model, found Oct 16 2026 (macOS 26.6, M5, FluidAudio 0.17.7):
/// at exactly 48 input tokens its `.cpuAndNeuralEngine` CPU path (BNNS) stops the process with
/// "Workspace Tensor accessed oob" (`brk 1` in libBNNS). Every other count from 2 to 512 runs, at any
/// speed, and so does 48 on `.cpuOnly`/`.cpuAndGPU`, which the v3 pipeline doesn't let us choose. All
/// three Lumi crashes that week were this. A trailing space (one pause token, inaudible) moves
/// such a sentence to 49 tokens.
enum KokoroAneTrap {
    static let tokenCounts: Set<Int> = [48]

    /// Tokens the chain feeds the models: BOS, each phoneme scalar the vocab knows, EOS
    /// (`KokoroAneVocab.encode`). Without a vocab every scalar counts: the English frontend only emits
    /// scalars the vocab knows, so that is still exact there, and padding happens only at 48 (never a
    /// band, which could itself push a real 47 to 48).
    static func tokenCount(_ phonemes: String, vocab: KokoroAneVocab?) -> Int {
        let known = phonemes.unicodeScalars.filter { vocab?.map[Character($0)] != nil || vocab == nil }.count
        return known + 2
    }

    /// `phonemes`, with a pause token added when its token count would trap (a space, or a full stop
    /// if a vocab ever lacked the space).
    static func avoiding(_ phonemes: String, vocab: KokoroAneVocab?) -> String {
        guard tokenCounts.contains(tokenCount(phonemes, vocab: vocab)) else { return phonemes }
        for pad in [" ", ".", ","] where !tokenCounts.contains(tokenCount(phonemes + pad, vocab: vocab)) {
            return phonemes + pad
        }
        return phonemes
    }

    /// `phonemes` in pieces of at most `max` scalars, split at spaces (a word longer than `max` is
    /// split where it must). One piece when it fits, the usual case.
    static func chunks(_ phonemes: String, max: Int) -> [String] {
        guard phonemes.unicodeScalars.count > max else { return [phonemes] }
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for word in phonemes.split(separator: " ", omittingEmptySubsequences: true) {
            var scalars = Array(word.unicodeScalars)
            while scalars.count > max {   // a single "word" longer than a chunk
                if !current.isEmpty { out.append(String(current)); current = .init() }
                out.append(String(String.UnicodeScalarView(scalars.prefix(max))))
                scalars.removeFirst(max)
            }
            let extra = current.isEmpty ? scalars.count : scalars.count + 1
            if current.count + extra > max { out.append(String(current)); current = .init() }
            if !current.isEmpty { current.append(" ") }
            current.append(contentsOf: scalars)
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// The English v3 vocab at the revision FluidAudio pins (`ModelStore.kokoroV3Revision`): the one
    /// it loaded, never an older revision left on disk.
    static func vocab(for store: ModelStore) -> KokoroAneVocab? {
        try? KokoroAneVocab.load(from: store.kokoroV3English.appending(path: "vocab.json"))
    }
}
