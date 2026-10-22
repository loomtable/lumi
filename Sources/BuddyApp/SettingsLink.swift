import AppKit
import BuddyCompanion
import Foundation

/// Opens a URL outside the app (System Settings for a settings link). Real: NSWorkspace.
@MainActor
public protocol OpenURLPort: AnyObject {
    func open(_ url: URL)
}

@MainActor
public final class LiveOpenURL: OpenURLPort {
    public init() {}
    public func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// An action that opens a System Settings privacy pane directly (no model turn, no shell):
/// `buddy://settings/<pane>`. Only these exact links are honoured; anything else is an ordinary
/// action prompt.
@MainActor
public enum SettingsLink {
    public static let scheme = "buddy"

    /// The System Settings page for `prompt`, or nil when it isn't a settings link.
    public static func url(for prompt: String) -> URL? {
        guard let kind = kind(for: prompt) else { return nil }
        return kind.settingsURL
    }

    /// Exactly one of the four links (surrounding whitespace aside): nothing to parse, nothing to
    /// get creative with.
    static func kind(for prompt: String) -> PermissionKind? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return PermissionKind.allCases.first { link(for: $0) == trimmed }
    }

    /// The link for `kind`, as the skill writes it.
    public static func link(for kind: PermissionKind) -> String {
        let pane = switch kind {
        case .screenRecording: "screen-recording"
        case .accessibility: "accessibility"
        case .inputMonitoring: "input-monitoring"
        case .microphone: "microphone"
        }
        return "\(scheme)://settings/\(pane)"
    }
}
