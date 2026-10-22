import Foundation
import Synchronization
import Testing
@testable import BuddyKeys

// MARK: - Time and flags

func ms(_ value: UInt64) -> Nanos { value * 1_000_000 }

/// Non-coalesced bit real events carry; the machine must ignore it.
let nonCoalesced: UInt64 = 0x100

extension BuddyKey {
    /// Flags of a real event for this key going down: device bit, shared bit, non-coalesced bit.
    var downFlags: UInt64 { downMask | independentMask | nonCoalesced }
}

let upFlags: UInt64 = nonCoalesced

let kVKShift: UInt16 = 56
let kVKOption: UInt16 = 58
let kVKCommand: UInt16 = 55
let kVKE: UInt16 = 14

// MARK: - Gesture machine driver

/// Wraps the machine like a real driver: `advance(to:)` only delivers a `.tick` when the
/// machine's deadline has been reached, and every emitted event is accumulated.
struct Driver {
    var machine: GestureMachine
    private(set) var events: [GestureEvent] = []

    init(_ key: BuddyKey = .rightOption, doubleTap: Bool = true) {
        machine = GestureMachine(key: key, config: GestureConfig(doubleTapEnabled: doubleTap))
    }

    var key: BuddyKey { machine.key }
    var state: GestureMachine.State { machine.state }
    var deadline: Nanos? { machine.deadline }

    @discardableResult
    mutating func send(_ event: InputEvent) -> [GestureEvent] {
        let out = machine.handle(event)
        events += out
        return out
    }

    @discardableResult
    mutating func down(at t: UInt64, extraFlags: UInt64 = 0) -> [GestureEvent] {
        send(.flagsChanged(keyCode: key.keyCode, flags: key.downFlags | extraFlags, time: ms(t)))
    }

    @discardableResult
    mutating func up(at t: UInt64, extraFlags: UInt64 = 0) -> [GestureEvent] {
        send(.flagsChanged(keyCode: key.keyCode, flags: upFlags | extraFlags, time: ms(t)))
    }

    /// A buddy-key flagsChanged with exactly these flags (e.g. no device bits).
    @discardableResult
    mutating func buddy(flags: UInt64, at t: UInt64) -> [GestureEvent] {
        send(.flagsChanged(keyCode: key.keyCode, flags: flags, time: ms(t)))
    }

    @discardableResult
    mutating func key(_ code: UInt16, at t: UInt64) -> [GestureEvent] {
        send(.keyDown(keyCode: code, time: ms(t)))
    }

    @discardableResult
    mutating func modifier(_ code: UInt16, flags: UInt64, at t: UInt64) -> [GestureEvent] {
        send(.flagsChanged(keyCode: code, flags: flags, time: ms(t)))
    }

    @discardableResult
    mutating func click(at t: UInt64) -> [GestureEvent] { send(.mouseDown(time: ms(t))) }

    @discardableResult
    mutating func scroll(at t: UInt64) -> [GestureEvent] { send(.scroll(time: ms(t))) }

    @discardableResult
    mutating func interrupted(at t: UInt64) -> [GestureEvent] { send(.tapInterrupted(time: ms(t))) }

    /// Delivers a tick at each deadline reached up to `t` (like a one-shot timer re-armed after
    /// every call), including repeating release polls. Returns everything emitted.
    @discardableResult
    mutating func advance(to t: UInt64, flags: UInt64? = nil) -> [GestureEvent] {
        var out: [GestureEvent] = []
        var iterations = 0
        while let d = machine.deadline, d <= ms(t) {
            iterations += 1
            guard iterations <= 1000 else {
                Issue.record("advance(to: \(t)) did not settle after 1000 ticks")
                break
            }
            out += send(.tick(time: d, flags: flags))
            if machine.deadline == d { break }
        }
        return out
    }

    /// Delivers a tick at exactly `t` regardless of deadline.
    @discardableResult
    mutating func tick(at t: UInt64, flags: UInt64? = nil) -> [GestureEvent] {
        send(.tick(time: ms(t), flags: flags))
    }

    /// Delivers a tick at an exact nanosecond time.
    @discardableResult
    mutating func tick(atNanos t: Nanos, flags: UInt64? = nil) -> [GestureEvent] {
        send(.tick(time: t, flags: flags))
    }
}

// MARK: - Async helpers

/// Polls `condition` until it holds or `timeout` passes, so a bug fails instead of hanging.
/// Real sleeps here only pace the polling; gesture timing always comes from `ManualClock`.
@discardableResult
func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= end { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

/// Collects everything an `AsyncStream` yields, and hands it out in order with a timeout.
final class StreamRecorder<Element: Sendable>: Sendable {
    private struct State {
        var items: [Element] = []
        var cursor = 0
    }

    private final class Box: Sendable {
        let state = Mutex(State())
    }

    private let box = Box()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<Element>) {
        let box = box
        task = Task {
            for await item in stream {
                box.state.withLock { $0.items.append(item) }
            }
        }
    }

    deinit {
        task.cancel()
    }

    var all: [Element] { box.state.withLock { $0.items } }

    /// The next `count` elements after those already returned. On timeout, records an issue and
    /// returns what arrived.
    func next(
        _ count: Int = 1,
        timeout: Duration = .seconds(2),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [Element] {
        let box = box
        let arrived = await eventually(timeout: timeout) {
            box.state.withLock { $0.items.count - $0.cursor >= count }
        }
        let out = box.state.withLock { s -> [Element] in
            let end = min(s.items.count, s.cursor + count)
            let slice = Array(s.items[s.cursor..<end])
            s.cursor = end
            return slice
        }
        if !arrived {
            Issue.record("Timed out waiting for \(count) element(s); got \(out)", sourceLocation: sourceLocation)
        }
        return out
    }
}

/// Runs `body` on a fresh `Thread` (not the main thread, not a Swift task) and returns its result.
func onBackgroundThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
        let thread = Thread { c.resume(returning: body()) }
        thread.name = "BuddyKeysTests.background"
        thread.start()
    }
}
