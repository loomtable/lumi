import BuddyCore
import CoreGraphics

/// The app in front when the buddy was summoned.
public struct FrontApp: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var bundle: String?

    public init(pid: Int32, name: String, bundle: String?) {
        self.pid = pid
        self.name = name
        self.bundle = bundle
    }
}

// Each sensor is synchronous and may block (AX messages to other apps); the builder runs it on
// the sensor queue with a deadline. Real implementations are in AXSensors.swift and
// SystemSensors.swift, fakes in Fakes.swift. A sensor returns nil when it has nothing.

public protocol FrontAppSensor: Sendable {
    func frontApp() -> FrontApp?
}

public protocol WindowSensor: Sendable {
    func window(pid: Int32) -> ContextPacket.Window?
}

public protocol SelectionSensor: Sendable {
    /// Never reads secure text fields.
    func selection(pid: Int32) -> ContextPacket.Selection?
}

public protocol EditableSensor: Sendable {
    /// Nil unless an editable, non-secure text element has focus.
    func editable(pid: Int32) -> ContextPacket.Editable?
}

public protocol CursorSensor: Sendable {
    /// The pointer in global points (top-left origin) and the element under it. The element is
    /// left out when it belongs to a process `skip` rejects (our own windows, blocked apps).
    func cursor(skip: @Sendable (Int32) -> Bool) -> ContextPacket.Cursor?
}

public protocol DisplaySensor: Sendable {
    /// The display under the pointer.
    func display() -> ContextPacket.Display?
}

public protocol RecentAppsSensor: Sendable {
    /// Most recent first, excluding `pid` (the front app) and apps whose bundle ID `isBlocked`.
    func recent(excluding pid: Int32, isBlocked: @Sendable (String?) -> Bool) -> [ContextPacket.RecentApp]
}

/// All sensors the builder uses, so the shell can swap any of them for a fake.
public struct ContextSensors: Sendable {
    public var frontApp: any FrontAppSensor
    public var window: any WindowSensor
    public var selection: any SelectionSensor
    public var cursor: any CursorSensor
    public var display: any DisplaySensor
    public var recent: any RecentAppsSensor
    public var browser: any BrowserSensor
    public var localServer: any LocalServerSensor
    public var terminal: any TerminalSensor
    public var editor: any EditorSensor
    public var editable: any EditableSensor
    /// Switches Electron and Chromium apps' AX trees on (live only; nil in tests, which use fake pids).
    public var accessibility: AccessibilityEnabler?

    public init(
        frontApp: any FrontAppSensor, window: any WindowSensor, selection: any SelectionSensor,
        cursor: any CursorSensor, display: any DisplaySensor, recent: any RecentAppsSensor,
        browser: any BrowserSensor = NoKindSensor(), localServer: any LocalServerSensor = NoKindSensor(),
        terminal: any TerminalSensor = NoKindSensor(), editor: any EditorSensor = NoKindSensor(),
        editable: any EditableSensor = NoKindSensor(),
        accessibility: AccessibilityEnabler? = nil
    ) {
        self.frontApp = frontApp
        self.window = window
        self.selection = selection
        self.cursor = cursor
        self.display = display
        self.recent = recent
        self.browser = browser
        self.localServer = localServer
        self.terminal = terminal
        self.editor = editor
        self.editable = editable
        self.accessibility = accessibility
    }
}
