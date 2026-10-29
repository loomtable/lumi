import SwiftUI

/// One Studio Settings page: the "needs attention" card while a grant is missing, then the page's form with its hero row, at most 640 pt wide.
public struct SettingsPageView: View {
    @Bindable var store: SettingsStore
    let page: SettingsPage
    /// Opens another page (the card's Details goes to Permissions).
    let open: (SettingsPage) -> Void
    @Environment(\.permissionCenter) private var permissions

    public init(store: SettingsStore, page: SettingsPage, open: @escaping (SettingsPage) -> Void) {
        self.store = store
        self.page = page
        self.open = open
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let permissions, permissions.needsAttention {
                PermissionsNeededCard(center: permissions, onPermissions: page == .permissions,
                                      resume: .page(page)) { open(.permissions) }
                    .padding(.top, 16)
            }
            content
                .environment(\.settingsHero, page)
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .general: KeysPane(settings: $store.keys, dictation: $store.dictation, dock: $store.dock)
        case .voice: VoicePane(settings: $store.voice, sessions: $store.sessions)
        case .model: ModelsPane(settings: $store.models)
        case .claudeCode: ClaudeCodePane()
        case .connections: ConnectionsPane(store: store)
        case .teammates: TeammatesPane(settings: $store.teammates)
        case .privacy: PrivacyPane(settings: $store.privacy, conversations: $store.conversations)
        case .permissions: PermissionsPane()
        case .appearance: AppearancePane(settings: $store.appearance)
        case .notifications: NotificationsPane(notifications: $store.notifications)
        case .about: AboutPane()
        }
    }
}
