import ApplicationServices
import CoreGraphics
import Darwin
import Dispatch
import Synchronization

/// Consumes the switcher keys while the buddy key is held or Lumi is listening, so ⌥Tab and the
/// rest never reach the front app. The tap exists only while armed: an always-on consuming tap
/// breaks some input methods (alt-tab-macos #5766). Real: `SwitcherTap` (Accessibility).
/// Fake: `FakeSwitcherTap`.
public protocol SwitcherInterceptor: Sendable {
    /// Starts consuming what `arming` maps. The stream yields each consumed key-down as
    /// `.switcherKeyDown` and ends on `deactivate`.
    func activate(_ arming: SwitcherFilter.Arming) throws(KeySourceError) -> AsyncStream<InputEvent>
    /// Changes what is consumed while active (the strip opened or closed).
    func update(_ arming: SwitcherFilter.Arming)
    /// Stops taking new keys. Key-ups of keys already taken are still consumed (within 1 s).
    func deactivate()
}

public final class SwitcherTap: SwitcherInterceptor {
    private struct Running {
        let tap: TapThread
        let continuation: AsyncStream<InputEvent>.Continuation
    }

    /// Shared with `EventTapSource(arming:)`, which drops what this tap takes.
    public let arming: KeyArming
    private let running = Mutex<Running?>(nil)
    /// A deactivated tap kept alive only to consume pending key-ups.
    private let draining = Mutex<TapThread?>(nil)

    public init(arming: KeyArming = KeyArming()) {
        self.arming = arming
    }

    public func activate(_ arming: SwitcherFilter.Arming) throws(KeySourceError) -> AsyncStream<InputEvent> {
        guard AXIsProcessTrusted() else { throw .accessibilityNotGranted }
        let (stream, continuation) = AsyncStream.makeStream(of: InputEvent.self)
        let shared = self.arming
        let context = TapThread.Context { [weak self] type, event in
            let kind: SwitcherFilter.Kind
            switch type {
            case .keyDown: kind = .keyDown
            case .keyUp: kind = .keyUp
            default: return false
            }
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let decision = shared.consume(
                kind, keyCode: code, flags: event.flags.rawValue,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            if let key = decision.key {
                continuation.yield(.switcherKeyDown(key, keyCode: code, time: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
            }
            if kind == .keyUp, shared.arming == nil, !shared.awaitingKeyUp { self?.finishDraining() }
            return decision.consume
        }
        // A tap still draining the last gesture's key-ups is replaced: this one takes them.
        finishDraining()
        let result: Result<Void, KeySourceError> = running.withLock { slot in
            guard slot == nil else { return .failure(.alreadyStarted) }
            shared.set(arming)
            guard let tap = TapThread.start(
                name: "BuddyKeys.switcher", options: .defaultTap, events: [.keyDown, .keyUp],
                callback: TapCallbacks.make(), context: context
            ) else {
                shared.set(nil)
                return .failure(.tapCreationFailed)
            }
            slot = Running(tap: tap, continuation: continuation)
            return .success(())
        }
        if case .failure(let error) = result {
            continuation.finish()
            throw error
        }
        return stream
    }

    public func update(_ arming: SwitcherFilter.Arming) {
        running.withLock { slot in
            guard slot != nil else { return }
            self.arming.set(arming)
        }
    }

    public func deactivate() {
        let stopped = running.withLock { slot in
            defer { slot = nil }
            arming.set(nil)
            return slot
        }
        guard let stopped else { return }
        stopped.continuation.finish()
        guard arming.awaitingKeyUp else {
            stopped.tap.stop()
            return
        }
        // Keep the tap for the key-ups; give up after 1 s so a lost key-up can't keep it alive.
        let tap = stopped.tap
        let previous = draining.withLock { slot in
            defer { slot = tap }
            return slot
        }
        previous?.stop()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.finishDraining(only: tap)
        }
    }

    /// Stops the draining tap; with `only`, just if it is still that tap.
    private func finishDraining(only expected: TapThread? = nil) {
        let tap = draining.withLock { slot -> TapThread? in
            guard let current = slot, expected == nil || current === expected else { return nil }
            slot = nil
            return current
        }
        tap?.stop()
    }
}

public final class FakeSwitcherTap: SwitcherInterceptor {
    private struct State {
        var continuation: AsyncStream<InputEvent>.Continuation?
        var arming: SwitcherFilter.Arming?
        var activations = 0
        var error: KeySourceError?
    }

    private let state = Mutex(State())

    public init(error: KeySourceError? = nil) {
        state.withLock { $0.error = error }
    }

    public var isActive: Bool { state.withLock { $0.continuation != nil } }
    /// The arming while active, nil while not.
    public var arming: SwitcherFilter.Arming? { state.withLock { $0.arming } }
    public var activations: Int { state.withLock { $0.activations } }

    public func setError(_ error: KeySourceError?) { state.withLock { $0.error = error } }

    public func activate(_ arming: SwitcherFilter.Arming) throws(KeySourceError) -> AsyncStream<InputEvent> {
        let (stream, c) = AsyncStream.makeStream(of: InputEvent.self)
        let error: KeySourceError? = state.withLock { s in
            if let e = s.error { return e }
            if s.continuation != nil { return .alreadyStarted }
            s.continuation = c
            s.arming = arming
            s.activations += 1
            return nil
        }
        if let error { throw error }
        return stream
    }

    public func update(_ arming: SwitcherFilter.Arming) {
        state.withLock { s in
            guard s.continuation != nil else { return }
            s.arming = arming
        }
    }

    public func deactivate() {
        let c = state.withLock { s in
            defer { s.continuation = nil; s.arming = nil }
            return s.continuation
        }
        c?.finish()
    }

    /// Simulates a consumed switcher key-down, if the arming takes it.
    @discardableResult
    public func press(keyCode: UInt16, flags: UInt64 = 0, time: Nanos) -> SwitcherKey? {
        state.withLock { s -> SwitcherKey? in
            guard let c = s.continuation, let arming = s.arming,
                  let key = SwitcherFilter(arming: arming).lookup(keyCode: keyCode, flags: flags)
            else { return nil }
            c.yield(.switcherKeyDown(key, keyCode: keyCode, time: time))
            return key
        }
    }
}
