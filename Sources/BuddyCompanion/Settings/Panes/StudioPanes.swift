import BuddyCore
import BuddyOverlay
import SwiftUI

/// Settings › Teammates: whether a session may start background helpers, and how many at once.
struct TeammatesPane: View {
    @Binding var settings: TeammatesPreferences

    var body: some View {
        PaneForm {
            Section {
                Picker("Teammates", selection: $settings.mode) {
                    Text("Off").tag(TeammatesMode.off)
                    Text("Ask first").tag(TeammatesMode.askFirst)
                    Text("Automatic").tag(TeammatesMode.automatic)
                }
                .pickerStyle(.segmented)
                Text(Self.help(settings.mode)).font(.callout).foregroundStyle(.secondary)
                Stepper(value: $settings.maxSubagents, in: SessionSettings.maxSubagentsRange) {
                    LabeledContent("At most", value: Self.count(settings.maxSubagents))
                }
                .disabled(settings.mode == .off)
            } footer: {
                Text("Each teammate is its own Claude Code session and uses its own tokens. To talk to one, write to the session: Lumi passes your words on.")
            }
        }
    }

    static func help(_ mode: TeammatesMode) -> String {
        switch mode {
        case .off: "Sessions do all their work themselves."
        case .askFirst: "When you ask by voice, Lumi proposes the split in one line and waits for your yes."
        case .automatic: "Sessions split big tasks on their own. You can stop the team at any time."
        }
    }

    static func count(_ n: Int) -> String { n == 1 ? "1 teammate" : "\(n) teammates" }
}

/// Settings › Notifications: the banner when you're away.
struct NotificationsPane: View {
    @Binding var notifications: NotificationsPreferences

    var body: some View {
        PaneForm {
            Section {
                Toggle(isOn: $notifications.notifyWhenAway) {
                    Text("Notify me when I'm away")
                    Text("One banner when a session that ran for a while finishes, and one reminder if it still needs you after 30 minutes.")
                }
            }
        }
    }
}

/// Settings › About: version, updates, licence and links.
struct AboutPane: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        PaneForm {
            Section {
                LabeledContent("Version", value: Self.version())
                Button("Check for Updates…") { openURL(Self.releasesURL) }
            }
            Section {
                LabeledContent("Licence", value: "GPL-3.0")
                Link("Source", destination: Self.sourceURL).buttonStyle(.lumiLink)
                Link("Site", destination: Self.siteURL).buttonStyle(.lumiLink)
            } footer: {
                Text("Lumi is made by Loomtable.")
            }
        }
    }

    static let releasesURL = URL(string: "https://github.com/loomtable/lumi/releases/latest")!
    static let sourceURL = URL(string: "https://github.com/loomtable/lumi")!
    static let siteURL = URL(string: "https://lumi.loomtable.com")!

    /// "1.4.0 (212)" from the bundle; "unknown" outside an app bundle.
    static func version(_ bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "unknown"
        guard let build = info["CFBundleVersion"] as? String else { return short }
        return "\(short) (\(build))"
    }
}
