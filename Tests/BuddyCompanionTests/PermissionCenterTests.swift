import Foundation
import Testing
@testable import BuddyCompanion

@Suite("PermissionCenter")
@MainActor
struct PermissionCenterTests {
    let defaults = UserDefaults(suiteName: NSTemporaryDirectory() + "permission-center-\(UUID().uuidString)")!

    func center(_ fake: FakePermissions, policy: PermissionPolicy = .default, fromTerminal: Bool = false,
                relaunch: @escaping @MainActor () -> Void = {}) -> PermissionCenter {
        PermissionCenter(permissions: fake, policy: policy, launchedByLaunchServices: !fromTerminal, defaults: defaults,
                         relaunch: relaunch)
    }

    static let allGranted: [PermissionKind: PermissionState] =
        Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, .granted) })

    @Test func grantedAtLaunchIsGrantedAndMissingIsMissing() {
        let c = center(FakePermissions([.microphone: .granted, .accessibility: .denied]))
        #expect(c.state(.microphone) == .granted)
        #expect(c.state(.accessibility) == .missing)
        #expect(c.state(.inputMonitoring) == .missing)
        #expect(c.needsAttention)
    }

    @Test func aLateGrantThatAppliesOnlyToANewProcessWaitsForARelaunch() {
        let fake = FakePermissions()
        let c = center(fake)
        var changes = 0
        c.onChange = { changes += 1 }
        fake.states = Self.allGranted
        c.refresh()
        #expect(c.state(.inputMonitoring) == .grantedNeedsRelaunch)
        #expect(c.state(.screenRecording) == .grantedNeedsRelaunch)
        #expect(c.state(.accessibility) == .granted, "applies live")
        #expect(c.state(.microphone) == .granted, "applies live")
        #expect(c.needsRelaunch)
        #expect(!c.allRequiredGranted, "still waiting: Continue stays gated")
        #expect(changes == 1)
        c.refresh()
        #expect(changes == 1, "no change, no callback")
    }

    @Test func aGrantProvedLiveByTheProbeIsGrantedAtOnce() {
        let fake = FakePermissions()
        let c = center(fake, policy: PermissionPolicy(required: PermissionPolicy.default.required,
                                                      appliesLive: Set(PermissionKind.allCases)))
        fake.states = Self.allGranted
        c.refresh()
        #expect(c.allRequiredGranted)
        #expect(!c.needsRelaunch)
    }

    @Test func aGrantTurnedOffLaterIsMissing() {
        let fake = FakePermissions(Self.allGranted)
        let c = center(fake)
        #expect(c.allRequiredGranted)
        fake.states[.screenRecording] = .denied
        c.refresh()
        #expect(c.state(.screenRecording) == .missing)
        #expect(c.needsAttention)
    }

    @Test func theMicrophoneIsRecommendedNotRequired() {
        var states = Self.allGranted
        states[.microphone] = .denied
        let c = center(FakePermissions(states))
        #expect(c.allRequiredGranted)
        #expect(!c.needsAttention)
    }

    @Test func inputMonitoringIsOneSwitchInTheRequiredSet() {
        var states = Self.allGranted
        states[.inputMonitoring] = .notDetermined
        let without = PermissionPolicy(required: [.accessibility, .screenRecording], appliesLive: PermissionPolicy.default.appliesLive)
        #expect(center(FakePermissions(states), policy: without).allRequiredGranted)
        #expect(!center(FakePermissions(states)).allRequiredGranted)
    }

    @Test func startedFromATerminalNothingReadsAsGranted() {
        let c = center(FakePermissions(Self.allGranted), fromTerminal: true)
        #expect(PermissionKind.allCases.allSatisfy { c.state($0) == .missing })
    }

    @Test func relaunchSavesWhereToComeBackToThenRelaunches() {
        var relaunched = 0
        let c = center(FakePermissions(), relaunch: { relaunched += 1 })
        c.relaunch(resume: .onboarding(stepID: "permissions"))
        #expect(defaults.string(forKey: OnboardingModel.resumeKey) == "permissions")
        c.relaunch(resume: .settings(.privacy))
        #expect(relaunched == 2)
        #expect(PermissionCenter.takeSettingsResume(defaults: defaults) == .privacy)
        #expect(PermissionCenter.takeSettingsResume(defaults: defaults) == nil, "read once")
    }

    @Test func fixAsksOnceEverThenOpensTheRightPane() async {
        let fake = FakePermissions()
        let c = center(fake)
        await c.fix(.screenRecording)
        #expect(fake.requested == [.screenRecording] && fake.opened.isEmpty, "the prompt alone, not Settings too")
        await c.fix(.screenRecording)
        #expect(fake.requested == [.screenRecording], "one request")
        #expect(fake.opened == [.screenRecording])
        #expect(c.asked == [.screenRecording])
        // The next launch remembers the prompt was shown: only the pane.
        let again = FakePermissions()
        await center(again).fix(.screenRecording)
        #expect(again.requested.isEmpty && again.opened == [.screenRecording])
    }
}
