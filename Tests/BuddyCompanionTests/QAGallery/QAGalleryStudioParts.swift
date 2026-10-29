import AppKit
import BuddyCore
import Foundation
import SwiftUI
import Testing
@testable import BuddyCompanion
@testable import BuddyOverlay

/// Studio's parts outside NavigationSplitView, whose List and detail ScrollView draw blank offscreen.
@Suite(.serialized, .enabled(if: Gallery.enabled))
@MainActor
struct QAGalleryStudioParts {
    typealias D = GalleryData

    func model(_ selection: StudioModel.Selection, transcripts: [SessionID: [TranscriptTurn]] = [:],
               details: [SessionID: SessionDetails] = [:]) -> (StudioModel, FakeStudioSource) {
        let source = FakeStudioSource(D.studioSessions)
        source.turns = transcripts
        source.detailsByID = details
        let m = StudioModel(source: source)
        m.selection = selection
        m.windowVisible = true
        return (m, source)
    }

    @Test func column() async {
        for id in ["s1", "s2", "s3", "s9", "s8"] {
            let sid = SessionID(rawValue: id)
            let (m, source) = model(.session(sid), transcripts: [sid: [D.historyTurn]])
            guard let session = m.selectedSession else { continue }
            for look in [Look.light, .dark, .lightRT] {
                await Shot.take("studio-30-column-\(id)", look, size: CGSize(width: 900, height: 760), prepare: { _ in
                    if id == "s1" {
                        source.emit(.turnStarted(userUUID: "u2", kind: .typed), to: sid)
                        source.emit(.step(TrailStep(id: "r1", kind: .read, verb: "Reading", object: "po-ledger.csv")), to: sid)
                        source.emit(.text("Looking at April next.", subagent: nil), to: sid)
                    }
                }) {
                    ConversationColumn(session: session, model: m)
                }
            }
        }
    }

    /// A lane opened from the sidebar or inspector on a page that only has history (U19 residual).
    @Test func laneFromSidebar() async {
        let sid = SessionID(rawValue: "s3")
        // Lane history is seeded by the per-branch polish shots; `FakeStudioSource.lanes` changes type there.
        let (m, _) = model(.session(sid), transcripts: [sid: [D.historyTurn]])
        guard let session = m.selectedSession else { return }
        await Shot.take("studio-36-lane-from-sidebar", .lightRT, size: CGSize(width: 900, height: 600), prepare: { _ in
            m.openTeammate("task0", in: sid)
        }) {
            ConversationColumn(session: session, model: m)
        }
    }

    @Test func inspector() async {
        let sid = SessionID(rawValue: "s3")
        let details = SessionDetails(claudeSessionID: "0b9d6c1e-6f0a-4a43-9b5e-4c3a7f2e1d00",
                                     workingDirectory: "/Users/someone/Finance/Q3 plans", model: "claude-opus-5-5",
                                     permissionMode: "default", files: [URL(fileURLWithPath: "/tmp/budget-notes.md")],
                                     contexts: [.init(id: "c1", appName: "Numbers", title: "Q3 budget")], costUSD: 0.42)
        for tab in StudioModel.InspectorTab.allCases {
            for look in [Look.light, .dark] {
                let (m, _) = model(.session(sid), details: [sid: details])
                m.inspectorTab = tab
                await Shot.take("studio-31-inspector-\(tab.rawValue)", look, size: CGSize(width: 320, height: 560)) {
                    StudioInspector(session: m.selectedSession!, model: m)
                }
            }
        }
        // A session with no teammates, files or context: the empty states.
        let (m, _) = model(.session(SessionID(rawValue: "s5")))
        for tab in StudioModel.InspectorTab.allCases {
            m.inspectorTab = tab
            await Shot.take("studio-32-inspector-empty-\(tab.rawValue)", .light, size: CGSize(width: 320, height: 300)) {
                StudioInspector(session: m.selectedSession!, model: m)
            }
        }
    }

    @Test func sidebarRows() async {
        let (m, _) = model(.session(SessionID(rawValue: "s1")))
        let grouping = m.sidebar(now: D.now)
        for look in [Look.light, .dark] {
            await Shot.take("studio-33-sidebar-rows", look, size: CGSize(width: 260, height: 760)) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(grouping.sections) { section in
                            Text(section.group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.top, 10)
                            ForEach(section.rows) { row in
                                SessionRow(row: row, now: D.now, model: m)
                                ForEach(row.teammates) { TeammateRow(teammate: $0) }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    @Test func settingsPagesAlone() async {
        let defaults = UserDefaults(suiteName: "qa.gallery.settings")!
        let store = SettingsStore(defaults: defaults)
        for page in SettingsPage.allCases {
            for look in [Look.light, .dark] {
                await Shot.take("studio-35-settings-\(page.rawValue)", look, size: CGSize(width: 760, height: 1100)) {
                    ScrollView { SettingsPageView(store: store, page: page) { _ in } }
                }
            }
        }
    }
}
