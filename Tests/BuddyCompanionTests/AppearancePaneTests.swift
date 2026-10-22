import Foundation
import Testing
@testable import BuddyCompanion

@Suite("Settings › Appearance")
@MainActor
struct AppearancePaneTests {
    private func decode(_ json: String) throws -> AppearancePreferences {
        try JSONDecoder().decode(AppearancePreferences.self, from: Data(json.utf8))
    }

    @Test("An unknown placement falls back to Smart and keeps the other fields")
    func unknownPlacement() throws {
        let a = try decode(#"{"placement": "floating", "inkIn": false}"#)
        #expect(a.placement == .smart)
        #expect(!a.inkIn)
        #expect(a.speakingGlow && a.dotField && a.sounds)
    }

    @Test("Placement raw values stay smart, nextToIt, centre (stored, and mapped onto Placer.Mode by name)")
    func placementRawValues() {
        #expect(AppearancePreferences.Placement.allCases.map(\.rawValue) == ["smart", "nextToIt", "centre"])
    }

    @Test("Each placement has its own title and help; only Smart mentions moving clear of content")
    func placementCopy() {
        let all = AppearancePreferences.Placement.allCases
        #expect(all.map(AppearancePane.title) == ["Smart", "Next to it", "Centre"])
        #expect(Set(all.map(AppearancePane.placementHelp)).count == all.count)
        for p in all {
            #expect(AppearancePane.placementHelp(p).contains("busy content") == (p == .smart))
        }
    }

    @Test("Changing a toggle through the store persists it; restoring defaults clears it")
    func persistAndRestore() {
        let defaults = TestDefaults().defaults
        let store = SettingsStore(defaults: defaults)
        store.appearance.dotField = false
        store.appearance.placement = .centre
        let reloaded = SettingsStore(defaults: defaults)
        #expect(!reloaded.appearance.dotField)
        #expect(reloaded.appearance.placement == .centre)
        reloaded.appearance = AppearancePreferences()
        #expect(SettingsStore(defaults: defaults).appearance == AppearancePreferences())
    }
}

@Suite("Settings › Appearance › Answer actions")
@MainActor
struct AnswerActionsTests {
    @Test("both toggles decode leniently: missing means on, and an off survives a round trip")
    func decode() throws {
        let old = try JSONDecoder().decode(AppearancePreferences.self, from: Data(#"{"placement":"centre"}"#.utf8))
        #expect(old.showRings && old.insertAndReplace && old.placement == .centre)
        var off = AppearancePreferences(); off.showRings = false; off.insertAndReplace = false
        let back = try JSONDecoder().decode(AppearancePreferences.self, from: JSONEncoder().encode(off))
        #expect(!back.showRings && !back.insertAndReplace)
    }
}
