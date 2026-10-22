import AppKit
import ApplicationServices
import BuddyCore
import CoreGraphics
import Synchronization

/// The focused app from AX (always current), named via NSRunningApplication. Falls back to
/// NSWorkspace, whose `frontmostApplication` only updates on a main run-loop turn.
public struct WorkspaceFrontAppSensor: FrontAppSensor {
    public init() {}

    public func frontApp() -> FrontApp? {
        let focused = AX.element(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute).flatMap(AX.pid)
        guard let app = focused.flatMap(NSRunningApplication.init(processIdentifier:))
            ?? NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontApp(
            pid: app.processIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            bundle: app.bundleIdentifier)
    }
}

public struct CGDisplaySensor: DisplaySensor {
    public init() {}

    public func display() -> ContextPacket.Display? {
        guard let p = CGEvent(source: nil)?.location else { return nil }
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count == 1,
              let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return nil }
        let scale = Double(mode.pixelWidth) / Double(mode.width)
        // Set in the global domain by System Settings, including in Auto mode.
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return ContextPacket.Display(id: id, scale: scale, appearance: dark ? .dark : .light)
    }
}

/// Remembers the apps the user was in before the current one, with the window title each had
/// when the user left it. Starts empty at launch; fills as apps are activated.
public final class WorkspaceRecentApps: RecentAppsSensor {
    public static let limit = 3

    struct Entry {
        var pid: Int32
        var bundle: String?
        var app: ContextPacket.RecentApp
    }

    /// Serial, so title reads finish in activation order.
    private static let titleQueue = DispatchQueue(label: "BuddyContext.recent", qos: .utility)

    private let entries = Mutex<[Entry]>([])
    private let lastFront = Mutex<FrontApp?>(nil)
    private let blocklist: @Sendable () -> Blocklist
    private let terminal: any TerminalSensor
    private let editor: any EditorSensor
    // Written once at the end of init and read only in deinit, when no other reference exists.
    nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    /// `blocklist` returns the current blocklist (it can change in Settings). A blocked app's
    /// title is never read; the builder also filters at read time with its own blocklist.
    public init(
        blocklist: @escaping @Sendable () -> Blocklist,
        terminal: any TerminalSensor = ProcessTreeTerminalSensor(),
        editor: any EditorSensor = TitleAndDocumentEditorSensor()
    ) {
        self.blocklist = blocklist
        self.terminal = terminal
        self.editor = editor
        AX.setProcessTimeout()  // the front-app read below must not wait 1.5 s on a hung app
        let front = WorkspaceFrontAppSensor().frontApp()
        lastFront.withLock { $0 = front }
        if let front {
            // The app in front at launch gets its AX tree too (Electron, Chromium).
            AccessibilityEnabler.shared.activated(
                pid: front.pid, bundleID: front.bundle,
                bundleURL: NSRunningApplication(processIdentifier: front.pid)?.bundleURL,
                blocked: blocklist().isBlocked(bundleID: front.bundle))
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil,
            using: Self.handler(for: self))
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Built in a nonisolated context: the notification can arrive on any thread.
    private nonisolated static func handler(for tracker: WorkspaceRecentApps) -> @Sendable (Notification) -> Void {
        { [weak tracker] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let now = FrontApp(pid: app.processIdentifier, name: app.localizedName ?? "", bundle: app.bundleIdentifier)
            guard let tracker else { return }
            // ~2 s to build an Electron or Chromium tree: start now, well before a summon.
            AccessibilityEnabler.shared.activated(
                pid: now.pid, bundleID: now.bundle, bundleURL: app.bundleURL,
                blocked: tracker.blocklist().isBlocked(bundleID: now.bundle))
            tracker.activated(now)
        }
    }

    func activated(_ now: FrontApp) {
        let previous = lastFront.withLock { last in
            defer { last = now }
            return last
        }
        guard let previous, previous.pid != now.pid, previous.pid != getpid(),
              !blocklist().isBlocked(bundleID: previous.bundle)
        else { return }
        // The AX read can block for the messaging timeout, so it runs off the posting thread.
        let (terminal, editor) = (terminal, editor)
        Self.titleQueue.async { [weak self] in
            let title = AXWindowSensor().window(pid: previous.pid)?.title
            var app = ContextPacket.RecentApp(app: previous.name, title: title)
            Self.addFolder(to: &app, of: previous, terminal: terminal, editor: editor)
            self?.record(Entry(pid: previous.pid, bundle: previous.bundle, app: app))
        }
    }

    /// The folder the user was working in there, so a question about "my project" can find it
    /// after they switch apps: a terminal's front tab (and its command), an editor's workspace.
    static func addFolder(
        to entry: inout ContextPacket.RecentApp, of app: FrontApp,
        terminal: any TerminalSensor, editor: any EditorSensor
    ) {
        switch AppKinds.kind(of: app.bundle) {
        case .terminal:
            let tab = terminal.terminal(app: app)
            entry.cwd = tab?.cwd
            entry.command = tab?.command
        case .editor:
            entry.cwd = editor.editor(app: app)?.workspace
        default:
            break
        }
    }

    func record(_ entry: Entry) {
        entries.withLock { list in
            list.removeAll { $0.pid == entry.pid }
            list.insert(entry, at: 0)
            if list.count > Self.limit + 1 { list.removeLast(list.count - Self.limit - 1) }
        }
    }

    public func recent(excluding pid: Int32, isBlocked: @Sendable (String?) -> Bool) -> [ContextPacket.RecentApp] {
        let current = blocklist()
        return entries.withLock { list in
            Array(list.filter { $0.pid != pid && !isBlocked($0.bundle) && !current.isBlocked(bundleID: $0.bundle) }
                .prefix(Self.limit).map(\.app))
        }
    }
}

enum RunningApps {
    static func bundleID(of pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    static func bundleURL(of pid: Int32) -> URL? {
        NSRunningApplication(processIdentifier: pid)?.bundleURL
    }
}
