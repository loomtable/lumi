import BuddyKeys
import BuddyOverlay
import SwiftUI

/// Settings › General: buddy key, timing, conflict check, practice, the dictation key and the Dock.
struct KeysPane: View {
    @Binding var settings: KeysPreferences
    /// The dictation key's section.
    var dictation: Binding<DictationPreferences>?
    /// "Show in Dock".
    var dock: Binding<DockPreferences>?
    @State private var environment = KeyEnvironment()
    @State private var practice = PracticeModel()
    @State private var practising = false
    @Environment(\.keyPractice) private var keyPractice

    var body: some View {
        PaneForm {
            Section("Lumi key") {
                Picker("Key", selection: $settings.key) {
                    ForEach(BuddyKey.allCases, id: \.self) { Text($0.settingsName).tag($0) }
                }
                Text("Tap to talk and tap to send. Hold to talk. Double-tap to type.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("New session") {
                    Text("\(settings.key.freshSymbol) + \(settings.key.symbol)")
                }
                Text("Hold it as you press the Lumi key; the plain key continues the session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Ignore the Lumi key while a password field is active", isOn: $settings.ignoreDuringSecureInput)
                Text("When another app uses secure entry, macOS hides other keys from Lumi, so ⌥ used to type a character there can look like a tap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Timing") {
                TimingSlider(title: "Hold after", value: $settings.holdThresholdMs)
                TimingSlider(title: "Double-tap within", value: $settings.doubleTapWindowMs)
                Button("Restore defaults") {
                    let d = KeysPreferences()
                    settings.holdThresholdMs = d.holdThresholdMs
                    settings.doubleTapWindowMs = d.doubleTapWindowMs
                }
                .disabled(settings.holdThresholdMs == KeysPreferences().holdThresholdMs
                    && settings.doubleTapWindowMs == KeysPreferences().doubleTapWindowMs)
            }

            Section("Check") {
                let conflicts = KeyConflicts.check(settings.key, in: environment)
                if conflicts.isEmpty {
                    Label("No conflicts found for this key.", systemImage: "checkmark.circle")
                }
                ForEach(conflicts) { ConflictRow(conflict: $0) }
            }

            Section("Practise") {
                PracticeView(model: practice)
                if practising {
                    Button("Stop practising") { Task { await stopPractice() } }
                } else {
                    Button("Start practising") { Task { await startPractice() } }
                    Text("While practising, the Lumi key won't start questions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let dictation {
                DictationKeySection(settings: dictation, buddyKey: settings.key, environment: environment)
            }

            if let dock {
                Section("Dock") {
                    Toggle("Show in Dock", isOn: dock.showInDock)
                    Text("Lumi stays in the menu bar either way.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { environment = KeyEnvironment.current() }
        .onChange(of: settings) { _, new in Task { await practice.update(new) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            environment = KeyEnvironment.current()
        }
        // Practice never outlives the user's attention: leaving the window or the app ends it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            Task { await stopPractice() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            Task { await stopPractice() }
        }
        .onDisappear { Task { await stopPractice() } }
    }

    private func startPractice() async {
        guard !practising else { return }
        practising = true
        keyPractice.begin()
        await practice.start(with: settings)
        if !practice.isRunning { await stopPractice() }
    }

    private func stopPractice() async {
        guard practising else { return }
        practising = false
        keyPractice.end()
        await practice.stop()
    }
}

/// Settings › General: tap the dictation key (or hold it), speak, and the words are typed where
/// the cursor is. Nothing is sent to Claude. Auto picks fn when the 🌐 key does nothing, else
/// right ⌘; the line under the picker says which key is in use and why (`DictationKeyResolver`).
struct DictationKeySection: View {
    @Binding var settings: DictationPreferences
    let buddyKey: BuddyKey
    let environment: KeyEnvironment

    var body: some View {
        Section {
            Picker("Dictation key", selection: $settings.choice) {
                ForEach(Self.choices, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            let resolution = self.resolution
            if settings.choice != .off {
                Label(resolution.reason, systemImage: resolution.key == nil ? "exclamationmark.triangle" : "info.circle")
                    .foregroundStyle(resolution.key == nil ? AnyShapeStyle(.lumiAmber) : AnyShapeStyle(.secondary))
                Picker("Mode", selection: $settings.mode) {
                    ForEach(DictationMode.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                }
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text(Self.help(for: settings.choice == .off ? nil : resolution.key, mode: settings.mode))
        }
    }

    private var resolution: DictationKeyResolution { settings.resolved(buddyKey: buddyKey, in: environment) }

    static func title(_ mode: DictationMode) -> String {
        switch mode {
        case .toggle: "Tap to start and stop"
        case .hold: "Hold to talk"
        }
    }

    /// How to use the key in effect. A key people chord with must be pressed on its own
    /// (`DictationKeyGate`), so its shortcuts keep working and never start a dictation.
    static func help(for key: BuddyKey?, mode: DictationMode = .toggle) -> String {
        let rest = "Your words are typed where the cursor is, in any app, and kept in Dictation history. Nothing is sent to Claude."
        let name = key.map(DictationKeyResolver.name) ?? "the dictation key"
        let how = switch mode {
        case .toggle: "Tap \(name) to start, and tap it again to type. Or hold it while you speak. Esc cancels."
        case .hold: "Hold \(name) and speak, then let go to type. Esc cancels."
        }
        guard let key, key != .function else { return how + " " + rest }
        return how + " " + rest + " Pressed with another key, \(name) works as usual."
    }

    /// Auto, Off, then every key.
    static let choices: [DictationKeyChoice] = [.auto, .off] + BuddyKey.allCases.map { .key($0) }

    static func title(_ choice: DictationKeyChoice) -> String {
        switch choice {
        case .auto: "Auto"
        case .off: "Off"
        case .key(let key): key.settingsName
        }
    }
}

private struct TimingSlider: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(
                    value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                    in: Double(KeysPreferences.timingRange.lowerBound)...Double(KeysPreferences.timingRange.upperBound),
                    step: 10)
                Text("\(value) ms").monospacedDigit().frame(width: 56, alignment: .trailing)
            }
        }
    }
}

private struct ConflictRow: View {
    let conflict: KeyConflict

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: conflict.severity == .warning ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(conflict.severity == .warning ? AnyShapeStyle(.lumiAmber) : AnyShapeStyle(.secondary))
            Text(conflict.message)
            Spacer()
            if conflict.fix == .openKeyboardSettings {
                Button("Open Keyboard Settings") { NSWorkspace.shared.open(KeyConflicts.keyboardSettingsURL) }
            }
        }
    }
}

struct PracticeView: View {
    let model: PracticeModel

    var body: some View {
        switch model.status {
        case .needsInputMonitoring:
            Label("Input Monitoring is needed to practise.", systemImage: "lock")
        case .failed(let reason):
            Label("Can't listen to the key: \(reason)", systemImage: "exclamationmark.triangle")
        case .idle, .listening:
            VStack(alignment: .leading, spacing: 6) {
                Text(model.last ?? "Try a tap, a hold and a double-tap.")
                HStack(spacing: 16) {
                    Text("Taps \(model.taps)")
                    Text("Holds \(model.holds)")
                    Text("Double-taps \(model.doubleTaps)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }
}
