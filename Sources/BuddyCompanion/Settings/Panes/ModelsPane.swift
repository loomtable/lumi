import BuddyCore
import SwiftUI

/// Settings › Models: per-mode model and effort with "default" or "custom" labels,
/// routing, restore defaults, and the plan-usage note.
struct ModelsPane: View {
    @Binding var settings: ModelPreferences

    var body: some View {
        PaneForm {
            Section {
                ForEach(Mode.allCases, id: \.self) { mode in
                    ModeRow(mode: mode, config: Binding(get: { settings.config(mode) }, set: { settings.set($0, for: mode) }),
                            isDefault: settings.isDefault(mode))
                }
            } footer: {
                Text("These run on your own Claude Code plan. Opus uses more of it than Sonnet or Haiku.")
            }
            Section {
                // Typed chats are the user's own Claude Code: no --model (owner, Round 3 S-06).
                Text("Typed chats use your Claude Code model (change it with /model).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Routing", selection: $settings.routing) {
                    Text("Auto").tag(Routing.auto)
                    Text("Always Quick").tag(Routing.alwaysQuick)
                    Text("Always Deep").tag(Routing.alwaysDeep)
                }
                Text(Self.routingHelp(settings.routing))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Restore defaults") { settings.restoreDefaults() }
                    .disabled(settings == ModelPreferences())
            }
        }
    }

    static func routingHelp(_ routing: Routing) -> String {
        switch routing {
        case .auto: "Auto starts in Quick and hands off to Deep when needed."
        case .alwaysQuick: "Every question stays in Quick. Say “go deep” to use Deep once."
        case .alwaysDeep: "Every question goes straight to Deep."
        }
    }
}

/// One mode: what it's for, its model (a known one or any ID Claude Code accepts) and effort.
struct ModeRow: View {
    let mode: Mode
    @Binding var config: ModeConfig
    let isDefault: Bool
    @State private var typingID = false
    /// The typed ID as the user edits it; saved only while it isn't blank, so clearing the
    /// field to type a new one doesn't snap back to the default.
    @State private var draftID = ""
    @FocusState private var editingID: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // As in the prototype's Settings: what the mode is for on the left, its menus on the
            // right, so the row fits the window's 560 pt minimum.
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(mode.displayName).font(.headline)
                        Text(isDefault ? "default" : "custom")
                            .font(.caption)
                            .foregroundStyle(isDefault ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    }
                    Text(Self.purpose(mode)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Picker("\(mode.displayName) model", selection: modelChoice) {
                    ForEach(ModelID.known, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                    Divider()
                    Text("Other model ID…").tag(ModelID?.none)
                }
                .labelsHidden()
                .fixedSize()
                Picker("\(mode.displayName) effort", selection: $config.effort) {
                    ForEach(mode.allowedEfforts, id: \.self) { Text(Self.effortName($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if typingID || !ModelID.known.contains(config.model) {
                TextField("Model ID", text: $draftID, prompt: Text("e.g. claude-sonnet-5-5"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($editingID)
                    // Saved on Return or leaving the field, not per keystroke: a model change
                    // restarts the warm Quick process.
                    .onSubmit(commitDraft)
                    .onChange(of: editingID) { _, editing in if !editing { commitDraft() } }
                    .onDisappear(perform: commitDraft)
            }
        }
        .padding(.vertical, 4)
        .onAppear { draftID = config.model.rawValue }
        .onChange(of: config.model) { _, model in
            if model.rawValue != draftID.trimmingCharacters(in: .whitespacesAndNewlines) { draftID = model.rawValue }
        }
        // Restore defaults (or any reset to the default) leaves "Other model ID…".
        .onChange(of: isDefault) { _, isDefault in if isDefault { typingID = false } }
    }

    private func commitDraft() {
        let id = draftID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty, id != config.model.rawValue { config.model = ModelID(rawValue: id) }
    }

    /// The menu: a known model, or nil for "Other" (a typed ID).
    private var modelChoice: Binding<ModelID?> {
        Binding(
            get: { typingID || !ModelID.known.contains(config.model) ? nil : config.model },
            set: { choice in
                if let choice {
                    typingID = false
                    config.model = choice
                } else {
                    typingID = true
                    draftID = config.model.rawValue
                }
            })
    }

    static func purpose(_ mode: Mode) -> String {
        switch mode {
        case .quick: "Every question starts here. Fast answers from what's on screen."
        case .deep: "Files, commands, the browser, careful reasoning."
        case .research: "Long background jobs with subagents."
        }
    }

    static func effortName(_ effort: Effort) -> String {
        switch effort {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
        }
    }
}
