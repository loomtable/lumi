import AVFAudio
import AVFoundation
import CoreAudio
import Dispatch
import Foundation
import Synchronization

/// The real mic: AVAudioEngine with voice processing (on by default), an AVAudioSinkNode on a prepared
/// engine, and 16 kHz mono out. Every rule here was measured:
///
/// - Sink node, never `installTap` (taps deliver 100 ms buffers). Warm start → first buffer p50 69 ms.
/// - `prepare()` doesn't run the mic hardware, so no privacy indicator until `start()`.
/// - After a configuration change, a fresh engine built from `inputNode.inputFormat(forBus:)`. Reusing the
///   engine either throws an uncatchable NSException (stale format, VP off) or fails kAUInitialize -10875
///   for a while (VP on), so rebuilds retry.
/// - With voice processing on, the engine ignores default-input changes, so we listen for them ourselves.
/// - A revoked permission shows up as exact zeros; `InputHealth` reports it.
/// - macOS 26 binds the input node to a per-process default-device aggregate, and a new engine makes Core
///   Audio rebuild it: about 0.5 s after every build the engine posts a configuration change of its own
///   (and stops itself if running). Within `settleWindow` of a build, a change that isn't a device change is
///   that echo: the same engine is reconnected in place. Rebuilding for it builds the next echo, which looped
///   forever after launch (idle) and restarted a first capture every half second (the mic indicator flickered).
///
/// Voice processing only when it's needed: a capture uses VP only if Voice Isolation is on
/// and another app is playing audio at the press, where its echo canceller keeps that audio out of the
/// transcript. Otherwise the capture is plain: live in about 70 ms, so the first word is kept (VP takes
/// about 450 ms before real audio, which clipped it). Idle is always plain and prepared: a VP engine ducks
/// every other app's audio by 30 dB for as long as it exists. VP is turned on with `.min` ducking (−8 dB)
/// on a stopped engine (enabling it on a prepared one fails, -10849) and off again at `stop()`. A second,
/// plain engine can't bridge the VP start-up: turning VP on stops other capture in the process (measured).
public actor EngineMic: MicCapture {
    public static let micAuthorized: @Sendable () -> Bool = {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Asks for the mic on first use; only `.denied` / `.restricted` count as no.
    public static let requestMicAccess: @Sendable () async -> Bool = {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    private let permission: @Sendable () -> Bool
    private let requestPermission: @Sendable () async -> Bool
    private let makeEngine: MicEngineFactory
    private let coalesceDelay: Duration
    private let retryDelay: Duration
    /// How long `start()` waits for the first non-zero sample before returning anyway.
    private let liveTimeout: Duration
    /// How long after a build a format-only change counts as the new engine's own echo (see above).
    private let settleWindow: Duration
    private let pipeline: CapturePipeline
    /// Settings › Voice Isolation: whether captures may use voice processing (when other audio plays).
    private var voiceProcessing: Bool
    /// Whether another app is playing audio, checked at each `start()`.
    private let otherAudioPlaying: @Sendable () -> Bool
    /// What this capture decided at `start()`; a mid-capture rebuild keeps it.
    private var captureUsesVoiceProcessing = false

    private var engine: (any MicEngine)?
    /// The Voice Isolation setting the current engine was built for.
    private var engineBuiltForVoiceProcessing = false
    /// Hardware format the current engine was built with, to tell real changes from start-up noise.
    private var builtFormat: MicFormat?
    /// When the current engine was built, for `settleWindow`.
    private var builtAt: ContinuousClock.Instant?
    /// Set synchronously by the notification and HAL callbacks, before any hop or sleep, so a `start()`
    /// in the coalescing window never starts a stale engine. Internal for tests.
    nonisolated let changes = ChangeFlags()
    private var running = false
    /// One recovery at a time. `start()` and `prepare()` wait for it instead of recovering themselves.
    private var recoveryTask: Task<Void, Never>?
    private var changedDuringRecovery = false
    /// Recoveries started, for tests.
    private(set) var recoveryCount = 0

    private let halQueue = DispatchQueue(label: "BuddyVoice.EngineMic.hal")
    private var halListener: AudioObjectPropertyListenerBlock?
    private let listensForDefaultInput: Bool

    public init(voiceProcessing: Bool = true, permission: @escaping @Sendable () -> Bool = EngineMic.micAuthorized) {
        self.init(voiceProcessing: voiceProcessing, permission: permission, requestPermission: EngineMic.requestMicAccess,
                  engineFactory: AVMicEngine.factory, otherAudioPlaying: { AudioHAL.otherProcessIsPlayingOutput() })
    }

    init(
        voiceProcessing: Bool,
        permission: @escaping @Sendable () -> Bool,
        requestPermission: @escaping @Sendable () async -> Bool,
        engineFactory: @escaping MicEngineFactory,
        otherAudioPlaying: @escaping @Sendable () -> Bool = { true },
        coalesceDelay: Duration = .milliseconds(150),
        retryDelay: Duration = .milliseconds(100),
        stallTimeout: Double = 1.0,
        firstFrameTimeout: Double = 3.0,
        liveTimeout: Duration = .seconds(1),
        settleWindow: Duration = .seconds(2),
        listenForDefaultInput: Bool = true
    ) {
        self.voiceProcessing = voiceProcessing
        self.permission = permission
        self.requestPermission = requestPermission
        makeEngine = engineFactory
        self.otherAudioPlaying = otherAudioPlaying
        self.coalesceDelay = coalesceDelay
        self.retryDelay = retryDelay
        self.liveTimeout = liveTimeout
        self.settleWindow = settleWindow
        listensForDefaultInput = listenForDefaultInput
        pipeline = CapturePipeline(permission: permission, stallTimeout: stallTimeout, firstFrameTimeout: firstFrameTimeout)
    }

    // Isolated so it may touch the engine and blocks, which aren't Sendable.
    isolated deinit {
        if let halListener { AudioHAL.removeDefaultInputListener(halListener, queue: halQueue) }
        engine?.invalidate()
    }

    // MARK: MicCapture

    public func prepare() async throws {
        installDefaultInputListener()
        await waitForRecovery()
        // Never rebuild under a live capture; changes while running belong to the recovery path.
        guard !running else { return }
        switch idleEngineAction() {
        case .keep:
            engine?.prepare()
        case .refresh:
            if await refreshInPlace() { engine?.prepare() } else { try await buildRetrying() }
        case .rebuild:
            try await buildRetrying()
        }
    }

    /// Whether voice processing is on in the current engine, for tests: off whenever idle.
    var voiceProcessingActive: Bool { engine?.voiceProcessingEnabled ?? false }

    public func start() async throws -> AsyncStream<MicEvent> {
        let (stream, continuation) = AsyncStream<MicEvent>.makeStream(bufferingPolicy: .bufferingNewest(1_024))
        let allowed = if permission() { true } else { await requestPermission() }
        guard allowed else {
            continuation.yield(.problem(.permissionDenied))
            continuation.finish()
            return stream
        }
        if running { await stop() }
        try await prepare()
        captureUsesVoiceProcessing = voiceProcessing && otherAudioPlaying()
        try await enableVoiceProcessingForCapture()
        guard let engine else { throw MicError.notPrepared }
        pipeline.begin(continuation, ring: engine.ring)
        running = true
        do {
            try engine.start()
            pipeline.engineStarted()
        } catch {
            // A device that changed since prepare() can fail the first start; same path as a config change.
            await recoverNow()
            if self.engine?.isRunning != true {
                running = false
                pipeline.end()
                // The recovery's engines are built with VP on; never leave one at idle.
                self.engine?.stop()
                await settleIdle()
                throw MicError.startFailed("\(error)")
            }
        }
        return stream
    }

    public func stop() async {
        running = false
        engine?.stop()
        pipeline.end()
        await settleIdle()
    }

    /// Returns once real (non-zero) audio has arrived, so the caller's "listening" cue is honest. Gives up
    /// after `liveTimeout` (a revoked permission gives zeros forever, and `InputHealth` reports that) and
    /// when the capture stops.
    public func untilLive() async {
        let deadline = ContinuousClock.now + liveTimeout
        while running, !pipeline.hasSignal, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Turns VP on for this capture when it was chosen. The idle engine is prepared, so it's stopped first
    /// (VP can't be switched on a prepared engine). If it won't switch, a fresh VP engine (slower).
    private func enableVoiceProcessingForCapture() async throws {
        guard captureUsesVoiceProcessing, let engine, !engine.voiceProcessingEnabled else { return }
        do {
            engine.stop()
            try engine.setVoiceProcessing(true)
            refreshFormat()
        } catch {
            try await buildRetrying(forCapture: true)
        }
    }

    /// Idle: VP off, so nothing is ducked, and prepared for a warm plain start (a prepared engine doesn't
    /// run the mic hardware, S5).
    private func settleIdle() async {
        guard switchVoiceProcessingOff() else {
            // The VP engine is already released, so even a failed rebuild leaves none ducking other apps.
            try? await buildRetrying()
            return
        }
        engine?.prepare()
    }

    /// Turns VP off in the stopped engine, or releases the engine if it won't switch. Synchronous, so no
    /// reference to a VP engine outlives it across an await.
    private func switchVoiceProcessingOff() -> Bool {
        guard let engine, engine.voiceProcessingEnabled else { return true }
        do {
            try engine.setVoiceProcessing(false)
            refreshFormat()
            return true
        } catch {
            engine.invalidate()
            self.engine = nil
            builtFormat = nil
            return false
        }
    }

    /// The engine's format changed because VP was switched, not because the device did.
    private func refreshFormat() {
        guard let engine else { return }
        let format = engine.hardwareFormat
        builtFormat = format
        pipeline.attach(ring: engine.ring, inputSampleRate: format.sampleRate)
    }

    public func setVoiceProcessing(_ enabled: Bool) async throws {
        voiceProcessing = enabled
        // Applied by the next prepare() or start(); a capture in progress keeps its engine.
        guard !running, engine != nil, engineBuiltForVoiceProcessing != enabled else { return }
        await waitForRecovery()
        // A start() may have resumed first and be capturing now.
        guard !running, engine != nil, engineBuiltForVoiceProcessing != voiceProcessing else { return }
        try await buildRetrying()
    }

    // MARK: Engine

    /// Idle builds are plain and prepared; capture builds have VP on when this capture chose it.
    private func build(forCapture: Bool = false) throws {
        engine?.invalidate()
        engine = nil
        builtFormat = nil
        // A fresh engine binds to the devices as they are now, so earlier changes are accounted for. Clear
        // before making it: a change that lands while it's being made must survive for the next check.
        let earlier = changes.take()
        let generation = changes.nextGeneration()
        let engine: any MicEngine
        do {
            engine = try makeEngine(forCapture && captureUsesVoiceProcessing, EngineMic.configurationChangeBlock(mic: self, generation: generation, changes: changes))
        } catch {
            changes.restore(earlier)
            throw error
        }
        let format = engine.hardwareFormat
        guard format.isValid else {
            engine.invalidate()
            changes.restore(earlier)
            throw MicError.invalidFormat(sampleRate: format.sampleRate, channels: format.channels)
        }
        engine.prepare()
        pipeline.attach(ring: engine.ring, inputSampleRate: format.sampleRate)
        self.engine = engine
        builtFormat = format
        builtAt = .now
        engineBuiltForVoiceProcessing = voiceProcessing
    }

    /// Voice processing reports 0 Hz / 0 ch for a while after a change (S5), so building fails until the
    /// device settles. Retries like `rebuildAndStart`, and gives up if a capture starts meanwhile.
    private func buildRetrying(forCapture: Bool = false) async throws {
        var lastError: any Error = MicError.notPrepared
        for attempt in 0..<10 {
            do {
                try build(forCapture: forCapture)
                return
            } catch {
                lastError = error
                if attempt < 9 { try? await Task.sleep(for: retryDelay) }
                guard !running else { throw lastError }
            }
        }
        throw lastError
    }

    private enum EngineAction { case keep, refresh, rebuild }

    /// What the next start needs: a new engine when there's none yet, the setting changed, the device
    /// changed, or the format changed after the settle window; the same engine reconnected when the format
    /// changed within it (the build's own echo).
    private func idleEngineAction() -> EngineAction {
        guard let engine, engineBuiltForVoiceProcessing == voiceProcessing, !engine.voiceProcessingEnabled else { return .rebuild }
        guard changes.takeDirty() else { return .keep }
        if changes.takeDeviceChanged() { return .rebuild }
        guard formatChanged() else { return .keep }
        return settling() ? .refresh : .rebuild
    }

    /// Within `settleWindow` of the current engine's build.
    private func settling() -> Bool {
        guard let builtAt else { return false }
        return ContinuousClock.now - builtAt < settleWindow
    }

    /// Reconnects the current engine to the current hardware format, stopped, retrying while the format
    /// settles. No new engine, so no new aggregate rebuild and no further echo. False: build one instead.
    private func refreshInPlace() async -> Bool {
        for attempt in 0..<10 {
            guard let engine else { return false }
            engine.stop()
            do {
                try engine.reconnect()
                refreshFormat()
                return true
            } catch {
                if attempt < 9 { try? await Task.sleep(for: retryDelay) }
            }
        }
        return false
    }

    /// The echo stopped a live capture: reconnect and start the same engine.
    private func restartInPlace() async -> Bool {
        guard await refreshInPlace() else { return false }
        guard running else { return true }
        guard let engine else { return false }
        do {
            try engine.start()
            pipeline.engineStarted()
            return true
        } catch {
            return false
        }
    }

    private func formatChanged() -> Bool {
        guard let engine, let builtFormat else { return true }
        if running, !engine.isRunning { return true }     // the engine stopped itself on the change
        let format = engine.hardwareFormat
        return !format.isValid || format != builtFormat
    }

    private func installDefaultInputListener() {
        guard listensForDefaultInput, halListener == nil else { return }
        let block = AudioHAL.listenerBlock(EngineMic.defaultInputChangeHandler(mic: self, changes: changes))
        if AudioHAL.addDefaultInputListener(block, queue: halQueue) == noErr { halListener = block }
    }

    // MARK: Recovery

    fileprivate func configurationChanged(generation: Int) {
        guard generation == changes.generation else { return }    // from an engine we already replaced
        scheduleRecovery()
    }

    fileprivate func defaultInputChanged() {
        // With voice processing on the engine posts nothing. An idle, unprepared engine may not either, so
        // always recover; a configuration change posted as well joins the same coalesced recovery.
        scheduleRecovery()
    }

    private func scheduleRecovery() {
        if recoveryTask != nil {
            changedDuringRecovery = true
            return
        }
        recoveryCount += 1
        recoveryTask = Task { await self.recoveryLoop(immediate: false) }
    }

    private func waitForRecovery() async {
        while let task = recoveryTask { await task.value }
    }

    /// Recovers right away (a failed start) or joins the recovery already running.
    private func recoverNow() async {
        if recoveryTask == nil {
            recoveryCount += 1
            recoveryTask = Task { await self.recoveryLoop(immediate: true) }
        }
        await waitForRecovery()
    }

    private func recoveryLoop(immediate: Bool) async {
        var force = immediate
        pipeline.setRecovering(true)
        repeat {
            changedDuringRecovery = false
            // One HAL change posts several notifications; let them land, then rebuild once.
            if !force { try? await Task.sleep(for: coalesceDelay) }
            let device = changes.takeDeviceChanged()
            _ = changes.takeDirty()
            if force || device || formatChanged() {
                // The current engine's own settle echo: keep it, reconnected (see the type comment).
                let inPlace = !force && !device && settling()
                if running {
                    if inPlace, await restartInPlace() {
                        // Same engine, same device: not announced as `.rebuilt`.
                    } else if !(await rebuildAndStart(announce: !force)) {
                        // `.rebuilt` is for mid-capture rebuilds, not for recovering a failed first start.
                        pipeline.yield(.problem(.engineFailed("could not restart the mic")))
                    }
                } else if inPlace, await refreshInPlace() {
                    engine?.prepare()
                } else {
                    // Idle: rebuild and prepare so the next start is warm, but never start (no mic indicator).
                    try? await buildRetrying()
                }
            }
            force = false
        } while changedDuringRecovery
        pipeline.setRecovering(false)
        recoveryTask = nil
    }

    /// Builds a fresh engine and starts it, retrying while the device settles. Only called while running.
    private func rebuildAndStart(announce: Bool) async -> Bool {
        for attempt in 0..<10 {
            guard running else { return true }
            do {
                try build(forCapture: true)
                guard let engine else { throw MicError.notPrepared }
                pipeline.switchRing(engine.ring)
                try engine.start()
                pipeline.engineStarted()
                if announce { pipeline.yield(.rebuilt) }
                return true
            } catch {
                if attempt < 9 { try? await Task.sleep(for: retryDelay) }
            }
        }
        return false
    }

    // MARK: Callbacks
    //
    // Built in static factories, outside the actor: the audio thread, NotificationCenter and the HAL call
    // these on their own threads, and a closure written inside the actor would inherit its isolation and
    // trap at runtime (found in S5).

    /// Real-time thread: copies channel 0 into the ring. No locks, no allocation.
    static func sinkBlock(ring: SampleRing) -> AVAudioSinkNodeReceiverBlock {
        { timestamp, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            guard let first = buffers.first, let data = first.mData else { return noErr }
            let stamp = timestamp.pointee
            let hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : 0
            // Non-interleaved (one buffer per channel) or interleaved: channel 0 is first either way.
            ring.write(data.assumingMemoryBound(to: Float.self), frames: Int(frameCount),
                       stride: Int(max(1, first.mNumberChannels)), hostTime: hostTime)
            return noErr
        }
    }

    /// Marks the change synchronously, then hops to the actor to schedule a coalesced recovery.
    static func configurationChangeBlock(mic: EngineMic, generation: Int, changes: ChangeFlags) -> @Sendable () -> Void {
        { [weak mic] in
            guard generation == changes.generation else { return }
            changes.markDirty()
            guard let mic else { return }
            Task { await mic.configurationChanged(generation: generation) }
        }
    }

    static func defaultInputChangeHandler(mic: EngineMic, changes: ChangeFlags) -> @Sendable () -> Void {
        { [weak mic] in
            changes.markDeviceChanged()
            guard let mic else { return }
            Task { await mic.defaultInputChanged() }
        }
    }
}

/// Change state shared with callbacks on other threads. Atomics only, so it's Sendable.
final class ChangeFlags: Sendable {
    private let currentGeneration = Atomic<Int>(0)
    private let dirty = Atomic<Bool>(false)
    private let deviceChanged = Atomic<Bool>(false)

    var generation: Int { currentGeneration.load(ordering: .acquiring) }

    func nextGeneration() -> Int { currentGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue }
    func markDirty() { dirty.store(true, ordering: .releasing) }
    func markDeviceChanged() {
        deviceChanged.store(true, ordering: .releasing)
        dirty.store(true, ordering: .releasing)
    }
    func takeDirty() -> Bool { dirty.exchange(false, ordering: .acquiringAndReleasing) }
    func takeDeviceChanged() -> Bool { deviceChanged.exchange(false, ordering: .acquiringAndReleasing) }

    /// Clears both flags and returns what they were.
    func take() -> (dirty: Bool, deviceChanged: Bool) { (takeDirty(), takeDeviceChanged()) }

    /// Puts back flags taken by `take()`, e.g. when the build they were cleared for failed.
    func restore(_ flags: (dirty: Bool, deviceChanged: Bool)) {
        if flags.deviceChanged { markDeviceChanged() }
        if flags.dirty { markDirty() }
    }
}

public enum MicError: Error, Equatable {
    case notPrepared
    case invalidFormat(sampleRate: Double, channels: AVAudioChannelCount)
    case startFailed(String)
}

/// Drains the ring every 10 ms on a serial queue, converts to 16 kHz mono and yields `MicEvent`s.
///
/// `@unchecked Sendable`: every mutable property is touched only on `queue` (public entry points use
/// `queue.sync`/`queue.async`; the timer handler runs on `queue`).
final class CapturePipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BuddyVoice.EngineMic.pipeline", qos: .userInteractive)
    private let permission: @Sendable () -> Bool
    /// Seconds without any frame, while capturing and not recovering, before reporting a stall.
    private let stallTimeout: Double
    /// The same before the first frame after a start: a slow voice-processing init or a Bluetooth profile
    /// switch can take a while to deliver anything.
    private let firstFrameTimeout: Double
    private var awaitingFirstFrame = true

    private var ring: SampleRing?
    private var resampler: Resampler?
    private var health = InputHealth()
    private var continuation: AsyncStream<MicEvent>.Continuation?
    private var timer: (any DispatchSourceTimer)?
    private var scratch: [Float] = []
    private var lastFrameAt = 0.0
    private var recovering = false
    private var stallReported = false
    /// A non-zero sample arrived since `begin`. VP gives about 160 ms of exact zeros after it's turned on.
    private var signalSeen = false

    init(permission: @escaping @Sendable () -> Bool, stallTimeout: Double = 1.0, firstFrameTimeout: Double = 3.0) {
        self.permission = permission
        self.stallTimeout = stallTimeout
        self.firstFrameTimeout = firstFrameTimeout
    }

    /// The engine's start() returned: the stall clock starts now, with the longer first-frame window.
    func engineStarted() {
        queue.sync {
            lastFrameAt = Self.now()
            awaitingFirstFrame = true
        }
    }

    private static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

    /// While an engine is being rebuilt no frames arrive; that gap isn't a stall.
    func setRecovering(_ value: Bool) {
        queue.sync {
            recovering = value
            lastFrameAt = Self.now()
        }
    }

    /// A new engine format (build): new resampler; any unread audio from the old ring is drained first.
    func attach(ring: SampleRing, inputSampleRate: Double) {
        queue.sync {
            drain()
            self.ring = ring
            if resampler?.input.sampleRate != inputSampleRate {
                resampler = Resampler(inputSampleRate: inputSampleRate)
            } else {
                resampler?.reset()
            }
            health.restartGrace()
        }
    }

    /// Mid-capture rebuild: keep the stream, read from the new engine's ring from now on.
    func switchRing(_ ring: SampleRing) {
        queue.sync {
            ring.beginCapture(at: HostTime.now())
            self.ring = ring
            lastFrameAt = Self.now()
        }
    }

    func begin(_ continuation: AsyncStream<MicEvent>.Continuation, ring: SampleRing) {
        queue.sync {
            self.continuation?.finish()
            self.continuation = continuation
            self.ring = ring
            ring.beginCapture(at: HostTime.now())
            resampler?.reset()
            health.reset()
            lastFrameAt = Self.now()
            awaitingFirstFrame = true
            stallReported = false
            signalSeen = false
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
            timer.setEventHandler(handler: CapturePipeline.drainHandler(self))
            timer.resume()
            self.timer = timer
        }
    }

    func end() {
        queue.sync {
            drain()
            timer?.cancel()
            timer = nil
            continuation?.finish()
            continuation = nil
        }
    }

    /// A non-zero sample has arrived since `begin`. `queue.sync` from the actor is safe: nothing on `queue`
    /// ever waits on the actor.
    var hasSignal: Bool { queue.sync { signalSeen } }

    func yield(_ event: MicEvent) {
        queue.async { self.continuation?.yield(event) }
    }

    static func drainHandler(_ pipeline: CapturePipeline) -> @Sendable () -> Void {
        { [weak pipeline] in pipeline?.tick() }
    }

    /// On `queue` only: drain, then check for an engine that stopped delivering callbacks.
    private func tick() {
        drain()
        guard let continuation, !recovering, !stallReported else { return }
        if Self.now() - lastFrameAt >= (awaitingFirstFrame ? firstFrameTimeout : stallTimeout) {
            stallReported = true
            continuation.yield(.problem(.engineFailed("no audio")))
        }
    }

    /// On `queue` only.
    private func drain() {
        guard let ring, let resampler, let continuation else { return }
        scratch.removeAll(keepingCapacity: true)
        let hostTime = ring.read(into: &scratch)
        guard !scratch.isEmpty else { return }
        lastFrameAt = Self.now()
        awaitingFirstFrame = false
        if !signalSeen, scratch.contains(where: { $0 != 0 }) { signalSeen = true }
        let samples = scratch.withUnsafeBufferPointer { resampler.process($0) }
        guard !samples.isEmpty else { return }
        continuation.yield(.audio(AudioChunk(samples: samples, capturedAt: HostTime.nanoseconds(hostTime))))
        if let problem = health.observe(samples, permissionGranted: permission) {
            continuation.yield(.problem(problem))
        }
    }
}
