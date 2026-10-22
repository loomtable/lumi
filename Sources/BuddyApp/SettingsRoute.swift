import BuddyCompanion

/// Where a request for Settings goes. Settings stays out of reach until setup is finished: until
/// then every request (the menu, ⌘,, a reopen, a Fix chip, a `buddy://settings/…` link) brings
/// onboarding forward instead, so there is always a way back to it. Afterwards, Settings as asked.
public enum SettingsRoute: Sendable, Equatable {
    /// Settings, at this pane, or at the pane it last showed when nil.
    case settings(SettingsPane?)
    case onboarding

    public static func route(_ pane: SettingsPane?, needsSetUp: Bool) -> SettingsRoute {
        needsSetUp ? .onboarding : .settings(pane)
    }
}
