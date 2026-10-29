import BuddyCompanion

/// The app's windows: the Lumi window (Studio, with Settings in its sidebar) and onboarding.
/// There are no others: the v1 Conversations and Settings windows are gone (owner, Oct 28), and
/// history lives in Studio's sidebar.
public enum LumiWindow: String, CaseIterable, Sendable {
    case studio, onboarding

    /// The SwiftUI window ID.
    public var id: String { rawValue }

    /// What opens at launch: onboarding until setup is finished, else nothing (Lumi lives in the
    /// menu bar, and the Lumi window opens when asked).
    public static func atLaunch(needsOnboarding: Bool) -> [LumiWindow] { needsOnboarding ? [.onboarding] : [] }

    /// A click on the Dock icon, or opening Lumi again from Spotlight or Finder: the Lumi window
    /// (onboarding until setup is finished), whatever else is on screen.
    public static func onReopen(needsSetUp: Bool) -> LumiWindow { needsSetUp ? .onboarding : .studio }

    /// Onboarding's Done closes onboarding and opens nothing.
    public static let afterOnboarding: [LumiWindow] = []

    /// The window a menu bar row opens; nil when it opens none. Until setup is finished, anything
    /// that would open the Lumi window brings onboarding forward instead (`SettingsRoute`).
    public static func opened(by action: StatusMenuItem.Action, needsSetUp: Bool) -> LumiWindow? {
        switch action {
        case .openPane, .openSettings, .openStudio, .newSession: needsSetUp ? .onboarding : .studio
        case .setUp: .onboarding
        case .showLastAnswer, .relaunch, .togglePause, .checkForUpdates, .sendFeedback, .quit: nil
        }
    }
}
