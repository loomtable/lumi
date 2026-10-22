import BuddyCore
import Foundation

/// What a capture produced.
public enum ContextResult: Sendable, Equatable {
    case packet(ContextPacket, ContextTimings)
    /// The front app is blocked: nothing was read and nothing may be captured. The shell shows
    /// "I don't look at <app>".
    case blocked(app: String)
    /// No focused app could be found (e.g. at the login window), or Lumi itself is
    /// focused (a card is key); the shell keeps the previous packet then.
    case noFrontApp
}

/// Real durations for one capture, for the trace log and the budget check.
public struct ContextTimings: Sendable, Equatable {
    public var totalMs: Double
    /// Sensors that finished, with their duration.
    public var sensorMs: [String: Double]
    /// Sensors over the budget (kept), or past the hard cap (their fields left out).
    public var late: [String]
    /// The budget `late` is measured against.
    var budgetMs: Double?
}

/// Builds the context packet: the front app first, then the blocklist check, then
/// every other sensor at once. A sensor past the hard cap, or with nothing, leaves its field out.
///
/// Built at summon time, while the user speaks. The shell fills `utterance`, `conversation` and
/// `screenshot` at send.
public struct ContextBuilder: Sendable {
    public var sensors: ContextSensors
    public var blocklist: Blocklist
    /// The target for the whole packet (under 200 ms). Only a trace figure: a sensor over it
    /// is reported `late` but still lands, since the user is usually still talking.
    public var budget: Duration
    /// A sensor slower than this is left out, so a hung app can't hold the question.
    public var hardCap: Duration
    /// The front app read. Kept short so the rest of the budget is left for the other sensors.
    public var frontAppDeadline: Duration

    public init(
        sensors: ContextSensors, blocklist: Blocklist = Blocklist(),
        budget: Duration = .milliseconds(180), hardCap: Duration = .seconds(1),
        frontAppDeadline: Duration = .milliseconds(40)
    ) {
        self.sensors = sensors
        self.blocklist = blocklist
        self.budget = budget
        self.hardCap = hardCap
        self.frontAppDeadline = frontAppDeadline
    }

    /// Call once at launch: sets the process-wide AX messaging timeout (0.25 s, measured in S1)
    /// and sweeps screenshots past retention. Keep `ScreenshotStore.startPeriodicSweep()` too.
    public static func prepare(store: ScreenshotStore = ScreenshotStore()) {
        AX.setProcessTimeout()
        store.sweep()
    }

    public func capture(at askedAt: Date = Date()) async -> ContextResult {
        let start = ContinuousClock.now
        var timings = ContextTimings(totalMs: 0, sensorMs: [:], late: [])
        timings.budgetMs = budget.milliseconds
        let sensors = sensors
        let blocklist = blocklist

        guard let front = await Deadline.run(within: frontAppDeadline, { sensors.frontApp.frontApp() }) else {
            return .noFrontApp
        }
        guard let app = front.value, app.pid != getpid() else { return .noFrontApp }
        timings.sensorMs["front_app"] = front.ms
        let blocked = blocklist.isBlocked(bundleID: app.bundle)
        // Electron and Chromium apps need ~2 s to build their AX tree: from this summon on they
        // get it (a blocked app gets its switch put back instead).
        sensors.accessibility?.summoned(
            pid: app.pid, bundleID: app.bundle, bundleURL: RunningApps.bundleURL(of: app.pid), blocked: blocked)
        // Checked before any other read or capture (privacy).
        if blocked { return .blocked(app: app.name) }

        let pid = app.pid
        let ownPID = getpid()
        let blockedPIDs = BlockedPIDs(blocklist: blocklist)
        let remaining = max(.zero, hardCap - (ContinuousClock.now - start))

        async let window = Deadline.run(within: remaining) { sensors.window.window(pid: pid) }
        async let selection = Deadline.run(within: remaining) { sensors.selection.selection(pid: pid) }
        async let editable = Deadline.run(within: remaining) { sensors.editable.editable(pid: pid) }
        async let cursor = Deadline.run(within: remaining) {
            sensors.cursor.cursor(skip: { $0 == ownPID || blockedPIDs.contains($0) })
        }
        async let display = Deadline.run(within: remaining) { sensors.display.display() }
        let kind = AppKinds.kind(of: app.bundle)
        async let kindFields = Deadline.run(within: remaining) { KindFields.read(kind: kind, app: app, sensors: sensors) }
        async let recent = Deadline.run(within: remaining) {
            sensors.recent.recent(excluding: pid, isBlocked: { blocklist.isBlocked(bundleID: $0) })
        }

        var packet = ContextPacket(askedAt: askedAt, utterance: "")
        packet.app = ContextPacket.App(name: app.name, bundle: app.bundle, kind: kind)
        packet.window = timings.take("window", await window)
        packet.selection = timings.take("selection", await selection)
        packet.editable = timings.take("editable", await editable)
        packet.cursor = timings.take("cursor", await cursor)
        packet.display = timings.take("display", await display)
        if let fields = timings.take("kind", await kindFields) {
            packet.browser = fields.browser
            if packet.browser?.tabTitle == nil { packet.browser?.tabTitle = packet.window?.title }
            packet.terminal = fields.terminal
            packet.editor = fields.editor
        }
        // The local server needs the URL, so it runs after the browser read, in what is left
        // before the cap; a slow lookup loses only this field.
        if let url = packet.browser?.url, LocalURL.port(of: url) != nil {
            let left = max(.zero, hardCap - (ContinuousClock.now - start))
            let server = timings.take(
                "local_server", await Deadline.run(within: left) { sensors.localServer.server(for: url) })
            // Never describe a blocked app's process.
            packet.localServer = server.flatMap { blockedPIDs.contains($0.pid) ? nil : $0 }
        }
        let recentApps = timings.take("recent", await recent)
        packet.recent = recentApps?.isEmpty == false ? recentApps : nil
        timings.totalMs = (ContinuousClock.now - start).milliseconds
        return .packet(packet, timings)
    }
}

extension ContextTimings {
    /// Records the sensor's timing and unwraps its value. Over the budget it is `late` but kept;
    /// past the hard cap it gives nil.
    mutating func take<T>(_ name: String, _ result: (value: T?, ms: Double)?) -> T? {
        guard let result else {
            late.append(name)
            return nil
        }
        sensorMs[name] = result.ms
        if let budgetMs, result.ms > budgetMs { late.append(name) }
        return result.value
    }
}

/// The fields that depend on the app kind (table). The local server is looked up by the
/// builder afterwards, from the browser's URL.
struct KindFields: Sendable {
    var browser: ContextPacket.Browser?
    var terminal: ContextPacket.Terminal?
    var editor: ContextPacket.Editor?

    static func read(kind: ContextPacket.AppKind, app: FrontApp, sensors: ContextSensors) -> KindFields {
        var f = KindFields()
        switch kind {
        case .browser:
            f.browser = sensors.browser.browser(app: app)
        case .terminal:
            f.terminal = sensors.terminal.terminal(app: app)
        case .editor:
            f.editor = sensors.editor.editor(app: app)
        case .chat, .document, .finder, .other:
            break
        }
        return f
    }
}

/// PIDs of running blocked apps, resolved lazily from the bundle IDs.
struct BlockedPIDs: Sendable {
    let blocklist: Blocklist

    func contains(_ pid: Int32) -> Bool {
        guard let app = RunningApps.bundleID(of: pid) else { return false }
        return blocklist.isBlocked(bundleID: app)
    }
}
