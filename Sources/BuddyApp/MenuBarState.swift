import BuddyBridge
import BuddyCompanion
import BuddyCore
import Foundation

/// What the menu bar icon shows: lit while the mic listens, pulsing while thinking
/// or researching, plain otherwise. Derived only from real coordinator phases and Research jobs.
public enum MenuBarActivity: Sendable, Equatable {
    case idle
    case listening
    case busy

    static func from(phase: BuddyCoordinator.Phase, researchRunning: Bool) -> MenuBarActivity {
        switch phase {
        case .listening: .listening
        case .thinking: .busy
        // A held recording means the mic has already stopped: nothing is being captured.
        case .idle, .held, .typing, .showing: researchRunning ? .busy : .idle
        }
    }
}

/// A line in the menu bar's problem list, with the Settings pane that fixes it.
public struct AppProblem: Sendable, Hashable, Identifiable {
    public let text: String
    /// Nil when no pane can fix it (e.g. the microphone stopped working).
    public let fix: SettingsPane?
    /// Clicking it quits and reopens the app (a grant macOS applies only to a new process).
    public let relaunches: Bool

    public var id: String { text }

    public init(text: String, fix: SettingsPane?, relaunches: Bool = false) {
        self.text = text
        self.fix = fix
        self.relaunches = relaunches
    }
}

/// What a click on the menu bar item does (a tucked answer folds into the
/// item, and the item brings it back). Right-click and ⌃-click always open the menu.
public enum StatusItemClick: Sendable, Equatable {
    case tuckAnswer
    case showLastAnswer
    case openMenu

    public static func action(secondary: Bool, answerShowing: Bool, answerKept: Bool) -> StatusItemClick {
        if secondary { return .openMenu }
        if answerShowing { return .tuckAnswer }
        return answerKept ? .showLastAnswer : .openMenu
    }
}

/// One row of the menu bar item's menu, built from the app's state each time it opens.
public struct StatusMenuItem: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case showLastAnswer, relaunch, openPane(SettingsPane), setUp, openSettings, togglePause,
             checkForUpdates, sendFeedback, quit
        /// The Lumi window at Home.
        case openStudio
        /// The Lumi window at Home, its composer ready to type (the Dock menu's New Session).
        case newSession
    }

    /// "Check for Updates…" opens this page in the browser; the app itself makes no network call.
    public static let releasesURL = URL(string: "https://github.com/loomtable/lumi/releases/latest")!
    /// Help › Lumi Website.
    public static let siteURL = URL(string: "https://lumi.loomtable.com")!

    /// Where "Send Feedback…" writes to (forwards to the company inbox). This is the one place to
    /// change it; it can later point to a web page instead of an email address.
    public static let feedbackAddress = "hello@loomtable.com"

    /// "Send Feedback…": a new email to `feedbackAddress` whose subject names the version and build,
    /// and whose body is an empty line and the macOS version. Nothing else: no logs, no screen
    /// content, no identifiers.
    public static func feedbackURL(version: String, build: String, macOS: String) -> URL {
        // Strict: only unreserved characters survive, so "&", "=", "+" and spaces can't break the query.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        let subject = "\(BuddyCore.appName) feedback (\(version), build \(build))"
        let body = "\nmacOS \(macOS)"
        return URL(string: "mailto:\(feedbackAddress)?subject=\(encode(subject))&body=\(encode(body))")!
    }

    /// The running app's `feedbackURL`, from the bundle's version and build and this Mac's macOS.
    public static func feedbackURL(bundle: Bundle = .main,
                                   os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> URL {
        let info = bundle.infoDictionary ?? [:]
        return feedbackURL(version: info["CFBundleShortVersionString"] as? String ?? "unknown",
                           build: info["CFBundleVersion"] as? String ?? "unknown", macOS: macOSVersion(os))
    }

    /// "26.0" or "26.0.1": the patch only when there is one, as About This Mac shows it.
    static func macOSVersion(_ os: OperatingSystemVersion) -> String {
        let base = "\(os.majorVersion).\(os.minorVersion)"
        return os.patchVersion == 0 ? base : "\(base).\(os.patchVersion)"
    }

    /// Nil: a separator.
    public let title: String?
    /// Nil: a line of text with no action (a problem no pane fixes).
    public let action: Action?
    public let enabled: Bool
    public let keyEquivalent: String
    public let checked: Bool

    public static let separator = StatusMenuItem(title: nil, action: nil)

    public init(title: String?, action: Action?, enabled: Bool = true, keyEquivalent: String = "", checked: Bool = false) {
        self.title = title
        self.action = action
        self.enabled = enabled
        self.keyEquivalent = keyEquivalent
        self.checked = checked
    }

    /// Show Last Answer first, then each problem as one true line (where a page fixes it, the
    /// line opens it), then setup or the Lumi window, the key, Pause, Check for Updates, Send
    /// Feedback and Quit. There is one Lumi window: "Open Lumi" opens it at Home, "Settings…" (⌘,)
    /// at Settings; history is its sidebar.
    /// The Dock icon's menu (shown with "Show in Dock" on): Open Lumi, New Session and Settings,
    /// or setup until it's finished.
    public static func dockMenu(needsSetUp: Bool) -> [StatusMenuItem] {
        if needsSetUp { return [StatusMenuItem(title: "Set Up \(BuddyCore.appName)…", action: .setUp)] }
        return [
            StatusMenuItem(title: "Open \(BuddyCore.appName)", action: .openStudio),
            StatusMenuItem(title: "New Session", action: .newSession),
            StatusMenuItem(title: "Settings…", action: .openSettings),
        ]
    }

    public static func menu(answerKept: Bool, problems: [AppProblem], needsSetUp: Bool, keyName: String,
                            paused: Bool) -> [StatusMenuItem] {
        let name = BuddyCore.appName
        var items = [StatusMenuItem(title: "Show Last Answer", action: .showLastAnswer, enabled: answerKept), .separator]
        for problem in problems {
            let action: Action? = problem.relaunches ? .relaunch : problem.fix.map { .openPane($0) }
            items.append(StatusMenuItem(title: problem.text, action: action, enabled: action != nil))
        }
        if !problems.isEmpty { items.append(.separator) }
        // Until setup is finished there's no Settings: setup takes its place (and ⌘,), so a
        // setup window closed before Done can always be reopened from here.
        if needsSetUp {
            items.append(StatusMenuItem(title: "Set Up \(name)…", action: .setUp, keyEquivalent: ","))
        } else {
            items.append(StatusMenuItem(title: "Open \(name)", action: .openStudio, keyEquivalent: "o"))
            items.append(StatusMenuItem(title: "Settings…", action: .openSettings, keyEquivalent: ","))
        }
        // the key can be changed any time from the menu bar (once Settings is there).
        if !needsSetUp { items.append(StatusMenuItem(title: "Lumi Key: \(keyName)…", action: .openPane(.keys))) }
        items += [
            StatusMenuItem(title: "Pause", action: .togglePause, checked: paused),
            .separator,
            StatusMenuItem(title: "Check for Updates…", action: .checkForUpdates),
            StatusMenuItem(title: "Send Feedback…", action: .sendFeedback),
            StatusMenuItem(title: "Quit \(name)", action: .quit, keyEquivalent: "q"),
        ]
        return items
    }
}

extension ResearchJob {
    /// Still working: the menu bar keeps pulsing.
    var isActive: Bool {
        switch state {
        case .queued, .running: true
        case .done, .failed, .cancelled: false
        }
    }
}
