import CoreGraphics
import Foundation
import Synchronization

/// Runs one CGEventTap on a dedicated thread with its own run loop, so the tap never waits
/// behind the main thread and is never disabled for a slow main-thread callback.
///
/// The callback runs on that thread. It must be a plain C function built in a nonisolated
/// context (see `TapCallbacks`): a closure that inherited main-actor isolation would trap there.
final class TapThread: Sendable {
    /// Shared with the callback through `userInfo`. Lives as long as the tap.
    final class Context: Sendable {
        // Set once on the tap thread before the run loop starts, and read only on the tap thread
        // afterwards (by the callback, to re-enable the tap after a timeout).
        nonisolated(unsafe) var port: CFMachPort?
        let onEvent: @Sendable (CGEventType, CGEvent) -> Bool

        /// `onEvent` runs on the tap thread and returns true to drop the event (active taps only).
        init(onEvent: @escaping @Sendable (CGEventType, CGEvent) -> Bool) {
            self.onEvent = onEvent
        }
    }

    private let context: Context
    // Written on the tap thread before `ready` is signalled and read only after waiting on it,
    // so the semaphore orders the accesses. `stop` hands it to CFRunLoopStop, which is
    // documented as safe to call from any thread.
    nonisolated(unsafe) private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private let stopped = Atomic(false)

    private init(context: Context) {
        self.context = context
    }

    /// Creates the tap on a new thread and waits (a few ms) for the result.
    static func start(
        name: String,
        options: CGEventTapOptions,
        events: [CGEventType],
        callback: CGEventTapCallBack,
        context: Context,
        onRunLoop setUp: (@Sendable (CFRunLoop) -> Void)? = nil
    ) -> TapThread? {
        let tap = TapThread(context: context)
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let thread = Thread { @Sendable in
            // The closure keeps `context` alive for the life of the tap, so unretained is safe.
            let info = Unmanaged.passUnretained(context).toOpaque()
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                eventsOfInterest: mask, callback: callback, userInfo: info
            ) else {
                tap.ready.signal()
                return
            }
            let current = CFRunLoopGetCurrent()!
            context.port = port
            tap.runLoop = current
            CFRunLoopAddSource(current, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            setUp?(current)
            tap.ready.signal()
            // Bounded slices, so a stop that lands before the loop first runs is still seen.
            while !tap.stopped.load(ordering: .acquiring) {
                CFRunLoopRunInMode(.defaultMode, 0.5, false)
            }
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        tap.ready.wait()
        return tap.runLoop == nil ? nil : tap
    }

    /// Stops the run loop; the thread then disables and invalidates the tap and exits. The
    /// thread keeps this object alive until then, so `stop` is the only way to end the tap.
    func stop() {
        stopped.store(true, ordering: .releasing)
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}

/// C callbacks for event taps. A `nonisolated` factory, so the closures carry no actor isolation
/// and are safe on the tap thread.
enum TapCallbacks {
    nonisolated static func make() -> CGEventTapCallBack {
        { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let context = Unmanaged<TapThread.Context>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let port = context.port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return context.onEvent(type, event) ? nil : Unmanaged.passUnretained(event)
        }
    }
}
