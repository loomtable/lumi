import Foundation

/// Speaks replies with the chosen voice: the on-device chain (Kokoro, then the system voice), the Mac's
/// voice, or ElevenLabs with the Mac's voice behind it. Only the on-device choice ever loads Kokoro, so
/// no other choice downloads it.
///
/// ElevenLabs failing before any audio means the Mac's voice says that reply. An account problem
/// (no key, a rejected key, an empty quota) keeps the Mac's voice until `setChoice` runs again (the
/// app calls it after a key is saved); a network problem only affects that reply. Each distinct problem
/// is reported once on `status`; `.recovered` follows once the line is no longer true (ElevenLabs spoke
/// again, or the choice was set again), on the same ordered stream.
actor ReplyVoiceSpeaker: SpeechSpeaker {
    private let onDevice: any SpeechSpeaker
    private let system: any SpeechSpeaker
    /// Where Kokoro lands on disk, for `.voice` progress while the on-device voice first loads.
    private let onDeviceDownload: DiskProgress?
    private let makeElevenLabs: @Sendable (String) -> ElevenLabsSpeaker
    private var choice: ReplyVoice
    private var elevenLabs: ElevenLabsSpeaker?
    /// The on-device chain's warm-up has started (Kokoro loading, loaded or failed over), so choosing it
    /// needs no new setup. Until then a reply uses the Mac's voice: speaking never starts a download.
    private var onDeviceWarmed = false
    private var accountProblem: ElevenLabsFailure?
    private var reported: ElevenLabsFailure?
    private enum Speaking { case onDevice, system, elevenLabs }
    private var speaking: Speaking?
    /// Bumped by `stop()`, so a reply that moves to the Mac's voice after a stop isn't spoken.
    private var stops = 0
    /// A problem line, or that ElevenLabs is speaking again after one (so a shown line can be cleared).
    enum Status: Sendable, Equatable {
        case problem(String)
        /// The last problem line no longer holds: ElevenLabs spoke again, or the choice was set again.
        case recovered
    }
    let status: AsyncStream<Status>
    private let statusContinuation: AsyncStream<Status>.Continuation

    init(onDevice: any SpeechSpeaker, system: any SpeechSpeaker, onDeviceDownload: DiskProgress? = nil, choice: ReplyVoice,
         makeElevenLabs: @escaping @Sendable (String) -> ElevenLabsSpeaker) {
        self.onDevice = onDevice
        self.system = system
        self.onDeviceDownload = onDeviceDownload
        self.makeElevenLabs = makeElevenLabs
        self.choice = choice
        (status, statusContinuation) = AsyncStream.makeStream(of: Status.self, bufferingPolicy: .bufferingNewest(4))
        if case .elevenLabs(let voiceID) = choice { elevenLabs = makeElevenLabs(voiceID) }
    }

    /// Returns true when the new choice needs a `warmUp` first: the on-device voice, not loaded yet.
    @discardableResult
    func setChoice(_ choice: ReplyVoice) async -> Bool {
        self.choice = choice
        accountProblem = nil
        if reported != nil {
            reported = nil
            statusContinuation.yield(.recovered)
        }
        switch choice {
        case .onDevice:
            elevenLabs = nil
        case .system:
            elevenLabs = nil
            await system.warmUp()
        case .elevenLabs(let voiceID):
            let speaker = makeElevenLabs(voiceID)
            elevenLabs = speaker
            await system.warmUp()
            await speaker.warmUp()
        }
        return choice == .onDevice && !onDeviceWarmed
    }

    /// The on-device chain only once its warm-up has run, so a reply never downloads Kokoro.
    private var speaksOnDevice: Bool { choice == .onDevice && onDeviceWarmed }

    func warmUp() async {
        await warmUp(progress: { _ in })
    }

    /// Warms only the chosen voice. The on-device one reports Kokoro's download as it lands on disk.
    func warmUp(progress: @escaping @Sendable (ModelLoadProgress) -> Void) async {
        if choice == .onDevice {
            onDeviceWarmed = true
            let watch = onDeviceDownload?.watch(progress)
            await onDevice.warmUp()
            watch?.cancel()
        } else {
            await system.warmUp()
        }
        await elevenLabs?.warmUp()
    }

    func speak(_ text: String) async throws -> AsyncStream<Float> {
        let stopsAtStart = stops
        if let elevenLabs, accountProblem == nil {
            do {
                let levels = try await elevenLabs.speak(text)
                speaking = .elevenLabs
                if reported != nil {
                    reported = nil
                    statusContinuation.yield(.recovered)
                }
                return levels
            } catch is VoiceUnavailable {
                let failure = await elevenLabs.lastFailure ?? .unreachable("unknown")
                // The choice changed while this reply waited (say, a new key was saved): the failure belongs
                // to the old ElevenLabs speaker, so it neither blocks the new one nor shows a stale line.
                if self.elevenLabs === elevenLabs {
                    if failure.isAccountProblem { accountProblem = failure }
                    report(failure)
                }
                guard stops == stopsAtStart else { return AsyncStream { $0.finish() } }
            }
        }
        if speaksOnDevice {
            let levels = try await onDevice.speak(text)
            speaking = .onDevice
            return levels
        }
        let levels = try await system.speak(text)
        speaking = .system
        return levels
    }

    func continueReply(_ text: String) async -> Bool {
        switch speaking {
        case .elevenLabs: await elevenLabs?.continueReply(text) ?? false
        case .onDevice: await onDevice.continueReply(text)
        case .system: await system.continueReply(text)
        case nil: false
        }
    }

    func stop() async {
        stops += 1
        speaking = nil
        await elevenLabs?.stop()
        await onDevice.stop()
        await system.stop()
    }

    private func report(_ failure: ElevenLabsFailure) {
        guard failure != reported else { return }
        reported = failure
        statusContinuation.yield(.problem(Self.line(for: failure)))
    }

    /// One true line per failure.
    static func line(for failure: ElevenLabsFailure) -> String {
        switch failure {
        case .noKey: "ElevenLabs has no API key, so the Mac voice is speaking."
        case .keyUnreadable: "Lumi couldn't read the ElevenLabs key from the Keychain, so the Mac voice is speaking."
        case .invalidKey: "ElevenLabs rejected the API key, so the Mac voice is speaking."
        case .quotaExceeded: "Your ElevenLabs quota is used up, so the Mac voice is speaking."
        case .missingPermission: "The ElevenLabs key isn't allowed to speak, so the Mac voice is speaking."
        case .unreachable, .modelRejected, .badResponse: "ElevenLabs couldn't be reached, so the Mac voice said this reply."
        }
    }
}
