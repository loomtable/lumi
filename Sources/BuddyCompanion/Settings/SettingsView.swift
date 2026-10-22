import SwiftUI

/// The Settings window's sections, in order.
public nonisolated enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case keys, models, voice, appearance, conversations, connections, privacy, claudeCode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keys: "Keys"
        case .models: "Models"
        case .voice: "Voice"
        case .appearance: "Appearance"
        case .conversations: "Conversations"
        case .connections: "Connections"
        case .privacy: "Privacy"
        case .claudeCode: "Claude Code"
        }
    }

    public var systemImage: String {
        switch self {
        case .keys: "keyboard"
        case .models: "cpu"
        case .voice: "waveform"
        case .appearance: "paintpalette"
        case .conversations: "bubble.left.and.bubble.right"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .privacy: "hand.raised"
        case .claudeCode: "terminal"
        }
    }
}

/// The Settings scene's content: one tab per pane. The app shell puts this in a `Settings`
/// scene and passes the shared store. Each pane lives in Panes/ and belongs to its area.
public struct SettingsView: View {
    @Bindable var store: SettingsStore
    @State private var ownSelection: SettingsPane
    private let sharedSelection: Binding<SettingsPane>?

    public init(store: SettingsStore, initialPane: SettingsPane = .keys) {
        self.store = store
        _ownSelection = State(initialValue: initialPane)
        sharedSelection = nil
    }

    /// The shell owns the selected pane, so the menu bar (or a card's ⌘,) can open Settings at a
    /// given pane even while the window is already open.
    public init(store: SettingsStore, selection: Binding<SettingsPane>) {
        self.store = store
        _ownSelection = State(initialValue: selection.wrappedValue)
        sharedSelection = selection
    }

    private var selection: Binding<SettingsPane> { sharedSelection ?? $ownSelection }
    @Environment(\.permissionCenter) private var permissions

    public var body: some View {
        TabView(selection: selection) {
            ForEach(SettingsPane.allCases) { pane in
                VStack(spacing: 0) {
                    // On every pane while a required grant is missing or waits for a reopen.
                    if let permissions, permissions.needsAttention {
                        PermissionsNeededCard(center: permissions, pane: pane) { selection.wrappedValue = .privacy }
                    }
                    paneView(pane)
                }
                .tabItem { Label(pane.title, systemImage: Self.symbol(pane, needsAttention: permissions?.needsAttention == true)) }
                .tag(pane)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    /// Privacy shows a warning badge while a required grant is missing (a toolbar tab can't take
    /// `.badge` on macOS).
    static func symbol(_ pane: SettingsPane, needsAttention: Bool) -> String {
        pane == .privacy && needsAttention ? "exclamationmark.triangle" : pane.systemImage
    }

    @ViewBuilder
    private func paneView(_ pane: SettingsPane) -> some View {
        switch pane {
        case .keys: KeysPane(settings: $store.keys)
        case .models: ModelsPane(settings: $store.models)
        case .voice: VoicePane(settings: $store.voice)
        case .appearance: AppearancePane(settings: $store.appearance)
        case .conversations: ConversationsPane(settings: $store.conversations)
        case .connections: ConnectionsPane(store: store)
        case .privacy: PrivacyPane(settings: $store.privacy)
        case .claudeCode: ClaudeCodePane()
        }
    }
}

/// The top of every Settings pane while a required grant is missing: what's missing, one button
/// that fixes the first of them (or reopens, when macOS needs that), and a link to the rows.
struct PermissionsNeededCard: View {
    let center: PermissionCenter
    let pane: SettingsPane
    let showPermissions: () -> Void

    var body: some View {
        let line = Self.line(center)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(line.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if pane != .privacy {
                Button("Details", action: showPermissions).buttonStyle(.link)
            }
            if line.offersReopen, AppRelauncher.canRelaunch {
                Button("Quit & Reopen") { center.relaunch(resume: .settings(pane)) }
            }
            if let kind = line.fix {
                Button("Allow \(kind.title)…") { Task { await center.fix(kind) } }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
    }

    struct Line: Equatable {
        var text: String
        /// The first missing grant, fixed by the card's button.
        var fix: PermissionKind?
        /// A grant waits for a reopen, or may already be on but unreadable until one.
        var offersReopen: Bool
    }

    /// Missing grants first (in the rows' order), then any waiting for a reopen.
    static func line(_ center: PermissionCenter) -> Line {
        let required = PermissionKind.allCases.filter { center.policy.required.contains($0) }
        let missing = required.filter { center.state($0) == .missing }
        let reopen = center.needsRelaunch
            || missing.contains { PermissionGrantRow.mayNeedReopen($0, state: .missing, asked: center.asked.contains($0)) }
        if let first = missing.first {
            let names = ListFormatter.localizedString(byJoining: missing.map(\.title))
            return Line(text: "Lumi needs \(names) to work.", fix: first, offersReopen: reopen)
        }
        let text = AppRelauncher.canRelaunch ? "Reopen Lumi to finish turning on its permissions."
                                             : "Quit Lumi and open it again to finish turning on its permissions."
        return Line(text: text, fix: nil, offersReopen: true)
    }
}
