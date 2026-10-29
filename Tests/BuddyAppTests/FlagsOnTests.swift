@testable import BuddyApp
import BuddyBridge
import BuddyCompanion
import BuddyConversations
import BuddyCore
import BuddyKeys
import Foundation
import Testing

/// v2 ships with every flag on (owner, Oct 28); each `v2.<name>` set to false is a kill switch.
@MainActor
struct FlagsOnTests {
    @Test func theSwitcherKeyMapIsOnByDefaultAndOffWithItsKillSwitch() {
        let keys = BuddyKeyMonitor.Options()
        #expect(AppRuntime.keyOptions(keys, features: LumiFeatures()).gesture.switcher != nil)
        #expect(AppRuntime.keyOptions(keys, features: .allOff).gesture.switcher == nil, "v1 parity")
        var noSwitcher = LumiFeatures()
        noSwitcher.switcher = false
        #expect(AppRuntime.keyOptions(keys, features: noSwitcher).gesture.switcher == nil)
    }

    /// V-08: the "N waiting" hint names the strip's next key for the current buddy key.
    @Test func theSwitchersNextKeyFollowsTheBuddyKey() {
        #expect(AppRuntime.switcherNextKeyName(.rightOption) == "Tab")
        #expect(AppRuntime.switcherNextKeyName(.rightCommand) == "`")
        #expect(AppRuntime.switcherNextKeyName(.leftCommand) == "`")
    }

    @Test func theDictationKeyReachesTheMonitorByDefault() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: NSTemporaryDirectory() + "flags-\(UUID().uuidString)")!)
        let on = EnginePreferences(store: store, features: LumiFeatures())
        #expect(on.keys.dictationKey != nil && on.keys.dictationKey == on.dictationKey)
        #expect(EnginePreferences(store: store, features: .allOff).keys.dictationKey == nil)
    }

    /// Studio's inspector and teammate lanes read the open Claude session: reading never mints one
    /// and never makes the session current (found while turning everything on).
    @Test func readingTheOpenClaudeSessionHasNoSideEffects() async throws {
        let h = try LiveSessionsTests.Harness()
        let now = Date()
        func ask(_ text: String) async -> SessionTurnPlan {
            await h.sessions.plan(SummonInput(source: .textBox, kind: .typed, command: .newSession, now: now),
                                  packet: ContextPacket(askedAt: now, utterance: text))
        }
        let first = await ask("trip to lisbon")
        let second = await ask("budget")
        #expect(h.sessions.current == second.id)
        #expect(await h.sessions.openClaudeSession(of: first.id) == nil, "minted but not acknowledged: none yet")
        h.sessions.apply(.initialized(InitSummary()), to: first.id)
        let deadline = ContinuousClock.now + waitCeiling
        while await h.sessions.openClaudeSession(of: first.id) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await h.sessions.openClaudeSession(of: first.id)?.id == first.launch?.claudeSession)
        #expect(h.sessions.current == second.id, "reading didn't make it current")
        #expect(await h.sessions.openClaudeSession(of: SessionID(rawValue: "s_none")) == nil)
    }
}
