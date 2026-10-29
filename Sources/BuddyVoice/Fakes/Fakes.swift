import Foundation
import Synchronization

// Fakes for every BuddyVoice seam, for tests here and in the app. All state sits behind a Mutex, so
// each fake is Sendable without @unchecked.

/// Holds a call open until the test releases it, to exercise what happens mid-call.
public final class FakeGate: Sendable {
    private struct State {
        var closed = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var arrivals = 0
    }
    private let state = Mutex(State())

    public init() {}

    /// Calls that reach the gate from now on wait for `open()`.
    public func close() { state.withLock { $0.closed = true } }

    public func open() {
        let waiting = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.closed = false
            defer { s.waiting = [] }
            return s.waiting
        }
        waiting.forEach { $0.resume() }
    }

    /// Calls that have reached the gate, waiting or not.
    public var arrivals: Int { state.withLock { $0.arrivals } }

    func pass() async {
        await withCheckedContinuation { c in
            let wait = state.withLock { s -> Bool in
                s.arrivals += 1
                if s.closed { s.waiting.append(c) }
                return s.closed
            }
            if !wait { c.resume() }
        }
    }
}

public final class FakeClock: VoiceClock {
    private let time: Mutex<Double>
    public init(_ start: Double = 0) { time = Mutex(start) }
    public func now() -> Double { time.withLock { $0 } }
    public func advance(_ seconds: Double) { time.withLock { $0 += seconds } }
}

public final class FakeMic: MicCapture {
    private struct State {
        var continuation: AsyncStream<MicEvent>.Continuation?
        var prepared = 0
        var starts = 0
        var stops = 0
        var voiceProcessing = true
        var startError: (any Error)?
        var holdLive = false
    }
    private let state = Mutex(State())

    /// Holds `start()` open while closed.
    public let startGate = FakeGate()
    /// Holds `prepare()` open while closed.
    public let prepareGate = FakeGate()

    public init() {}

    public var prepareCount: Int { state.withLock { $0.prepared } }
    public var startCount: Int { state.withLock { $0.starts } }
    public var stopCount: Int { state.withLock { $0.stops } }
    public var voiceProcessing: Bool { state.withLock { $0.voiceProcessing } }
    public var isRunning: Bool { state.withLock { $0.continuation != nil } }

    public func failNextStart(with error: any Error) { state.withLock { $0.startError = error } }

    /// While held, `untilLive()` waits until the capture stops, like a mic that never delivers audio.
    public func holdLiveSignal(_ hold: Bool) { state.withLock { $0.holdLive = hold } }

    public func untilLive() async {
        while state.withLock({ $0.holdLive && $0.continuation != nil }) {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    public func prepare() async throws {
        await prepareGate.pass()
        state.withLock { $0.prepared += 1 }
    }

    public func start() async throws -> AsyncStream<MicEvent> {
        await startGate.pass()
        let (stream, continuation) = AsyncStream.makeStream(of: MicEvent.self)
        try state.withLock { s in
            if let e = s.startError { s.startError = nil; throw e }
            s.starts += 1
            s.continuation = continuation
        }
        return stream
    }

    public func stop() async {
        let c = state.withLock { s -> AsyncStream<MicEvent>.Continuation? in
            s.stops += 1
            defer { s.continuation = nil }
            return s.continuation
        }
        c?.finish()
    }

    public func setVoiceProcessing(_ enabled: Bool) async throws {
        state.withLock { $0.voiceProcessing = enabled }
    }

    /// Delivers an event to the running capture. Returns false when not running.
    @discardableResult
    public func send(_ event: MicEvent) -> Bool {
        guard let c = state.withLock({ $0.continuation }) else { return false }
        c.yield(event)
        return true
    }

    /// Delivers `seconds` of audio at a constant amplitude in 20 ms chunks.
    public func sendAudio(seconds: Double, amplitude: Float = 0.1, capturedAt: UInt64 = 0) {
        let chunk = Int(AudioChunk.sampleRate * 0.02)
        for _ in 0 ..< Int((seconds / 0.02).rounded()) {
            send(.audio(AudioChunk(samples: [Float](repeating: amplitude, count: chunk), capturedAt: capturedAt)))
        }
    }
}

public final class FakeTranscriber: SpeechTranscriber {
    private struct State {
        var loaded = 0
        var begins = 0
        var cancels = 0
        var samples = 0
        var totalSamples = 0
        var finishes = 0
        var result = ""
        var numbered = false
        var finishError: (any Error)?
        var finishDelay: Duration = .zero
        var beginDelay: Duration = .zero
        var beginError: (any Error)?
        var loadError: (any Error)?
        var loadProgress: [ModelLoadProgress] = []
    }
    private let state = Mutex(State())

    public init(result: String = "") { state.withLock { $0.result = result } }

    public var loadCount: Int { state.withLock { $0.loaded } }
    public var beginCount: Int { state.withLock { $0.begins } }
    public var cancelCount: Int { state.withLock { $0.cancels } }
    public var finishCount: Int { state.withLock { $0.finishes } }
    /// Samples appended since the last begin().
    public var sampleCount: Int { state.withLock { $0.samples } }
    /// Samples appended since this transcriber was made, across every begin.
    public var totalSampleCount: Int { state.withLock { $0.totalSamples } }

    public func setResult(_ text: String) { state.withLock { $0.result = text } }
    /// Each finish returns "<result> <n>", n counting finishes from 1, so chunks can be told apart.
    public func numberResults() { state.withLock { $0.numbered = true } }
    public func failNextFinish(with error: any Error) { state.withLock { $0.finishError = error } }
    /// `finish` takes this long, like a model call on a busy Neural Engine.
    public func delayFinish(_ delay: Duration) { state.withLock { $0.finishDelay = delay } }
    public func delayBegin(_ delay: Duration) { state.withLock { $0.beginDelay = delay } }
    public func failNextBegin(with error: any Error) { state.withLock { $0.beginError = error } }

    public func failNextLoad(with error: any Error) { state.withLock { $0.loadError = error } }
    /// Progress reports the next `load` delivers, in order.
    public func reportOnLoad(_ progress: [ModelLoadProgress]) { state.withLock { $0.loadProgress = progress } }

    /// While closed, `load` stops after its first progress report until the gate opens.
    public let loadGate = FakeGate()

    public func load(progress: @escaping @Sendable (ModelLoadProgress) -> Void) async throws {
        let reports = try state.withLock { s -> [ModelLoadProgress] in
            if let e = s.loadError { s.loadError = nil; throw e }
            s.loaded += 1
            return s.loadProgress
        }
        for (index, report) in reports.enumerated() {
            progress(report)
            if index == 0 { await loadGate.pass() }
        }
    }

    public func begin() async throws {
        let delay = state.withLock { $0.beginDelay }
        if delay > .zero { try? await Task.sleep(for: delay) }
        try state.withLock { s in
            if let e = s.beginError { s.beginError = nil; throw e }
            s.begins += 1
            s.samples = 0
        }
    }
    public func append(_ samples: [Float]) async throws {
        state.withLock { s in
            s.samples += samples.count
            s.totalSamples += samples.count
        }
    }

    public func finish() async throws -> String {
        let delay = state.withLock { $0.finishDelay }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return try state.withLock { s in
            s.finishes += 1
            if let e = s.finishError { s.finishError = nil; throw e }
            return s.numbered ? "\(s.result) \(s.finishes)" : s.result
        }
    }

    public func cancel() async { state.withLock { $0.cancels += 1 } }
}

/// Reports speech while the incoming samples are louder than `threshold`.
public final class FakeSpeechDetector: SpeechActivityDetector {
    private struct State {
        var speaking = false
        var resets = 0
        var loaded = 0
        var failing = false
    }
    private let state = Mutex(State())
    public let threshold: Float

    public init(threshold: Float = 0.01) { self.threshold = threshold }

    public var resetCount: Int { state.withLock { $0.resets } }

    /// Every `process` call throws while set, like a VAD model that isn't loaded.
    public func setFailing(_ failing: Bool) { state.withLock { $0.failing = failing } }

    public func load() async throws { state.withLock { $0.loaded += 1 } }
    public func reset() async { state.withLock { $0.resets += 1; $0.speaking = false } }

    public func process(_ samples: [Float]) async throws -> SpeechActivity? {
        struct VADDown: Error {}
        if state.withLock({ $0.failing }) { throw VADDown() }
        let loud = LevelMeter.rms(samples[...]) > threshold
        return state.withLock { s in
            guard loud != s.speaking else { return nil }
            s.speaking = loud
            return loud ? .started : .ended
        }
    }
}

public final class FakeSpeaker: SpeechSpeaker {
    private struct State {
        var warmUps = 0
        var spoken: [String] = []
        var continued: [String] = []
        var stops = 0
        var continuation: AsyncStream<Float>.Continuation?
        var speakError: (any Error)?
    }
    private let state = Mutex(State())

    /// Holds `speak()` open while closed, like Kokoro synthesising.
    public let speakGate = FakeGate()

    public init() {}

    public var warmUpCount: Int { state.withLock { $0.warmUps } }
    public var spoken: [String] { state.withLock { $0.spoken } }
    /// Lines appended to the reply in flight by `continueReply`.
    public var continued: [String] { state.withLock { $0.continued } }
    public var stopCount: Int { state.withLock { $0.stops } }
    public var isSpeaking: Bool { state.withLock { $0.continuation != nil } }

    public func failNextSpeak(with error: any Error) { state.withLock { $0.speakError = error } }

    public func warmUp() async { state.withLock { $0.warmUps += 1 } }

    /// Like the real speakers, a `stop()` that lands while synthesising means the reply never plays.
    public func speak(_ text: String) async throws -> AsyncStream<Float> {
        let stopsAtEntry = state.withLock { $0.stops }
        await speakGate.pass()
        let (stream, continuation) = AsyncStream.makeStream(of: Float.self)
        let play = try state.withLock { s -> Bool in
            if let e = s.speakError { s.speakError = nil; throw e }
            guard s.stops == stopsAtEntry else { return false }
            s.spoken.append(text)
            s.continuation = continuation
            return true
        }
        if !play { continuation.finish() }
        return stream
    }

    /// Appends while a reply is playing, like Kokoro; false once it has finished or was stopped.
    public func continueReply(_ text: String) async -> Bool {
        state.withLock { s in
            guard s.continuation != nil else { return false }
            s.continued.append(text)
            return true
        }
    }

    /// Emits one reply RMS frame.
    public func emit(level: Float) { _ = state.withLock { $0.continuation }?.yield(level) }

    /// Ends playback as if the reply finished.
    public func finishSpeaking() {
        let c = state.withLock { s -> AsyncStream<Float>.Continuation? in
            defer { s.continuation = nil }
            return s.continuation
        }
        c?.finish()
    }

    public func stop() async {
        state.withLock { $0.stops += 1 }
        finishSpeaking()
    }
}

public final class FakeSoundPlayer: SoundPlayer {
    private let played = Mutex<[BuddySound]>([])
    public init() {}
    public var sounds: [BuddySound] { played.withLock { $0 } }
    public func play(_ sound: BuddySound) async { played.withLock { $0.append(sound) } }
}
