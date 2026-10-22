import AppKit
import BuddyContext
import BuddyKeys
import Foundation
import Testing
@testable import BuddyCompanion

@Suite("Key conflicts")
struct KeyConflictTests {
    func ids(_ key: BuddyKey, _ env: KeyEnvironment = KeyEnvironment()) -> Set<String> {
        Set(KeyConflicts.check(key, in: env).map(\.id))
    }

    @Test("right ⌥ with nothing installed: only the reassuring typing note")
    func clean() {
        #expect(ids(.rightOption) == ["option-typing"])
        #expect(KeyConflicts.check(.rightOption, in: KeyEnvironment()).allSatisfy { $0.severity == .info })
    }

    @Test("Claude Desktop installed warns for either ⌥, not for Fn")
    func claude() {
        let env = KeyEnvironment(installedBundleIDs: ["com.anthropic.claudefordesktop"])
        #expect(ids(.rightOption, env).contains("claude-quick-entry"))
        #expect(ids(.leftOption, env).contains("claude-quick-entry"))
        #expect(!ids(.function, env).contains("claude-quick-entry"))
    }

    @Test("⌘ keys warn about Siri/Dictation only when they're on, and about Gemini when installed")
    func command() {
        #expect(!ids(.rightCommand).contains("siri-dictation"))
        let siri = KeyConflicts.check(.rightCommand, in: KeyEnvironment(siriEnabled: true))
        #expect(siri.first { $0.id == "siri-dictation" }?.message.hasPrefix("Siri can") == true)
        #expect(ids(.rightCommand, KeyEnvironment(dictationEnabled: true)).contains("siri-dictation"))
        #expect(ids(.rightCommand, KeyEnvironment(installedBundleIDs: ["com.google.GeminiMacOS"])).contains("gemini"))
        #expect(!ids(.rightOption, KeyEnvironment(siriEnabled: true)).contains("siri-dictation"))
        #expect(ids(.leftCommand).contains("left-modifier"))
    }

    @Test("Fn: Globe setting not Do Nothing gives a fix; Do Nothing doesn't; Wispr Flow conflicts")
    func fn() {
        let notSet = KeyConflicts.check(.function, in: KeyEnvironment(globeKeyUsage: 2))
        #expect(notSet.first { $0.id == "globe-key" }?.fix == .openKeyboardSettings)
        #expect(!ids(.function, KeyEnvironment(globeKeyUsage: 0)).contains("globe-key"))
        // Unset is the macOS default (not "Do Nothing"), so it warns too.
        #expect(ids(.function, KeyEnvironment(globeKeyUsage: nil)).contains("globe-key"))
        #expect(ids(.function, KeyEnvironment(installedBundleIDs: ["com.electron.wispr-flow"])).contains("wispr-flow"))
        #expect(ids(.function).contains("fn-keyboards"))
    }

    @Test("shift and left-hand keys warn; ⌥Space apps and Sticky Keys are informational")
    func others() {
        #expect(ids(.rightShift).contains("shift"))
        #expect(ids(.leftControl).contains("left-modifier"))
        let env = KeyEnvironment(installedBundleIDs: ["com.raycast.macos", "com.superduper.superwhisper"], stickyKeys: true)
        let found = KeyConflicts.check(.rightOption, in: env)
        #expect(found.first { $0.id == "option-space" }?.severity == .info)
        #expect(found.first { $0.id == "option-space" }?.message.contains("Superwhisper") == true)
        #expect(KeyEnvironment.watchedApps["com.openai.codex"] == nil)
        #expect(found.first { $0.id == "sticky-keys" }?.severity == .info)
    }

    @Test("every key has a picker name")
    func names() {
        #expect(Set(BuddyKey.allCases.map(\.settingsName)).count == BuddyKey.allCases.count)
    }
}

@Suite("Blocked apps")
@MainActor
struct BlockedAppsTests {
    @Test("built-in rows only for installed apps, locked; user rows removable, sorted")
    func rows() {
        let names = ["com.1password.1password": "1Password", "com.example.b": "Bravo", "com.example.a": "alpha"]
        let rows = BlockedApps.rows(user: ["com.example.b", "com.example.a", "com.example.gone"], installedName: { names[$0] })
        #expect(rows.first?.name == "1Password" && rows.first?.builtIn == true)
        #expect(rows.filter(\.builtIn).count == 1)
        #expect(rows.filter { !$0.builtIn }.map(\.name) == ["alpha", "Bravo", "com.example.gone"])
    }

    @Test("adding skips duplicates, blanks and apps already blocked by default")
    func adding() {
        #expect(BlockedApps.adding("com.example.a", to: []) == ["com.example.a"])
        #expect(BlockedApps.adding("com.example.a", to: ["com.example.a"]) == ["com.example.a"])
        #expect(BlockedApps.adding("  ", to: []) == [])
        #expect(BlockedApps.adding("com.1password.1password", to: []) == [])
        #expect(BlockedApps.adding("com.loomtable.lumi", to: []) == [])  // never ourselves
        #expect(BlockedApps.removing("com.example.a", from: ["com.example.a", "x"]) == ["x"])
    }
}

@Suite("Permission fix")
@MainActor
struct PermissionFixTests {
    @Test("Input Monitoring, Accessibility, Screen Recording: the first press only requests, every later press only opens the pane")
    func onePathPerPress() async {
        for kind in [PermissionKind.inputMonitoring, .accessibility, .screenRecording] {
            let p = FakePermissions([kind: .notDetermined])
            var prompted: Set<PermissionKind> = []
            _ = await PermissionFix.apply(kind, state: .notDetermined, prompted: &prompted, using: p)
            #expect(p.requested == [kind])
            #expect(p.opened.isEmpty, "the system prompt has its own Open System Settings button")
            #expect(prompted == [kind])
            _ = await PermissionFix.apply(kind, state: .notDetermined, prompted: &prompted, using: p)
            #expect(p.requested == [kind], "macOS prompts once: no silent second request")
            #expect(p.opened == [kind])
        }
    }

    @Test("prompted on an earlier launch: straight to the pane; granted: nothing")
    func promptedBeforeOrGranted() async {
        let p = FakePermissions([.screenRecording: .notDetermined, .accessibility: .granted])
        var prompted: Set<PermissionKind> = [.screenRecording]
        _ = await PermissionFix.apply(.screenRecording, state: .notDetermined, prompted: &prompted, using: p)
        #expect(p.requested.isEmpty && p.opened == [.screenRecording])
        #expect(await PermissionFix.apply(.accessibility, state: .granted, prompted: &prompted, using: p) == .granted)
        #expect(p.requested.isEmpty && p.opened == [.screenRecording])
    }

    @Test("microphone: prompts while undecided, else Settings")
    func microphone() async {
        let p = FakePermissions([.microphone: .notDetermined], afterRequest: [.microphone: .granted])
        var prompted: Set<PermissionKind> = []
        #expect(await PermissionFix.apply(.microphone, state: .notDetermined, prompted: &prompted, using: p) == .granted)
        #expect(p.opened.isEmpty)
        let denied = FakePermissions([.microphone: .denied])
        _ = await PermissionFix.apply(.microphone, state: .denied, prompted: &prompted, using: denied)
        #expect(denied.requested.isEmpty)
        #expect(denied.opened == [.microphone])
    }

    @Test("Settings: a card names the missing required grants and fixes the first; Privacy is badged")
    @MainActor
    func permissionsCard() {
        let t = TestDefaults()
        let p = FakePermissions([.inputMonitoring: .granted])
        let center = PermissionCenter(permissions: p, launchedByLaunchServices: true, defaults: t.defaults, relaunch: {})
        let line = PermissionsNeededCard.line(center)
        #expect(line.text == "Lumi needs Accessibility and Screen Recording to work.")
        #expect(line.fix == .accessibility && !line.offersReopen)
        let symbol = SettingsView.symbol(.privacy, needsAttention: center.needsAttention)
        #expect(symbol == "exclamationmark.triangle")
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "a symbol that exists")
        #expect(SettingsView.symbol(.keys, needsAttention: true) == SettingsPane.keys.systemImage)
        p.states[.accessibility] = .granted
        p.states[.screenRecording] = .granted
        center.refresh()
        #expect(PermissionsNeededCard.line(center).offersReopen, "Screen Recording waits for a reopen")
        #expect(PermissionsNeededCard.line(center).fix == nil)
    }

    @Test("sent to System Settings for Screen Recording that still reads missing: a reopen is offered too")
    func reopenWhileUnreadable() {
        #expect(PermissionGrantRow.mayNeedReopen(.screenRecording, state: .missing, asked: true))
        #expect(PermissionGrantRow.mayNeedReopen(.inputMonitoring, state: .missing, asked: true))
        #expect(!PermissionGrantRow.mayNeedReopen(.screenRecording, state: .missing, asked: false), "first visit: just Allow")
        #expect(!PermissionGrantRow.mayNeedReopen(.accessibility, state: .missing, asked: true), "applies live")
    }

    @Test("the row's button says what it will do")
    func buttonTitles() {
        #expect(PermissionGrantRow.buttonTitle(asked: false) == "Allow…")
        #expect(PermissionGrantRow.buttonTitle(asked: true) == "Open Settings")
        #expect(PermissionGrantRow.status(.grantedNeedsRelaunch) == "Allowed, needs a reopen")
    }

    @Test("every permission links to its own macOS 26 Privacy page; relaunch only where macOS needs it")
    func urls() {
        #expect(Set(PermissionKind.allCases.map(\.settingsURL)).count == PermissionKind.allCases.count)
        #expect(PermissionKind.allCases.allSatisfy { $0.settingsURL.absoluteString.contains("com.apple.settings.PrivacySecurity.extension") })
        #expect(PermissionKind.allCases.filter(\.needsRelaunchAfterGrant) == [.inputMonitoring, .screenRecording])
    }
}

@Suite("Practice")
@MainActor
struct PracticeTests {
    @Test("without Input Monitoring the practice area says so and listens to nothing")
    func needsPermission() async {
        let source = FakeKeySource()
        let model = PracticeModel(makeSource: { source }, inputMonitoringGranted: { false })
        await model.start(with: KeysPreferences())
        #expect(model.status == .needsInputMonitoring)
        #expect(!source.isStarted)
    }

    @Test("gestures from the key are counted and described")
    func counts() async throws {
        let source = FakeKeySource()
        // A manual clock: with the real one the timer fires at once for these small fake times
        // and races the remaining events.
        let model = PracticeModel(makeSource: { source }, inputMonitoringGranted: { true }, clock: ManualClock())
        var prefs = KeysPreferences()
        prefs.doubleTapWindowMs = 150
        await model.start(with: prefs)
        #expect(model.status == .listening)
        let key = BuddyKey.rightOption
        let down = key.downMask | key.independentMask
        let t: (UInt64) -> Nanos = { $0 * 1_000_000 }
        // A double-tap: down, up, down, up within the window.
        for (flags, ms) in [(down, 0), (0, 50), (down, 100), (0, 150)] as [(UInt64, UInt64)] {
            source.send(.input(.flagsChanged(keyCode: key.keyCode, flags: flags, time: t(ms))))
        }
        for _ in 0..<10_000 where model.doubleTaps == 0 { await Task.yield() }
        #expect(model.doubleTaps == 1)
        #expect(model.last?.hasPrefix("Double-tap") == true)
        await model.stop()
        #expect(model.status == .idle)
        #expect(!source.isStarted)
    }

    @Test("a stop racing a start leaves no tap running; update retunes without a new tap")
    func lifecycle() async {
        let source = FakeKeySource()
        var made = 0
        let model = PracticeModel(makeSource: { made += 1; return source }, inputMonitoringGranted: { true }, clock: ManualClock())
        async let started: Void = model.start(with: KeysPreferences())
        await model.stop()
        await started
        await model.stop()
        #expect(!source.isStarted)
        await model.start(with: KeysPreferences())
        let before = made
        var faster = KeysPreferences()
        faster.holdThresholdMs = 200
        await model.update(faster)
        #expect(made == before)
        #expect(source.isStarted)
        await model.stop()
        #expect(!source.isStarted)
    }

    @Test("the practice coordinator stays active until every user has ended")
    func coordinator() {
        var changes: [Bool] = []
        let c = KeyPracticeCoordinator { changes.append($0) }
        c.begin()   // Settings › Keys
        c.begin()   // onboarding
        c.end()
        #expect(c.isActive)
        c.end()
        c.end()     // extra end is ignored
        #expect(changes == [true, false])
        #expect(!c.isActive)
    }
}
