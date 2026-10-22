import ApplicationServices
import CoreGraphics
import Foundation

/// Sticky Keys has no public API. The Accessibility settings pane writes `stickyKey` in the
/// `com.apple.universalaccess` domain; a missing key means off.
public enum StickyKeys {
    @Sendable public static func isEnabled() -> Bool {
        UserDefaults(suiteName: "com.apple.universalaccess")?.bool(forKey: "stickyKey") ?? false
    }
}

public struct KeyPermissions: Sendable, Equatable {
    /// Needed for the listen-only buddy key tap.
    public var inputMonitoring: Bool
    /// Needed for the active Esc tap (and AX elsewhere).
    public var accessibility: Bool

    public init(inputMonitoring: Bool, accessibility: Bool) {
        self.inputMonitoring = inputMonitoring
        self.accessibility = accessibility
    }

    /// Non-prompting checks. A listen-only `tapCreate` succeeds even without Input Monitoring
    /// (seen on macOS 26.6), so this, not tap creation, is the permission check.
    public static func current() -> KeyPermissions {
        KeyPermissions(inputMonitoring: CGPreflightListenEventAccess(), accessibility: AXIsProcessTrusted())
    }

    /// Shows the system's Input Monitoring prompt (once per app; afterwards the user must use
    /// System Settings). Returns the current state.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }
}
