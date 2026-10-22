import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import BuddyKeys

/// What a tap callback saw, recorded from the thread it ran on.
final class CallbackLog: Sendable {
    struct Entry: Sendable, Equatable {
        let type: CGEventType
        let keyCode: Int64
        let flags: UInt64
        let onMainThread: Bool
    }

    let entries = Mutex<[Entry]>([])

    func record(_ type: CGEventType, _ event: CGEvent) {
        let entry = Entry(
            type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags.rawValue, onMainThread: Thread.isMainThread)
        entries.withLock { $0.append(entry) }
    }

    var all: [Entry] { entries.withLock { $0 } }
}

/// The result of one callback invocation, reduced to Sendable values.
struct CallbackResult: Sendable, Equatable {
    /// The callback passed the event on (returned non-nil).
    let passed: Bool
    /// What it returned is the event it was given.
    let sameEvent: Bool
    let onMainThread: Bool
}

/// Builds the callback and calls it on a background `Thread`, as the tap thread would.
func invokeCallback(
    context: TapThread.Context?,
    type: CGEventType,
    keyCode: CGKeyCode,
    keyDown: Bool = true,
    flags: UInt64
) async -> CallbackResult {
    await onBackgroundThread {
        let callback = TapCallbacks.make()
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)!
        if type == .flagsChanged { event.type = .flagsChanged }
        event.flags = CGEventFlags(rawValue: flags)
        let info = context.map { Unmanaged.passUnretained($0).toOpaque() }
        let proxy = OpaquePointer(bitPattern: 0x1)!  // unused by the callback
        let result = callback(proxy, type, event, info)
        return CallbackResult(
            passed: result != nil,
            sameEvent: result.map { $0.takeUnretainedValue() === event } ?? false,
            onMainThread: Thread.isMainThread)
    }
}

@Suite("Tap callback off the main thread")
struct TapCallbackTests {
    let rightOptionDown = ModifierMask.alternate | ModifierMask.deviceRightAlt

    @Test("passes the event on when onEvent returns false")
    func passes() async {
        let log = CallbackLog()
        let context = TapThread.Context { type, event in
            log.record(type, event)
            return false
        }
        let result = await invokeCallback(context: context, type: .flagsChanged, keyCode: 61, flags: rightOptionDown)
        #expect(result == CallbackResult(passed: true, sameEvent: true, onMainThread: false))
        #expect(log.all == [.init(type: .flagsChanged, keyCode: 61, flags: rightOptionDown, onMainThread: false)])
    }

    @Test("drops the event when onEvent returns true")
    func drops() async {
        let log = CallbackLog()
        let context = TapThread.Context { type, event in
            log.record(type, event)
            return true
        }
        let result = await invokeCallback(context: context, type: .flagsChanged, keyCode: 61, flags: rightOptionDown)
        #expect(result == CallbackResult(passed: false, sameEvent: false, onMainThread: false))
        #expect(log.all.count == 1)
    }

    @Test("with no userInfo, passes the event on")
    func noContext() async {
        let result = await invokeCallback(context: nil, type: .keyDown, keyCode: 0, flags: 0)
        #expect(result == CallbackResult(passed: true, sameEvent: true, onMainThread: false))
    }

    @Test("tap-disabled notices reach onEvent (no port yet: no re-enable)",
          arguments: [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput])
    func tapDisabled(type: CGEventType) async {
        let log = CallbackLog()
        let context = TapThread.Context { type, event in
            log.record(type, event)
            return false
        }
        let result = await invokeCallback(context: context, type: type, keyCode: 0, flags: 0)
        #expect(result.passed)
        #expect(log.all.map(\.type) == [type])
    }

    @Test("the EventTapSource path: input mapped and yielded from the tap thread")
    func eventTapSourcePath() async {
        let (stream, continuation) = AsyncStream.makeStream(of: InputEvent.self)
        let context = TapThread.Context { type, event in
            if let input = EventTapSource.input(type: type, event: event, time: 42) {
                continuation.yield(input)
            }
            return false
        }
        let result = await invokeCallback(context: context, type: .flagsChanged, keyCode: 61, flags: rightOptionDown)
        continuation.finish()
        #expect(result.passed)
        var received: [InputEvent] = []
        for await input in stream { received.append(input) }
        #expect(received == [.flagsChanged(keyCode: 61, flags: rightOptionDown, time: 42)])
    }

    /// `EscapeTap.activate()` needs Accessibility, so its own closure is not reachable here.
    /// This mirrors it: the shared callback driving `EscapeFilter` on the tap thread.
    @Test("the EscapeTap path: plain Esc dropped, its up dropped, other keys passed")
    func escapeFilterPath() async {
        final class Filter: Sendable { let value = Mutex(EscapeFilter()) }
        let filter = Filter()
        let context = TapThread.Context { type, event in
            let kind: EscapeFilter.Kind
            switch type {
            case .keyDown: kind = .keyDown
            case .keyUp: kind = .keyUp
            default: return false
            }
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            return filter.value.withLock { $0.consume(kind, keyCode: code, flags: event.flags.rawValue).consume }
        }
        let esc = CGKeyCode(EscapeFilter.escapeKeyCode)
        #expect(await !invokeCallback(context: context, type: .keyDown, keyCode: esc, flags: 0).passed)
        #expect(await !invokeCallback(context: context, type: .keyUp, keyCode: esc, keyDown: false, flags: 0).passed)
        #expect(await invokeCallback(context: context, type: .keyDown, keyCode: 0, flags: 0).passed)
        let cmd = ModifierMask.command | ModifierMask.deviceLeftCmd
        #expect(await invokeCallback(context: context, type: .keyDown, keyCode: esc, flags: cmd).passed)
        #expect(await invokeCallback(context: context, type: .keyUp, keyCode: esc, keyDown: false, flags: 0).passed)
    }
}

@Suite("EventTapSource.input mapping")
struct EventTapSourceInputTests {
    func keyboard(_ code: CGKeyCode, flags: UInt64 = 0) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        event.flags = CGEventFlags(rawValue: flags)
        return event
    }

    @Test("flagsChanged carries key code, flags and time")
    func flagsChanged() {
        let flags = ModifierMask.alternate | ModifierMask.deviceRightAlt
        let event = keyboard(61, flags: flags)
        event.type = .flagsChanged
        #expect(EventTapSource.input(type: .flagsChanged, event: event, time: 7)
                == .flagsChanged(keyCode: 61, flags: flags, time: 7))
    }

    @Test("keyDown carries the key code")
    func keyDown() {
        #expect(EventTapSource.input(type: .keyDown, event: keyboard(14), time: 9) == .keyDown(keyCode: 14, time: 9))
    }

    @Test("mouse downs map to mouseDown",
          arguments: [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown])
    func mouse(type: CGEventType) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
        #expect(EventTapSource.input(type: type, event: event, time: 3) == .mouseDown(time: 3))
    }

    @Test("scroll maps to scroll")
    func scroll() {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
        #expect(EventTapSource.input(type: .scrollWheel, event: event, time: 5) == .scroll(time: 5))
    }

    @Test("tap disabled notices map to tapInterrupted",
          arguments: [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput])
    func tapDisabled(type: CGEventType) {
        #expect(EventTapSource.input(type: type, event: keyboard(0), time: 11) == .tapInterrupted(time: 11))
    }

    @Test("other event types are ignored", arguments: [CGEventType.keyUp, .mouseMoved, .leftMouseUp, .null])
    func ignored(type: CGEventType) {
        #expect(EventTapSource.input(type: type, event: keyboard(0), time: 1) == nil)
    }

    @Test("the tap listens for exactly the gesture inputs")
    func eventsOfInterest() {
        #expect(Set(EventTapSource.events.map(\.rawValue)) == Set([
            CGEventType.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ].map(\.rawValue)))
    }
}
