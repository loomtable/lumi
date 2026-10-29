import AppKit
import BuddyCore

/// The icon of the app a session came from (03 §4.2's origin badge), cached per bundle ID. Nil when
/// the session has no origin or the app isn't on this Mac.
enum OriginIcon {
    private static var cache: [String: NSImage?] = [:]

    static func image(_ origin: SessionOrigin?) -> NSImage? {
        guard let bundleID = origin?.key.bundleID, !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = icon
        return icon
    }
}
