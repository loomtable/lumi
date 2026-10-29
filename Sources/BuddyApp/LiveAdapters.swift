import AppKit
import BuddyAct
import BuddyBridge
import BuddyContext
import BuddyCore
import BuddyKeys
import Foundation
import OSLog
import Synchronization

// Live implementations of the coordinator's ports, each a thin pass-through to its module.

/// Packet via `ContextBuilder`, screenshot via ScreenCaptureKit (model-sized JPEG).
public struct LiveContext: ContextPort {
    private let builder: ContextBuilder
    private let shooter: any Screenshotter
    /// The current blocklist (Settings › Privacy can change it at any time); read per capture.
    private let blocklist: @Sendable () -> Blocklist

    public init(builder: ContextBuilder, shooter: any Screenshotter = ScreenCaptureKitShooter(),
                blocklist: @escaping @Sendable () -> Blocklist) {
        self.builder = builder
        self.shooter = shooter
        self.blocklist = blocklist
    }

    public func capture() async -> SummonContext {
        // A per-call copy reads the current blocklist and records which process the packet was
        // built from, without shared state.
        let front = RecordingFrontApp(base: builder.sensors.frontApp)
        var builder = builder
        builder.blocklist = blocklist()
        builder.sensors.frontApp = front
        let result = await builder.capture()
        guard case .packet = result else { return SummonContext(result: result) }
        return SummonContext(result: result, pid: front.pid)
    }

    /// The question still goes without one, with the reason in the packet. A failed capture is
    /// retried once (it runs while the user is still speaking); a missing grant isn't.
    public func screenshot(displayID: UInt32?) async -> ShotOutcome {
        await screenshot(displayID: displayID, focus: nil)
    }

    public func screenshot(displayID: UInt32?, focus: ModelRegion.Focus?) async -> ShotOutcome {
        var target = displayID
        for attempt in 1...2 {
            // A capture superseded by a new summon isn't retried; nobody reads its result.
            if attempt > 1, Task.isCancelled { break }
            do {
                // A nil display is the main one, as the shooter captures it: the two change together.
                let region = focus.flatMap {
                    ModelRegion.choose(window: $0.window, cursor: $0.cursor, display: CGDisplayBounds(target ?? CGMainDisplayID()))
                }
                let shot = try await shooter.capture(displayID: target, blocklist: blocklist(), options: .model, region: region)
                // A close-up only beside a window image, and only inside it.
                let detail = region == nil ? nil : focus?.detail.flatMap { shot.detail(around: $0) }
                return .shot(CapturedShot(path: shot.file.path, data: shot.fileData, mediaType: "image/jpeg", screenshot: shot,
                                          detail: detail))
            } catch ScreenshotError.screenRecordingNotGranted {
                Self.log.notice("screenshot unavailable: Screen Recording not granted")
                return .unavailable(.notGranted)
            } catch {
                // The error's kind only: its text never carries screen content.
                Self.log.error("screenshot attempt \(attempt, privacy: .public) failed: \(Self.kind(error), privacy: .public)")
                // The display went away (unplugged): windows move to the main one, so try that.
                if case .displayNotFound = error { target = nil }
            }
        }
        return .unavailable(.captureFailed)
    }

    private static let log = Logger(subsystem: BuddyCore.bundleIdentifier, category: "context")

    static func kind(_ error: ScreenshotError) -> String {
        switch error {
        case .screenRecordingNotGranted: "not granted"
        case .displayNotFound: "display not found"
        case .captureFailed: "capture failed"
        }
    }
}

/// Passes the front app through and keeps its pid for this one capture.
private final class RecordingFrontApp: FrontAppSensor {
    private let base: any FrontAppSensor
    private let read = Mutex<Int32?>(nil)

    init(base: any FrontAppSensor) { self.base = base }

    var pid: Int32? { read.withLock { $0 } }

    func frontApp() -> FrontApp? {
        let app = base.frontApp()
        read.withLock { $0 = app?.pid }
        return app
    }
}

/// Rings via BuddyContext's `ScreenPointLocator`: AX text first, then OCR of the summon capture.
public struct LiveLocator: LocatePort {
    private let locator: ScreenPointLocator
    /// Read per call, so an app blocked in Settings applies at once.
    private let blocklist: @Sendable () -> Blocklist

    public init(blocklist: @escaping @Sendable () -> Blocklist, locator: ScreenPointLocator = ScreenPointLocator()) {
        self.blocklist = blocklist
        self.locator = locator
    }

    public func locate(_ quotes: [String], pid: Int32, shot: CapturedShot?) async -> [LocatedPoint] {
        await locator.locate(quotes, pid: pid, screenshot: shot?.screenshot, blocklist: blocklist())
    }
}

/// Questions go through the Quick → Deep cascade; open-session turns through the session pool.
public struct LiveBridge: BridgePort {
    private let cascade: Cascade
    private let sessions: LiveSessionTurns?

    public init(cascade: Cascade, sessions: LiveSessionTurns? = nil) {
        self.cascade = cascade
        self.sessions = sessions
    }

    /// `.cascade` asks, `.deeper` goes deeper, `.session` is one turn in an open session.
    public func send(_ request: TurnRequest) async -> AsyncStream<TurnStreamEvent> {
        switch request.target {
        case .cascade:
            return Self.relay(await ask(request.question, state: request.state), as: TurnStreamEvent.cascade)
        case .deeper:
            return Self.relay(await goDeeper(request.question, state: request.state), as: TurnStreamEvent.cascade)
        case .session(let id, let launch):
            guard let sessions else { return AsyncStream { $0.finish() } }
            return Self.relay(await sessions.run(request, id: id, launch: launch), as: TurnStreamEvent.session)
        }
    }

    static func relay<E: Sendable>(_ stream: AsyncStream<E>, as wrap: @escaping @Sendable (E) -> TurnStreamEvent) -> AsyncStream<TurnStreamEvent> {
        AsyncStream { continuation in
            let relay = Task {
                for await event in stream { continuation.yield(wrap(event)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }

    public func ask(_ question: Question, state: ConversationState) async -> AsyncStream<CascadeEvent> {
        await cascade.ask(question, state: state)
    }

    public func goDeeper(_ question: Question, state: ConversationState) async -> AsyncStream<CascadeEvent> {
        await cascade.goDeeper(question, state: state)
    }

    public func cancel(conversation: String) async {
        await cascade.cancel(conversation: conversation)
        await sessions?.pool.interrupt(SessionID(rawValue: conversation))
    }
}

/// The scoped Esc tap from BuddyKeys (needs Accessibility).
public struct LiveEscape: EscapePort {
    private let tap: any EscapeInterceptor

    public init(tap: any EscapeInterceptor = EscapeTap()) {
        self.tap = tap
    }

    public func activate() throws -> AsyncStream<Void> {
        try tap.activate()
    }

    public func deactivate() {
        tap.deactivate()
    }
}

/// The pointer in global points with a top-left origin (AppKit reports bottom-left).
public struct LivePointer: PointerPort {
    public init() {}

    public func location() -> CGPoint {
        let p = NSEvent.mouseLocation
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}

/// Inserts drafts with BuddyAct; failures become one true line for a chip.
@MainActor
public final class LiveInserter: InsertPort {
    private let inserter: TextInserter
    private let accessibilityGranted: @MainActor () -> Bool

    public init(inserter: TextInserter, accessibilityGranted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() }) {
        self.inserter = inserter
        self.accessibilityGranted = accessibilityGranted
    }

    public func insert(_ text: String, into pid: Int32?) async -> String? {
        Self.problem(for: await inserter.insert(text, into: pid), accessibilityGranted: accessibilityGranted())
    }

    static let needsAccessibility = "\(BuddyCore.appName) needs Accessibility to insert text. Turn it on in Settings › Privacy."

    /// Nil for every outcome where the text went in (or is on the clipboard, ready to paste).
    static func problem(for result: InsertResult, accessibilityGranted: Bool = true) -> String? {
        // Without Accessibility no field can be found or typed into: clicking one wouldn't help.
        if result == .noFocusedField, !accessibilityGranted { return needsAccessibility }
        return switch result {
        case .insertedViaAccessibility, .insertedViaAccessibilityUnverified, .pasted:
            nil
        case .pasteUnconfirmed:
            "It's on your clipboard. Paste it where you want it."
        case .refusedSecureField:
            "I don't type into password fields."
        case .refusedBlockedApp:
            "I don't insert into that app."
        case .refusedOwnApp, .noFocusedField:
            "Click the field you want it in, then try again."
        case .refusedEmptyText:
            "There's nothing to insert."
        case .refusedMultilineInTerminal:
            "I don't paste several lines into a terminal."
        case .focusChanged:
            "The focus moved, so I didn't insert it."
        case .pasteFailed:
            "Pasting didn't work here."
        case .busy:
            "Still inserting the last one."
        }
    }
}
