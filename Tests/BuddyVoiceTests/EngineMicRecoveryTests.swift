import Foundation
import Synchronization
import Testing
@testable import BuddyVoice

/// A scripted engine. `@unchecked Sendable`: all mutable state is behind `state`; the change callback is
/// immutable after init.
private final class FakeEngine: MicEngine, @unchecked Sendable {
    struct State {
        var format = MicFormat(sampleRate: 48_000, channels: 1)
        var running = false
        /// Prepared or started: AVAudioEngine.stop() releases it, and VP can't be switched while set.
        var initialized = false
        var voiceProcessing = false
        /// Every setVoiceProcessing call that switched VP, in order.
        var switches: [Bool] = []
        var switchFailures = 0
        var starts = 0
        var prepares = 0
        var reconnects = 0
        var invalidated = false
        var startFailures = 0
        var startDelay: Double = 0
    }
    let ring = SampleRing()
    let state = Mutex(State())
    let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void, startFailures: Int, voiceProcessing: Bool = false) {
        self.onChange = onChange
        state.withLock {
            $0.startFailures = startFailures
            $0.voiceProcessing = voiceProcessing
            $0.format.channels = voiceProcessing ? 9 : 1
        }
    }

    var hardwareFormat: MicFormat { state.withLock { $0.format } }
    var isRunning: Bool { state.withLock { $0.running } }
    var starts: Int { state.withLock { $0.starts } }
    var prepares: Int { state.withLock { $0.prepares } }
    var reconnects: Int { state.withLock { $0.reconnects } }
    var invalidated: Bool { state.withLock { $0.invalidated } }
    var voiceProcessingEnabled: Bool { state.withLock { $0.voiceProcessing } }
    var switches: [Bool] { state.withLock { $0.switches } }

    func setVoiceProcessing(_ enabled: Bool) throws {
        try state.withLock { s in
            guard s.voiceProcessing != enabled else { return }
            if s.initialized { throw MicError.startFailed("-10849: VP switched on a prepared engine") }
            if s.switchFailures > 0 { s.switchFailures -= 1; throw MicError.startFailed("scripted switch") }
            s.voiceProcessing = enabled
            s.format.channels = enabled ? 9 : 1                // VP on a MacBook Pro mic: 9 channels
            s.switches.append(enabled)
        }
    }

    func reconnect() throws {
        try state.withLock { s in
            guard s.format.isValid else { throw MicError.invalidFormat(sampleRate: s.format.sampleRate, channels: s.format.channels) }
            s.reconnects += 1
        }
    }

    func prepare() { state.withLock { $0.prepares += 1; $0.initialized = true } }
    func start() throws {
        let delay = state.withLock { $0.startDelay }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }    // a slow voice-processing init
        try state.withLock { s in
            if s.startFailures > 0 { s.startFailures -= 1; throw MicError.startFailed("scripted") }
            s.starts += 1
            s.running = true
            s.initialized = true
        }
    }
    func stop() { state.withLock { $0.running = false; $0.initialized = false } }

    /// Delivers `frames` of 48 kHz audio into the ring, as the sink block would.
    func deliver(frames: Int = 480) {
        let samples = [Float](repeating: 0.1, count: frames)
        samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: frames, stride: 1, hostTime: 0) }
    }
    func invalidate() { state.withLock { $0.invalidated = true; $0.running = false; $0.initialized = false } }

    /// The hardware changed under the engine: new format, and AVAudioEngine stops itself.
    func hardwareChanged(to rate: Double) {
        state.withLock { $0.format.sampleRate = rate; $0.running = false }
    }

    /// Posts the configuration-change notification from a background thread, as AVFAudio does.
    func postChange() {
        let onChange = onChange
        Thread.detachNewThread { onChange() }
    }
}

/// Records every engine the mic builds and how many were alive at once.
private final class EngineFactory: Sendable {
    private struct State {
        var engines: [FakeEngine] = []
        var buildFailures = 0
        var startFailuresForNext = 0
        var startDelayForNext: Double = 0
        var switchFailuresForNext = 0
        var failAllStarts = false
        var maxAlive = 0
        var onMake: (@Sendable () -> Void)?
        var echo: (delay: Double, rate: Double)?
    }
    private let state = Mutex(State())

    var engines: [FakeEngine] { state.withLock { $0.engines } }
    var maxAlive: Int { state.withLock { $0.maxAlive } }
    func failBuilds(_ n: Int) { state.withLock { $0.buildFailures = n } }
    func failStartOfNextEngine(_ n: Int) { state.withLock { $0.startFailuresForNext = n } }
    func slowStartOfNextEngine(_ seconds: Double) { state.withLock { $0.startDelayForNext = seconds } }
    func failEveryStart() { state.withLock { $0.failAllStarts = true } }
    func failSwitchesOfNextEngine(_ n: Int) { state.withLock { $0.switchFailuresForNext = n } }
    /// Engines still alive with voice processing on. Each one ducks other apps' audio.
    var liveVoiceProcessingEngines: Int { engines.filter { !$0.invalidated && $0.voiceProcessingEnabled }.count }
    /// Runs once, inside the next engine construction (after a successful build check).
    func duringNextMake(_ body: @escaping @Sendable () -> Void) { state.withLock { $0.onMake = body } }
    /// macOS 26: every new engine makes Core Audio rebuild the process's default-device aggregate, and
    /// `delay` seconds later the engine reports the settled format, stops itself if running, and posts a
    /// configuration change. Once per engine; reconnecting the same engine posts nothing more.
    func echoAfterEveryBuild(delay: Double, settledRate: Double) { state.withLock { $0.echo = (delay, settledRate) } }

    var make: MicEngineFactory {
        { [self] voiceProcessing, onChange in
            let (engine, hook) = try state.withLock { s -> (FakeEngine, (@Sendable () -> Void)?) in
                if s.buildFailures > 0 { s.buildFailures -= 1; throw MicError.invalidFormat(sampleRate: 0, channels: 0) }
                let e = FakeEngine(onChange: onChange, startFailures: s.failAllStarts ? .max : s.startFailuresForNext,
                                   voiceProcessing: voiceProcessing)
                e.state.withLock { [s] in $0.startDelay = s.startDelayForNext; $0.switchFailures = s.switchFailuresForNext }
                s.startFailuresForNext = 0
                s.startDelayForNext = 0
                s.switchFailuresForNext = 0
                s.engines.append(e)
                s.maxAlive = max(s.maxAlive, s.engines.filter { !$0.invalidated }.count)
                defer { s.onMake = nil }
                return (e, s.onMake)
            }
            hook?()
            if let echo = state.withLock({ $0.echo }) {
                Thread.detachNewThread {
                    Thread.sleep(forTimeInterval: echo.delay)
                    engine.hardwareChanged(to: echo.rate)
                    engine.onChange()
                }
            }
            return engine
        }
    }
}

private final class EventLog: Sendable {
    let events = Mutex<[MicEvent]>([])
    var all: [MicEvent] { events.withLock { $0 } }

    func collect(_ stream: AsyncStream<MicEvent>) {
        Task { for await e in stream { events.withLock { $0.append(e) } } }
    }
}

private func makeMic(
    _ factory: EngineFactory,
    coalesce: Duration = .milliseconds(40),
    stallTimeout: Double = 30,
    firstFrameTimeout: Double = 30,
    liveTimeout: Duration = .zero,
    settleWindow: Duration = .zero,
    voiceProcessing: Bool = true,
    otherAudioPlaying: @escaping @Sendable () -> Bool = { true },
    permission: @escaping @Sendable () -> Bool = { true },
    request: @escaping @Sendable () async -> Bool = { true }
) -> EngineMic {
    EngineMic(voiceProcessing: voiceProcessing, permission: permission, requestPermission: request,
              engineFactory: factory.make, otherAudioPlaying: otherAudioPlaying, coalesceDelay: coalesce, retryDelay: .milliseconds(10),
              stallTimeout: stallTimeout, firstFrameTimeout: firstFrameTimeout, liveTimeout: liveTimeout,
              settleWindow: settleWindow, listenForDefaultInput: false)
}

private func eventually(_ timeout: Duration = .seconds(2), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

struct EngineMicRecoveryTests {
    @Test func burstOfNotificationsRebuildsOnce() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory)
        let log = EventLog()
        log.collect(try await mic.start())
        let first = try #require(factory.engines.first)
        first.hardwareChanged(to: 44_100)
        for _ in 0 ..< 5 { first.postChange() }

        #expect(await eventually { factory.engines.count == 2 && factory.engines[1].isRunning })
        try await Task.sleep(for: .milliseconds(150))
        #expect(factory.engines.count == 2, "one rebuild for the whole burst")
        #expect(await mic.recoveryCount == 1)
        #expect(first.invalidated)
        #expect(await eventually { log.all.filter { $0 == .rebuilt }.count == 1 })
    }

    @Test func notificationsFromReplacedEnginesAreIgnored() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory)
        _ = try await mic.start()
        let first = try #require(factory.engines.first)
        first.hardwareChanged(to: 44_100)
        first.postChange()
        #expect(await eventually { factory.engines.count == 2 })

        first.postChange()                                   // late notification from the old engine
        try await Task.sleep(for: .milliseconds(150))
        #expect(factory.engines.count == 2)
        #expect(await mic.recoveryCount == 1)
    }

    @Test func voiceProcessingsOwnStartNotificationKeepsTheWarmEngine() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory)
        _ = try await mic.start()
        let first = try #require(factory.engines.first)
        first.postChange()                                   // same format, still running
        try await Task.sleep(for: .milliseconds(150))
        #expect(factory.engines.count == 1)
        #expect(first.isRunning)
    }

    @Test func changeWhileIdleRebuildsButNeverStarts() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory)
        try await mic.prepare()
        let first = try #require(factory.engines.first)
        first.hardwareChanged(to: 44_100)
        first.postChange()

        #expect(await eventually { factory.engines.count == 2 })
        try await Task.sleep(for: .milliseconds(100))
        let second = factory.engines[1]
        #expect(!second.voiceProcessingEnabled && second.prepares >= 1, "idle: VP off, prepared for a warm plain start")
        #expect(second.starts == 0 && first.starts == 0, "a config change must not light the mic")
    }

    @Test func startDuringPendingRecoveryWaitsAndUsesTheFreshEngine() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory, coalesce: .milliseconds(200))
        try await mic.prepare()
        let first = try #require(factory.engines.first)
        first.hardwareChanged(to: 44_100)
        first.onChange()                                     // synchronous, so the flag is set before start()

        _ = try await mic.start()                            // inside the 200 ms coalescing window
        #expect(first.starts == 0, "never starts the stale engine")
        let current = try #require(factory.engines.last)
        #expect(current !== first)
        #expect(current.isRunning)
    }

    @Test func overlappingChangesNeverRunTwoRecoveries() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory)
        _ = try await mic.start()
        let first = try #require(factory.engines.first)
        factory.failBuilds(3)                                // the device settles slowly (VP: -10875)
        first.hardwareChanged(to: 44_100)
        first.postChange()
        for _ in 0 ..< 10 {
            try await Task.sleep(for: .milliseconds(5))
            factory.engines.last?.postChange()
        }
        #expect(await eventually { factory.engines.last?.isRunning == true })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await mic.recoveryCount == 1)
        #expect(factory.maxAlive == 1, "never two engines at once")
    }

    @Test func failedFirstStartRecoversWithAFreshEngine() async throws {
        let factory = EngineFactory()
        factory.failStartOfNextEngine(1)
        let mic = makeMic(factory)
        let log = EventLog()
        log.collect(try await mic.start())
        #expect(factory.engines.count == 2)
        #expect(factory.engines[1].isRunning)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!log.all.contains(.rebuilt), "`.rebuilt` is for mid-capture rebuilds only")
    }

    // Idle ducking: a VP engine ducks other apps by 30 dB while it exists, so VP is on only while capturing.
    @Test func aQuietMacCapturesPlainAndWarm() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory, otherAudioPlaying: { false })
        try await mic.prepare()
        let engine = try #require(factory.engines.first)
        #expect(engine.prepares >= 1, "warm before the press")
        _ = try await mic.start()
        #expect(engine.isRunning && !engine.voiceProcessingEnabled, "plain capture: live at once, first word kept")
        await mic.stop()
        #expect(engine.switches.isEmpty, "VP never switched")
        #expect(factory.engines.count == 1 && factory.liveVoiceProcessingEngines == 0)
    }

    @Test func otherAudioPlayingUsesVoiceProcessingForThatCaptureOnly() async throws {
        let playing = Mutex(true)
        let factory = EngineFactory()
        let mic = makeMic(factory, otherAudioPlaying: { playing.withLock { $0 } })
        try await mic.prepare()
        let engine = try #require(factory.engines.first)
        _ = try await mic.start()
        #expect(engine.voiceProcessingEnabled && engine.isRunning, "VP keeps the playing audio out of the transcript")
        #expect(factory.engines.count == 1, "the prepared engine was stopped and switched, no fallback rebuild")
        await mic.stop()
        #expect(!engine.voiceProcessingEnabled && engine.prepares >= 2, "idle: plain and warm again")
        playing.withLock { $0 = false }
        _ = try await mic.start()
        #expect(!engine.voiceProcessingEnabled, "decided per press: quiet now, so plain")
        await mic.stop()
        #expect(factory.liveVoiceProcessingEngines == 0)
    }

    @Test func voiceIsolationOffNeverUsesVoiceProcessingEvenWithAudioPlaying() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory, voiceProcessing: false, otherAudioPlaying: { true })
        try await mic.prepare()
        let engine = try #require(factory.engines.first)
        _ = try await mic.start()
        #expect(!engine.voiceProcessingEnabled)
        await mic.stop()
        #expect(engine.switches.isEmpty)
    }

    @Test func aMidCaptureRebuildKeepsAPlainCapturePlain() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory, otherAudioPlaying: { false })
        try await mic.prepare()
        _ = try await mic.start()
        let first = try #require(factory.engines.first)
        first.hardwareChanged(to: 44_100)
        first.postChange()
        #expect(await eventually { factory.engines.count == 2 && factory.engines[1].isRunning })
        #expect(!factory.engines[1].voiceProcessingEnabled, "the capture's own choice, not the setting")
        await mic.stop()
    }

    @Test func voiceProcessingIsOnOnlyWhileCapturing() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory)
        try await mic.prepare()
        let engine = try #require(factory.engines.first)
        #expect(!engine.voiceProcessingEnabled && engine.prepares >= 1, "idle after prepare: VP off, prepared")
        for _ in 0 ..< 2 {
            _ = try await mic.start()
            #expect(engine.voiceProcessingEnabled && engine.isRunning)
            #expect(await mic.voiceProcessingActive)
            await mic.stop()
            #expect(!engine.voiceProcessingEnabled && !engine.isRunning)
            #expect(!(await mic.voiceProcessingActive))
        }
        #expect(engine.switches == [true, false, true, false])
        #expect(factory.engines.count == 1, "the same engine every listen")
        #expect(factory.liveVoiceProcessingEngines == 0)
    }

    @Test func voiceIsolationOffNeverEnablesVoiceProcessingAndStaysWarm() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory, voiceProcessing: false)
        try await mic.prepare()
        let engine = try #require(factory.engines.first)
        #expect(engine.prepares == 1, "plain engine prepared for a warm start")
        _ = try await mic.start()
        await mic.stop()
        #expect(engine.switches.isEmpty && !engine.voiceProcessingEnabled)
        #expect(engine.prepares >= 2, "prepared again after stop")
        _ = try await mic.start()
        #expect(factory.engines.count == 1)
    }

    @Test func voiceIsolationSettingChangesKeepIdleFreeOfVoiceProcessing() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory, voiceProcessing: false)
        try await mic.prepare()                              // plain engine, prepared
        try await mic.setVoiceProcessing(true)               // a prepared engine can't switch VP on: rebuild
        #expect(factory.engines.count == 2)
        #expect(factory.liveVoiceProcessingEngines == 0)
        _ = try await mic.start()
        #expect(factory.engines[1].voiceProcessingEnabled && factory.engines[1].isRunning)
        await mic.stop()
        try await mic.setVoiceProcessing(false)
        #expect(factory.liveVoiceProcessingEngines == 0)
        _ = try await mic.start()
        #expect(factory.liveVoiceProcessingEngines == 0, "Voice Isolation off captures without VP")
    }

    @Test func switchFailuresFallBackWithoutLeavingVoiceProcessingAtIdle() async throws {
        let factory = EngineFactory()
        factory.failSwitchesOfNextEngine(1)                  // the idle engine won't switch VP on
        let mic = makeMic(factory)
        try await mic.prepare()
        _ = try await mic.start()
        #expect(factory.engines.count == 2, "a fresh VP engine when the idle one won't switch")
        let capturing = factory.engines[1]
        #expect(capturing.voiceProcessingEnabled && capturing.isRunning)
        capturing.state.withLock { $0.switchFailures = 1 }   // and this one won't switch off
        await mic.stop()
        #expect(capturing.invalidated)
        #expect(factory.liveVoiceProcessingEngines == 0, "never a VP engine at idle")
    }

    @Test func startThatNeverRecoversLeavesNoVoiceProcessingAtIdle() async throws {
        let factory = EngineFactory()
        factory.failEveryStart()                             // device hogged: every rebuild's start throws
        let mic = makeMic(factory)
        await #expect(throws: MicError.self) { _ = try await mic.start() }
        #expect(factory.engines.count > 1, "the recovery built VP engines")
        #expect(factory.liveVoiceProcessingEngines == 0, "never a VP engine at idle")
        #expect(!(await mic.voiceProcessingActive))
    }

    @Test func midCaptureRebuildKeepsVoiceProcessingThenIdleDropsIt() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory)
        let log = EventLog()
        log.collect(try await mic.start())
        let first = try #require(factory.engines.first)
        first.hardwareChanged(to: 44_100)
        first.postChange()
        #expect(await eventually { factory.engines.count == 2 && factory.engines[1].isRunning })
        #expect(factory.engines[1].voiceProcessingEnabled, "the rebuilt capture keeps voice isolation")
        #expect(await eventually { log.all.contains(.rebuilt) })
        await mic.stop()
        #expect(factory.liveVoiceProcessingEngines == 0)
    }

    @Test func switchingVoiceProcessingIsNotADeviceChange() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory)
        _ = try await mic.start()                            // 1 → 9 channels
        let engine = try #require(factory.engines.first)
        engine.postChange()                                  // same device, VP's own format
        try await Task.sleep(for: .milliseconds(150))
        await mic.stop()                                     // 9 → 1 channels
        engine.postChange()
        try await Task.sleep(for: .milliseconds(150))
        #expect(factory.engines.count == 1, "no rebuild from VP's own format flips")
        _ = try await mic.start()
        #expect(factory.engines.count == 1)
    }

    @Test func untilLiveReturnsOnceRealAudioArrives() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory, liveTimeout: .seconds(5))
        try await mic.prepare()
        let engine = try #require(factory.engines.first)
        let clock = ContinuousClock()
        let began = clock.now
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            let zeros = [Float](repeating: 0, count: 4_800)  // VP's warm-up zeros don't count as live
            zeros.withUnsafeBufferPointer { engine.ring.write($0.baseAddress!, frames: 4_800, stride: 1, hostTime: 0) }
            try? await Task.sleep(for: .milliseconds(150))
            engine.deliver()
        }
        _ = try await mic.start()
        await mic.untilLive()
        let waited = clock.now - began
        #expect(waited >= .milliseconds(240) && waited < .seconds(2))
    }

    @Test func untilLiveGivesUpAfterTheTimeoutOrOnStop() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory, liveTimeout: .milliseconds(100))
        let clock = ContinuousClock()
        var began = clock.now
        _ = try await mic.start()                            // the fake never delivers (a revoked mic)
        await mic.untilLive()
        #expect(clock.now - began < .seconds(1))
        #expect(factory.engines.first?.isRunning == true)

        let patient = makeMic(EngineFactory(), liveTimeout: .seconds(30))
        _ = try await patient.start()
        began = clock.now
        async let live: Void = patient.untilLive()
        try await Task.sleep(for: .milliseconds(30))
        await patient.stop()
        await live
        #expect(clock.now - began < .seconds(1), "stop() ends the wait")
    }

    @Test func engineThatNeverDeliversIsReportedAfterTheFirstFrameWindow() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory, stallTimeout: 0.05, firstFrameTimeout: 0.15)
        let log = EventLog()
        log.collect(try await mic.start())                   // the fake never writes to its ring
        #expect(await eventually { log.all.contains(.problem(.engineFailed("no audio"))) })
        #expect(log.all.filter { $0 == .problem(.engineFailed("no audio")) }.count == 1)
    }

    // Fix 3: the stall clock starts when start() returns, and the first frame gets a longer window.
    @Test func slowStartIsNotAStallButAMidCaptureGapIs() async throws {
        let factory = EngineFactory()
        factory.slowStartOfNextEngine(0.3)                   // longer than the mid-capture window
        let mic = makeMic(factory, stallTimeout: 0.1, firstFrameTimeout: 0.5)
        let log = EventLog()
        log.collect(try await mic.start())
        try await Task.sleep(for: .milliseconds(300))        // still inside the first-frame window
        #expect(log.all.isEmpty, "no false stall at the start of a listen")

        let engine = try #require(factory.engines.first)
        engine.deliver()                                     // first frame arrives
        #expect(await eventually { log.all.contains { if case .audio = $0 { true } else { false } } })
        #expect(!log.all.contains(.problem(.engineFailed("no audio"))))
        // Frames stop: now the short mid-capture window applies.
        #expect(await eventually(.milliseconds(400)) { log.all.contains(.problem(.engineFailed("no audio"))) })
    }

    // Fix 1: a start() that resumes first must not lose its engine to setVoiceProcessing's rebuild.
    @Test func settingChangeWaitingOnRecoveryDoesNotKillALiveCapture() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory, coalesce: .milliseconds(100))
        try await mic.prepare()
        let first = try #require(factory.engines.first)
        first.hardwareChanged(to: 44_100)
        first.onChange()                                     // recovery pending
        async let started = mic.start()                      // waits for the recovery
        try await Task.sleep(for: .milliseconds(10))
        async let setting: Void = mic.setVoiceProcessing(false)   // also waits
        let stream = try await started
        try await setting
        let live = try #require(factory.engines.last)
        #expect(live.isRunning && !live.invalidated, "the capturing engine survives")
        let log = EventLog()
        log.collect(stream)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!log.all.contains { if case .problem = $0 { true } else { false } })
    }

    @Test func prepareWhileCapturingNeverRebuilds() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory)
        _ = try await mic.start()
        try await mic.setVoiceProcessing(false)              // applies to the next listen
        try await mic.prepare()
        #expect(factory.engines.count == 1)
        #expect(factory.engines[0].isRunning)
        await mic.stop()
        _ = try await mic.start()
        #expect(factory.engines.count == 2, "the setting applies on the next start")
    }

    // Fix 2: builds that fail while the device settles are retried everywhere.
    @Test(arguments: ["prepare", "start"])
    func buildIsRetriedWhileTheDeviceSettles(entry: String) async throws {
        let factory = EngineFactory()
        factory.failBuilds(3)                                // VP: 0 Hz / 0 ch for a while
        let mic = makeMic(factory)
        if entry == "prepare" { try await mic.prepare() } else { _ = try await mic.start() }
        #expect(factory.engines.count == 1)
        if entry == "start" { #expect(factory.engines[0].isRunning) }
    }

    @Test func idleRecoveryRetriesUntilTheDeviceSettles() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory)
        try await mic.prepare()
        let first = try #require(factory.engines.first)
        factory.failBuilds(3)
        first.hardwareChanged(to: 44_100)
        first.postChange()
        #expect(await eventually { factory.engines.count == 2 })
        _ = try await mic.start()
        #expect(factory.engines.count == 2, "start uses the engine the idle recovery built")
        #expect(factory.engines[1].isRunning)
    }

    // Fix 4: a default-input change that lands while an engine is being made isn't lost.
    @Test func deviceChangeDuringEngineConstructionSurvives() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory)
        factory.duringNextMake { mic.changes.markDeviceChanged() }
        try await mic.prepare()
        #expect(factory.engines.count == 1)
        _ = try await mic.start()
        #expect(factory.engines.count == 2, "the change seen during construction forces a fresh engine")
        #expect(factory.engines[1].isRunning)
    }

    @Test func firstUseAsksForTheMic() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory, permission: { false }, request: { true })
        _ = try await mic.start()
        #expect(factory.engines.first?.isRunning == true)
    }

    @Test func refusedPromptReportsDenied() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory, permission: { false }, request: { false })
        var events: [MicEvent] = []
        for await e in try await mic.start() { events.append(e) }
        #expect(events == [.problem(.permissionDenied)])
        #expect(factory.engines.isEmpty)
    }
}

/// The first listen after launch on macOS 26 (it didn't hear the first time, and the mic
/// indicator flickered). Each new engine posts its own configuration change about 0.5 s after it's built;
/// rebuilding for it built the next one, forever.
struct EngineMicSettleEchoTests {
    @Test func aNewEnginesOwnEchoAtIdleKeepsThatEngine() async throws {
        let factory = EngineFactory()
        factory.echoAfterEveryBuild(delay: 0.05, settledRate: 44_100)
        let mic = makeMic(factory, settleWindow: .seconds(2))
        try await mic.prepare()
        let first = try #require(factory.engines.first)

        #expect(await eventually { first.reconnects == 1 })
        try await Task.sleep(for: .milliseconds(500))           // several echo periods
        #expect(factory.engines.count == 1, "no rebuild loop: the echo is answered in place")
        #expect(!first.invalidated && !first.isRunning, "idle: never started, no mic indicator")
        #expect(first.prepares >= 2, "prepared again for a warm start")
    }

    @Test func firstCaptureRightAfterLaunchSurvivesTheEcho() async throws {
        let factory = EngineFactory()
        factory.echoAfterEveryBuild(delay: 0.05, settledRate: 44_100)
        let mic = makeMic(factory, settleWindow: .seconds(2), voiceProcessing: false)
        let log = EventLog()
        log.collect(try await mic.start())                     // the press lands before the echo
        let first = try #require(factory.engines.first)

        #expect(await eventually { first.starts == 2 && first.isRunning }, "same engine restarted once")
        try await Task.sleep(for: .milliseconds(500))
        #expect(factory.engines.count == 1, "no restart every half second")
        #expect(first.isRunning && first.starts == 2)
        #expect(!log.all.contains(.rebuilt))
        #expect(!log.all.contains { if case .problem = $0 { true } else { false } })
        await mic.stop()
    }

    @Test func aRealChangeAfterTheSettleWindowStillRebuilds() async throws {
        let factory = EngineFactory()
        let mic = makeMic(factory, settleWindow: .milliseconds(100))
        try await mic.prepare()
        let first = try #require(factory.engines.first)
        try await Task.sleep(for: .milliseconds(200))
        first.hardwareChanged(to: 44_100)
        first.postChange()

        #expect(await eventually { factory.engines.count == 2 })
        #expect(first.invalidated && first.reconnects == 0)
    }
}
