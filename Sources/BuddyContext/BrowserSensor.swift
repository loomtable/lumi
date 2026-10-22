import ApplicationServices
import BuddyCore
import CoreServices
import Foundation
import Synchronization

public protocol BrowserSensor: Sendable {
    /// URL, host and tab title of the browser's front tab. Without Automation consent (or for
    /// browsers with no scripting, like Firefox), only the tab title from the window.
    func browser(app: FrontApp) -> ContextPacket.Browser?
}

/// Whether we may send Apple events to an app (System Settings › Privacy › Automation).
public enum AutomationConsent: Sendable, Equatable {
    case granted
    case denied
    /// Never asked. Reading now would show the system dialog, so the sensor doesn't.
    case notAsked
    case unavailable(OSStatus)

    /// Checks without ever prompting. The check costs 20–50 ms (measured), so answers are cached
    /// per process for a minute. `request` clears the cache, so a grant made in onboarding applies
    /// at once; one made by hand in System Settings applies within a minute.
    public static func check(pid: Int32, now: ContinuousClock.Instant = .now) -> AutomationConsent {
        if let hit = cache.withLock({ $0[pid] }), now - hit.at < .seconds(60) { return hit.consent }
        let consent = status(pid: pid, ask: false)
        if case .unavailable = consent {} else {
            cache.withLock { $0[pid] = (consent, now) }
        }
        return consent
    }

    private static let cache = Mutex<[Int32: (consent: AutomationConsent, at: ContinuousClock.Instant)]>([:])

    /// Shows the system consent dialog if needed and waits for the answer. Onboarding only, and
    /// never on the main thread.
    public static func request(pid: Int32) -> AutomationConsent {
        let consent = status(pid: pid, ask: true)
        cache.withLock { $0[pid] = nil }
        return consent
    }

    static func status(pid: Int32, ask: Bool) -> AutomationConsent {
        guard var target = NSAppleEventDescriptor(processIdentifier: pid).aeDesc?.pointee else {
            return .unavailable(OSStatus(procNotFound))
        }
        // The same class and ID the sensor sends (core suite 'getd').
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .unavailable(status)
        }
    }
}

public struct AppleEventBrowserSensor: BrowserSensor {
    /// Reply timeout for the URL request. Within the packet budget; a busy browser gives nil.
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 0.12) {
        self.timeout = timeout
    }

    public func browser(app: FrontApp) -> ContextPacket.Browser? {
        // No URL (no consent yet, or no scripting): nil. The tab title still reaches the packet
        // as window.title, which is the fallback.
        guard let path = BrowserScripting.path(for: app.bundle),
              AutomationConsent.check(pid: app.pid) == .granted,
              let url = BrowserScripting.frontTabURL(pid: app.pid, path: path, timeout: timeout)
        else { return nil }
        // tab_title is filled by the builder from the window sensor, which is already running.
        let clean = Redact.url(url)
        return ContextPacket.Browser(url: clean, host: URLComponents(string: clean)?.host)
    }
}

/// Apple-event object paths to the front tab's URL, from each browser's scripting dictionary
/// (Chrome: scripting.sdef; Safari: Safari.sdef). Chromium browsers share Chrome's.
enum BrowserScripting {
    struct Path: Equatable {
        /// Property of the window that is the front tab ('acTa' Chrome, 'cTab' Safari).
        let tab: FourCharCode
        /// URL property of the tab ('URL ' Chrome, 'pURL' Safari).
        let url: FourCharCode
    }

    static let chromium = Path(tab: fourCC("acTa"), url: fourCC("URL "))
    static let safari = Path(tab: fourCC("cTab"), url: fourCC("pURL"))

    static func path(for bundle: String?) -> Path? {
        switch bundle {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview": safari
        case "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
             "com.vivaldi.Vivaldi", "company.thebrowser.Browser":
            chromium
        default: nil
        }
    }

    /// Sends `get URL of <tab> of window 1` to the running process `pid` (never launches it).
    static func frontTabURL(pid: Int32, path: Path, timeout: TimeInterval) -> String? {
        let window = specifier(want: fourCC("cwin"), form: fourCC("indx"),
                               data: NSAppleEventDescriptor(int32: 1), from: NSAppleEventDescriptor.null())
        let tab = property(path.tab, of: window)
        let url = property(path.url, of: tab)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(url, forKeyword: keyDirectObject)
        guard let reply = try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout) else {
            return nil
        }
        let value = reply.paramDescriptor(forKeyword: keyDirectObject)?.stringValue
        return value?.isEmpty == false ? value : nil
    }

    static func property(_ code: FourCharCode, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: fourCC("prop"), form: fourCC("prop"), data: NSAppleEventDescriptor(typeCode: code), from: container)
    }

    static func specifier(
        want: FourCharCode, form: FourCharCode, data: NSAppleEventDescriptor, from: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: fourCC("obj "))!
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: fourCC("want"))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: fourCC("form"))
        spec.setDescriptor(data, forKeyword: fourCC("seld"))
        spec.setDescriptor(from, forKeyword: fourCC("from"))
        return spec
    }

    static func fourCC(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}
