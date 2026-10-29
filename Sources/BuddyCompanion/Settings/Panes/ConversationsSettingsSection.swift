import SwiftUI

/// Settings › Privacy's sessions part: idle limit, retention, temporary mode. The engine applies
/// each change at once (a shorter retention prunes; temporary mode switches the index).
struct ConversationsSettingsSection: View {
    @Binding var settings: ConversationsPreferences

    var body: some View {
        Section {
            Picker("Start a new session after", selection: $settings.idleTimeoutMinutes) {
                ForEach(Self.choices(Self.idleChoices, current: settings.idleTimeoutMinutes), id: \.self) {
                    Text("\($0) min idle").tag($0)
                }
            }
            Picker("Keep sessions for", selection: $settings.retentionDays) {
                ForEach(Self.choices(Self.retentionChoices, current: settings.retentionDays), id: \.self) {
                    Text(Self.days($0)).tag($0)
                }
            }
            Toggle(isOn: $settings.temporaryMode) {
                Text("Temporary mode")
                Text("Save nothing: sessions and dictations live in memory and are deleted when you turn this off.")
            }
        } footer: {
            Text("Sessions unused for longer than “Keep sessions for” are removed from this Mac, and so are older dictations.")
        }
    }

    static let idleChoices = [5, 15, 30, 60, 120, 240]
    static let retentionChoices = [7, 30, 90, 180, 365]

    /// The presets, plus the stored value if it isn't one of them, so the picker always shows it.
    static func choices(_ presets: [Int], current: Int) -> [Int] {
        presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    static func days(_ n: Int) -> String {
        switch n {
        case 365: "1 year"
        case 1: "1 day"
        default: "\(n) days"
        }
    }
}
