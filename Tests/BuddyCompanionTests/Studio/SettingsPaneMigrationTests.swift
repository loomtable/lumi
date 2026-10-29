import BuddyCore
import BuddyKeys
import Foundation
import Testing
@testable import BuddyCompanion

/// Studio's eleven Settings pages over the old eight panes: same stored keys, old deep links land
/// on the page that now holds them, and every stored section has a page.
@Suite("Settings pane migration")
@MainActor
struct SettingsPaneMigrationTests {
    let defaults = UserDefaults(suiteName: NSTemporaryDirectory() + "pane-migration-\(UUID().uuidString)")!

    /// The UserDefaults keys today's builds wrote. They must never change.
    static let storedKeys = [
        "settings.keys.v1", "settings.privacy.v1", "settings.conversations.v1", "settings.voice.v1",
        "settings.appearance.v1", "settings.models.v1", "settings.connections.v1", "settings.sessions.v1",
        "settings.notifications.v1", "settings.teammates.v1", "settings.dictation.v1", "settings.dock.v1",
    ]

    @Test func storedKeysAreUnchanged() {
        let keys = [
            KeysPreferences.storageKey, PrivacyPreferences.storageKey, ConversationsPreferences.storageKey,
            VoicePreferences.storageKey, AppearancePreferences.storageKey, ModelPreferences.storageKey,
            ConnectionsPreferences.storageKey, SessionsPreferences.storageKey, NotificationsPreferences.storageKey,
            TeammatesPreferences.storageKey, DictationPreferences.storageKey, DockPreferences.storageKey,
        ]
        #expect(keys == Self.storedKeys)
    }

    @Test func aValueSavedByTheOldWindowIsReadAndWrittenUnderTheSameKey() throws {
        var old = KeysPreferences()
        old.holdThresholdMs = 420
        defaults.set(try JSONEncoder().encode(old), forKey: "settings.keys.v1")
        let store = SettingsStore(defaults: defaults)
        #expect(store.keys.holdThresholdMs == 420)
        store.teammates.maxSubagents = 5
        store.dictation.enabled = false
        let saved = Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("settings.") && $0.hasSuffix(".v1") })
        #expect(saved.isSubset(of: Set(Self.storedKeys)))
        #expect(saved.isSuperset(of: ["settings.keys.v1", "settings.teammates.v1", "settings.dictation.v1"]))
    }

    @Test func elevenPagesInOrder() {
        #expect(SettingsPage.allCases.map(\.title) == [
            "General", "Voice", "Model for voice answers", "Claude Code", "Connections", "Teammates", "Privacy", "Permissions",
            "Appearance", "Notifications", "About",
        ])
        #expect(Set(SettingsPage.allCases.map(\.systemImage)).count == 11)
        #expect(SettingsPage.allCases.allSatisfy { !$0.summary.isEmpty })
    }

    @Test(arguments: [
        (SettingsPane.keys, SettingsPage.general), (.models, .model), (.voice, .voice), (.appearance, .appearance),
        (.conversations, .privacy), (.connections, .connections), (.privacy, .permissions), (.claudeCode, .claudeCode),
    ])
    func oldPaneOpensItsNewPage(pane: SettingsPane, page: SettingsPage) {
        #expect(SettingsPage(pane) == page)
    }

    @Test func everyOldPaneHasAPage() {
        #expect(SettingsPane.allCases.count == 8)
        for pane in SettingsPane.allCases { _ = SettingsPage(pane) }
    }

    @Test func everyStoredSectionIsOnAPage() {
        let shown = Set(SettingsPage.allCases.flatMap(\.storageKeys))
        #expect(shown == Set(Self.storedKeys))
    }

    @Test func aStudioRelaunchComesBackToItsPage() {
        var relaunched = 0
        let center = PermissionCenter(permissions: FakePermissions(), launchedByLaunchServices: true, defaults: defaults,
                                      relaunch: { relaunched += 1 })
        center.relaunch(resume: .page(.permissions))
        #expect(relaunched == 1)
        #expect(PermissionCenter.takeSettingsPageResume(defaults: defaults) == .permissions)
        #expect(PermissionCenter.takeSettingsPageResume(defaults: defaults) == nil, "read once")
    }

    /// A resume stored by a build before Studio (the old pane's raw value) opens its page.
    @Test func anOldWindowResumeOpensTheMappedPage() {
        defaults.set(SettingsPane.privacy.rawValue, forKey: PermissionCenter.settingsResumeKey)
        #expect(PermissionCenter.takeSettingsPageResume(defaults: defaults) == .permissions)
    }

    @Test func resumeValuesNeverReadAsAnOldPane() {
        for page in SettingsPage.allCases {
            #expect(SettingsPane(rawValue: page.resumeValue) == nil)
            #expect(SettingsPage(resumeValue: page.resumeValue) == page)
        }
        #expect(SettingsPage(resumeValue: "page:nope") == nil)
        #expect(SettingsPage(resumeValue: "nope") == nil)
    }

    @Test func dictationPickerOffersAutoOffAndEveryKey() {
        #expect(Array(DictationKeySection.choices.prefix(2)) == [.auto, .off])
        #expect(DictationKeySection.choices.count == 2 + BuddyKey.allCases.count)
        #expect(DictationKeySection.title(.auto) == "Auto")
        #expect(DictationKeySection.title(.key(.rightCommand)) == BuddyKey.rightCommand.settingsName)
        // The line under the picker: which key Auto picked and why, or why there is none.
        var d = DictationPreferences()
        #expect(d.resolved(buddyKey: .rightOption, in: KeyEnvironment(globeKeyUsage: 0)).reason.hasPrefix("Auto: fn"))
        d.choice = .key(.rightOption)
        #expect(d.resolved(buddyKey: .rightOption, in: KeyEnvironment()).reason.contains("Lumi key"))
    }

    @Test func teammatesCopy() {
        #expect(TeammatesPane.count(1) == "1 teammate")
        #expect(TeammatesPane.count(3) == "3 teammates")
        #expect(TeammatesMode.allCases.allSatisfy { !TeammatesPane.help($0).isEmpty })
    }
}
