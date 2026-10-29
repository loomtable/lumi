import BuddyKeys
import Foundation
import SwiftUI
import Testing
@testable import BuddyCompanion

@MainActor
final class FakeClaudeCheck: ClaudeCodeChecking {
    var status: ClaudeCodeStatus
    init(_ status: ClaudeCodeStatus) { self.status = status }
    func check() async -> ClaudeCodeStatus { status }
}

@Suite("Onboarding")
@MainActor
struct OnboardingTests {
    func model(
        _ permissions: FakePermissions = FakePermissions(), claude: ClaudeCodeStatus = ClaudeCodeStatus(),
        external: [ExternalOnboardingStep] = [], defaults: UserDefaults
    ) -> OnboardingModel {
        OnboardingModel(permissions: center(permissions, defaults: defaults), claudeCheck: FakeClaudeCheck(claude),
                        external: external, defaults: defaults)
    }

    @Test("pages: welcome (with Claude Code), permissions, other modules' steps in order without duplicates, then the key")
    func order() {
        let t = TestDefaults()
        let m = model(external: [
            ExternalOnboardingStep(id: "voice", title: "Voice") { Text("v") },
            ExternalOnboardingStep(id: "models", title: "Models") { Text("m") },
            ExternalOnboardingStep(id: "voice", title: "Voice again") { Text("v2") },
        ], defaults: t.defaults)
        #expect(m.steps == [.welcome, .permissions, .external(id: "voice"), .external(id: "models"), .keySetup])
        #expect(m.externalStep("voice")?.title == "Voice")
    }

    @Test("an external step can hold Continue back until it's ready")
    func continueGate() {
        let t = TestDefaults()
        final class Ready { var value = false }
        let ready = Ready()
        let m = model(FakePermissions(PermissionKind.allCases.reduce(into: [:]) { $0[$1] = .granted }), external: [
            ExternalOnboardingStep(id: "voice", title: "Voice", canContinue: { ready.value }) { Text("v") },
        ], defaults: t.defaults)
        m.next()  // welcome → (permissions all granted, skipped) → voice
        #expect(m.current == .external(id: "voice") && !m.canContinue)
        m.next()
        #expect(m.current == .external(id: "voice"), "next() does nothing while Continue is held")
        ready.value = true
        #expect(m.canContinue)
        m.next()
        #expect(m.current == .keySetup)
    }

    @Test("Try it: speaking once the chosen voice is ready, typing until then")
    func tryIt() {
        #expect(OnboardingView.tryIt(key: "⌥", setup: .voice, voiceReady: true)
            == "Select a word anywhere, tap ⌥ and ask \"what does this mean?\"")
        #expect(OnboardingView.tryIt(key: "⌥", setup: .voice, voiceReady: false)
            == "Voice is still getting ready, so type for now: select a word anywhere, double-tap ⌥ and type \"what does this mean?\"")
        #expect(OnboardingView.tryIt(key: "⌥", setup: .typeOnly, voiceReady: false)
            == "Select a word anywhere, double-tap ⌥ and type \"what does this mean?\"")
        #expect(OnboardingView.tryIt(key: "⌥", setup: .typeOnly, voiceReady: true).contains("double-tap"),
                "typing was chosen: a ready voice doesn't change the hint")
        #expect(!OnboardingView.tryIt(key: "⌥", setup: .notChosen, voiceReady: false).contains("getting ready"))
    }

    @Test("Try it: one gesture table, each row once, with the new-conversation key for this key")
    func gestures() {
        #expect(OnboardingView.gestures(.rightOption).map(\.gesture) == ["Tap", "Hold", "Double-tap", "⇧ + ⌥"])
        #expect(OnboardingView.gestures(.rightShift).last?.gesture == "⌃ + ⇧", "a ⇧ key starts fresh with ⌃")
        #expect(OnboardingView.gestures(.rightOption).last?.does == "start a new session")
        #expect(OnboardingView.gestures(.rightOption).allSatisfy { !$0.does.isEmpty })
    }

    @Test("Claude Code: the sign-in command works before PATH is set up")
    func signInCommand() {
        #expect(OnboardingModel.signInCommand(path: nil) == "~/.local/bin/claude")
        #expect(OnboardingModel.signInCommand(path: NSHomeDirectory() + "/.local/bin/claude") == "~/.local/bin/claude")
        #expect(OnboardingModel.signInCommand(path: "/opt/homebrew/bin/claude") == "/opt/homebrew/bin/claude")
        #expect(OnboardingModel.installCommand == "curl -fsSL https://claude.ai/install.sh | bash")
    }

    @Test("Claude Code: the welcome page re-checks by itself until installed and signed in")
    func watchClaudeCode() async {
        let t = TestDefaults()
        let check = FakeClaudeCheck(ClaudeCodeStatus())
        let m = OnboardingModel(permissions: center(defaults: t.defaults), claudeCheck: check, defaults: t.defaults)
        await m.checkClaudeCode()
        #expect(!m.claudeCodeReady)
        let watch = Task { await m.watchClaudeCode(every: .milliseconds(5)) }
        var ready = ClaudeCodeStatus()
        ready.executablePath = "/Users/x/.local/bin/claude"
        ready.loggedIn = true
        check.status = ready
        await watch.value  // returns once the check reads ready
        #expect(m.claudeCodeReady)
        let idle = Task { await m.watchClaudeCode(every: .seconds(60)) }
        await idle.value  // already ready: returns at once
    }

    /// The required grants allowed (the microphone isn't required), so Continue never holds.
    static func requiredGranted() -> FakePermissions {
        FakePermissions([.inputMonitoring: .granted, .accessibility: .granted, .screenRecording: .granted])
    }

    func center(_ permissions: FakePermissions = FakePermissions(), defaults: UserDefaults, terminal: Bool = false,
                relaunch: @escaping @MainActor () -> Void = {}) -> PermissionCenter {
        PermissionCenter(permissions: permissions, launchedByLaunchServices: !terminal, defaults: defaults, relaunch: relaunch)
    }

    @Test("permissions are read without prompting; the page is done only when all four are allowed")
    func checkedBeforeShown() {
        let t = TestDefaults()
        let p = FakePermissions([.microphone: .granted, .accessibility: .denied])
        let m = model(p, defaults: t.defaults)
        #expect(m.permissionState(.microphone) == .granted)
        #expect(!m.isSatisfied(.permissions))
        #expect(p.requested.isEmpty)  // nothing prompted just by building the flow
        p.states = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, .granted) })
        m.permissions.refresh()       // what the center's poll does
        #expect(!m.isSatisfied(.permissions), "Input Monitoring and Screen Recording wait for a reopen")
        #expect(model(p, defaults: t.defaults).isSatisfied(.permissions), "after the reopen")
    }

    @Test("Grant on a missing Input Monitoring asks without also opening its pane; a late grant offers to reopen")
    func grant() async {
        let t = TestDefaults()
        let p = FakePermissions([.microphone: .notDetermined], afterRequest: [.microphone: .granted])
        let m = model(p, defaults: t.defaults)
        await m.grant(.microphone)
        #expect(m.permissionState(.microphone) == .granted)
        #expect(p.opened.isEmpty, "the mic prompt isn't covered by Settings")
        await m.grant(.inputMonitoring)
        #expect(p.requested == [.microphone, .inputMonitoring])
        #expect(p.opened.isEmpty, "the system prompt alone")
        #expect(m.asked.contains(.inputMonitoring))
        p.states[.inputMonitoring] = .granted
        m.permissions.refresh()
        #expect(m.permissionState(.inputMonitoring) == .grantedNeedsRelaunch)
    }

    @Test("the permissions page holds Continue until the required grants work; the microphone is optional")
    func requiredGate() {
        let t = TestDefaults()
        let p = FakePermissions([.microphone: .denied, .inputMonitoring: .granted, .accessibility: .granted])
        let m = model(p, defaults: t.defaults)
        m.next()  // welcome → permissions
        #expect(m.current == .permissions && !m.canContinue, "Screen Recording is still missing")
        m.next()
        #expect(m.current == .permissions, "next() does nothing while Continue is held")
        p.states[.screenRecording] = .granted
        m.permissions.refresh()
        #expect(m.permissionState(.screenRecording) == .grantedNeedsRelaunch && !m.canContinue, "not until it applies")
        let after = model(p, defaults: t.defaults)  // the reopened app: granted at launch, back on this page
        #expect(after.current == .permissions && after.canContinue, "the microphone doesn't block")
    }

    @Test("Quit & Reopen comes back to the step it was pressed on")
    func relaunchResumes() {
        let t = TestDefaults()
        final class Count { var n = 0 }
        let count = Count()
        let m = OnboardingModel(permissions: center(defaults: t.defaults, relaunch: { count.n += 1 }),
                                claudeCheck: FakeClaudeCheck(ClaudeCodeStatus()), defaults: t.defaults)
        m.next()
        m.relaunch()
        #expect(count.n == 1)
        #expect(t.defaults.string(forKey: OnboardingModel.resumeKey) == "permissions")
    }

    @Test("Claude Code is ready only when installed and signed in, and that completes the welcome page")
    func claudeCode() async {
        let t = TestDefaults()
        let installed = model(claude: ClaudeCodeStatus(executablePath: "/usr/local/bin/claude", loggedIn: false), defaults: t.defaults)
        #expect(!installed.claudeCodeChecked)  // "Checking…" until the first answer
        await installed.checkClaudeCode()
        #expect(installed.claudeCodeChecked)
        #expect(!installed.isSatisfied(.welcome))
        let ready = model(claude: ClaudeCodeStatus(executablePath: "/usr/local/bin/claude", version: "2.1", loggedIn: true), defaults: t.defaults)
        await ready.checkClaudeCode()
        #expect(ready.isSatisfied(.welcome))
    }

    @Test("an external step reports its own completion")
    func external() {
        let t = TestDefaults()
        let downloaded = Flag()
        let m = model(external: [ExternalOnboardingStep(id: "models", title: "Models", isComplete: { downloaded.isSet }) { Text("m") }], defaults: t.defaults)
        #expect(!m.isSatisfied(.external(id: "models")))
        downloaded.set()
        #expect(m.isSatisfied(.external(id: "models")))
    }

    @Test("Back and Continue move through the pages; finishing completes every step")
    func navigation() {
        let t = TestDefaults()
        let m = model(Self.requiredGranted(), defaults: t.defaults)
        #expect(OnboardingModel.needsOnboarding(external: [], defaults: t.defaults))
        m.back()
        #expect(m.index == 0)
        for _ in 0..<10 where !m.isLast { m.next() }  // bounded: a held Continue must fail, not hang
        #expect(m.current == .keySetup)
        #expect(m.progress == (step: m.steps.count, of: m.steps.count))
        m.next()  // Done
        #expect(!OnboardingModel.needsOnboarding(external: [], defaults: t.defaults))
        #expect(model(Self.requiredGranted(), defaults: t.defaults).index == 0)
    }

    @Test("Continue skips the permissions page when everything is already allowed")
    func skipsGranted() {
        let t = TestDefaults()
        let all = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, PermissionState.granted) })
        let m = model(FakePermissions(all), defaults: t.defaults)
        m.next()
        #expect(m.current == .keySetup)
        m.next()
        #expect(!OnboardingModel.needsOnboarding(external: [], defaults: t.defaults))
    }

    @Test("a relaunch mid-way (Quit & Reopen) resumes on the same page")
    func resumes() {
        let t = TestDefaults()
        let first = model(defaults: t.defaults)
        first.next()
        #expect(first.current == .permissions)
        let relaunched = model(defaults: t.defaults)
        #expect(relaunched.current == .permissions)
        relaunched.back()
        #expect(model(defaults: t.defaults).current == .welcome)
    }

    @Test("a newly added required step re-onboards just that step")
    func newStep() {
        let t = TestDefaults()
        let m = model(Self.requiredGranted(), defaults: t.defaults)
        for _ in 0..<10 where !m.isLast { m.next() }  // bounded: a held Continue must fail, not hang
        m.next()
        let voice = [ExternalOnboardingStep(id: "voice", title: "Voice") { Text("v") }]
        #expect(OnboardingModel.needsOnboarding(external: voice, defaults: t.defaults))
        let again = model(Self.requiredGranted(), external: voice, defaults: t.defaults)
        #expect(again.current == .external(id: "voice"))
        again.next()  // → the key page, already completed but last
        again.next()
        #expect(!OnboardingModel.needsOnboarding(external: voice, defaults: t.defaults))
    }

    @Test("a version-1 completion (version number only) counts its built-in steps as done")
    func olderVersion() {
        let t = TestDefaults()
        t.defaults.set(1, forKey: OnboardingModel.completedKey)
        #expect(!OnboardingModel.needsOnboarding(external: [], defaults: t.defaults))
        let voice = [ExternalOnboardingStep(id: "voice", title: "Voice") { Text("v") }]
        #expect(OnboardingModel.needsOnboarding(external: voice, defaults: t.defaults))
        #expect(model(external: voice, defaults: t.defaults).current == .external(id: "voice"))
    }

    @Test("started from a terminal: the terminal's grants never show as Lumi's")
    func borrowedGrants() {
        let t = TestDefaults()
        let all = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, PermissionState.granted) })
        let m = OnboardingModel(permissions: center(FakePermissions(all), defaults: t.defaults, terminal: true),
                                claudeCheck: FakeClaudeCheck(ClaudeCodeStatus()), defaults: t.defaults)
        #expect(PermissionKind.allCases.allSatisfy { m.permissionState($0) == .missing })
        #expect(!m.isSatisfied(.permissions))
        m.next()  // never skipped as "already set up"
        #expect(m.current == .permissions)
    }

    @Test("a version-2 resume at the old key page doesn't skip the permissions page")
    func versionTwoKeyResume() {
        let t = TestDefaults()
        t.defaults.set(["welcome", "claudeCode", "permission.microphone"], forKey: OnboardingModel.completedStepsKey)
        t.defaults.set("keySetup", forKey: OnboardingModel.resumeKey)
        #expect(model(defaults: t.defaults).current == .permissions)
    }

    @Test("version 2: finished users stay finished; a half-done run restarts at the first merged page not done")
    func versionTwo() {
        let done = TestDefaults()
        done.defaults.set(["welcome", "claudeCode", "permission.microphone", "keySetup", "permission.accessibility",
                           "permission.screenRecording", "tryIt"], forKey: OnboardingModel.completedStepsKey)
        #expect(!OnboardingModel.needsOnboarding(external: [], defaults: done.defaults))
        let half = TestDefaults()
        half.defaults.set(["welcome", "claudeCode", "permission.microphone", "keySetup"], forKey: OnboardingModel.completedStepsKey)
        half.defaults.set("permission.accessibility", forKey: OnboardingModel.resumeKey)  // an old page id
        #expect(OnboardingModel.needsOnboarding(external: [], defaults: half.defaults))
        #expect(model(defaults: half.defaults).current == .permissions)
    }

    @Test("external steps start once, and their header accessories are shown on every step")
    func externalHooks() {
        let t = TestDefaults()
        let starts = Counter()
        let m = model(external: [
            ExternalOnboardingStep(id: "voice", title: "Voice", headerAccessory: AnyView(Text("12%")), onStart: { starts.count += 1 }) { Text("v") },
            ExternalOnboardingStep(id: "other", title: "Other") { Text("o") },
        ], defaults: t.defaults)
        m.start(); m.start()
        #expect(starts.count == 1)
        #expect(m.headerAccessories.count == 1)
    }

    @Test("when Claude Code checks overlap, only the newest answer is kept")
    func overlappingChecks() async {
        let t = TestDefaults()
        let check = ManualClaudeCheck()
        let m = OnboardingModel(permissions: center(defaults: t.defaults), claudeCheck: check, defaults: t.defaults)
        let older = Task { await m.checkClaudeCode() }
        while check.pending.count < 1 { await Task.yield() }
        let newer = Task { await m.checkClaudeCode() }
        while check.pending.count < 2 { await Task.yield() }
        check.pending[1].resume(returning: ClaudeCodeStatus(executablePath: "/bin/claude", loggedIn: true))
        await newer.value
        check.pending[0].resume(returning: ClaudeCodeStatus())
        await older.value
        #expect(m.claudeCodeReady)
    }

    @Test("8 GB or less: the welcome page says once that replies may be slower, without blocking anything")
    func lowMemoryNote() {
        let t = TestDefaults()
        let low = OnboardingModel(permissions: center(defaults: t.defaults), claudeCheck: FakeClaudeCheck(ClaudeCodeStatus()),
                                  defaults: t.defaults, lowMemory: true)
        #expect(low.memoryNote == "Lumi works best with 16 GB of memory. On 8 GB, replies may be slower when many apps are open.")
        #expect(low.steps == model(defaults: t.defaults).steps, "no extra step: it's a line on the welcome page")
        #expect(model(defaults: t.defaults).memoryNote == nil)
    }

    @Test("the shell's first-question callback completes the key page")
    func firstQuestion() {
        let t = TestDefaults()
        let m = model(defaults: t.defaults)
        #expect(!m.isSatisfied(.keySetup))
        m.firstQuestionCompleted()
        #expect(m.isSatisfied(.keySetup))
    }
}

@MainActor
final class Counter {
    var count = 0
}

@MainActor
final class ManualClaudeCheck: ClaudeCodeChecking {
    var pending: [CheckedContinuation<ClaudeCodeStatus, Never>] = []
    func check() async -> ClaudeCodeStatus {
        await withCheckedContinuation { pending.append($0) }
    }
}

@MainActor
final class Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}
