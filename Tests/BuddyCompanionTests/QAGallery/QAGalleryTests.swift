import AppKit
import BuddyCore
import Foundation
import SwiftUI
import Testing
@testable import BuddyCompanion
@testable import BuddyOverlay

/// The gallery's screens. Each test writes PNGs and VoiceOver dumps; none asserts on pixels.
@Suite(.serialized, .enabled(if: Gallery.enabled))
@MainActor
struct QAGalleryTests {
    typealias D = GalleryData

    // MARK: Panel (compact)

    func panel(_ name: String, _ model: ConversationPageModel, looks: [Look] = Look.floating, height: CGFloat = 620,
               width: CGFloat = 400, pinned: Bool = false, prepare: ((NSView) async -> Void)? = nil) async {
        for look in looks {
            let chrome = PanelChrome()
            chrome.pinned = pinned
            await Shot.take("panel-\(name)", look, size: CGSize(width: width + 48, height: height + 48), backdrop: .desktop,
                            prepare: prepare) {
                PanelRootView(model: model, chrome: chrome, onPin: {}, onExpand: {}, onMinimise: {}, onClose: {},
                              onComposerFocus: { _ in }, onContentHeight: { _ in })
                    .frame(width: width, height: height)
                    .shadow(color: .black.opacity(look.dark ? 0.35 : 0.16), radius: 12, y: 8)
            }
        }
    }

    @Test func panelStates() async {
        await panel("01-empty", D.model(ConversationPage(session: SessionID(rawValue: "s_new"), title: "New session")),
                    looks: Look.all, height: 260)
        await panel("02-running", D.model(D.running()), looks: Look.all)
        await panel("03-done", D.model(D.done()), looks: Look.all)
        await panel("04-done-expanded", D.model(D.done()), looks: Look.floating, height: 760) { view in
            AX.press("Worked for", in: view)
        }
        await panel("05-approval-edit", D.model(D.approval()), looks: Look.all, height: 700)
        await panel("06-approval-tier2-command", D.model(D.approval(tier: .needsClick, command: true)), height: 620)
        await panel("07-question", D.model(D.question()), height: 560)
        await panel("08-question-multi", D.model(D.question(multi: true)), height: 600)
        await panel("09-plan", D.model(D.plan()), height: 560)
        await panel("10-teammates", D.model(D.teammates()), looks: Look.all, height: 680)
        await panel("11-lane", D.model(D.teammates(), lane: "task0"), height: 560)
        await panel("12-stopped", D.model(D.stopped()))
        await panel("13-failed", D.model(D.failed()))
        await panel("14-interrupted", D.model(D.interrupted()))
        await panel("15-retrying", D.model(D.retrying()), height: 360)
        await panel("16-long-title", D.model(D.done(longTitle: true)), pinned: true)
        await panel("17-history-reopened", D.model(D.history()), height: 520)
        let answering = D.model(D.questionTwo())
        answering.answerInComposer("q2", questions: ["Which numbers should lead the update?", "How long should it be?"])
        await panel("21-question-answering-in-composer", answering, height: 520)
        var cut = D.interrupted()
        cut.markInterrupted()
        await panel("22-interrupted-continue", D.model(cut))
        await panel("18-narrow-340", D.model(D.running()), width: 340)
        await panel("19-wide-560", D.model(D.done()), width: 560)
    }

    @Test func composerStates() async {
        let cases: [(String, ConversationPageModel)] = [
            ("a-draft", D.model(D.done(), draft: "And April?")),
            ("b-running-stop", D.model(D.running())),
            ("c-running-steer-draft", D.model(D.running(), draft: "Skip payroll")),
            ("d-listening", D.model(D.done(), listening: true)),
            ("e-text-only", D.model(D.done(), withScreen: false)),
            ("f-long-app-name", D.model(D.done(), app: "Microsoft Excel for Mac")),
            ("g-no-app", D.model(D.done(), app: nil)),
            ("h-attachments", D.model(D.done(), attachments: [
                PageAttachment(url: URL(fileURLWithPath: "/tmp/invoices-march-final-v2-signed.pdf"), kind: .file),
                PageAttachment(url: URL(fileURLWithPath: "/tmp/po-ledger.csv"), kind: .file),
            ])),
            ("i-multiline-draft", D.model(D.done(), draft: "Line one of a longer direction\nline two\nline three\nline four\nline five\nline six\nline seven")),
        ]
        for (name, model) in cases {
            await panel("20-composer-\(name)", model, height: 420)
        }
    }

    /// The composer alone in the Panel (400, 340) and the Studio column, light and dark.
    @Test func composerMatrix() async {
        let cases: [(String, ConversationPageModel)] = [
            ("idle", D.model(D.done())),
            ("running", D.model(D.running())),
            ("attachments", D.model(D.done(), attachments: [
                PageAttachment(url: URL(fileURLWithPath: "/tmp/invoices-march-final-v2-signed.pdf"), kind: .file),
                PageAttachment(url: URL(fileURLWithPath: "/tmp/po-ledger.csv"), kind: .file)])),
            ("draft", D.model(D.done(), draft: "And April?")),
        ]
        for (name, model) in cases {
            for width in [400.0, 340.0] {
                await panel("30-matrix-\(name)-\(Int(width))", model, height: 300, width: width)
            }
            for look in Look.floating {
                await Shot.take("page-matrix-\(name)-studio", look, size: CGSize(width: 900, height: 300)) {
                    ConversationPageView(model: model, density: .comfortable)
                }
            }
        }
    }

    // MARK: Glance card with ⤢ Continue

    @Test func glanceContinue() async {
        ContinueInPanel.enabled = true
        defer { ContinueInPanel.enabled = false }
        let answer = Answer(block: BuddyBlock(say: "March is high because of three one-off invoices, not a run-rate change.", shape: .card),
                            lane: Lane(mode: .quick, model: .haiku), conversation: .ember, turn: 3, replyHint: "tap ⌥ to reply · click to type",
                            question: "Why is March so high?")
        for look in Look.all {
            await Shot.take("glance-continue", look, size: CGSize(width: 400, height: 220), backdrop: .desktop) {
                TokensReader { t in
                    AnswerContent(answer: answer, style: .card, t: t, web: nil, webHeight: 0)
                        .frame(width: BuddyOverlayController.cardWidth)
                        .modifier(SurfaceChrome(t: t, shape: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous)))
                }
            }
        }
    }

    // MARK: Switcher

    func switcherModel(_ tiles: [SessionSnapshot], highlight: Int, peek: SessionSnapshot? = nil) -> SwitcherModel {
        let m = SwitcherModel()
        m.tiles = tiles
        m.highlight = highlight
        m.isOpen = true
        m.now = D.now
        m.peek = peek
        m.peekShowsKeys = peek != nil
        for t in tiles {
            if let b = t.origin?.key.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
                m.icons[b] = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return m
    }

    @Test func switcherStrip() async {
        let all = D.strip
        let eight = Array(D.studioSessions.prefix(8))
        let cases: [(String, SwitcherModel, Backdrop)] = [
            ("01-one-session", switcherModel(Array(all.prefix(1)), highlight: 1), .desktop),
            ("02-four-highlight-ready", switcherModel(Array(all.prefix(4)), highlight: 3), .desktop),
            ("03-eight-highlight2", switcherModel(eight, highlight: 1), .desktop),
            ("04-eight-new", switcherModel(eight, highlight: 8), .desktop),
            ("05-bright-backdrop", switcherModel(Array(all.prefix(6)), highlight: 2), .bright),
        ]
        let looks = [Look.lightRT, .darkRT, Look(dark: false, reduceTransparency: true, increaseContrast: true),
                     Look(dark: true, reduceTransparency: true, increaseContrast: true),
                     Look(dark: true, reduceTransparency: true, reduceMotion: true)]
        for (name, model, backdrop) in cases {
            for look in looks {
                let room = 2 * SwitcherPanelLayout.shadowRoom
                let size = CGSize(width: SwitcherGeometry.stripWidth + room,
                                  height: SwitcherGeometry.stripHeight(sessions: model.tiles.count) + room)
                await Shot.take("switcher-\(name)", look, size: size, backdrop: backdrop) {
                    StripView(model: model, onEvent: { _ in })
                }
            }
        }
        // Every chip highlighted once, so each state's selected line shows.
        let size = CGSize(width: SwitcherGeometry.stripWidth + 2 * SwitcherPanelLayout.shadowRoom,
                          height: SwitcherGeometry.maxStripHeight + 2 * SwitcherPanelLayout.shadowRoom)
        for i in 0...eight.count {
            await Shot.take("switcher-06-highlight-\(i)", .darkRT, size: size, backdrop: .desktop) {
                StripView(model: switcherModel(eight, highlight: i), onEvent: { _ in })
            }
        }
    }

    // MARK: Unified surface (63-SWITCHER-UX): the pill row, and the strip grown out of it

    func pillModel(_ target: PillTarget, _ surface: OverlayModel.Surface, ready: Bool = true, level: Double = 0.6) -> OverlayModel {
        let m = OverlayModel()
        m.surface = surface
        m.pillTarget = target
        if case .session(let s) = target, let b = s.origin?.key.bundleID { m.pillTargetIcon = BuddyOverlayController.appIcon(b) }
        m.micReady = ready
        m.showsGettingReady = !ready
        m.mic.value = level
        return m
    }

    func pillRow(_ m: OverlayModel, t: Tokens) -> some View {
        PillContent(model: m, t: t)
            .modifier(SurfaceChrome(t: t, shape: Capsule(), rim: m.surface.isListening ? .listening(m.mic) : nil))
    }

    @Test func unifiedPill() async {
        let all = D.strip
        let rows: [(String, OverlayModel)] = [
            ("getting-ready", pillModel(.session(all[0]), .listening(hint: "tap ⌥ to send"), ready: false, level: 0)),
            ("listening", pillModel(.session(all[0]), .listening(hint: "tap ⌥ to send"))),
            ("listening-new", pillModel(.new, .listening(hint: "tap ⌥ to send"))),
            ("listening-none", pillModel(.none, .listening(hint: "tap ⌥ to send"))),
            ("thinking", pillModel(.session(all[2]), .thinking(Lane(mode: .quick, model: .haiku), status: "Searching the web for “TAP fares to Lisbon”"))),
        ]
        for (name, m) in rows {
            for look in Look.floating {
                await Shot.take("unified-pill-\(name)", look, size: CGSize(width: 560, height: 90), backdrop: .desktop) {
                    TokensReader { t in pillRow(m, t: t) }
                }
            }
        }
    }

    @Test func unifiedStrip() async {
        let eight = Array(D.studioSessions.prefix(8))
        for (name, atBottom, highlight, count) in [("top", false, 1, 8), ("top-plus", false, 8, 8), ("bottom", true, 1, 8),
                                                    ("top-two", false, 1, 2)] {
            let tiles = Array(eight.prefix(count))
            let model = switcherModel(tiles, highlight: highlight)
            let target: PillTarget = highlight < tiles.count ? .session(tiles[highlight]) : .new
            let pill = pillModel(target, .listening(hint: "release to send"))
            let width = SwitcherGeometry.stripWidth
            model.headerHeight = SwitcherGeometry.headerHeight
            model.headerAtBottom = atBottom
            model.plateWidth = width
            let room = SwitcherPanelLayout.shadowRoom
            let height = SwitcherGeometry.headerHeight + SwitcherGeometry.stripHeight(sessions: tiles.count) + 2 * room
            for look in [Look.lightRT, .darkRT, Look(dark: true, reduceTransparency: true, increaseContrast: true)] {
                await Shot.take("unified-strip-\(name)", look, size: CGSize(width: width + 2 * room, height: height), backdrop: .desktop) {
                    TokensReader { t in
                        ZStack(alignment: atBottom ? .bottom : .top) {
                            StripView(model: model, onEvent: { _ in })
                            // The overlay's pill, drawn over the header as it is on screen.
                            pillRow(pill, t: t)
                                .padding(atBottom ? .bottom : .top, room + SwitcherGeometry.headerInset)
                        }
                    }
                }
            }
        }
    }

    @Test func switcherPeek() async {
        let all = D.strip
        for (i, s) in all.enumerated() {
            for look in Look.floating {
                await Shot.take("peek-\(i)-\(s.id.rawValue)", look, size: CGSize(width: 360, height: 300), backdrop: .desktop) {
                    PeekView(model: switcherModel(all, highlight: i, peek: s), onEvent: { _ in })
                }
            }
        }
    }

    // MARK: Studio

    func studio(_ name: String, sessions: [SessionSnapshot], selection: StudioModel.Selection, inspector: StudioModel.InspectorTab? = nil,
                size: CGSize = CGSize(width: 1180, height: 780), looks: [Look] = [.light, .dark, .darkRT],
                transcripts: [SessionID: [TranscriptTurn]] = [:], details: [SessionID: SessionDetails] = [:],
                needsAttention: Bool = false, events: [SessionEvent] = [], prepare: ((NSView) async -> Void)? = nil) async {
        for look in looks {
            let source = FakeStudioSource(sessions)
            source.turns = transcripts
            source.detailsByID = details
            let model = StudioModel(source: source)
            model.selection = selection
            if let inspector {
                model.inspectorShown = true
                model.inspectorTab = inspector
            }
            let defaults = UserDefaults(suiteName: "qa.gallery.\(UUID().uuidString)")!
            let store = SettingsStore(defaults: defaults)
            let center: PermissionCenter? = needsAttention ? {
                let fake = GalleryPermissions()
                fake.states = [.screenRecording: .denied, .accessibility: .granted, .microphone: .granted, .inputMonitoring: .granted]
                return PermissionCenter(permissions: fake, launchedByLaunchServices: true, defaults: defaults, relaunch: {})
            }() : nil
            await Shot.take("studio-\(name)", look, size: size, prepare: { view in
                if case .session(let id) = selection {
                    for e in events { source.emit(e, to: id) }
                }
                await prepare?(view)
            }) {
                StudioView(model: model, store: store)
                    .environment(\.permissionCenter, center)
                    .environment(\.claudeCodeStatus, ClaudeCodeStatus())
            }
        }
    }

    @Test func studioHome() async {
        await studio("01-home-first-run", sessions: [], selection: .home, looks: [.light, .dark] + Look.all)
        await studio("02-home", sessions: D.studioSessions, selection: .home, looks: [.light, .dark] + Look.all)
        await studio("03-home-min-880", sessions: D.studioSessions, selection: .home, size: CGSize(width: 880, height: 560))
        await studio("04-home-needs-attention", sessions: D.studioSessions, selection: .home, needsAttention: true)
    }

    @Test func studioSession() async {
        let id = SessionID(rawValue: "s1")
        let details = SessionDetails(claudeSessionID: "0b9d6c1e-6f0a-4a43-9b5e-4c3a7f2e1d00", workingDirectory: "~/Finance/Q3",
                                     model: "claude-opus-5-5", permissionMode: "default",
                                     files: [URL(fileURLWithPath: "/tmp/budget-notes.md")],
                                     contexts: [.init(id: "c1", appName: "Numbers", title: "Q3 budget")], costUSD: 0.42)
        let live: [SessionEvent] = [
            .turnStarted(userUUID: "u2", kind: .typed),
            .step(TrailStep(id: "r1", kind: .read, verb: "Reading", object: "po-ledger.csv")),
            .text("Looking at April next.", subagent: nil),
        ]
        await studio("10-session", sessions: D.studioSessions, selection: .session(id), transcripts: [id: [D.historyTurn]],
                     events: live)
        for tab in StudioModel.InspectorTab.allCases {
            await studio("11-inspector-\(tab.rawValue)", sessions: D.studioSessions, selection: .session(SessionID(rawValue: "s3")),
                         inspector: tab, transcripts: [SessionID(rawValue: "s3"): [D.historyTurn]],
                         details: [SessionID(rawValue: "s3"): details])
        }
        await studio("12-session-long-title", sessions: D.studioSessions, selection: .session(SessionID(rawValue: "s9")),
                     transcripts: [SessionID(rawValue: "s9"): [D.historyTurn]])
        await studio("13-session-min-880", sessions: D.studioSessions, selection: .session(id), size: CGSize(width: 880, height: 560),
                     transcripts: [id: [D.historyTurn]])
    }

    @Test func studioSettings() async {
        for page in SettingsPage.allCases {
            await studio("20-settings-\(page.rawValue)", sessions: D.studioSessions, selection: .settings(page),
                         size: CGSize(width: 1180, height: 900), looks: page == .general ? [.light, .dark] + Look.all : [.light, .dark],
                         needsAttention: page == .permissions || page == .general)
        }
    }

    // MARK: Comfortable density page alone (Studio column)

    @Test func comfortablePage() async {
        for (name, page) in [("running", D.running()), ("approval", D.approval()), ("teammates", D.teammates()), ("done", D.done())] {
            await Shot.take("page-comfortable-\(name)", .lightRT, size: CGSize(width: 900, height: 760)) {
                ConversationPageView(model: D.model(page), density: .comfortable)
            }
        }
    }
}
