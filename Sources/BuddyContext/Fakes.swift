import BuddyCore
import CoreGraphics
import Foundation
import Synchronization

/// A sensor that returns a fixed value after an optional delay (to test deadlines), and counts
/// how often it was asked. One type serves every sensor protocol.
public final class FakeSensor<Value: Sendable>: Sendable {
    public let value: Value
    public let delay: Duration
    private let calls = Mutex(0)

    public init(_ value: Value, delay: Duration = .zero) {
        self.value = value
        self.delay = delay
    }

    public var callCount: Int { calls.withLock { $0 } }

    func read() -> Value {
        calls.withLock { $0 += 1 }
        if delay > .zero { Thread.sleep(forTimeInterval: delay.timeInterval) }
        return value
    }
}

extension FakeSensor: FrontAppSensor where Value == FrontApp? {
    public func frontApp() -> FrontApp? { read() }
}

extension FakeSensor: WindowSensor where Value == ContextPacket.Window? {
    public func window(pid: Int32) -> ContextPacket.Window? { read() }
}

extension FakeSensor: SelectionSensor where Value == ContextPacket.Selection? {
    public func selection(pid: Int32) -> ContextPacket.Selection? { read() }
}

extension FakeSensor: CursorSensor where Value == ContextPacket.Cursor? {
    public func cursor(skip: @Sendable (Int32) -> Bool) -> ContextPacket.Cursor? { read() }
}

extension FakeSensor: DisplaySensor where Value == ContextPacket.Display? {
    public func display() -> ContextPacket.Display? { read() }
}

extension FakeSensor: RecentAppsSensor where Value == [ContextPacket.RecentApp] {
    public func recent(excluding pid: Int32, isBlocked: @Sendable (String?) -> Bool) -> [ContextPacket.RecentApp] {
        read()
    }
}

public final class FakeScreenshotter: Screenshotter {
    public let result: Result<URL, ScreenshotError>
    private let requests = Mutex<[(displayID: UInt32?, blocklist: Blocklist, options: ScreenshotOptions, region: CGRect?)]>([])

    public init(result: Result<URL, ScreenshotError>) {
        self.result = result
    }

    public var requestCount: Int { requests.withLock { $0.count } }
    public var lastOptions: ScreenshotOptions? { requests.withLock { $0.last?.options } }
    public var lastRegion: CGRect? { requests.withLock { $0.last?.region } }

    public func capture(
        displayID: UInt32?, blocklist: Blocklist, options: ScreenshotOptions, region: CGRect?
    ) async throws(ScreenshotError) -> Screenshot {
        requests.withLock { $0.append((displayID, blocklist, options, region)) }
        let url = try result.get()
        return Screenshot(
            file: url, fileData: Data(), fileWidth: 1, fileHeight: 1, full: Self.pixel, displayID: displayID ?? 1, scale: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// A 1×1 image standing in for a capture.
    static let pixel: CGImage = {
        let ctx = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()
}

/// Reports nothing, for kinds a configuration doesn't cover.
public struct NoKindSensor: BrowserSensor, LocalServerSensor, TerminalSensor, EditorSensor, EditableSensor {
    public init() {}
    public func browser(app: FrontApp) -> ContextPacket.Browser? { nil }
    public func server(for url: String) -> ContextPacket.LocalServer? { nil }
    public func terminal(app: FrontApp) -> ContextPacket.Terminal? { nil }
    public func editor(app: FrontApp) -> ContextPacket.Editor? { nil }
    public func editable(pid: Int32) -> ContextPacket.Editable? { nil }
}

extension FakeSensor: EditableSensor where Value == ContextPacket.Editable? {
    public func editable(pid: Int32) -> ContextPacket.Editable? { read() }
}

extension FakeSensor: BrowserSensor where Value == ContextPacket.Browser? {
    public func browser(app: FrontApp) -> ContextPacket.Browser? { read() }
}

extension FakeSensor: LocalServerSensor where Value == ContextPacket.LocalServer? {
    public func server(for url: String) -> ContextPacket.LocalServer? { read() }
}

extension FakeSensor: TerminalSensor where Value == ContextPacket.Terminal? {
    public func terminal(app: FrontApp) -> ContextPacket.Terminal? { read() }
}

extension FakeSensor: EditorSensor where Value == ContextPacket.Editor? {
    public func editor(app: FrontApp) -> ContextPacket.Editor? { read() }
}

extension ContextSensors {
    /// The real sensors. `recent` should be one long-lived tracker created at launch.
    public static func live(recent: any RecentAppsSensor) -> ContextSensors {
        ContextSensors(
            frontApp: WorkspaceFrontAppSensor(), window: AXWindowSensor(), selection: AXSelectionSensor(),
            cursor: AXCursorSensor(), display: CGDisplaySensor(), recent: recent,
            browser: AppleEventBrowserSensor(), localServer: LibprocLocalServerSensor(),
            terminal: ProcessTreeTerminalSensor(), editor: TitleAndDocumentEditorSensor(),
            editable: AXEditableSensor(),
            accessibility: .shared)
    }
}
