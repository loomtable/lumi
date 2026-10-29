import AppKit
import BuddyCore
import Foundation
import SwiftUI
import Testing
@testable import BuddyCompanion
@testable import BuddyOverlay

/// Every theme (67-THEMES.md) on the key surfaces: a Studio session column, a Glance card, the
/// unified strip and Settings › Appearance. Liquid Glass doesn't draw offscreen, so the floating
/// surfaces use Reduce Transparency (glass then falls back to its solid look).
@Suite(.serialized, .enabled(if: Gallery.enabled))
@MainActor
struct QAGalleryThemes {
    typealias D = GalleryData

    static let looks: [Look] = Theme.allCases.flatMap { theme in
        (theme.forcedDark.map { [$0] } ?? [false, true]).map { Look(dark: $0, theme: theme) }
    }

    @Test func themes() async {
        let gallery = QAGalleryTests()
        let sid = SessionID(rawValue: "s1")
        let (studio, _) = QAGalleryStudioParts().model(.session(sid), transcripts: [sid: [D.historyTurn]])
        let answer = Answer(block: BuddyBlock(say: "March is high because of three one-off invoices, not a run-rate change.", shape: .card),
                            lane: Lane(mode: .quick, model: .haiku), conversation: .ember, turn: 3,
                            replyHint: "tap ⌥ to reply · click to type", question: "Why is March so high?")
        let eight = Array(D.studioSessions.prefix(8))
        let strip = gallery.switcherModel(eight, highlight: 1)
        let pill = gallery.pillModel(.session(eight[1]), .listening(hint: "release to send"))
        let width = SwitcherGeometry.stripWidth
        strip.headerHeight = SwitcherGeometry.headerHeight
        strip.plateWidth = width
        let room = SwitcherPanelLayout.shadowRoom
        let stripHeight = SwitcherGeometry.headerHeight + SwitcherGeometry.stripHeight(sessions: eight.count) + 2 * room
        let store = SettingsStore(defaults: UserDefaults(suiteName: "qa.gallery.themes")!)

        for look in Self.looks {
            var floating = look
            floating.reduceTransparency = true
            store.appearance.theme = look.theme
            if let session = studio.selectedSession {
                await Shot.take("themes-studio-column", look, size: CGSize(width: 900, height: 620)) {
                    ConversationColumn(session: session, model: studio).studioBackground()
                }
            }
            await Shot.take("themes-glance", floating, size: CGSize(width: 400, height: 200), backdrop: .desktop) {
                TokensReader { t in
                    AnswerContent(answer: answer, style: .card, t: t, web: nil, webHeight: 0)
                        .frame(width: BuddyOverlayController.cardWidth)
                        .modifier(SurfaceChrome(t: t, shape: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous)))
                }
            }
            await Shot.take("themes-strip", floating, size: CGSize(width: width + 2 * room, height: stripHeight), backdrop: .desktop) {
                TokensReader { t in
                    ZStack(alignment: .top) {
                        StripView(model: strip, onEvent: { _ in })
                        gallery.pillRow(pill, t: t).padding(.top, room + SwitcherGeometry.headerInset)
                    }
                }
            }
            await Shot.take("themes-settings-appearance", look, size: CGSize(width: 760, height: 520)) {
                ScrollView { SettingsPageView(store: store, page: .appearance) { _ in } }.studioBackground()
            }
        }
    }

    /// Every agent mark size (sidebar 16 and 20, Home 22, pill and Panel 24, strip 34, header 56)
    /// for the Studio's sessions, which cover each state and colour, in every theme.
    @Test func agentMarks() async {
        let sessions = D.studioSessions
        let sizes: [CGFloat] = [16, 20, 24, 34, 56]
        for look in Self.looks {
            await Shot.take("themes-agent-marks", look, size: CGSize(width: 820, height: 330)) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sizes, id: \.self) { size in
                        HStack(spacing: 14) {
                            ForEach(sessions) { AgentMark(session: $0, size: size).frame(width: 56) }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .studioBackground()
            }
        }
    }
}
