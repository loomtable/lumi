import BuddyKeys
import SwiftUI

/// Settings › Keys: buddy key, timing, conflict check, practice.
struct KeysPane: View {
    @Binding var settings: KeysPreferences
    @State private var environment = KeyEnvironment()
    @State private var practice = PracticeModel()
    @State private var practising = false
    @Environment(\.keyPractice) private var keyPractice

    var body: some View {
        Form {
            Section("Lumi key") {
                Picker("Key", selection: $settings.key) {
                    ForEach(BuddyKey.allCases, id: \.self) { Text($0.settingsName).tag($0) }
                }
                Text("Tap to talk and tap to send. Hold to talk. Double-tap to type.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("New conversation") {
                    Text("\(settings.key.freshSymbol) + \(settings.key.symbol)")
                }
                Text("Hold it as you press the Lumi key; the plain key continues the conversation.")
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
        }
        .formStyle(.grouped)
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
                .foregroundStyle(conflict.severity == .warning ? Color.orange : Color.secondary)
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
