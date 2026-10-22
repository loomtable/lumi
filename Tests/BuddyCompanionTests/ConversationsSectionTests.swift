import Foundation
import Testing
@testable import BuddyCompanion

@Suite("Settings › Conversations section")
@MainActor
struct ConversationsSectionTests {
    @Test("presets are within the stored ranges, and a non-preset stored value is still offered")
    func choices() {
        #expect(ConversationsSettingsSection.idleChoices.allSatisfy(ConversationsPreferences.idleRange.contains))
        #expect(ConversationsSettingsSection.retentionChoices.allSatisfy(ConversationsPreferences.retentionRange.contains))
        #expect(ConversationsSettingsSection.idleChoices.contains(ConversationsPreferences().idleTimeoutMinutes))
        #expect(ConversationsSettingsSection.retentionChoices.contains(ConversationsPreferences().retentionDays))
        #expect(ConversationsSettingsSection.choices([7, 30, 90], current: 45) == [7, 30, 45, 90])
        #expect(ConversationsSettingsSection.choices([7, 30, 90], current: 30) == [7, 30, 90])
        #expect(ConversationsSettingsSection.days(365) == "1 year")
    }
}

@Suite("Open Settings at a pane")
@MainActor
struct SettingsPaneOpenerTests {
    @Test("the shell's opener receives the pane; the default does nothing")
    func opens() {
        let seen = Box()
        let opener = SettingsPaneOpener { seen.pane = $0 }
        opener(.keys)
        #expect(seen.pane == .keys)
        SettingsPaneOpener()(.voice)   // no-op, no crash
    }
}

@MainActor
private final class Box { var pane: SettingsPane? }
