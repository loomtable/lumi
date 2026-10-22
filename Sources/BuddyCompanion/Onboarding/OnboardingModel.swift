import AppKit
import Foundation
import Observation
import SwiftUI

/// One page of first-run onboarding (condensed: related steps
/// share a page so permissions can be granted in one place).
public enum OnboardingStepKind: Equatable, Sendable {
    /// What it does and never looks at, plus the Claude Code check (steps 1–2).
    case welcome
    /// Microphone, Input Monitoring, Accessibility and Screen Recording as rows (steps 3–6).
    case permissions
    /// A step another module provides (Voice, model download), shown after the permissions in
    /// the order given.
    case external(id: String)
    /// The buddy key and the guided first question (steps 4 and 9).
    case keySetup

    /// Stable id, stored when the step is completed.
    public var id: String {
        switch self {
        case .welcome: "welcome"
        case .permissions: "permissions"
        case .external(let id): "external.\(id)"
        case .keySetup: "keySetup"
        }
    }
}

/// A step plugged in from another module, e.g. the Voice choice.
public struct ExternalOnboardingStep: Identifiable {
    public let id: String
    public let title: String
    public let view: AnyView
    /// Shown in the header on every step while onboarding is open (e.g. the model-download
    /// progress chip, visible during steps 3–7). Nil for none.
    public let headerAccessory: AnyView?
    /// Called once when onboarding appears (e.g. start downloading models in the background).
    public let onStart: (@MainActor () -> Void)?
    /// True once nothing more is needed; shows a ✓. Read @Observable state here, so the view
    /// updates when it changes.
    public let isComplete: @MainActor () -> Bool
    /// False while the step still needs a choice: Continue is disabled.
    public let canContinue: @MainActor () -> Bool

    public init<V: View>(
        id: String, title: String, headerAccessory: AnyView? = nil, onStart: (@MainActor () -> Void)? = nil,
        isComplete: @escaping @MainActor () -> Bool = { false }, canContinue: @escaping @MainActor () -> Bool = { true },
        @ViewBuilder view: () -> V
    ) {
        self.id = id
        self.title = title
        self.headerAccessory = headerAccessory
        self.onStart = onStart
        self.isComplete = isComplete
        self.canContinue = canContinue
        self.view = AnyView(view())
    }
}

/// Checks Claude Code for onboarding step 2. The shell must inject a real one (BuddyBridge's
/// probe: `claude auth status`, exit 0 when signed in, plus `claude --version`): there is
/// deliberately no default, so onboarding never shows a status nobody measured.
@MainActor
public protocol ClaudeCodeChecking: AnyObject {
    func check() async -> ClaudeCodeStatus
}

/// Drives onboarding: the order of steps, whether each is already satisfied (checked
/// without prompting before it is shown), what has been completed, and where to resume.
@Observable
public final class OnboardingModel {
    /// Version 2 introduced step-level completion; version 3 merged the pages. Users who finished
    /// version 1 only stored the version number; their built-in steps count as done.
    public static let version = 3
    static let completedKey = "onboarding.completedVersion"
    static let completedStepsKey = "onboarding.completedSteps"
    static let resumeKey = "onboarding.resumeStep"

    /// The built-in steps, which a finished version 1 or 2 covered.
    static let builtInSteps: Set<String> = ["welcome", "permissions", "keySetup"]
    /// Version 2's last step: whoever completed it went through every built-in page.
    static let versionTwoLastStep = "tryIt"

    public private(set) var steps: [OnboardingStepKind]
    public private(set) var index = 0
    public private(set) var claudeCode = ClaudeCodeStatus()
    /// False until the first Claude Code check returns ("Checking…").
    public private(set) var claudeCodeChecked = false
    /// Set by the shell when the guided first question has been answered.
    public private(set) var firstQuestionDone = false

    /// The documented native install (code.claude.com/docs/en/setup). It puts `claude` in
    /// ~/.local/bin, which a new user's Terminal may not have on its PATH yet.
    public static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    /// Where the native installer puts `claude`, written so Terminal expands it.
    public static let nativeInstallPath = "~/.local/bin/claude"
    /// What to run to sign in: the found binary's full path (home as ~), else the native
    /// installer's path, so it works before the PATH is set up.
    public static func signInCommand(path: String?) -> String {
        guard let path else { return nativeInstallPath }
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    public static let signInNext = "Sign in when it asks, then come back here. This page checks again by itself."
    /// How often `watchClaudeCode` re-checks.
    public static let claudeRecheckInterval: Duration = .seconds(4)

    /// Whether macOS attributes permission checks to Lumi itself. Started from a terminal
    /// (the binary run directly, not through Finder, Spotlight or `open`), macOS checks the
    /// terminal's grants instead, so every row would read as allowed while Lumi has none.
    /// Then nothing reads as allowed and the page says how to open it properly.
    public var launchedByLaunchServices: Bool { !permissions.launchedFromTerminal }
    /// The welcome page's line on a Mac with 8 GB of memory or less: advice, never a block.
    public let memoryNote: String?
    public static let lowMemoryNote =
        "Lumi works best with 16 GB of memory. On 8 GB, replies may be slower when many apps are open."
    /// The app's one permission state (the shell's), observable, so the rows update on a grant.
    @ObservationIgnored public let permissions: PermissionCenter
    @ObservationIgnored let claudeCheck: any ClaudeCodeChecking
    @ObservationIgnored let external: [ExternalOnboardingStep]
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var completed: Set<String>
    @ObservationIgnored private var claudeCheckGeneration = 0
    @ObservationIgnored private var started = false

    public init(
        permissions: PermissionCenter, claudeCheck: any ClaudeCodeChecking,
        external: [ExternalOnboardingStep] = [], defaults: UserDefaults = .standard, lowMemory: Bool = false
    ) {
        memoryNote = lowMemory ? Self.lowMemoryNote : nil
        self.permissions = permissions
        self.claudeCheck = claudeCheck
        // Later duplicates of an id are dropped.
        var seen: Set<String> = []
        self.external = external.filter { seen.insert($0.id).inserted }
        self.defaults = defaults
        completed = Self.completedSteps(defaults)
        steps = Self.steps(external: self.external)
        permissions.refresh()
        // Resume where the user was (e.g. after the relaunch Input Monitoring asks for), but never
        // past the first step not yet completed (an older version's resume id may point later).
        let firstOpen = steps.firstIndex(where: { !completed.contains($0.id) })
        if let resume = defaults.string(forKey: Self.resumeKey), let i = steps.firstIndex(where: { $0.id == resume }) {
            index = min(i, firstOpen ?? i)
        } else if let firstOpen {
            index = firstOpen
        }
    }

    /// Welcome (with Claude Code), permissions, other modules' steps, then the key with practice
    /// and the first question, which needs Input Monitoring from the permissions page.
    static func steps(external: [ExternalOnboardingStep]) -> [OnboardingStepKind] {
        [.welcome, .permissions] + external.map { .external(id: $0.id) } + [.keySetup]
    }

    static func completedSteps(_ defaults: UserDefaults) -> Set<String> {
        if let stored = defaults.stringArray(forKey: completedStepsKey) {
            let done = Set(stored)
            return done.contains(versionTwoLastStep) ? done.union(builtInSteps) : done
        }
        return defaults.integer(forKey: completedKey) >= 1 ? builtInSteps : []
    }

    /// Whether onboarding must be shown: some step (including a newly added external one) has
    /// never been completed. It then opens at the first such step.
    public static func needsOnboarding(external: [ExternalOnboardingStep], defaults: UserDefaults = .standard) -> Bool {
        let done = completedSteps(defaults)
        return steps(external: external).contains { !done.contains($0.id) }
    }

    public var current: OnboardingStepKind { steps[index] }
    public var isLast: Bool { index == steps.count - 1 }
    public var progress: (step: Int, of: Int) { (index + 1, steps.count) }
    public var headerAccessories: [AnyView] { external.compactMap(\.headerAccessory) }

    public func externalStep(_ id: String) -> ExternalOnboardingStep? {
        external.first { $0.id == id }
    }

    /// The permissions page holds Continue until the required grants work (the microphone is only
    /// recommended); an external step until it's ready (the Voice step until a voice is chosen).
    /// Started from a terminal the grants can't be read, so the page never blocks.
    public var canContinue: Bool {
        switch current {
        case .permissions: permissions.allRequiredGranted || permissions.launchedFromTerminal
        case .external(let id): externalStep(id)?.canContinue() ?? true
        case .welcome, .keySetup: true
        }
    }

    /// Runs the external steps' onStart hooks, once.
    public func start() {
        guard !started else { return }
        started = true
        for step in external { step.onStart?() }
    }

    public func permissionState(_ kind: PermissionKind) -> PermissionCenter.State { permissions.state(kind) }
    /// Grants whose prompt or pane was shown this run.
    public var asked: Set<PermissionKind> { permissions.asked }


    /// Overlapping checks (appear, the watch and "Check again") keep only the newest answer.
    public func checkClaudeCode() async {
        claudeCheckGeneration += 1
        let mine = claudeCheckGeneration
        let status = await claudeCheck.check()
        guard mine == claudeCheckGeneration else { return }
        claudeCode = status
        claudeCodeChecked = true
    }

    /// Re-checks until Claude Code is installed and signed in, so the welcome page picks up what
    /// the user did in Terminal by itself. Ends when cancelled (the page is left).
    public func watchClaudeCode(every interval: Duration = claudeRecheckInterval) async {
        while !claudeCodeReady {
            do { try await Task.sleep(for: interval) } catch { return }
            await checkClaudeCode()
        }
    }

    public var claudeCodeReady: Bool {
        claudeCode.executablePath != nil && claudeCode.loggedIn == true
    }

    /// The shell calls this when the guided first question has been answered.
    public func firstQuestionCompleted() {
        firstQuestionDone = true
    }

    /// Every grant, the recommended microphone too: the page is skipped only then.
    public var allPermissionsGranted: Bool {
        PermissionKind.allCases.allSatisfy { permissions.state($0) == .granted }
    }

    /// Whether `step` needs nothing from the user (shown with a ✓, and Continue is enough).
    public func isSatisfied(_ step: OnboardingStepKind) -> Bool {
        switch step {
        case .welcome: claudeCodeReady
        case .permissions: allPermissionsGranted
        case .external(let id): externalStep(id)?.isComplete() ?? false
        case .keySetup: firstQuestionDone
        }
    }

    /// A row's Grant button: the system prompt where macOS still shows one, and the exact System
    /// Settings pane whenever the grant is still missing (see `PermissionFix`).
    public func grant(_ kind: PermissionKind) async {
        await permissions.fix(kind)
    }

    /// Quit & Reopen for a grant macOS applies only to a new process; onboarding comes back here.
    public func relaunch() {
        permissions.relaunch(resume: .onboarding(stepID: current.id))
    }

    /// Completes this step and moves on, past a permissions page with nothing left to grant.
    /// Only the required grants block (see `canContinue`): typing works without the mic.
    public func next() {
        permissions.refresh()
        guard canContinue else { return }
        markCompleted(current)
        if isLast {
            finish()
            return
        }
        index += 1
        while !isLast, current == .permissions, isSatisfied(current) {
            markCompleted(current)
            index += 1
        }
        defaults.set(current.id, forKey: Self.resumeKey)
    }

    public func back() {
        if index > 0 { index -= 1 }
        defaults.set(current.id, forKey: Self.resumeKey)
    }

    public func finish() {
        for step in steps { markCompleted(step) }
        defaults.set(Self.version, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.resumeKey)
    }

    private func markCompleted(_ step: OnboardingStepKind) {
        guard completed.insert(step.id).inserted else { return }
        defaults.set(completed.sorted(), forKey: Self.completedStepsKey)
    }
}

/// Quits and reopens the app, for permissions macOS only applies to a new process.
@MainActor
public enum AppRelauncher {
    /// Only when running as an app bundle (not in tests or a CLI).
    public static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    public static func relaunch() {
        guard canRelaunch else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
