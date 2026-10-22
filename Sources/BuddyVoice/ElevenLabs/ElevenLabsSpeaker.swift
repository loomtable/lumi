import BuddyCore
import Foundation
import os
import Synchronization

/// ElevenLabs Eleven v4 Turbo, the opt-in voice. Same contract as `KokoroSpeaker`: a reply is
/// spoken sentence by sentence, `speak` returns once the first audio is playing, and `continueReply`
/// queues a follow-on line behind it. Each sentence streams, so audio starts before it's fully rendered.
///
/// Failures before any audio throw, so `FallbackSpeaker` says the reply with the on-device voice: a
/// missing or rejected key, or an exhausted quota, as `loadFailed` (on-device until the key changes);
/// anything else (offline, a timeout, a server error) as `synthesisFailed` (this reply only). A failure
/// mid-reply ends it after what already played, like Kokoro.
public actor ElevenLabsSpeaker: LoadableSpeaker {
    private let client: ElevenLabsClient
    private let voiceID: String
    private let playback: AudioPlayback
    private var generation = 0
    private var reply: (generation: Int, opening: Task<AudioPlayback.ReplyHandle, any Error>)?
    private var tail: Task<Void, Never>?
    /// The last failure, for the "using the on-device voice" line.
    public private(set) var lastFailure: ElevenLabsFailure?
    private let log = Logger(subsystem: BuddyCore.bundleIdentifier, category: "voice")

    /// Samples gathered before a mid-sentence piece is queued (100 ms), so playback isn't fed tiny buffers.
    static let pieceSamples = 2_400

    public init(voiceID: String, client: ElevenLabsClient, playback: AudioPlayback) {
        self.voiceID = voiceID
        self.client = client
        self.playback = playback
    }

    /// Only checks that a key is saved; the network isn't touched until a reply.
    public func load() async throws {
        do {
            _ = try await client.key()
        } catch {
            lastFailure = .noKey
            throw VoiceUnavailable.loadFailed("no ElevenLabs key")
        }
    }

    public func warmUp() async {
        try? await load()
        await playback.prewarm(sampleRate: ElevenLabsClient.sampleRate)
    }

    public func speak(_ text: String) async throws -> AsyncStream<Float> {
        generation += 1
        let id = generation
        tail?.cancel()
        tail = nil
        reply = nil
        let ticket = await playback.reserveReply()
        try await load()
        let sentences = SentenceSplitter.split(text)
        guard !sentences.isEmpty, id == generation else { return AsyncStream { $0.finish() } }
        let playback = self.playback
        let opening = Task { try await playback.beginReply(sampleRate: ElevenLabsClient.sampleRate, ticket: ticket) }
        reply = (id, opening)
        let firstAudio = FirstAudio()
        tail = Task {
            let handle: AudioPlayback.ReplyHandle
            do {
                handle = try await opening.value
            } catch {
                firstAudio.resolve(.failure(error))   // the output itself failed; report that, not the voice
                return
            }
            // Stopped before anything was requested: don't send (or pay for) a request nobody will hear.
            guard await self.isCurrent(id, ticket: ticket) else {
                firstAudio.resolve(.success(()))
                await handle.finish()
                return
            }
            await self.speakSentences(sentences, into: handle, generation: id, firstAudio: firstAudio)
        }
        do {
            try await firstAudio.wait()
        } catch let failure as ElevenLabsFailure {
            throw Self.unavailable(failure)
        }
        let handle = try await opening.value
        guard id == generation else { return AsyncStream { $0.finish() } }
        lastFailure = nil
        return handle.levels
    }

    public func continueReply(_ text: String) async -> Bool {
        guard let (id, opening) = reply, id == generation else { return false }
        let sentences = SentenceSplitter.split(text)
        guard !sentences.isEmpty else { return true }
        let attach = Task { () -> AudioPlayback.ReplyHandle? in
            guard let handle = try? await opening.value, await handle.hold() else { return nil }
            return handle
        }
        let previous = tail
        tail = Task {
            await previous?.value
            guard let handle = await attach.value else { return }
            await self.speakSentences(sentences, into: handle, generation: id, firstAudio: nil)
        }
        return await attach.value != nil
    }

    public func stop() async {
        generation += 1
        tail?.cancel()
        tail = nil
        reply = nil
        await playback.stopVoice()
    }

    /// Streams each sentence into the reply in order, then releases its hold. `firstAudio` resolves when
    /// the first audible piece is queued, or with the error if a sentence fails before any audio.
    private func speakSentences(_ sentences: [String], into reply: AudioPlayback.ReplyHandle, generation id: Int,
                                firstAudio: FirstAudio?) async {
        for sentence in sentences {
            guard id == generation, !Task.isCancelled else { break }
            do {
                guard try await streamSentence(sentence, into: reply, generation: id, firstAudio: firstAudio) else { break }
            } catch {
                // Stopped or replaced: the request was cancelled on purpose, not a failure.
                guard id == generation, !Task.isCancelled else { break }
                let failure = error as? ElevenLabsFailure ?? .unreachable("connection dropped")
                lastFailure = failure
                if let firstAudio, !firstAudio.isResolved {
                    firstAudio.resolve(.failure(failure))
                } else {
                    log.error("ElevenLabs failed mid-reply, ending it early: \(String(describing: failure), privacy: .public)")
                }
                break
            }
        }
        firstAudio?.resolve(.success(()))   // nothing audible (or stopped): speak() still returns
        await reply.finish()
    }

    /// One sentence: its quiet lead-in is trimmed or capped like a Kokoro sentence, then the rest plays as
    /// it arrives. Returns false once the reply was stopped or replaced.
    private func streamSentence(_ sentence: String, into reply: AudioPlayback.ReplyHandle, generation id: Int,
                                firstAudio: FirstAudio?) async throws -> Bool {
        let stream = try await client.speech(sentence, voiceID: voiceID)
        var pending: [Float] = []
        var started = false
        for try await samples in stream {
            guard id == generation else { return false }
            pending += samples
            if !started {
                // Wait for the first word, so `append` trims (or caps) the lead-in as a whole.
                guard Self.isAudible(pending) else { continue }
                guard try await reply.append(pending) else { return false }
                started = true
                firstAudio?.resolve(.success(()))
                pending = []
            } else if pending.count >= Self.pieceSamples {
                guard try await reply.appendContinuing(pending) else { return false }
                pending = []
            }
        }
        guard id == generation, !pending.isEmpty else { return id == generation }
        return try await started ? reply.appendContinuing(pending) : reply.append(pending)
    }

    private func isCurrent(_ id: Int, ticket: AudioPlayback.ReplyTicket) async -> Bool {
        guard id == generation else { return false }
        return await playback.isCurrent(ticket)
    }

    static func isAudible(_ samples: [Float]) -> Bool {
        LevelWindows.rms(samples, sampleRate: ElevenLabsClient.sampleRate).contains { $0 > LevelWindows.quiet }
    }

    static func unavailable(_ failure: ElevenLabsFailure) -> VoiceUnavailable {
        failure.isAccountProblem
            ? .loadFailed("ElevenLabs: \(failure)")
            : .synthesisFailed("ElevenLabs: \(failure)")
    }
}

/// Resolves once: when the first audio of a reply is queued, or with the error that prevented it.
/// A class, so closures capture a reference rather than the Mutex itself (a Swift 6.4 bug).
final class FirstAudio: Sendable {
    private struct State {
        var result: Result<Void, any Error>?
        var waiters: [CheckedContinuation<Void, any Error>] = []
    }
    private let state = Mutex(State())

    var isResolved: Bool { state.withLock { $0.result != nil } }

    func resolve(_ result: Result<Void, any Error>) {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
            guard s.result == nil else { return [] }
            s.result = result
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume(with: result) }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let ready = state.withLock { s -> Result<Void, any Error>? in
                if let r = s.result { return r }
                s.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
