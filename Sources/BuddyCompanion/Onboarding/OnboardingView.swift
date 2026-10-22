import AppKit
import BuddyKeys
import BuddyVoice
import SwiftUI

/// First-run onboarding (condensed): welcome with the Claude Code check,
/// every permission on one page with live status, other modules' steps, then the buddy key and
/// the first question. Back and Continue. The shell closes it on `onFinish`.
public struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @Bindable var store: SettingsStore
    let onFinish: () -> Void
    @State private var environment = KeyEnvironment()
    @Environment(\.voicePrepareState) private var voiceState
    @AccessibilityFocusState private var titleFocused: Bool

    public init(model: OnboardingModel, store: SettingsStore, onFinish: @escaping () -> Void) {
        self.model = model
        self.store = store
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Step \(model.progress.step) of \(model.progress.of)")
                if model.isSatisfied(model.current) {
                    Label("Already set up", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                // Other modules' progress (e.g. model download), on every step.
                ForEach(Array(model.headerAccessories.enumerated()), id: \.offset) { $0.element }
            }
            .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                page
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .accessibilityFocused($titleFocused)
            }
            .frame(maxHeight: .infinity)
            HStack {
                if model.index > 0 {
                    Button("Back") { model.back() }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button(model.isLast ? "Done" : "Continue") {
                    if model.isLast {
                        model.finish()
                        onFinish()
                    } else {
                        model.next()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
            }
        }
        .padding(28)
        .frame(width: 580, height: 460)
        .task {
            model.start()
            environment = KeyEnvironment.current()
            await model.checkClaudeCode()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            environment = KeyEnvironment.current()
            if model.current == .welcome, !model.claudeCodeReady { Task { await model.checkClaudeCode() } }
        }
        // Picks up an install or sign-in done in Terminal without a button press.
        .task(id: model.current == .welcome) {
            if model.current == .welcome { await model.watchClaudeCode() }
        }
        .onChange(of: model.index) { titleFocused = true }
    }

    @ViewBuilder private var page: some View {
        switch model.current {
        case .welcome:
            VStack(alignment: .leading, spacing: 16) {
                StepText(
                    title: "Ask about anything on your screen",
                    text: "Press one key, ask out loud, and get a short spoken answer with a picture when it helps. Your own Claude Code does the thinking.\n\nLumi only looks when you summon it, never at password managers or apps you block, and keeps screenshots for at most 24 hours.")
                Divider()
                ClaudeCodeStep(model: model)
                if let note = model.memoryNote {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .permissions:
            VStack(alignment: .leading, spacing: 12) {
                Text("Allow Lumi").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("The first press asks macOS: choose Open System Settings there and turn on Lumi. Later presses open the right place in System Settings. This page updates as soon as you turn one on. The microphone is optional: you can always type.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.launchedByLaunchServices {
                    LaunchedFromTerminalNotice()
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(PermissionKind.allCases) { kind in
                        PermissionGrantRow(kind: kind, state: model.permissionState(kind), asked: model.asked.contains(kind),
                                           required: model.permissions.policy.required.contains(kind),
                                           grant: { Task { await model.grant(kind) } }, relaunch: { model.relaunch() })
                        if kind != PermissionKind.allCases.last { Divider() }
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        case .external(let id):
            if let step = model.externalStep(id) {
                step.view
            }
        case .keySetup:
            VStack(alignment: .leading, spacing: 14) {
                Text("Try it").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                HStack(spacing: 12) {
                    Picker("Your key", selection: $store.keys.key) {
                        ForEach(BuddyKey.allCases, id: \.self) { Text($0.settingsName).tag($0) }
                    }
                    .fixedSize()
                    // The full recorder (mouse buttons, chords, timing) lives in Settings › Keys,
                    // which opens only once setup is finished.
                    Text("More options in Settings › Keys after setup.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(KeyConflicts.check(store.keys.key, in: environment).filter { $0.severity == .warning }) {
                    Label($0.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(Self.gestures(store.keys.key), id: \.gesture) { row in
                        GridRow {
                            Text(row.gesture).font(.headline)
                            Text(row.does).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if model.permissionState(.inputMonitoring) != .granted {
                    PermissionGrantRow(kind: .inputMonitoring, state: model.permissionState(.inputMonitoring),
                                       asked: model.asked.contains(.inputMonitoring),
                                       grant: { Task { await model.grant(.inputMonitoring) } }, relaunch: { model.relaunch() })
                }
                Divider()
                // Voice progress is in the header chip; this is only the question to ask.
                Text(Self.tryIt(key: store.keys.key.symbol, setup: store.voice.setup, voiceReady: voiceState == .ready))
                    .fixedSize(horizontal: false, vertical: true)
                if model.firstQuestionDone {
                    Label("That's it: you asked your first question.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }
}

extension OnboardingView {
    /// What each press of the key does, shown as a small table. The new-conversation row names
    /// the fresh modifier for this key, as Settings › Keys does.
    static func gestures(_ key: BuddyKey) -> [(gesture: String, does: String)] {
        [
            ("Tap", "talk, then tap again to send"),
            ("Hold", "talk while you hold it"),
            ("Double-tap", "type instead"),
            ("\(key.freshSymbol) + \(key.symbol)", "start a new conversation"),
        ]
    }

    /// One line. Speaking waits for the voice the user chose; typing works at once.
    static func tryIt(key: String, setup: VoicePreferences.VoiceSetup, voiceReady: Bool) -> String {
        if setup == .voice, voiceReady {
            return "Select a word anywhere, tap \(key) and ask \"what does this mean?\""
        }
        let typing = "double-tap \(key) and type \"what does this mean?\""
        return setup == .voice
            ? "Voice is still getting ready, so type for now: select a word anywhere, \(typing)"
            : "Select a word anywhere, \(typing)"
    }
}

private struct StepText: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ClaudeCodeStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code").font(.headline).accessibilityAddTraits(.isHeader)
            if !model.claudeCodeChecked {
                Label("Checking…", systemImage: "hourglass")
            } else if model.claudeCodeReady {
                Label("Found\(model.claudeCode.version.map { " (\($0))" } ?? ""), and you're signed in.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let path = model.claudeCode.executablePath {
                Text(model.claudeCode.loggedIn == false
                    ? "Claude Code is installed but not signed in."
                    : "Claude Code is installed, but Lumi couldn't tell whether you're signed in.")
                TerminalCommand(command: OnboardingModel.signInCommand(path: path))
                Text(OnboardingModel.signInNext).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Lumi uses your own Claude Code. Install it in Terminal:")
                TerminalCommand(command: OnboardingModel.installCommand)
                Text("Then run this once to sign in:")
                TerminalCommand(command: OnboardingModel.signInCommand(path: nil))
                Text(OnboardingModel.signInNext).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.claudeCodeChecked, !model.claudeCodeReady {
                Button("Check again") { Task { await model.checkClaudeCode() } }
            }
        }
    }
}

/// A Terminal command to copy.
private struct TerminalCommand: View {
    let command: String

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }
}
