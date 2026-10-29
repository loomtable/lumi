import Foundation
import Testing
@testable import BuddyCore

struct LumiFeaturesTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: NSTemporaryDirectory() + "features-\(UUID().uuidString)")!
    }

    private func flags(_ f: LumiFeatures) -> [String: Bool] {
        ["sessions": f.sessions, "switcher": f.switcher, "panel": f.panel,
         "dictation": f.dictation, "permissionHost": f.permissionHost]
    }

    /// Teammates follow Settings › Teammates; nothing read a v2.teammates flag, so it's gone.
    @Test func teammatesHaveNoKillSwitch() {
        #expect(!LumiFeatures.names.contains("teammates"))
        let d = defaults()
        d.set(false, forKey: "v2.teammates")
        #expect(LumiFeatures(defaults: d) == LumiFeatures(), "a leftover v2.teammates key changes nothing")
    }

    /// Studio is the app's only window, so it has no kill switch (owner, Oct 28).
    @Test func studioHasNoKillSwitch() {
        #expect(!LumiFeatures.names.contains("studio"))
        let d = defaults()
        d.set(false, forKey: "v2.studio")
        #expect(LumiFeatures(defaults: d) == LumiFeatures(), "a leftover v2.studio key changes nothing")
    }

    @Test func everythingIsOnByDefault() {
        #expect(LumiFeatures(defaults: defaults()) == LumiFeatures())
        #expect(flags(LumiFeatures()).values.allSatisfy { $0 })
        #expect(flags(.allOff).values.allSatisfy { !$0 })
    }

    @Test func eachKeySetToFalseTurnsOnlyItsFeatureOff() {
        for name in LumiFeatures.names {
            let d = defaults()
            d.set(false, forKey: "v2.\(name)")
            #expect(flags(LumiFeatures(defaults: d)).filter { !$0.value }.map(\.key) == [name])
        }
    }

    @Test func aKeySetToTrueStaysOn() {
        let d = defaults()
        for name in LumiFeatures.names { d.set(true, forKey: "v2.\(name)") }
        #expect(LumiFeatures(defaults: d) == LumiFeatures())
    }
}
