/// Shared value types and contracts used by every Lumi module.
///
/// Rules for this module: no UI, no system side effects, no dependencies. Every target
/// depends on it, so change it with care.
public enum BuddyCore {
    public static let appName = "Lumi"
    public static let bundleIdentifier = "com.loomtable.lumi"
    /// The app's own folder under Application Support, Caches and Logs: the bundle ID.
    public static let folderName = bundleIdentifier
}
