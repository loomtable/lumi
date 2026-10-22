import SwiftUI

/// Settings › Conversations: composes two parts from separate modules, so neither edits
/// the other's file.
struct ConversationsPane: View {
    @Binding var settings: ConversationsPreferences

    var body: some View {
        Form {
            ConversationsSettingsSection(settings: $settings)
            ConversationHistoryView()
        }
        .formStyle(.grouped)
    }
}
