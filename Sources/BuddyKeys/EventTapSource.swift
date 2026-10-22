import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Synchronization

/// The real buddy key sensor: a listen-only CGEventTap (Input Monitoring) on its own thread,
/// for flagsChanged plus the cancel sources (key down, mouse down, scroll). It also polls
/// Secure Event Input every 250 ms on the same thread.
public final class EventTapSource: KeyEventSource {
    private struct Running {
        let tap: TapThread
        let continuation: AsyncStream<KeySourceEvent>.Continuation
    }

    private let running = Mutex<Running?>(nil)

    public init() {}

    static let events: [CGEventType] = [
        .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]

    public func start() throws(KeySourceError) -> AsyncStream<KeySourceEvent> {
        // tapCreate succeeds without the grant, so check it explicitly (S1).
        guard CGPreflightListenEventAccess() else { throw .inputMonitoringNotGranted }
        let (stream, continuation) = AsyncStream.makeStream(of: KeySourceEvent.self)
        let context = TapThread.Context { type, event in
            if let input = Self.input(type: type, event: event, time: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) {
                continuation.yield(.input(input))
            }
            return false
        }
        let secure = SecureInputState(IsSecureEventInputEnabled())
        if secure.last.withLock({ $0 }) { continuation.yield(.secureInput(true)) }
        let result: Result<Void, KeySourceError> = running.withLock { slot in
            guard slot == nil else { return .failure(.alreadyStarted) }
            guard let tap = TapThread.start(
                name: "BuddyKeys.listen", options: .listenOnly, events: Self.events,
                callback: TapCallbacks.make(), context: context,
                onRunLoop: { runLoop in Self.pollSecureInput(on: runLoop, state: secure, continuation: continuation) }
            ) else { return .failure(.tapCreationFailed) }
            slot = Running(tap: tap, continuation: continuation)
            return .success(())
        }
        if case .failure(let error) = result {
            continuation.finish()
            throw error
        }
        continuation.onTermination = { [weak self] _ in self?.stop() }
        return stream
    }

    public func stop() {
        let stopped = running.withLock { slot in
            defer { slot = nil }
            return slot
        }
        // Outside the lock: finishing runs onTermination, which calls stop again.
        stopped?.tap.stop()
        stopped?.continuation.finish()
    }

    public func currentFlags() -> UInt64 {
        CGEventSource.flagsState(.hidSystemState).rawValue
    }

    /// Maps a tap callback to gesture input. Out-of-band "tap disabled" notices become
    /// `tapInterrupted`, because events may have been lost while it was off.
    static func input(type: CGEventType, event: CGEvent, time: Nanos) -> InputEvent? {
        switch type {
        case .flagsChanged:
            .flagsChanged(
                keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags.rawValue, time: time)
        case .keyDown:
            .keyDown(keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)), time: time)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            .mouseDown(time: time)
        case .scrollWheel:
            .scroll(time: time)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            .tapInterrupted(time: time)
        default:
            nil
        }
    }

    final class SecureInputState: Sendable {
        let last: Mutex<Bool>
        init(_ value: Bool) { last = Mutex(value) }
    }

    private static func pollSecureInput(
        on runLoop: CFRunLoop, state: SecureInputState,
        continuation: AsyncStream<KeySourceEvent>.Continuation
    ) {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.25, 0.25, 0, 0) { @Sendable _ in
            let on = IsSecureEventInputEnabled()
            let changed = state.last.withLock { last in
                defer { last = on }
                return last != on
            }
            if changed { continuation.yield(.secureInput(on)) }
        }
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
    }
}
