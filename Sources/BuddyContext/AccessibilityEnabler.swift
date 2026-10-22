import AppKit
import ApplicationServices
import Foundation
import Synchronization

/// Electron and Chromium apps build their accessibility tree only once told an assistive app is
/// present. Without it they report no focused element and no selection, so the packet has no
/// selection and rings fall back to OCR.
///
/// Measured (macOS 26.6, `AXSelectionLiveTests`): Slack and VS Code need `AXManualAccessibility`;
/// Chrome 155 needs `AXEnhancedUserInterface` (it rejects ManualAX). Either takes about 2 s to
/// build the tree, far over the packet's 200 ms.
///
/// A live tree has a cost (`ChromeAXCostTests`): with EUI on, Chrome let only 7 of 10 AX-driven
/// window resizes land (10 of 10 off), as window managers like Rectangle see; VS Code with
/// ManualAX missed all 10 in one run. So a switch is on only around a summon: it goes on when the
/// user summons in that app (that summon's selection is read by OCR; rings for its answer, a few
/// seconds later, usually find AX text), and goes back off `linger` after the last summon there.
/// Never for a blocked app; everything is put back when Lumi quits.
public final class AccessibilityEnabler: Sendable {
    public static let shared = AccessibilityEnabler()

    enum Switch: String, Sendable {
        /// Electron's switch for building its AX tree.
        case manualAX = "AXManualAccessibility"
        /// Chromium's "assistive technology is present" switch.
        case enhancedUI = "AXEnhancedUserInterface"
    }

    /// Chromium browsers (they ignore ManualAX). Electron apps are found by their framework.
    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "company.thebrowser.Browser",
    ]

    struct Entry: Sendable {
        var kind: Switch
        var bundleID: String?
        /// Tells a relaunched app that got a recycled pid apart from the one we switched on.
        var launched: Date?
        var before: Bool
        /// Switched back off at this time unless another summon comes first.
        var until: Date
    }

    private struct State: Sendable {
        var enabled: [Int32: Entry] = [:]
        var closed = false
    }

    /// How long a switch stays on after the last summon in that app: follow-ups and rings use it.
    let linger: TimeInterval

    private let state = Mutex(State())
    /// AX writes can block for the messaging timeout: never on the caller's thread, and one at a
    /// time, so `enable`'s check-then-set can't race and `restoreAll` sees every write.
    private static let queue = DispatchQueue(label: "BuddyContext.accessibility", qos: .utility)
    private let setter: @Sendable (Int32, Switch, Bool) -> Bool?
    private let reader: @Sendable (Int32, Switch) -> Bool?
    private let electron: @Sendable (URL) -> Bool
    private let launchDate: @Sendable (Int32) -> Date?
    private let now: @Sendable () -> Date

    init(
        linger: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init,
        setter: @escaping @Sendable (Int32, Switch, Bool) -> Bool? = AccessibilityEnabler.liveSet,
        reader: @escaping @Sendable (Int32, Switch) -> Bool? = AccessibilityEnabler.liveRead,
        electron: @escaping @Sendable (URL) -> Bool = AccessibilityEnabler.isElectron,
        launchDate: @escaping @Sendable (Int32) -> Date? = { NSRunningApplication(processIdentifier: $0)?.launchDate }
    ) {
        self.setter = setter
        self.reader = reader
        self.electron = electron
        self.launchDate = launchDate
        self.linger = linger
        self.now = now
    }

    static func kind(bundleID: String?, bundleURL: URL?, electron: (URL) -> Bool) -> Switch? {
        if let bundleID, chromium.contains(bundleID) { return .enhancedUI }
        if let bundleURL, electron(bundleURL) { return .manualAX }
        return nil
    }

    static func isElectron(_ bundle: URL) -> Bool {
        FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Frameworks/Electron Framework.framework").path)
    }

    /// An app became active: only a now-blocked app is acted on (its switch is put back).
    public func activated(pid: Int32, bundleID: String?, bundleURL: URL?, blocked: Bool) {
        guard blocked, pid != getpid() else { return }
        Self.queue.async { [self] in restore(pid: pid) }
    }

    /// A summon in the app in front: switched on for this summon and `linger` after it.
    public func summoned(pid: Int32, bundleID: String?, bundleURL: URL?, blocked: Bool) {
        guard pid != getpid() else { return }
        Self.queue.async { [self] in
            if blocked { restore(pid: pid); return }
            enable(pid: pid, bundleID: bundleID, bundleURL: bundleURL)
            Self.queue.asyncAfter(deadline: .now() + linger + 0.5) { [self] in expire() }
        }
    }

    /// Puts back every switch whose linger has passed.
    func expire() {
        let due = state.withLock { s in s.enabled.filter { $0.value.until <= now() }.map(\.key) }
        for pid in due { restore(pid: pid) }
    }

    /// On the serial queue (or in tests).
    func enable(pid: Int32, bundleID: String?, bundleURL: URL?) {
        let launched = launchDate(pid)
        let until = now().addingTimeInterval(linger)
        let fresh = state.withLock { s -> Bool in
            guard !s.closed else { return false }
            if var entry = s.enabled[pid], entry.launched == launched {
                entry.until = until // still on: the linger starts again
                s.enabled[pid] = entry
                return false
            }
            s.enabled[pid] = nil // a recycled pid: a different process
            return true
        }
        guard fresh, let kind = Self.kind(bundleID: bundleID, bundleURL: bundleURL, electron: electron),
              let before = setter(pid, kind, true)
        else { return }
        state.withLock { $0.enabled[pid] = Entry(kind: kind, bundleID: bundleID, launched: launched, before: before, until: until) }
    }

    /// Puts back the value we found, only if it's still the one we wrote (another tool, such as
    /// VoiceOver, may have taken it over since).
    func restore(pid: Int32) {
        guard let entry = state.withLock({ $0.enabled.removeValue(forKey: pid) }),
              launchDate(pid) == entry.launched, reader(pid, entry.kind) != false
        else { return }
        _ = setter(pid, entry.kind, entry.before)
    }

    /// Lumi is quitting: no switch stays on because of us, and none is set afterwards.
    public func restoreAll() {
        Self.queue.sync {
            state.withLock { $0.closed = true }
            for pid in state.withLock({ Array($0.enabled.keys) }) { restore(pid: pid) }
        }
    }

    var enabledPIDs: Set<Int32> { state.withLock { Set($0.enabled.keys) } }
    /// Tests: waits until everything queued so far has run.
    func drainForTests() { Self.queue.sync {} }

    /// Sets the switch; returns its previous value (false if unreadable), or nil if it was refused.
    /// Chrome answers "not implemented" to the write yet builds its tree, so that counts as set.
    static let liveSet: @Sendable (Int32, Switch, Bool) -> Bool? = { pid, kind, on in
        let before = liveRead(pid, kind) ?? false
        let result = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid), kind.rawValue as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
        return result == .success || result == .notImplemented ? before : nil
    }

    static let liveRead: @Sendable (Int32, Switch) -> Bool? = { pid, kind in
        AX.value(AXUIElementCreateApplication(pid), kind.rawValue) as? Bool
    }
}
