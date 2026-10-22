import AppKit
import Foundation
import Observation
import SwiftUI

/// Which grants the app can't work without, and which ones macOS applies to a running process.
/// The probe on macOS 26.6 decides the two Input Monitoring answers; each is one switch here.
public struct PermissionPolicy: Sendable, Equatable {
    /// Required to continue onboarding, badged and warned about when missing. The microphone is
    /// only recommended: typing works without it.
    public var required: Set<PermissionKind>
    /// Grants that work in this process as soon as they're turned on. The others only apply to a
    /// process started after the grant, so a late grant reads `.grantedNeedsRelaunch`.
    public var appliesLive: Set<PermissionKind>

    public init(required: Set<PermissionKind>, appliesLive: Set<PermissionKind>) {
        self.required = required
        self.appliesLive = appliesLive
    }

    public static let `default` = PermissionPolicy(
        required: [.inputMonitoring, .accessibility, .screenRecording],
        appliesLive: Set(PermissionKind.allCases.filter { !$0.needsRelaunchAfterGrant }))
}

/// Every permission's state for the whole app: onboarding, Settings, the menu bar and the
/// runtime's warnings read this one object. Never prompts; `fix` is the only call that may.
@MainActor
@Observable
public final class PermissionCenter {
    public enum State: Sendable, Equatable {
        case missing
        case granted
        /// Turned on after this process started, for a grant macOS only applies to a new process.
        case grantedNeedsRelaunch
    }

    /// Where a relaunch comes back to.
    public enum Resume: Sendable, Equatable {
        case none
        case onboarding(stepID: String)
        case settings(SettingsPane)
    }

    public private(set) var states: [PermissionKind: State] = [:]
    public let policy: PermissionPolicy
    /// Grants whose system prompt or pane was shown this run (see `PermissionFix`).
    public private(set) var asked: Set<PermissionKind> = []
    /// Told after every change of `states`.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let permissions: any PermissionChecking
    @ObservationIgnored private let launchedByLaunchServices: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let relaunchApp: @MainActor () -> Void
    /// What each grant read when this process started.
    @ObservationIgnored private var atLaunch: [PermissionKind: PermissionState] = [:]
    /// Late grants shown to work in this process (the buddy key started after one).
    @ObservationIgnored private var appliedLive: Set<PermissionKind> = []

    static let settingsResumeKey = "permissions.resumeSettingsPane"
    /// Grants whose system request was made, on any launch: macOS prompts at most once, so later
    /// presses go straight to System Settings (see `PermissionFix`).
    static let promptedKey = "permissions.prompted"

    public init(permissions: any PermissionChecking = SystemPermissions.shared, policy: PermissionPolicy = .default,
                launchedByLaunchServices: Bool = LaunchCheck.isOwnResponsibleProcess, defaults: UserDefaults = .standard,
                relaunch: @escaping @MainActor () -> Void = { AppRelauncher.relaunch() }) {
        self.permissions = permissions
        self.policy = policy
        self.launchedByLaunchServices = launchedByLaunchServices
        self.defaults = defaults
        relaunchApp = relaunch
        atLaunch = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, read($0)) })
        states = current()
    }

    public func state(_ kind: PermissionKind) -> State { states[kind] ?? .missing }

    public var allRequiredGranted: Bool { policy.required.allSatisfy { state($0) == .granted } }
    /// A required grant is missing or waits for a relaunch: the menu bar is badged. Never when
    /// started from a terminal, whose grants this process borrows and can't be read.
    public var needsAttention: Bool { launchedByLaunchServices && !allRequiredGranted }
    /// Started from a terminal: the views say how to open the app properly instead.
    public var launchedFromTerminal: Bool { !launchedByLaunchServices }
    public var needsRelaunch: Bool { states.values.contains(.grantedNeedsRelaunch) }

    /// A late grant was shown to work without a relaunch (the buddy key started after it).
    public func markAppliedLive(_ kind: PermissionKind) {
        guard appliedLive.insert(kind).inserted else { return }
        refresh()
    }

    /// Re-reads every grant without prompting.
    public func refresh() {
        let now = current()
        guard now != states else { return }
        states = now
        onChange?()
    }

    /// A row's button: the system prompt the first time, else the exact pane. Never both.
    public func fix(_ kind: PermissionKind) async {
        asked.insert(kind)
        var prompted = Set((defaults.stringArray(forKey: Self.promptedKey) ?? []).compactMap(PermissionKind.init(rawValue:)))
        _ = await PermissionFix.apply(kind, state: read(kind), prompted: &prompted, using: permissions)
        defaults.set(prompted.map(\.rawValue).sorted(), forKey: Self.promptedKey)
        refresh()
    }

    /// Quits and reopens, coming back to `resume`.
    public func relaunch(resume: Resume = .none) {
        switch resume {
        case .none: break
        case .onboarding(let id): defaults.set(id, forKey: OnboardingModel.resumeKey)
        case .settings(let pane): defaults.set(pane.rawValue, forKey: Self.settingsResumeKey)
        }
        relaunchApp()
    }

    /// The Settings pane a relaunch asked to come back to, once.
    public static func takeSettingsResume(defaults: UserDefaults = .standard) -> SettingsPane? {
        guard let raw = defaults.string(forKey: settingsResumeKey) else { return nil }
        defaults.removeObject(forKey: settingsResumeKey)
        return SettingsPane(rawValue: raw)
    }

    /// Polls while the app runs: every second while something required is missing, otherwise
    /// every few seconds (a grant turned off in System Settings), and on every activation.
    public func watch() async {
        let activations = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.refresh()
            }
        }
        defer { activations.cancel() }
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: needsAttention ? .seconds(1) : .seconds(5))
        }
    }

    /// Started from a terminal, the checks are about the terminal's grants: none reads as granted.
    private func read(_ kind: PermissionKind) -> PermissionState {
        launchedByLaunchServices ? permissions.state(kind) : .notDetermined
    }

    private func current() -> [PermissionKind: State] {
        Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { kind in
            guard read(kind) == .granted else { return (kind, .missing) }
            let late = atLaunch[kind] != .granted && !policy.appliesLive.contains(kind) && !appliedLive.contains(kind)
            return (kind, late ? .grantedNeedsRelaunch : .granted)
        })
    }
}

extension EnvironmentValues {
    /// The shell's one PermissionCenter; nil in previews and tests that don't set it.
    @Entry public var permissionCenter: PermissionCenter? = nil
}
