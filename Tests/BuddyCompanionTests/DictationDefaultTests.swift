import BuddyKeys
import Foundation
import Testing
@testable import BuddyCompanion

/// The dictation key's "Auto" default and conflict resolution (owner decision, Oct 28).
@Suite("Dictation key default")
struct DictationDefaultTests {
    nonisolated static let doNothing = KeyEnvironment(globeKeyUsage: 0)
    nonisolated static let emoji = KeyEnvironment(globeKeyUsage: 2)
    nonisolated static let unsetGlobe = KeyEnvironment(globeKeyUsage: nil)  // the macOS default is not Do Nothing
    /// Other dictation apps aren't detected (owner, Oct 29): Auto still picks fn.
    nonisolated static let otherApp = KeyEnvironment(installedBundleIDs: ["com.example.dictation"], globeKeyUsage: 0)
    nonisolated static let siri = KeyEnvironment(globeKeyUsage: 2, siriEnabled: true, dictationEnabled: true)
    nonisolated static let gemini = KeyEnvironment(installedBundleIDs: ["com.google.GeminiMacOS"], globeKeyUsage: 0)

    nonisolated struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let choice: DictationKeyChoice
        let buddy: BuddyKey
        let env: KeyEnvironment
        let expected: BuddyKey?
        var testDescription: String { name }
    }

    nonisolated static let rows: [Row] = [
        // Auto
        Row(name: "auto, 🌐 does nothing → fn", choice: .auto, buddy: .rightOption, env: doNothing, expected: .function),
        Row(name: "auto, 🌐 shows emoji → right ⌘", choice: .auto, buddy: .rightOption, env: emoji, expected: .rightCommand),
        Row(name: "auto, 🌐 never set → right ⌘", choice: .auto, buddy: .rightOption, env: unsetGlobe, expected: .rightCommand),
        Row(name: "auto, fn is the buddy key → right ⌘", choice: .auto, buddy: .function, env: doNothing, expected: .rightCommand),
        Row(name: "auto, another dictation app installed → still fn", choice: .auto, buddy: .rightOption, env: otherApp, expected: .function),
        Row(name: "auto, Siri and Dictation on don't block right ⌘", choice: .auto, buddy: .rightOption, env: siri, expected: .rightCommand),
        Row(name: "auto, buddy right ⌘, 🌐 does nothing → fn", choice: .auto, buddy: .rightCommand, env: doNothing, expected: .function),
        Row(name: "auto, buddy right ⌘, 🌐 in use → none", choice: .auto, buddy: .rightCommand, env: emoji, expected: nil),
        Row(name: "auto, buddy left ⌘ → right ⌘", choice: .auto, buddy: .leftCommand, env: emoji, expected: .rightCommand),
        // Off
        Row(name: "off", choice: .off, buddy: .rightOption, env: doNothing, expected: nil),
        // Explicit keys
        Row(name: "right ⌘ picked", choice: .key(.rightCommand), buddy: .rightOption, env: doNothing, expected: .rightCommand),
        Row(name: "right ⌘ picked with Siri on (double press only)", choice: .key(.rightCommand), buddy: .rightOption, env: siri, expected: .rightCommand),
        Row(name: "right ⌘ picked with Gemini (double press only)", choice: .key(.rightCommand), buddy: .rightOption, env: gemini, expected: .rightCommand),
        Row(name: "picked key equals the buddy key", choice: .key(.rightOption), buddy: .rightOption, env: doNothing, expected: nil),
        Row(name: "fn picked, 🌐 in use", choice: .key(.function), buddy: .rightOption, env: emoji, expected: nil),
        Row(name: "fn picked, another dictation app installed", choice: .key(.function), buddy: .rightOption, env: otherApp, expected: .function),
        Row(name: "fn picked, 🌐 does nothing", choice: .key(.function), buddy: .rightOption, env: doNothing, expected: .function),
        Row(name: "right ⌥ picked with Claude's Quick Entry (double tap only)", choice: .key(.rightOption), buddy: .rightCommand,
            env: KeyEnvironment(installedBundleIDs: ["com.anthropic.claudefordesktop"]), expected: .rightOption),
        Row(name: "left ⇧ picked (stray-tap warnings don't apply to a hold)", choice: .key(.leftShift), buddy: .rightOption, env: doNothing, expected: .leftShift),
    ]

    @Test("resolution", arguments: rows)
    func resolution(row: Row) {
        let r = DictationKeyResolver.resolve(row.choice, buddyKey: row.buddy, in: row.env)
        #expect(r.key == row.expected)
        #expect(!r.reason.isEmpty)
    }

    @Test("Settings says which key Auto picked and why")
    func reasons() {
        #expect(DictationKeyResolver.resolve(.auto, buddyKey: .rightOption, in: Self.doNothing).reason
            == "Auto: fn, because the 🌐 key is set to Do Nothing. If another app also uses fn, pick another key here.")
        #expect(DictationKeyResolver.resolve(.auto, buddyKey: .function, in: Self.doNothing).reason
            == "Auto: right ⌘, because fn is your Lumi key.")
        #expect(DictationKeyResolver.resolve(.auto, buddyKey: .rightOption, in: Self.emoji).reason
            == "Auto: right ⌘, because the 🌐 key has a macOS action (set it to Do Nothing to use fn).")
        #expect(DictationKeyResolver.resolve(.key(.rightOption), buddyKey: .rightOption, in: Self.doNothing).reason
            == "Off: right ⌥ is already your Lumi key.")
        #expect(DictationKeyResolver.resolve(.key(.function), buddyKey: .rightOption, in: Self.emoji).reason.hasPrefix("Off. Set Keyboard"))
    }

    @Test("every hold-safe id exists in KeyConflicts")
    func holdSafeIDs() {
        let all = KeyEnvironment(
            installedBundleIDs: Set(KeyEnvironment.watchedApps.keys), globeKeyUsage: 2, stickyKeys: true,
            siriEnabled: true, dictationEnabled: true)
        let ids = Set(BuddyKey.allCases.flatMap { KeyConflicts.check($0, in: all).map(\.id) })
        #expect(DictationKeyResolver.holdSafe.isSubset(of: ids))
    }

    @Test("the help line follows the mode, and says a chord key still works in shortcuts (QA R14)")
    func help() {
        #expect(DictationKeySection.help(for: .function).hasPrefix("Tap fn to start, and tap it again to type."))
        #expect(DictationKeySection.help(for: .function, mode: .hold).hasPrefix("Hold fn and speak, then let go to type."))
        let cmd = DictationKeySection.help(for: .rightCommand)
        #expect(cmd.hasPrefix("Tap right ⌘ to start"))
        #expect(cmd.hasSuffix("Pressed with another key, right ⌘ works as usual."))
        #expect(!DictationKeySection.help(for: .function).contains("Pressed with another key"))
        #expect(DictationKeySection.help(for: nil).hasPrefix("Tap the dictation key"))
        #expect(DictationKeySection.help(for: .function).contains("Dictation history"))
    }

    @Test("the mode defaults to tap to toggle, survives a round trip, and an unknown value reads as the default")
    func mode() throws {
        #expect(DictationPreferences().mode == .toggle)
        var prefs = DictationPreferences()
        prefs.mode = .hold
        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(DictationPreferences.self, from: data).mode == .hold)
        let old = try JSONDecoder().decode(DictationPreferences.self, from: Data(#"{"enabled":true,"dictationKey":"auto"}"#.utf8))
        #expect(old.mode == .toggle)
        let odd = try JSONDecoder().decode(DictationPreferences.self, from: Data(#"{"mode":"shout"}"#.utf8))
        #expect(odd.mode == .toggle)
        #expect(DictationKeySection.title(DictationMode.toggle) == "Tap to start and stop")
        #expect(DictationKeySection.title(DictationMode.hold) == "Hold to talk")
    }

    @Test("the key environment is read at most once per max age, and again after invalidate (QA R15)")
    func environmentCache() {
        var reads = 0
        var time = ContinuousClock.now
        let start = time
        let cache = KeyEnvironmentCache(
            maxAge: .seconds(30), read: { reads += 1; return KeyEnvironment(globeKeyUsage: reads) }, now: { time })
        #expect(cache.current().globeKeyUsage == 1)
        time = start + .seconds(10)
        #expect(cache.current().globeKeyUsage == 1)
        #expect(reads == 1)
        time = start + .seconds(31)
        #expect(cache.current().globeKeyUsage == 2)
        cache.invalidate()
        #expect(cache.current().globeKeyUsage == 3)
    }
}
