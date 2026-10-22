import BuddyApp
@testable import BuddyBridge
@testable import BuddyContext
import BuddyCore
import BuddyVoice
import CoreGraphics
import Foundation
import Synchronization

final class FakeVoice: VoicePort {
    enum Call: Equatable {
        case start, finish, discard, sendHeld, interrupt, speak(String), stopSpeaking, play(BuddySound)
    }

    let levels: AsyncStream<VoiceLevel>
    let events: AsyncStream<VoiceEvent>
    let levelSink: AsyncStream<VoiceLevel>.Continuation
    let eventSink: AsyncStream<VoiceEvent>.Continuation
    private let state = Mutex<(calls: [Call], transcript: String, longSpeech: Double?)>(([], "what does this mean?", nil))

    init() {
        (levels, levelSink) = AsyncStream.makeStream()
        (events, eventSink) = AsyncStream.makeStream()
    }

    var calls: [Call] { state.withLock { $0.calls } }
    func setTranscript(_ text: String) { state.withLock { $0.transcript = text } }
    private func record(_ call: Call) { state.withLock { $0.calls.append(call) } }

    /// Scenario tests: how many overlay calls had happened at each voice call, so what the user
    /// sees and hears can be put in one order. The coordinator waits on each voice call, so the
    /// count read here is the overlay's state at that moment.
    func setOverlayCount(_ count: @escaping @Sendable () async -> Int) { marker.withLock { $0 = count } }
    private let marker = Mutex<(@Sendable () async -> Int)?>(nil)
    var marks: [(call: Call, overlayIndex: Int)] { markLog.withLock { $0 } }
    private let markLog = Mutex<[(call: Call, overlayIndex: Int)]>([])
    private func mark(_ call: Call) async {
        guard let count = marker.withLock({ $0 }) else { return }
        let index = await count()
        markLog.withLock { $0.append((call, index)) }
    }

    func prepare() async throws {}
    func startListening() async throws {
        record(.start)
        await mark(.start)
        if let error = startError.withLock({ $0 }) { throw error }
    }
    /// True: `finishListening` waits, like a long transcript.
    let holdFinish = Mutex(false)
    func finishListening() async throws -> String {
        record(.finish)
        await mark(.finish)
        while holdFinish.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        return state.withLock { $0.transcript }
    }
    func discard(confirmed: Bool, playSound: Bool) async -> VoiceDiscard {
        record(.discard)
        await mark(.discard)
        return state.withLock { s -> VoiceDiscard in
            if !confirmed, let seconds = s.longSpeech { return .needsConfirmation(speechSeconds: seconds) }
            return .discarded
        }
    }
    func sendHeld() async throws -> String? {
        record(.sendHeld)
        await mark(.sendHeld)
        return state.withLock { $0.transcript }
    }
    /// Why each `interrupt` was called, in order.
    var interruptReasons: [ListenInterruption] { reasons.withLock { $0 } }
    private let reasons = Mutex<[ListenInterruption]>([])

    func interrupt(_ reason: ListenInterruption) async {
        record(.interrupt)
        await mark(.interrupt)
        reasons.withLock { $0.append(reason) }
        if reason == .confirmingDiscard { state.withLock { $0.longSpeech = nil } } // now held; Esc confirms
    }
    func setSoundsEnabled(_ enabled: Bool) async {}
    func setStartError(_ error: (any Error)?) { startError.withLock { $0 = error.map { $0 as any Error } } }
    private let startError = Mutex<(any Error)?>(nil)
    /// Makes an unconfirmed discard ask first, as BuddyVoice does past 30 s of speech.
    func setLongSpeech(_ seconds: Double?) { state.withLock { $0.longSpeech = seconds } }
    /// Whether each `speak` continued the reply in flight, in order.
    var continuations: [Bool] { continued.withLock { $0 } }
    private let continued = Mutex<[Bool]>([])

    func speak(_ text: String, continuing: Bool) async throws -> Bool {
        record(.speak(text))
        await mark(.speak(text))
        continued.withLock { $0.append(continuing) }
        return true
    }
    func stopSpeaking() async {
        record(.stopSpeaking)
        await mark(.stopSpeaking)
    }
    func play(_ sound: BuddySound) async {
        record(.play(sound))
        await mark(.play(sound))
    }
}

struct FakeContext: ContextPort {
    var result: ContextResult
    var shot: CapturedShot? = CapturedShot(path: "/tmp/shot.jpg", data: Data([1, 2, 3]), mediaType: "image/jpeg")
    /// The front app's process, reported with a built packet only (as LiveContext does).
    var pid: Int32 = 4242

    func capture() async -> SummonContext {
        guard case .packet = result else { return SummonContext(result: result) }
        return SummonContext(result: result, pid: pid)
    }
    /// Why there's no shot when `shot` is nil.
    var unavailable: ContextPacket.ScreenshotUnavailable = .captureFailed
    func screenshot(displayID: UInt32?) async -> ShotOutcome { shot.map(ShotOutcome.shot) ?? .unavailable(unavailable) }

    static func packet(selection: ContextPacket.Selection? = nil, editable: ContextPacket.Editable? = nil,
                       kind: ContextPacket.AppKind = .browser) -> FakeContext {
        var packet = ContextPacket(askedAt: Date(timeIntervalSince1970: 0), utterance: "")
        packet.app = .init(name: "Safari", bundle: "com.apple.Safari", kind: .browser)
        packet.cursor = .init(x: 100, y: 200)
        packet.selection = selection
        packet.editable = editable
        packet.app?.kind = kind
        return FakeContext(result: .packet(packet, ContextTimings(totalMs: 2, sensorMs: [:], late: [])))
    }
}

/// Replays scripted cascade events and records what was asked.
final class FakeBridge: BridgePort {
    private let state = Mutex<(script: [CascadeEvent], asked: [Question], deeper: [Question], cancelled: [String])>(([], [], [], []))

    init(script: [CascadeEvent] = []) {
        state.withLock { $0.script = script }
    }

    var asked: [Question] { state.withLock { $0.asked } }
    var deeperCount: Int { state.withLock { $0.deeper.count } }
    var deeper: [Question] { state.withLock { $0.deeper } }
    var cancelled: [String] { state.withLock { $0.cancelled } }
    func setScript(_ script: [CascadeEvent]) { state.withLock { $0.script = script } }

    func ask(_ question: Question, state conversation: ConversationState) async -> AsyncStream<CascadeEvent> {
        let script = state.withLock {
            $0.asked.append(question)
            return $0.script
        }
        return Self.stream(script, conversation: conversation)
    }

    func goDeeper(_ question: Question, state conversation: ConversationState) async -> AsyncStream<CascadeEvent> {
        let script = state.withLock {
            $0.deeper.append(question)
            return $0.script
        }
        return Self.stream(script, conversation: conversation)
    }

    func cancel(conversation: String) async { state.withLock { $0.cancelled.append(conversation) } }

    /// `.done` events get the asked conversation's id, as the real cascade would.
    private static func stream(_ script: [CascadeEvent], conversation: ConversationState) -> AsyncStream<CascadeEvent> {
        AsyncStream { continuation in
            for event in script {
                if case .done(var result) = event {
                    result.state.id = conversation.id
                    continuation.yield(.done(result))
                } else {
                    continuation.yield(event)
                }
            }
            continuation.finish()
        }
    }
}

struct FixedPointer: PointerPort {
    var point = CGPoint(x: 400, y: 300)
    func location() -> CGPoint { point }
}

@MainActor final class FakeInserter: InsertPort {
    var inserted: [String] = []
    var problem: String?
    var pids: [Int32?] = []
    func insert(_ text: String, into pid: Int32?) async -> String? {
        inserted.append(text)
        pids.append(pid)
        return problem
    }
}

/// A bridge whose streams the test drives event by event, for cancellation races.
final class ManualBridge: BridgePort {
    private let state = Mutex<(streams: [AsyncStream<CascadeEvent>.Continuation], cancelled: [String], states: [ConversationState])>(([], [], []))

    var cancelled: [String] { state.withLock { $0.cancelled } }
    var streamCount: Int { state.withLock { $0.streams.count } }
    /// The conversation state each ask was made with.
    var askedStates: [ConversationState] { state.withLock { $0.states } }

    func ask(_ question: Question, state conversation: ConversationState) async -> AsyncStream<CascadeEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CascadeEvent.self)
        state.withLock {
            $0.streams.append(continuation)
            $0.states.append(conversation)
        }
        return stream
    }

    func goDeeper(_ question: Question, state conversation: ConversationState) async -> AsyncStream<CascadeEvent> {
        await ask(question, state: conversation)
    }

    func cancel(conversation: String) async { state.withLock { $0.cancelled.append(conversation) } }

    /// Sends to the n-th stream (0-based).
    func send(_ event: CascadeEvent, to index: Int = 0) {
        let continuation = state.withLock { $0.streams[index] }
        continuation.yield(event)
    }

    func finish(_ index: Int = 0) {
        let continuation = state.withLock { $0.streams[index] }
        continuation.finish()
    }
}

/// Counts screenshot requests, to prove blocked apps are never captured.
final class CountingContext: ContextPort {
    let result: ContextResult
    private let shots = Mutex(0)
    init(result: ContextResult) { self.result = result }
    private let focusLog = Mutex<[ModelRegion.Focus?]>([])
    var screenshotCount: Int { shots.withLock { $0 } }
    /// The focus each screenshot was asked for.
    var focuses: [ModelRegion.Focus?] { focusLog.withLock { $0 } }
    func capture() async -> SummonContext { SummonContext(result: result) }
    func screenshot(displayID: UInt32?) async -> ShotOutcome {
        await screenshot(displayID: displayID, focus: nil)
    }
    func screenshot(displayID: UInt32?, focus: ModelRegion.Focus?) async -> ShotOutcome {
        shots.withLock { $0 += 1 }
        focusLog.withLock { $0.append(focus) }
        return .unavailable(.captureFailed)
    }
}

/// Records activation and lets the test press Esc.
final class FakeEscape: EscapePort {
    private let state = Mutex<(active: Bool, continuation: AsyncStream<Void>.Continuation?)>((false, nil))
    var isActive: Bool { state.withLock { $0.active } }

    func activate() throws -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        state.withLock { $0 = (true, continuation) }
        return stream
    }

    func deactivate() {
        let continuation = state.withLock { s -> AsyncStream<Void>.Continuation? in
            defer { s = (false, nil) }
            return s.continuation
        }
        continuation?.finish()
    }

    func press() { state.withLock { $0.continuation }?.yield() }
}

/// A voice whose `startListening` and `speak` suspend until the test releases them, to
/// reproduce a key press or Esc landing while the mic starts or a reply synthesises.
final class GatedVoice: VoicePort {
    let levels: AsyncStream<VoiceLevel> = AsyncStream { $0.finish() }
    let events: AsyncStream<VoiceEvent> = AsyncStream { $0.finish() }
    private let state = Mutex<(calls: [FakeVoice.Call], gates: [CheckedContinuation<Void, Never>], gateStart: Bool, gateSpeak: Bool)>(([], [], false, false))

    init(gateStart: Bool = false, gateSpeak: Bool = false) {
        state.withLock { $0.gateStart = gateStart; $0.gateSpeak = gateSpeak }
    }

    var calls: [FakeVoice.Call] { state.withLock { $0.calls } }
    var waiting: Int { state.withLock { $0.gates.count } }

    /// Releases every suspended call.
    func release() {
        let gates = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            defer { s.gates.removeAll() }
            return s.gates
        }
        gates.forEach { $0.resume() }
    }

    private func record(_ call: FakeVoice.Call) { state.withLock { $0.calls.append(call) } }

    private func gate() async {
        await withCheckedContinuation { continuation in
            state.withLock { $0.gates.append(continuation) }
        }
    }

    func prepare() async throws {}
    func startListening() async throws {
        record(.start)
        if state.withLock({ $0.gateStart }) { await gate() }
    }
    func finishListening() async throws -> String {
        record(.finish)
        return "what does this mean?"
    }
    func discard(confirmed: Bool, playSound: Bool) async -> VoiceDiscard {
        record(.discard)
        return .discarded
    }
    func sendHeld() async throws -> String? { nil }
    func interrupt(_ reason: ListenInterruption) async { record(.interrupt) }
    func setSoundsEnabled(_ enabled: Bool) async {}
    func speak(_ text: String, continuing: Bool) async throws -> Bool {
        if state.withLock({ $0.gateSpeak }) { await gate() }
        record(.speak(text))
        return true
    }
    func stopSpeaking() async { record(.stopSpeaking) }
    func play(_ sound: BuddySound) async { record(.play(sound)) }
}

/// Records prepare and locate calls and answers with fixed rects for the quotes it knows.
final class FakeLocator: LocatePort {
    enum Call: Equatable {
        case locate([String], pid: Int32, path: String?)
    }

    private let state = Mutex<(calls: [Call], rects: [String: CGRect], gated: Bool, gates: [CheckedContinuation<Void, Never>])>(([], [:], false, []))

    /// `gated`: each locate suspends until `release()`, as AX and OCR take time.
    init(rects: [String: CGRect] = [:], gated: Bool = false) {
        state.withLock { $0.rects = rects; $0.gated = gated }
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var locateCount: Int { calls.count { if case .locate = $0 { true } else { false } } }
    var waiting: Int { state.withLock { $0.gates.count } }
    /// Locates that have returned their answer.
    var returned: Int { returnedCount.withLock { $0 } }
    private let returnedCount = Mutex(0)

    func release() {
        let gates = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            defer { s.gates.removeAll() }
            return s.gates
        }
        gates.forEach { $0.resume() }
    }

    func locate(_ quotes: [String], pid: Int32, shot: CapturedShot?) async -> [LocatedPoint] {
        let gated = state.withLock { s in
            s.calls.append(.locate(quotes, pid: pid, path: shot?.path))
            return s.gated
        }
        if gated { await withCheckedContinuation { c in state.withLock { $0.gates.append(c) } } }
        defer { returnedCount.withLock { $0 += 1 } }
        return state.withLock { s in quotes.compactMap { q in s.rects[q].map { LocatedPoint(quote: q, rect: $0, source: .accessibility) } }
        }
    }
}
