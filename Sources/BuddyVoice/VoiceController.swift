import BuddyCore
import Foundation

/// Coordinates mic, speech-to-text, VAD safeguards, reply speech, meters and sounds for one buddy.
///
/// The transcript is returned only by `finishListening()` / `sendHeld()`, for the bridge. `events` and
/// `levels` carry states and loudness, never words, so the UI layer can't show what the user said.
///
/// Listen transitions (start, finish, discard, interrupt, auto-stop, mic failure) run one at a time, so a
/// gesture that lands while another transition is in flight waits for it instead of being dropped.
public actor VoiceController {
    public enum State: Sendable, Equatable {
        case idle
        case starting
        case listening
        /// Finalising after the gesture, an auto-stop or a discard.
        case finishing
        /// Listening stopped on its own; the recording is kept until `sendHeld()` or `discard`.
        case held
        /// Synthesising a reply; `stopSpeaking()` cancels it before it plays.
        case preparingReply
        case speaking
    }

    /// Where `prepare()` is, for the "setting up voice" chip.
    public enum PrepareState: Sendable, Equatable {
        case notStarted
        case preparing(PrepareStep)
        case ready
        /// Call `prepare()` again to retry.
        case failed(String)
    }

    public enum PrepareStep: Sendable, Equatable {
        /// Downloading or compiling the speech model; nil until the downloader first reports.
        case speechModel(ModelLoadProgress?)
        case voiceActivity
        /// Loading the reply voice; the on-device one reports its first download (nil until it does).
        case voice(ModelLoadProgress?)
        case microphone
    }

    /// Loudness for the effects, 0…1, about every 20 ms. A 0 marks the end of listening or speaking.
    public enum Level: Sendable, Equatable {
        /// Mic level for the dots and rim.
        case mic(Float)
        /// Reply level for the speaking glow.
        case reply(Float)
    }

    public enum Event: Sendable, Equatable {
        /// Near the length limit: 1:45 of a question (it stops at 2:00), 58 minutes of a dictation
        /// (it stops at 60, keeping everything).
        case nearLimit
        /// Listening stopped (on its own, or by `interrupt`). `held` says whether a recording was kept
        /// for `sendHeld()` / `discard`; false means there was nothing to keep. Decided inside the
        /// transition, so it never races with later ones.
        case autoStopped(ListenStopReason, held: Bool)
        case prepare(PrepareState)
        case micProblem(MicProblem)
        /// The mic engine was rebuilt after a device or format change; listening continues.
        case micRebuilt
        case speakingFinished
        /// ElevenLabs couldn't speak, so the on-device voice did: one true line, reported once per problem.
        case replyVoiceProblem(String)
        /// The last `replyVoiceProblem` line no longer holds (ElevenLabs spoke again, or the reply voice was
        /// set again): clear it.
        case replyVoiceRecovered
        /// The transcript is taking longer than `slowFinishNotice` (a long dictation, a slow Mac): say
        /// so, so the wait doesn't look frozen. `long` once it has taken `longFinishNotice`. Each sent
        /// at most once per finish.
        case transcribing(long: Bool)
    }

    public enum DiscardResult: Sendable, Equatable {
        case discarded
        /// More than 30 s of speech: ask first, then call `discard(confirmed: true)`.
        case needsConfirmation(speechSeconds: Double)
        case nothingToDiscard
    }

    public enum VoiceError: Error, Equatable {
        /// The speech model hasn't finished loading (first run downloads and compiles it). The
        /// buddy key answers "Still setting up voice".
        case stillSettingUp
        case notListening
        /// A held recording must be sent or discarded before listening again.
        case recordingHeld
        /// The speech model didn't answer within its limit (a hung Neural Engine call).
        case transcriptionTimedOut
        /// No voice setup chosen yet (`VoiceSettings.setupChosen`), so nothing was downloaded to listen.
        case notSetUp
        /// `removeModels` while voice is loading, listening or speaking: try again once it's idle.
        case busy
        /// `removeModels` in a copy with another bundle ID (QA): the models are the release app's,
        /// shared, and a copy never deletes them.
        case sharedModels
    }

    /// State changes. Unbounded: there are only a few per listen and none may be dropped.
    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    /// Meter frames. Only the newest few are kept for a slow consumer; an old level is useless.
    public nonisolated let levels: AsyncStream<Level>
    private let levelContinuation: AsyncStream<Level>.Continuation

    private let mic: any MicCapture
    /// Where the models live, for `removeModels`. Nil (the default, so a controller on fakes never
    /// deletes real folders): `removeModels` does nothing. `live()` passes the real ones.
    private let store: ModelStore?
    private let kokoroLexicon: URL?
    private let transcriber: any SpeechTranscriber
    private let detector: any SpeechActivityDetector
    private let speaker: any SpeechSpeaker
    private let sounds: any SoundPlayer
    private let clock: any VoiceClock
    private let limits: ListenSafeguards.Limits
    private let dictationLimits: ListenSafeguards.Limits
    private let tickInterval: Duration?
    /// How long a transcriber call may take. A finish is well under a second normally (0.65 s for
    /// 4 min of audio on an M5, 1.8 s CPU-only), but a Core ML call on a saturated Neural Engine can
    /// hang; past this the listen ends with `.transcriptionTimedOut`. Generous and fixed, so no long
    /// dictation or slow Mac is ever cut; `.transcribing` shows progress meanwhile. Nil: no limit.
    private let finishDeadline: Duration?
    /// A finish that runs longer than this is announced with `.transcribing`, and again (`long`)
    /// after `longFinishNotice`. Nil: never.
    private let slowFinishNotice: Duration?
    private let longFinishNotice: Duration?

    public private(set) var state: State = .idle {
        didSet {
            guard oldValue == .preparingReply, state != .preparingReply else { return }
            let waiters = preparationWaiters
            preparationWaiters = []
            waiters.forEach { $0.resume() }
        }
    }
    /// `speak(_:continuing: true)` calls waiting for the reply they continue to finish preparing.
    private var preparationWaiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var prepareState: PrepareState = .notStarted
    private var prepareTask: Task<Void, any Error>?
    /// `VoiceSettings.setupChosen`: false loads nothing but the mic, and listening throws `.notSetUp`.
    public private(set) var setupChosen: Bool
    /// Bumped when the settings need more than the last prepare loaded, so a prepare in flight
    /// for the old settings doesn't end as `.ready`.
    private var needsGeneration = 0
    public private(set) var soundsEnabled: Bool

    /// A listen transition is running; later ones wait in `waiters`, first come first served.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Bumped on every start; capture loops and ticks from an older listen are ignored.
    private var session = 0
    private var safeguards: ListenSafeguards?
    private var micMeter = LevelMeter.mic()
    private var framer = MeterFramer()
    private var captureTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    /// Audio reaches STT and VAD while true, including the drain after the mic stops.
    private var acceptingAudio = false
    private var captureError: (any Error)?
    private var held: (result: Result<String, any Error>, speechSeconds: Double)?
    /// This listen is a dictation (`startListening(.dictation)`).
    private var dictating = false
    /// A dictation's finished chunks, in order, and when the transcriber's current one began.
    private var dictatedParts: [String] = []
    private var chunkStartedAt: Double = 0
    /// Audio chunks fully handled in this listen; a deterministic hook for tests.
    private(set) var processedChunks = 0

    private var replyMeter = LevelMeter.reply()
    private var replyTask: Task<Void, Never>?
    private var replyGeneration = 0

    /// - Parameter tickInterval: how often safeguards are checked when no audio arrives (a stalled mic
    ///   must still hit the 2-minute stop). `nil` checks only on audio, for tests.
    /// - Parameter levelBuffer: meter frames kept for a slow `levels` consumer.
    public init(
        mic: any MicCapture,
        transcriber: any SpeechTranscriber,
        detector: any SpeechActivityDetector,
        speaker: any SpeechSpeaker,
        sounds: any SoundPlayer,
        clock: any VoiceClock = SystemVoiceClock(),
        limits: ListenSafeguards.Limits = .init(),
        dictationLimits: ListenSafeguards.Limits = .dictation,
        tickInterval: Duration? = .milliseconds(250),
        levelBuffer: Int = 8,
        soundsEnabled: Bool = true,
        setupChosen: Bool = true,
        store: ModelStore? = nil,
        kokoroLexicon: URL? = nil,
        finishDeadline: Duration? = .seconds(30),
        slowFinishNotice: Duration? = .milliseconds(1500),
        longFinishNotice: Duration? = .seconds(10)
    ) {
        self.slowFinishNotice = slowFinishNotice
        self.longFinishNotice = longFinishNotice
        self.finishDeadline = finishDeadline
        self.soundsEnabled = soundsEnabled
        self.setupChosen = setupChosen
        self.store = store
        self.kokoroLexicon = kokoroLexicon
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
        (levels, levelContinuation) = AsyncStream.makeStream(of: Level.self, bufferingPolicy: .bufferingNewest(levelBuffer))
        self.mic = mic
        self.transcriber = transcriber
        self.detector = detector
        self.speaker = speaker
        self.sounds = sounds
        self.clock = clock
        self.limits = limits
        self.dictationLimits = dictationLimits
        self.tickInterval = tickInterval
        if let router = speaker as? ReplyVoiceSpeaker {
            let status = router.status
            let continuation = continuation
            Task {
                for await change in status {
                    switch change {
                    case .problem(let line): continuation.yield(.replyVoiceProblem(line))
                    case .recovered: continuation.yield(.replyVoiceRecovered)
                    }
                }
            }
        }
    }

    /// Settings › Voice: which voice speaks the next reply. Call it again after an ElevenLabs key is
    /// saved, so a remembered key problem is cleared.
    public func setReplyVoice(_ voice: ReplyVoice) async {
        guard let router = speaker as? ReplyVoiceSpeaker else { return }
        if await router.setChoice(voice), setupChosen { needsMore() }
    }

    /// Onboarding's voice step chose a setup (or, false, not yet). When that needs downloads, the
    /// state goes back to `.notStarted`: call `prepare()` to load them.
    public func setSetupChosen(_ chosen: Bool) {
        guard chosen != setupChosen else { return }
        setupChosen = chosen
        if chosen { needsMore() }
    }

    /// Deletes a downloaded part to free the space (Settings › Voice). Models already loaded keep working
    /// until the app quits, so choosing the part again in the same run downloads nothing until the next
    /// launch. The caller changes the settings so nothing downloads it again unasked (`.lumiVoice`:
    /// replies in the Mac voice; `.speechRecognition`: no setup chosen). Throws `.busy` while voice is
    /// loading, listening or speaking, so it never deletes a download in progress.
    /// The release app (bundle ID `com.loomtable.lumi`) owns the shared models and FluidAudio's
    /// lexicon; a copy never deletes them. Tests set it.
    var isReleaseApp = BuddyCore.paths.isRelease
    func setReleaseAppForTesting(_ release: Bool) { isReleaseApp = release }

    public func removeModels(_ part: VoiceModelPart) async throws {
        guard prepareTask == nil, state == .idle, !busy else { throw VoiceError.busy }
        guard isReleaseApp else { throw VoiceError.sharedModels }
        guard let store, let kokoroLexicon else { return }
        try VoiceStorage.remove(part, store: store, lexicon: kokoroLexicon, sharedLexicon: isReleaseApp)
    }

    /// The settings now need something not loaded: the next `prepare()` loads it.
    private func needsMore() {
        needsGeneration += 1
        if prepareState == .ready { setPrepare(.notStarted) }
    }

    // MARK: Setup

    /// Loads models, warms the voice and prepares the mic engine (without running the mic). Reports
    /// each step as `.prepare(_)` events and `prepareState`. A call while one is running joins it; a
    /// call after a failure retries.
    public func prepare() async throws {
        while true {
            while let prepareTask { try await prepareTask.value }
            if prepareState == .ready { return }
            let task = Task { try await self.performPrepare() }
            prepareTask = task
            try await task.value
            // The settings needed more while it ran (it ended `.notStarted`): load that too.
            if prepareState == .ready { return }
        }
    }

    /// Clears `prepareTask` itself before it ends, so a caller waiting on it never sees it again.
    private func performPrepare() async throws {
        defer { prepareTask = nil }
        let generation = needsGeneration
        do {
            if setupChosen { try await prepareVoice() }
            setPrepare(.preparing(.microphone))
            try await mic.prepare()
            // The settings needed more meanwhile: not ready for them yet.
            setPrepare(generation == needsGeneration ? .ready : .notStarted)
        } catch {
            setPrepare(.failed(String(describing: error)))
            throw error
        }
    }

    /// Speech model, voice activity and the reply voice. Each loads once, so after a settings change
    /// only what's new does any work.
    private func prepareVoice() async throws {
        setPrepare(.preparing(.speechModel(nil)))
        // FluidAudio reports on its own queue. One stream, drained in order on this actor, keeps the
        // reports in order; draining it before the next step means none arrives late.
        let (reports, report) = AsyncStream.makeStream(of: ModelLoadProgress.self)
        let drain = Task { for await progress in reports { self.speechModelProgress(progress) } }
        do {
            try await transcriber.load { report.yield($0) }
        } catch {
            report.finish()
            await drain.value
            throw error
        }
        report.finish()
        await drain.value
        setPrepare(.preparing(.voiceActivity))
        try await detector.load()
        setPrepare(.preparing(.voice(nil)))
        if let router = speaker as? ReplyVoiceSpeaker {
            let (reports, report) = AsyncStream.makeStream(of: ModelLoadProgress.self)
            let drain = Task { for await progress in reports { self.voiceProgress(progress) } }
            await router.warmUp { report.yield($0) }
            report.finish()
            await drain.value
        } else {
            await speaker.warmUp()
        }
    }

    private func voiceProgress(_ progress: ModelLoadProgress) {
        guard case .preparing(.voice) = prepareState else { return }
        setPrepare(.preparing(.voice(progress)))
    }

    private func setPrepare(_ new: PrepareState) {
        guard new != prepareState else { return }
        prepareState = new
        emit(.prepare(new))
    }

    private func speechModelProgress(_ progress: ModelLoadProgress) {
        guard case .preparing(.speechModel) = prepareState else { return }
        setPrepare(.preparing(.speechModel(progress)))
    }

    /// Settings › Sounds. Off silences every sound, including the discard tone.
    public func setSoundsEnabled(_ enabled: Bool) {
        soundsEnabled = enabled
    }

    /// Settings › Voice Isolation. Applies from the next listen; no restart.
    public func setVoiceProcessing(_ enabled: Bool) async throws {
        try await mic.setVoiceProcessing(enabled)
    }

    // MARK: Listening

    /// Starts listening. Stops any reply first (buddy key while speaking). Returns once the mic has
    /// real audio (about 450 ms with voice processing), so a cue played after it is honest. That wait is
    /// outside the lock: send, Esc and double-tap act at once.
    /// `.dictation`: no stop on silence, a 60-minute limit, and the transcript built chunk by chunk.
    public func startListening(_ kind: ListenKind = .question) async throws {
        try await exclusive { try await self.performStart(kind) }
        await mic.untilLive()
    }

    /// The second tap or the release: finalises and returns the transcript for the bridge (about 30 ms
    /// after the last sample with Parakeet). A held recording is returned instead if there is one.
    public func finishListening() async throws -> String {
        try await exclusive { try await self.performFinish() }
    }

    /// Returns and clears the recording kept by an auto-stop: nil when there is none, and throws the
    /// error if finalising it failed.
    public func sendHeld() async throws -> String? {
        try await exclusive {
            guard await self.state == .held else { return nil }
            return try await self.takeHeld()
        }
    }

    /// Seconds of speech the VAD has heard since this listen began (the safeguards' total), or 0
    /// when not listening. The switcher reads it on release: enough speech sends, less switches.
    public func heardSpeechSeconds() -> Double {
        guard state == .listening else { return 0 }
        return safeguards?.speechSeconds(at: clock.now()) ?? 0
    }

    /// Discards the current or held recording. Over 30 s of speech needs `confirmed: true`; to
    /// stop the mic while asking, `interrupt(.confirmingDiscard)` first. `playSound: false` for discards
    /// the user didn't ask for (double-tap to the text box, new conversation, error paths).
    public func discard(confirmed: Bool = false, playSound: Bool = true) async -> DiscardResult {
        (try? await exclusive { await self.performDiscard(confirmed: confirmed, playSound: playSound) }) ?? .nothingToDiscard
    }

    /// Screen lock, sleep, screen sharing, typing or `.confirmingDiscard`: stops and keeps the
    /// recording (unless nothing was said, except for `.confirmingDiscard`, which always holds).
    public func interrupt(_ reason: ListenStopReason) async {
        _ = try? await exclusive { await self.performAutoStop(reason, session: nil) }
    }

    // MARK: Speaking

    /// Speaks a reply. Ignored while the user is talking or a recording is held. Returns once playback
    /// has started (false if it was ignored or stopped first); the end is reported as `.speakingFinished`.
    ///
    /// With `continuing`, a reply that is still preparing or playing isn't cut: `text` is queued after
    /// it on the same reply, and this returns true once it's queued (one `.speakingFinished` at the
    /// end of both). A reply still preparing is waited for; if it's stopped or replaced meanwhile,
    /// this returns false and says nothing. With nothing in flight, or a voice that can't append, it
    /// starts a new reply.
    @discardableResult
    public func speak(_ text: String, continuing: Bool = false) async throws -> Bool {
        // A transition in flight (even a no-op one) finishes first; then the state decides.
        await settle()
        if continuing, state == .preparingReply {
            let generation = replyGeneration
            await withCheckedContinuation { preparationWaiters.append($0) }
            // The reply it continues was stopped or replaced while it prepared; it goes with it.
            guard generation == replyGeneration else { return false }
        }
        if continuing, state == .speaking {
            let generation = replyGeneration
            if await speaker.continueReply(text) {
                // Stopped while it was being queued: stopSpeaking() already silenced it.
                return generation == replyGeneration
            }
            // The reply ended while we asked; fall through and start a new one.
            await settle()
        }
        switch state {
        case .idle: break
        case .speaking, .preparingReply: await stopSpeaking()
        case .starting, .listening, .finishing, .held: return false
        }
        guard state == .idle else { return false }
        replyGeneration += 1
        let generation = replyGeneration
        state = .preparingReply
        let levels: AsyncStream<Float>
        do {
            levels = try await speaker.speak(text)
        } catch {
            if generation == replyGeneration { state = .idle }
            throw error
        }
        // Stopped, or the user started talking, while it was synthesising: stopSpeaking() already told
        // the speaker, which drops a reply stopped mid-synthesis.
        guard generation == replyGeneration, state == .preparingReply else { return false }
        replyMeter.reset()
        state = .speaking
        replyTask = Task { await self.consumeReply(levels, generation: generation) }
        return true
    }

    /// Stops the reply within 150 ms, including one still being synthesised. Emits
    /// `.speakingFinished` either way, also for a reply that was stopped before it played, so the UI
    /// can always hide the stop button on that event.
    public func stopSpeaking() async {
        guard state == .speaking || state == .preparingReply else { return }
        replyGeneration += 1
        state = .idle
        replyTask?.cancel()
        replyTask = nil
        level(.reply(0))
        emit(.speakingFinished)
        await speaker.stop()
    }

    // MARK: Sounds

    /// Plays an interface sound, unless Sounds is off or the user is speaking.
    public func play(_ sound: BuddySound) async {
        guard soundsEnabled else { return }
        if state == .listening, safeguards?.isSpeechActive == true { return }
        await sounds.play(sound)
    }

    // MARK: Transitions

    /// Waits for any in-flight transition, then runs `body` as the only one. `body` must not call
    /// `exclusive` again (it would wait for itself).
    private func exclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
        // release() handed the lock straight to us; `busy` is still true.
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// Waits until no transition is running.
    private func settle() async {
        await acquire()
        release()
    }

    private func performStart(_ kind: ListenKind) async throws {
        switch state {
        case .listening: return
        case .held: throw VoiceError.recordingHeld
        case .speaking, .preparingReply: await stopSpeaking()
        case .idle, .starting, .finishing: break
        }
        guard setupChosen else { throw VoiceError.notSetUp }
        state = .starting
        session += 1
        let current = session
        await retireCapture()
        do {
            do {
                try await bounded { try await $0.begin() }
            } catch VoiceModelError.notLoaded {
                throw VoiceError.stillSettingUp
            }
            await detector.reset()
            captureError = nil
            processedChunks = 0
            micMeter.reset()
            framer.reset()
            dictating = kind == .dictation
            dictatedParts = []
            chunkStartedAt = clock.now()
            safeguards = ListenSafeguards(startedAt: chunkStartedAt, limits: dictating ? dictationLimits : limits)
            let stream = try await mic.start()
            state = .listening
            acceptingAudio = true
            captureTask = Task { await self.consume(stream, session: current) }
            if let tickInterval {
                tickTask = Task { await self.tickLoop(every: tickInterval, session: current) }
            }
        } catch {
            // Nothing began when the model isn't loaded yet; a cancel would only queue behind the load.
            if (error as? VoiceError) != .stillSettingUp { await cancelTranscriber() }
            safeguards = nil
            state = .idle
            throw error
        }
    }

    private func performFinish() async throws -> String {
        switch state {
        case .held: return try takeHeld()
        case .listening: break
        default: throw VoiceError.notListening
        }
        state = .finishing
        await stopCapture()
        defer { state = .idle }
        return try await finalTranscript()
    }

    /// The transcript once capture has stopped: a dictation's earlier chunks and the last one. A
    /// failure keeps the chunks already done (never lose speech) and throws only with none.
    private func finalTranscript() async throws -> String {
        let parts = dictatedParts
        dictatedParts = []
        let last: Result<String, any Error>
        if let captureError {
            await cancelTranscriber()
            last = .failure(captureError)
        } else {
            do {
                last = .success(try await finishWithNotices { try await $0.finish() }
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                last = .failure(error)
            }
        }
        switch last {
        case .success(let text): return Self.joined(parts + [text])
        case .failure(let error):
            guard !parts.isEmpty else { throw error }
            return Self.joined(parts)
        }
    }

    static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A transcriber call, cut off at `finishDeadline` with `.transcriptionTimedOut`. Its calls run one
    /// at a time, so one hung on a saturated Neural Engine would hold every later begin, finish and
    /// cancel (and this actor's `exclusive` lock with them) for good.
    private func bounded<T: Sendable>(_ call: @escaping @Sendable (any SpeechTranscriber) async throws -> T) async throws -> T {
        let transcriber = self.transcriber
        let work = Task { try await call(transcriber) }
        guard let finishDeadline else { return try await work.value }
        switch await race(work, within: finishDeadline) {
        case .done(let result): return try result.get()
        case .timedOut: throw VoiceError.transcriptionTimedOut
        }
    }

    /// A bounded finish that says `.transcribing` while it takes long.
    private func finishWithNotices(_ call: @escaping @Sendable (any SpeechTranscriber) async throws -> String) async throws -> String {
        let notice = slowFinishNotice.map { delay in
            Task { [weak self, longFinishNotice] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.emit(.transcribing(long: false))
                guard let longFinishNotice, longFinishNotice > delay else { return }
                try? await Task.sleep(for: longFinishNotice - delay)
                guard !Task.isCancelled else { return }
                await self?.emit(.transcribing(long: true))
            }
        }
        defer { notice?.cancel() }
        return try await bounded(call)
    }

    /// `cancel()` takes effect when it starts (it ends the session at once), so after the deadline
    /// it's safe to move on while it waits its turn.
    private func cancelTranscriber() async {
        _ = try? await bounded { await $0.cancel() }
    }

    private func takeHeld() throws -> String {
        guard let held else { throw VoiceError.notListening }
        self.held = nil
        state = .idle
        return try held.result.get()
    }

    private func performDiscard(confirmed: Bool, playSound: Bool) async -> DiscardResult {
        switch state {
        case .listening:
            let now = clock.now()
            if !confirmed, let g = safeguards, g.discardNeedsConfirmation(at: now) {
                return .needsConfirmation(speechSeconds: g.speechSeconds(at: now))
            }
            state = .finishing
            acceptingAudio = false
            await mic.stop()
            await retireCapture()
            stopTicking()
            level(.mic(0))
            await cancelTranscriber()
            dictatedParts = []
            state = .idle
        case .held:
            let speech = held?.speechSeconds ?? 0
            if !confirmed, speech > limits.confirmDiscardOver { return .needsConfirmation(speechSeconds: speech) }
            held = nil
            state = .idle
        case .idle, .starting, .finishing, .preparingReply, .speaking:
            return .nothingToDiscard
        }
        if playSound { await play(.discard) }
        return .discarded
    }

    /// Stops listening on its own, keeps the tail, and holds the transcript without sending it.
    /// - Parameter session: the listen that asked; nil means whichever is current.
    private func performAutoStop(_ reason: ListenStopReason, session asked: Int?) async {
        guard state == .listening, asked == nil || asked == session else { return }
        state = .finishing
        let speech = safeguards?.speechSeconds(at: clock.now()) ?? 0
        let heardSpeech = safeguards?.heardSpeech ?? false
        await stopCapture()
        let result: Result<String, any Error>
        do {
            result = .success(try await finalTranscript())
        } catch {
            result = .failure(error)
        }
        // Nothing was said (a tap and then silence): there's nothing to keep, and holding an empty
        // recording would block the next tap.
        // A failed finalise is always held, so the error reaches the user instead of vanishing.
        let keep: Bool
        if reason != .confirmingDiscard, !heardSpeech, case .success(let text) = result, text.isEmpty {
            keep = false
            state = .idle
        } else {
            keep = true
            held = (result, speech)
            state = .held
        }
        emit(.autoStopped(reason, held: keep))
    }

    /// A revoked permission leaves nothing worth keeping; any other failure keeps what was heard.
    private func performMicFailure(_ problem: MicProblem, session asked: Int) async {
        guard state == .listening, asked == session else { return }
        if problem == .permissionDenied {
            state = .finishing
            acceptingAudio = false
            await mic.stop()
            await retireCapture()
            stopTicking()
            level(.mic(0))
            await cancelTranscriber()
            state = .idle
        } else {
            await performAutoStop(.micFailed, session: asked)
        }
    }

    // MARK: Capture

    private func emit(_ event: Event) { continuation.yield(event) }
    private func level(_ value: Level) { levelContinuation.yield(value) }

    /// Stops the mic and lets the capture loop drain what was already captured.
    private func stopCapture() async {
        await mic.stop()
        await captureTask?.value
        captureTask = nil
        acceptingAudio = false
        stopTicking()
        level(.mic(0))
    }

    /// Ends an older capture loop without processing its backlog.
    private func retireCapture() async {
        captureTask?.cancel()
        await captureTask?.value
        captureTask = nil
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func consume(_ stream: AsyncStream<MicEvent>, session current: Int) async {
        for await event in stream {
            guard current == session else { return }
            switch event {
            case .audio(let chunk):
                await handleAudio(chunk, session: current)
            case .rebuilt:
                emit(.micRebuilt)
            case .problem(let problem):
                emit(.micProblem(problem))
                schedule { await self.performMicFailure(problem, session: current) }
            }
        }
    }

    private func handleAudio(_ chunk: AudioChunk, session current: Int) async {
        guard current == session, acceptingAudio else { return }
        do {
            try await transcriber.append(chunk.samples)
        } catch {
            if captureError == nil { captureError = error }
        }
        let now = clock.now()
        var activity: SpeechActivity?
        do {
            activity = try await detector.process(chunk.samples)
            if let activity { safeguards?.observe(activity, at: now) }
        } catch {
            // Without the VAD, silence can't be told from speech; don't cut the user off for it.
            safeguards?.disableSilenceStop()
        }
        if dictating, state == .listening, current == session,
           Self.nextChunk(after: now - chunkStartedAt, pause: activity == .ended) {
            await rotateChunk(at: now)
        }
        if state == .listening, current == session {
            for rms in framer.push(chunk.samples) {
                level(.mic(micMeter.update(rms: rms, dt: MeterFramer.frameSeconds)))
            }
            checkSafeguards(at: now, session: current)
        }
        processedChunks += 1
    }

    /// A dictation is transcribed in chunks, so its length never matters and each finish is as
    /// quick as a short question's: at the first pause after 45 s, or after 5 minutes regardless.
    static func nextChunk(after elapsed: Double, pause: Bool) -> Bool {
        (pause && elapsed >= 45) || elapsed >= 300
    }

    /// Finishes the dictation's current chunk and begins the next. The capture loop waits meanwhile
    /// (the mic's stream buffers), so no audio falls between chunks. A chunk that fails to finish
    /// is lost alone; if the next can't begin, the chunks so far are still returned at the end.
    private func rotateChunk(at now: Double) async {
        chunkStartedAt = now
        guard captureError == nil else { return }
        if let text = try? await bounded({ try await $0.finish() }) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { dictatedParts.append(text) }
        }
        do {
            try await bounded { try await $0.begin() }
        } catch {
            captureError = error
        }
    }

    private func tickLoop(every interval: Duration, session current: Int) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, current == session, state == .listening else { return }
            checkSafeguards(at: clock.now(), session: current)
        }
    }

    private func checkSafeguards(at now: Double, session current: Int) {
        guard state == .listening, let actions = safeguards?.tick(at: now) else { return }
        for action in actions {
            switch action {
            case .warnNearLimit: emit(.nearLimit)
            case .stop(let reason): schedule { await self.performAutoStop(reason, session: current) }
            }
        }
    }

    /// Runs a transition from inside the capture loop or a tick without waiting on it: the transition
    /// drains that same loop, so awaiting it there would deadlock.
    private func schedule(_ body: @escaping @Sendable () async -> Void) {
        Task { _ = try? await self.exclusive(body) }
    }

    // MARK: Reply

    private func consumeReply(_ levels: AsyncStream<Float>, generation: Int) async {
        for await rms in levels {
            guard generation == replyGeneration else { return }
            level(.reply(replyMeter.update(rms: rms, dt: MeterFramer.frameSeconds)))
        }
        guard generation == replyGeneration, state == .speaking else { return }
        state = .idle
        level(.reply(0))
        emit(.speakingFinished)
    }
}

extension VoiceController {
    /// The speech-to-text `model` runs on: the Mac's own recognition, or Parakeet.
    static func transcriber(for model: SpeechModel, store: ModelStore) -> any SpeechTranscriber {
        model.isParakeet ? ParakeetTranscriber(model: model, store: store) : AppleSpeechTranscriber()
    }

    /// The production wiring: real mic, the speech model (`settings.speechModel`), Silero, Kokoro with the
    /// system voice as fallback, and interface sounds, all sharing one playback engine. Pass `mic` to feed
    /// audio from elsewhere, such as a `FileMic` in end-to-end tests.
    public static func live(settings: VoiceSettings = VoiceSettings(), mic: (any MicCapture)? = nil) -> VoiceController {
        let store = ModelStore(settings: settings)
        let playback = AudioPlayback()
        let system = SystemSpeaker(playback: playback)
        return VoiceController(
            mic: mic ?? EngineMic(voiceProcessing: settings.voiceProcessing),
            transcriber: transcriber(for: settings.speechModel, store: store),
            detector: SileroDetector(store: store),
            speaker: ReplyVoiceSpeaker(
                onDevice: FallbackSpeaker(
                    primary: KokoroSpeaker(voice: settings.kokoroVoice, store: store, playback: playback),
                    fallback: system
                ),
                system: system,
                onDeviceDownload: DiskProgress(folders: [store.kokoroV3English, ModelStore.unredirectableKokoroG2P],
                                               expectedBytes: VoiceDownloadSize.lumiVoice),
                choice: settings.replyVoice,
                makeElevenLabs: { ElevenLabsSpeaker(voiceID: $0, client: ElevenLabsClient(), playback: playback) }
            ),
            sounds: TonePlayer(playback: playback),
            soundsEnabled: settings.soundsEnabled,
            setupChosen: settings.setupChosen,
            store: store,
            kokoroLexicon: VoiceStorage.kokoroLexicon
        )
    }
}
