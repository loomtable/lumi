import ApplicationServices
import CoreGraphics
import Dispatch
import Synchronization

/// Decides which events the scoped Esc tap consumes: plain Esc key-down, and the key-up that
/// pairs with a consumed key-down. Everything else passes, including Esc with any modifier
/// (⌘⌥Esc opens Force Quit), so no app ever sees an unpaired key-up from us.
public struct EscapeFilter: Sendable, Equatable {
    public static let escapeKeyCode: UInt16 = 0x35  // kVK_Escape

    public enum Kind: Sendable { case keyDown, keyUp }

    private var downConsumed = false

    public init() {}

    /// A plain Esc key-down was consumed and its key-up has not arrived yet.
    public var awaitingKeyUp: Bool { downConsumed }

    /// Returns true to consume. `isEscape` is reported for a consumed key-down only. While
    /// `draining`, no new key-down is taken; only a pending key-up is still consumed.
    /// Autorepeat key-downs of a consumed Esc are consumed too, without reporting a new press,
    /// including while draining.
    public mutating func consume(
        _ kind: Kind, keyCode: UInt16, flags: UInt64, isRepeat: Bool = false, draining: Bool = false
    ) -> (consume: Bool, isEscape: Bool) {
        guard keyCode == Self.escapeKeyCode else { return (false, false) }
        switch kind {
        case .keyDown where isRepeat:
            return (downConsumed, false)
        case .keyDown:
            guard !draining, flags & ModifierMask.anyModifier == 0 else { return (false, false) }
            downConsumed = true
            return (true, true)
        case .keyUp:
            guard downConsumed else { return (false, false) }
            downConsumed = false
            return (true, false)
        }
    }
}

/// While a card or the pill is visible but not key, consumes Esc so it never reaches the user's
/// app. Activate when one appears; deactivate when it goes or when the card becomes key (then
/// Esc must reach the card, which hands focus back). The tap exists only in between.
/// Real: `EscapeTap` (Accessibility). Fake: `FakeEscapeInterceptor`.
public protocol EscapeInterceptor: Sendable {
    /// Starts consuming Esc. The stream yields once per Esc press and ends on `deactivate`.
    func activate() throws(KeySourceError) -> AsyncStream<Void>
    /// Stops consuming Esc. If an Esc key-down was consumed and is still held, its key-up is
    /// consumed too (within 1 s), so the app never sees an unpaired key-up.
    func deactivate()
}

public final class EscapeTap: EscapeInterceptor {
    private struct Running {
        let tap: TapThread
        let continuation: AsyncStream<Void>.Continuation
        let filter: FilterState
    }

    private let running = Mutex<Running?>(nil)
    /// A deactivated tap kept alive only to consume one pending Esc key-up.
    private let draining = Mutex<TapThread?>(nil)

    public init() {}

    public func activate() throws(KeySourceError) -> AsyncStream<Void> {
        guard AXIsProcessTrusted() else { throw .accessibilityNotGranted }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let filter = FilterState()
        let context = TapThread.Context { [weak self] type, event in
            let kind: EscapeFilter.Kind
            switch type {
            case .keyDown: kind = .keyDown
            case .keyUp: kind = .keyUp
            default: return false
            }
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let (decision, drained) = filter.value.withLock { f in
                let d = f.filter.consume(
                    kind, keyCode: code, flags: event.flags.rawValue,
                    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, draining: f.draining)
                return (d, f.draining && !f.filter.awaitingKeyUp)
            }
            if decision.isEscape { continuation.yield() }
            if drained { self?.finishDraining() }
            return decision.consume
        }
        let result: Result<Void, KeySourceError> = running.withLock { slot in
            guard slot == nil else { return .failure(.alreadyStarted) }
            guard let tap = TapThread.start(
                name: "BuddyKeys.escape", options: .defaultTap, events: [.keyDown, .keyUp],
                callback: TapCallbacks.make(), context: context
            ) else { return .failure(.tapCreationFailed) }
            slot = Running(tap: tap, continuation: continuation, filter: filter)
            return .success(())
        }
        if case .failure(let error) = result {
            continuation.finish()
            throw error
        }
        return stream
    }

    public func deactivate() {
        let stopped = running.withLock { slot in
            defer { slot = nil }
            return slot
        }
        guard let stopped else { return }
        stopped.continuation.finish()
        let pending = stopped.filter.value.withLock { f in
            f.draining = true
            return f.filter.awaitingKeyUp
        }
        guard pending else {
            stopped.tap.stop()
            return
        }
        // Keep the tap for the key-up; give up after 1 s so a missed key-up can't keep it alive.
        // (If the key-up lands before the tap is stored here, the timeout ends it instead.)
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

    private final class FilterState: Sendable {
        struct Value {
            var filter = EscapeFilter()
            var draining = false
        }
        let value = Mutex(Value())
    }
}

public final class FakeEscapeInterceptor: EscapeInterceptor {
    private let continuation = Mutex<AsyncStream<Void>.Continuation?>(nil)

    public init() {}

    public var isActive: Bool { continuation.withLock { $0 != nil } }

    public func activate() throws(KeySourceError) -> AsyncStream<Void> {
        let (stream, c) = AsyncStream.makeStream(of: Void.self)
        let alreadyActive = continuation.withLock { slot in
            if slot != nil { return true }
            slot = c
            return false
        }
        if alreadyActive { throw .alreadyStarted }
        return stream
    }

    public func deactivate() {
        let c = continuation.withLock { slot in
            defer { slot = nil }
            return slot
        }
        c?.finish()
    }

    /// Simulates the user pressing Esc while active.
    public func pressEscape() {
        _ = continuation.withLock { $0?.yield() }
    }
}
