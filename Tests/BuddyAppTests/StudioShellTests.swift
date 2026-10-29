@testable import BuddyApp
import BuddyCompanion
import BuddyCore
import BuddyOverlay
import Foundation
import Testing

@Suite("Studio shell")
@MainActor
struct StudioShellTests {
    /// The owner's QA 0.2.0 found the v1 Conversations window open. The app has two windows now,
    /// and nothing at launch, at onboarding's Done or in the menu opens anything else.
    @Test func nothingOpensAV1Window() {
        #expect(LumiWindow.allCases == [.studio, .onboarding], "no Conversations or Settings window")
        #expect(LumiWindow.atLaunch(needsOnboarding: false).isEmpty, "a set-up Lumi opens no window at launch")
        #expect(LumiWindow.atLaunch(needsOnboarding: true) == [.onboarding])
        #expect(LumiWindow.afterOnboarding.isEmpty, "Done closes onboarding and opens nothing")
        for needsSetUp in [false, true] {
            let problems = [AppProblem(text: "Claude Code isn't signed in.", fix: .claudeCode)]
            let items = StatusMenuItem.menu(answerKept: true, problems: problems, needsSetUp: needsSetUp, keyName: "Right ⌥",
                                            paused: false)
            let opened = Set(items.compactMap(\.action).compactMap { LumiWindow.opened(by: $0, needsSetUp: needsSetUp) })
            #expect(opened == (needsSetUp ? [.onboarding] : [.studio]), "every row opens the Lumi window or setup")
            #expect(!items.contains { $0.keyEquivalent == "y" }, "no ⌘Y Conversations row")
        }
        // Every deep link (Fix chips, problem rows, a relaunch's resume) is a Studio page.
        for pane in SettingsPane.allCases {
            #expect(SettingsRoute.route(pane, needsSetUp: false) == .settings(pane))
            #expect(SettingsRoute.route(pane, needsSetUp: true) == .onboarding)
        }
    }

    @Test func theMenuOpensTheOneWindow() {
        let items = StatusMenuItem.menu(answerKept: false, problems: [], needsSetUp: false, keyName: "Right ⌥", paused: false)
        #expect(items.contains(StatusMenuItem(title: "Open Lumi", action: .openStudio, keyEquivalent: "o")))
        #expect(items.contains(StatusMenuItem(title: "Settings…", action: .openSettings, keyEquivalent: ",")))
        #expect(items.contains(StatusMenuItem(title: "Lumi Key: Right ⌥…", action: .openPane(.keys))))
        #expect(items.filter { $0.keyEquivalent == "," }.count == 1)
    }

    @Test func theMenuStillOffersSetupFirst() {
        let items = StatusMenuItem.menu(answerKept: false, problems: [], needsSetUp: true, keyName: "Right ⌥", paused: false)
        #expect(items.contains { $0.action == .setUp })
        #expect(!items.contains { $0.action == .openStudio || $0.action == .openSettings })
    }

    /// Every Fix chip and problem row still lands on a Studio page.
    @Test func fixActionsLandOnTheirPage() {
        #expect(SettingsPage(.claudeCode) == .claudeCode)
        #expect(SettingsPage(.models) == .model)
        #expect(SettingsPage(.voice) == .voice)
        #expect(AppRuntime.fix(for: "Lumi needs Accessibility").map(SettingsPage.init) == .permissions)
    }

    @Test func sourceForwardsToTheSessionStore() async throws {
        let a = SessionSnapshot.sample("s_a", title: "Q3 variance")
        let port = FakeSessionsPort([a])
        let source = SessionsStudioSource(port: port)
        #expect(source.snapshots.map(\.id) == [a.id])
        await source.open(a.id)
        await source.setPinned(true, for: a.id)
        await source.rename(a.id, to: "Q3")
        try await source.forget(a.id)
        #expect(port.calls == [.setCurrent(a.id), .pinned(true, a.id), .rename(a.id, "Q3"), .forget(a.id)])
        #expect(source.snapshots.isEmpty)
    }

    @Test func sourceStreamsTheStoreChanges() async {
        let port = FakeSessionsPort([.sample("s_a")])
        let source = SessionsStudioSource(port: port)
        var changes = source.changes().makeAsyncIterator()
        #expect(await changes.next()?.count == 1)
        port.put(.sample("s_b"))
        #expect(await changes.next()?.map(\.id.rawValue) == ["s_b", "s_a"])
    }

    @Test func withoutAStoreStudioIsEmptyUntilOneAttaches() async {
        let source = SessionsStudioSource()
        #expect(source.snapshots.isEmpty)
        #expect(await source.startSession(text: "hi") == nil)
        #expect(await source.transcript(for: SessionID(rawValue: "x")).isEmpty)
        var changes = source.changes().makeAsyncIterator()
        #expect(await changes.next() == [])
        source.attach(FakeSessionsPort([.sample("s_a")]))
        #expect(await changes.next()?.map(\.id.rawValue) == ["s_a"])
    }

    @Test func hooksCarryTheEngineCalls() async {
        var hooks = SessionsStudioSource.Hooks()
        var handled: [PanelEvent] = []
        var files: [URL] = []
        hooks.startSession = { _, urls in files = urls; return SessionID(rawValue: "s_new") }
        hooks.handle = { handled.append($0) }
        let source = SessionsStudioSource(port: nil, hooks: hooks)
        #expect(await source.startSession(text: "hi") == SessionID(rawValue: "s_new"))
        let doc = URL(fileURLWithPath: "/tmp/q3.csv")
        #expect(await source.startSession(text: "hi", attachments: [doc]) == SessionID(rawValue: "s_new"))
        #expect(files == [doc])
        #expect(!source.canDictate)
        await source.handle(.stop(SessionID(rawValue: "s_new")))
        #expect(handled == [.stop(SessionID(rawValue: "s_new"))])
    }

    @Test func openingASessionMarksItSeen() async {
        var seen: [SessionID] = []
        var hooks = SessionsStudioSource.Hooks()
        hooks.opened = { seen.append($0) }
        let port = FakeSessionsPort([.sample("s_a")])
        let source = SessionsStudioSource(port: port, hooks: hooks)
        await source.open(SessionID(rawValue: "s_a"))
        #expect(seen == [SessionID(rawValue: "s_a")])
        #expect(port.calls == [.setCurrent(SessionID(rawValue: "s_a"))])
    }

    @Test func theShownStudioPageIsReportedToTheStore() {
        let port = PageRecordingPort()
        let source = SessionsStudioSource(port: port)
        let a = SessionID(rawValue: "s_a"), b = SessionID(rawValue: "s_b")
        source.shownSessionChanged(from: nil, to: a)
        source.shownSessionChanged(from: a, to: b)
        source.shownSessionChanged(from: b, to: nil)
        #expect(port.pages == ["shown s_a", "hidden s_a", "shown s_b", "hidden s_b"])
    }

    @Test func dictationTypesIntoStudioOnlyWhileItsComposerIsKey() {
        let source = SessionsStudioSource()
        #expect(!source.composerIsKey, "no Studio window")
        let host = FakePageShowing()
        source.pageHost = host
        source.insertIntoComposer("ignored?")
        #expect(host.inserted == ["ignored?"], "the model itself checks focus")
        host.composerIsKey = true
        #expect(source.composerIsKey)
    }

    @Test func asAPageHostItReportsTheStudioModel() {
        let source = SessionsStudioSource()
        #expect(source.shownSession == nil, "no Studio window")
        let host = FakePageShowing()
        source.pageHost = host
        host.shown = (SessionID(rawValue: "s_a"), true)
        #expect(source.shownSession?.id == SessionID(rawValue: "s_a"))
        #expect(source.shownSession?.isKey == true)
        source.record(question: "And April?", kind: .voiceInPage, context: nil, to: SessionID(rawValue: "s_a"))
        #expect(host.recorded == ["And April?"])
    }
}

@MainActor
private final class FakePageShowing: StudioPageShowing {
    var shown: (id: SessionID, isKey: Bool)?
    var recorded: [String] = []
    var composerIsKey = false
    var inserted: [String] = []
    var shownSession: (id: SessionID, isKey: Bool)? { shown }
    func record(question: String, kind: TurnKind, context: ContextStrip?, to session: SessionID) { recorded.append(question) }
    func applyEdit(_ edit: PageEdit, to session: SessionID) {}
    func insertIntoComposer(_ text: String) { inserted.append(text) }
}

/// Records page visibility; the rest of the port is inert.
@MainActor
private final class PageRecordingPort: SessionsPort {
    var pages: [String] = []
    var snapshots: [SessionSnapshot] { [] }
    var current: SessionID? { nil }
    func changes() -> AsyncStream<[SessionSnapshot]> { AsyncStream { $0.finish() } }
    func setCurrent(_ id: SessionID) async {}
    func setPinned(_ pinned: Bool, for id: SessionID) async {}
    func setArchived(_ archived: Bool, for id: SessionID) async {}
    func rename(_ id: SessionID, to title: String) async {}
    func forget(_ id: SessionID) async throws {}
    func apply(_ event: SessionEvent, to id: SessionID) {}
    func pageShown(_ id: SessionID, kind: PageKind) { pages.append("shown \(id.rawValue)") }
    func pageHidden(_ id: SessionID, kind: PageKind) { pages.append("hidden \(id.rawValue)") }
}
