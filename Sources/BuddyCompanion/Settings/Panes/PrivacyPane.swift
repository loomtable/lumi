import AppKit
import SwiftUI

/// Settings › Privacy: blocked apps, what is captured, what is stored, trace log,
/// permissions.
struct PrivacyPane: View {
    @Binding var settings: PrivacyPreferences
    @Environment(\.permissions) private var permissions
    @Environment(\.storageLocations) private var storage
    @Environment(\.traceLogActions) private var traceLogActions
    @State private var confirmingTraceDelete = false
    @State private var traceDeleted = false
    /// The latest delete; a second press replaces it, so "Deleted." stays its full 3 s.
    @State private var traceDeleteTask: Task<Void, Never>?
    @Environment(\.permissionCenter) private var sharedCenter
    /// Previews and tests without the shell's center get one of their own (not polled).
    @State private var ownCenter: PermissionCenter?
    @State private var blockedRows: [BlockedApp] = []

    var body: some View {
        Form {
            Section("Blocked apps") {
                Text("Lumi never looks at these apps: no screenshot, no text, no window titles.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(blockedRows) { app in
                    HStack {
                        Text(app.name)
                        Spacer()
                        if app.builtIn {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Always blocked")
                        } else {
                            Button("Remove") {
                                settings.blockedBundleIDs = BlockedApps.removing(app.bundleID, from: settings.blockedBundleIDs)
                            }
                        }
                    }
                }
                Button("Add App…") {
                    if let id = BlockedApps.chooseApp() {
                        settings.blockedBundleIDs = BlockedApps.adding(id, to: settings.blockedBundleIDs)
                    }
                }
            }

            Section("What Lumi looks at") {
                Text("Only when you summon it: the app and window in front, your selection, the element under the pointer, and a screenshot of that display. Windows of blocked apps are left out of the screenshot. Text in password fields is never read, though a password field's dots can appear in the screenshot.")
                Text("Your question, this context and the screenshot go to your own Claude Code, which sends them to Anthropic to answer. If you turn on ElevenLabs voice, the reply text is sent to ElevenLabs to be spoken. Nothing else leaves this Mac.")
                    .foregroundStyle(.secondary)
            }

            Section("Stored on this Mac") {
                Picker("Keep screenshots for", selection: $settings.screenshotRetentionHours) {
                    ForEach(PrivacyPreferences.retentionChoices, id: \.self) { Text("\($0) h").tag($0) }
                }
                Toggle("Trace log", isOn: $settings.traceLogEnabled)
                Text("Timings and event types only, never what you said or saw. Kept 7 days in ~/Library/Logs/com.loomtable.lumi.")
                    .font(.caption).foregroundStyle(.secondary)
                if let deleteTraceLog = traceLogActions.delete {
                    HStack {
                        Button("Delete trace log…", role: .destructive) { confirmingTraceDelete = true }
                        if traceDeleted { Text("Deleted.").font(.caption).foregroundStyle(.secondary) }
                    }
                    .confirmationDialog("Delete the trace log?", isPresented: $confirmingTraceDelete) {
                        Button("Delete", role: .destructive) {
                            traceDeleteTask?.cancel()
                            traceDeleteTask = Task {
                                await deleteTraceLog()
                                traceDeleted = true
                                // A confirmation, not a state. Cancelled by a newer delete, which shows its own.
                                guard (try? await Task.sleep(for: .seconds(3))) != nil else { return }
                                traceDeleted = false
                            }
                        }
                    } message: {
                        Text("Every trace file in ~/Library/Logs/com.loomtable.lumi is removed. If the trace log is on, it starts again from now.")
                    }
                }
                ForEach(storage) { location in
                    LabeledContent(location.title) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([location.url]) }
                    }
                }
            }

            Section("Permissions") {
                if let center {
                    if center.launchedFromTerminal { LaunchedFromTerminalNotice() }
                    ForEach(PermissionKind.allCases) { kind in
                        PermissionGrantRow(kind: kind, state: center.state(kind), asked: center.asked.contains(kind),
                                           required: center.policy.required.contains(kind),
                                           grant: { Task { await center.fix(kind) } },
                                           relaunch: { center.relaunch(resume: .settings(.privacy)) })
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: settings.blockedBundleIDs) { blockedRows = BlockedApps.rows(user: settings.blockedBundleIDs) }
        .task { if sharedCenter == nil, ownCenter == nil { ownCenter = PermissionCenter(permissions: permissions) } }
    }

    private var center: PermissionCenter? { sharedCenter ?? ownCenter }
}

/// What a permission's Grant or Fix button does: one path per press, never the system prompt and
/// System Settings together (the prompt has its own "Open System Settings" button).
///
/// - Microphone: macOS prompts while it is undecided; after that only System Settings can change it.
/// - Input Monitoring, Accessibility and Screen Recording: the request adds Lumi to the System
///   Settings list and shows the system prompt, but only while undecided and at most once per app.
///   So the first press ever (`prompted`, kept across launches) only requests, and every later
///   press only opens the exact pane.
enum PermissionFix {
    @MainActor
    static func apply(
        _ kind: PermissionKind, state: PermissionState, prompted: inout Set<PermissionKind>,
        using permissions: any PermissionChecking
    ) async -> PermissionState {
        if state == .granted { return state }
        if kind == .microphone {
            if state == .notDetermined { return await permissions.request(kind) }
            permissions.openSettings(kind)
            return permissions.state(kind)
        }
        if prompted.insert(kind).inserted { return await permissions.request(kind) }
        permissions.openSettings(kind)
        return permissions.state(kind)
    }
}
