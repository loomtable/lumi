import AppKit

enum RunningApp {
    static func bundleID(_ pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
