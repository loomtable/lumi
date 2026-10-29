import BuddyCore
import BuddyOverlay
import SwiftUI

/// The one Lumi window (04 §6): sessions and Settings in the sidebar, Home, a session's page or a
/// Settings page in the content column, and the inspector beside a session. The app shell puts it in
/// `Window("Lumi")` with the shared store and the companion services in the environment.
public struct StudioView: View {
    @Bindable var model: StudioModel
    let store: SettingsStore
    @FocusState private var searchFocused: Bool

    public init(model: StudioModel, store: SettingsStore) {
        self.model = model
        self.store = store
    }

    public var body: some View {
        // Ember is the window's one accent: links, toggles, sliders, focus rings and selection (04 §7.1).
        split.emberTint()
    }

    private var split: some View {
        NavigationSplitView {
            StudioSidebar(model: model, searchFocused: $searchFocused)
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
        } detail: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .studioBackground()
                .animation(Motion.crossfade, value: model.selection)
        }
        .inspector(isPresented: inspectorShown) {
            if let session = model.selectedSession { StudioInspector(session: session, model: model) }
        }
        .environment(\.openStudioSettings, StudioSettingsOpener { [model] page in model.showSettings(page) })
        .background { shortcuts }
        .background { StudioWindowObserver(model: model) }
        .alert(model.notice ?? "", isPresented: noticeShown) { Button("OK", role: .cancel) {} }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            model.windowVisible = true
            model.start()
        }
        .onDisappear { model.windowVisible = false }
        .navigationTitle(title)
        // The page's own header names it: no second title in the toolbar, and the window's
        // background runs under the toolbar (canvas: one surface, traffic lights over it).
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    @ViewBuilder
    private var content: some View {
        switch model.selection {
        case .home:
            HomeView(model: model, store: store)
        case .session:
            if let session = model.selectedSession {
                ConversationColumn(session: session, model: model)
            } else {
                HomeView(model: model, store: store)
            }
        case .settings(let page):
            SettingsPageView(store: store, page: page) { model.showSettings($0) }
                .id(page)
        case .dictation:
            if let history = model.dictationHistory {
                DictationHistoryView(history: history)
            } else {
                HomeView(model: model, store: store)
            }
        }
    }

    private var title: String {
        switch model.selection {
        case .home: BuddyCore.appName
        case .session: model.selectedSession?.title ?? BuddyCore.appName
        case .settings(let page): page.title
        case .dictation: DictationHistoryView.title
        }
    }

    /// Only beside a session.
    private var inspectorShown: Binding<Bool> {
        Binding(get: { model.inspectorShown && model.selectedSession != nil }, set: { model.inspectorShown = $0 })
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    /// ⌘K search, ⌥⌘↑/↓ previous and next session. ⌘N is the Session menu's (LumiApp).
    private var shortcuts: some View {
        Group {
            Button("Search") {
                if model.showsSettingsList { model.leaveSettings() }
                searchFocused = true
            }
            .keyboardShortcut("k", modifiers: .command)
            Button("Previous Session") { model.move(by: -1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Session") { model.move(by: 1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
