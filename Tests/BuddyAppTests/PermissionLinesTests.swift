import BuddyAct
import BuddyCompanion
import BuddyConversations
import BuddyKeys
import BuddyOverlay
import Foundation
import Testing
@testable import BuddyApp

/// The runtime's permission warnings: one true line per missing required grant, gone once it's
/// granted; a reopen line for grants waiting on a new process; the buddy key started after a late grant.
@Suite("Permission lines")
@MainActor
struct PermissionLinesTests {
    let fake = FakePermissions()

    func runtime(policy: PermissionPolicy = .default) -> AppRuntime {
        let center = PermissionCenter(permissions: fake, policy: policy, launchedByLaunchServices: true,
                                      defaults: UserDefaults(suiteName: NSTemporaryDirectory() + "perm-lines-\(UUID().uuidString)")!,
                                      relaunch: {})
        let runtime = AppRuntime(voice: UnavailableVoice(), conversationIndex: { try ConversationIndex(url: nil) },
                                 overlay: { FakeOverlay() },
                                 traceDirectory: FileManager.default.temporaryDirectory.appending(path: "t-\(UUID().uuidString)"),
                                 permissions: center)
        runtime.observePermissions()
        return runtime
    }

    func grant(_ kinds: PermissionKind..., in runtime: AppRuntime) {
        for kind in kinds { fake.states[kind] = .granted }
        runtime.permissions.refresh()
    }

    @Test func eachMissingRequiredGrantIsOneLineThatOpensPrivacy() {
        let runtime = runtime()
        #expect(runtime.problems.map(\.text) == [
            AppRuntime.missingLine(.inputMonitoring), AppRuntime.missingLine(.accessibility),
            AppRuntime.missingLine(.screenRecording),
        ], "the microphone is only recommended: no line")
        #expect(runtime.problems.allSatisfy { $0.fix == .privacy && !$0.relaunches })
    }

    @Test func aGrantTurnedOnRemovesItsLineAndOneTurnedOffBringsItBack() {
        fake.states = [.inputMonitoring: .granted, .screenRecording: .granted]
        let runtime = runtime()
        #expect(runtime.problems.map(\.text) == [AppRuntime.missingLine(.accessibility)])
        grant(.accessibility, in: runtime)
        #expect(runtime.problems.isEmpty)
        fake.states[.accessibility] = .denied
        runtime.permissions.refresh()
        #expect(runtime.problems.map(\.text) == [AppRuntime.missingLine(.accessibility)])
    }

    @Test func aLateGrantMacOSAppliesOnRelaunchIsOneReopenLine() throws {
        let runtime = runtime()
        grant(.inputMonitoring, .screenRecording, in: runtime)
        let reopen = try #require(runtime.problems.first { $0.relaunches })
        #expect(reopen.text == "Reopen Lumi to finish turning on Input Monitoring and Screen Recording.")
        #expect(runtime.problems.map(\.text) == [AppRuntime.missingLine(.accessibility), reopen.text])
    }

    @Test func otherLinesStayWhenPermissionsChange() {
        let runtime = runtime()
        runtime.setPermissionMode("plan")
        grant(.accessibility, in: runtime)
        #expect(runtime.problems.contains { $0.text == TurnFailureLine.permissionModeLine("plan") })
    }

    @Test func aLateInputMonitoringGrantStartsTheBuddyKey() async {
        let runtime = runtime()
        var starts = 0
        runtime.startKeyListener = { () throws(KeySourceError) in
            starts += 1
            if self.fake.state(.inputMonitoring) != .granted { throw .inputMonitoringNotGranted }
        }
        await runtime.startKeyListenerIfNeeded()
        #expect(starts == 1)
        #expect(runtime.keyListenerFailure == .inputMonitoringNotGranted)
        #expect(runtime.problems.filter { $0.text.contains("Input Monitoring") }.count == 1, "the permission line only")
        grant(.inputMonitoring, in: runtime)
        for _ in 0..<200 where runtime.keyListenerFailure != nil { await Task.yield() }
        #expect(starts == 2)
        #expect(runtime.keyListenerFailure == nil)
        #expect(runtime.permissions.state(.inputMonitoring) == .granted, "it works in this process: no reopen")
        #expect(!runtime.problems.contains { $0.text.contains("Input Monitoring") })
        await runtime.startKeyListenerIfNeeded()
        #expect(starts == 2, "running: never started twice")
    }

    @Test func inputMonitoringTurnedOffAndBackOnRestartsTheBuddyKey() async {
        fake.states = [.inputMonitoring: .granted]
        let runtime = runtime()
        var starts = 0
        runtime.startKeyListener = { () throws(KeySourceError) in
            starts += 1
            if self.fake.state(.inputMonitoring) != .granted { throw .inputMonitoringNotGranted }
        }
        await runtime.startKeyListenerIfNeeded()
        #expect(starts == 1)
        fake.states[.inputMonitoring] = .denied
        runtime.permissions.refresh()
        #expect(runtime.keyListenerFailure == .inputMonitoringNotGranted)
        grant(.inputMonitoring, in: runtime)
        for _ in 0..<200 where starts < 2 || runtime.keyListenerFailure != nil { await Task.yield() }
        #expect(starts == 2, "the old tap is dead: a fresh one starts")
        #expect(runtime.keyListenerFailure == nil)
        #expect(runtime.permissions.state(.inputMonitoring) == .granted)
    }

    @Test func startedFromATerminalNoPermissionLineOrBadgeClaimsAnything() {
        let center = PermissionCenter(permissions: fake, launchedByLaunchServices: false,
                                      defaults: UserDefaults(suiteName: NSTemporaryDirectory() + "perm-lines-\(UUID().uuidString)")!,
                                      relaunch: {})
        let runtime = AppRuntime(voice: UnavailableVoice(), conversationIndex: { try ConversationIndex(url: nil) },
                                 overlay: { FakeOverlay() },
                                 traceDirectory: FileManager.default.temporaryDirectory.appending(path: "t-\(UUID().uuidString)"),
                                 permissions: center)
        runtime.observePermissions()
        #expect(runtime.problems.isEmpty)
        #expect(!center.needsAttention)
        #expect(!center.allRequiredGranted, "onboarding still can't trust it")
    }

    @Test func aListenerThatFailsForAnotherReasonSaysSo() async {
        fake.states = [.inputMonitoring: .granted]
        let runtime = runtime()
        runtime.startKeyListener = { () throws(KeySourceError) in throw .tapCreationFailed }
        await runtime.startKeyListenerIfNeeded()
        #expect(runtime.problems.contains { $0.text == AppRuntime.message(for: .tapCreationFailed) })
    }

    @Test func insertWithoutAccessibilityNamesTheRealCause() {
        #expect(LiveInserter.problem(for: .noFocusedField, accessibilityGranted: false) == LiveInserter.needsAccessibility)
        #expect(LiveInserter.problem(for: .noFocusedField, accessibilityGranted: true) == "Click the field you want it in, then try again.")
        #expect(LiveInserter.problem(for: .refusedSecureField, accessibilityGranted: false) == "I don't type into password fields.")
    }

    @Test func theAnswerChipOffersAccessibilityThenScreenRecordingThenNothing() {
        let runtime = runtime()
        #expect(AppRuntime.missingForChip(runtime.permissions) == .accessibility, "never Input Monitoring")
        grant(.accessibility, in: runtime)
        #expect(AppRuntime.missingForChip(runtime.permissions) == .screenRecording)
        grant(.screenRecording, in: runtime)
        #expect(AppRuntime.missingForChip(runtime.permissions) == nil, "waiting on a reopen is the menu's line")
    }
}
