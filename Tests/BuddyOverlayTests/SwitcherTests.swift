import AppKit
import BuddyCore
import Foundation
import SwiftUI
import Testing
@testable import BuddyOverlay

nonisolated private let now = Date(timeIntervalSince1970: 1_760_000_000)
private func snap(
    _ id: String, _ status: SessionStatus = .idle, used: Date = now, title: String = "Trip to Lisbon",
    app: String? = nil, teammates: Int = 0, pinned: Bool = false
) -> SessionSnapshot {
    let mates = (0..<teammates).map { TeammateSnapshot(id: "t\($0)", toolUseID: "u\($0)", name: "Scout \($0)", state: .working) }
    return SessionSnapshot(
        id: SessionID(rawValue: id), title: title, color: .sage,
        origin: app.map { SessionOrigin(key: ContextKey(bundleID: "com.example.\($0)"), appName: $0) }, harness: .open,
        status: status, teammates: mates, pinned: pinned, lastUsed: used)
}

@Suite("Switcher · geometry")
struct SwitcherGeometryTests {
    @Test("the grid: three chips across, New after the last session, 1–3 rows")
    func grid() {
        let g = SwitcherGeometry.self
        #expect(g.stripWidth == 616)
        #expect(g.rows(sessions: 0) == 1 && g.rows(sessions: 2) == 1 && g.rows(sessions: 3) == 2 && g.rows(sessions: 8) == 3)
        #expect(g.stripHeight(sessions: 1) == g.paddingY + g.chipHeight + g.footerHeight)
        #expect(g.maxStripHeight == g.paddingY + 3 * g.chipHeight + 2 * g.gap + g.footerHeight)
        #expect(g.tileFrame(0) == CGRect(x: 10, y: 8, width: 196, height: 48))
        #expect(g.tileFrame(2).maxX == g.stripWidth - g.paddingX)
        #expect(g.tileFrame(3) == CGRect(x: 10, y: 60, width: 196, height: 48))
        #expect(g.tileFrame(8).maxY == g.maxStripHeight - g.footerHeight) // New, after 8 sessions
    }

    @Test("without a pill: top centre of the visible frame, clamped to narrow screens")
    func placement() {
        let screen = CGRect(x: 0, y: 80, width: 1440, height: 800)
        let h = SwitcherGeometry.stripHeight(sessions: 6)
        #expect(SwitcherGeometry.stripFrame(sessions: 6, in: screen) == CGRect(x: 412, y: 864 - h, width: 616, height: h))
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1050)
        #expect(SwitcherGeometry.stripFrame(sessions: 6, in: second).midX == second.midX)
        let tiny = CGRect(x: 0, y: 0, width: 500, height: 400)
        #expect(SwitcherGeometry.stripFrame(sessions: 6, in: tiny).width == 468)
    }

    @Test("around the pill: its row is the header, the chips grow down (up for a pill at the bottom), as wide as the chips")
    func aroundThePill() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 920)
        let pill = CGRect(x: 600, y: 872, width: 270, height: 36)  // top centre, AppKit space
        let plate = SwitcherGeometry.plateFrame(around: pill, sessions: 5, atBottom: false, in: screen)
        #expect(plate.midX == pill.midX)
        #expect(plate.maxY == pill.maxY + SwitcherGeometry.headerInset)
        #expect(plate.width == SwitcherGeometry.stripWidth)
        #expect(plate.height == pill.height + 2 * SwitcherGeometry.headerInset + SwitcherGeometry.stripHeight(sessions: 5))
        let low = CGRect(x: 600, y: 12, width: 270, height: 36)
        let up = SwitcherGeometry.plateFrame(around: low, sessions: 5, atBottom: true, in: screen)
        #expect(up.minY == low.minY - SwitcherGeometry.headerInset)
        // One session: one short row, no wider than the chips.
        let one = SwitcherGeometry.plateFrame(around: pill, sessions: 1, atBottom: false, in: screen)
        #expect(one.width == SwitcherGeometry.stripWidth && one.height < plate.height)
        // A pill wider than the chips: the plate grows to hold it.
        let wide = SwitcherGeometry.plateFrame(around: CGRect(x: 300, y: 872, width: 700, height: 36), sessions: 1,
                                               atBottom: false, in: screen)
        #expect(wide.width == 700 + 2 * SwitcherGeometry.paddingX)
        // A pill dragged to the edge: the plate stays on screen.
        let edge = SwitcherGeometry.plateFrame(around: CGRect(x: 1300, y: 872, width: 160, height: 36), sessions: 5,
                                               atBottom: false, in: screen)
        #expect(edge.maxX == screen.maxX - SwitcherGeometry.screenMargin)
    }

    @Test("peek above its tile, below when there is no room, clamped to the screen")
    func peek() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 300, height: 150)
        let tile = CGRect(x: 100, y: 80, width: 76, height: 96)
        #expect(SwitcherGeometry.peekFrame(size: size, anchor: tile, screen: screen) == CGRect(x: 16, y: 188, width: 300, height: 150))
        let high = CGRect(x: 900, y: 770, width: 30, height: 16)
        let below = SwitcherGeometry.peekFrame(size: size, anchor: high, screen: screen)
        #expect(below.maxY == high.minY - 12)
        #expect(below.maxX == 984)
    }
}

@Suite("Switcher · tile look")
struct TileLookTests {
    private let permission = PermissionAsk(id: "r1", title: "Edit AuthSession.swift", toolName: "Edit",
                                           detail: .plain("x"), tier: .reversible)

    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        var status: SessionStatus
        var ring: TileLook.Ring
        var text: String
        var word: String?
        var tone: TileLook.Tone
        var testDescription: String { text }
    }

    nonisolated static let cases: [Case] = [
        Case(status: .thinking(since: now.addingTimeInterval(-180), progress: nil), ring: .comet, text: "Running · 3m", word: "Running", tone: .ember),
        Case(status: .thinking(since: now, progress: StepProgress(done: 3, total: 5)), ring: .progress(0.6), text: "Step 3 of 5", word: "Running", tone: .ember),
        Case(status: .thinking(since: now, progress: nil), ring: .comet, text: "Running", word: "Running", tone: .ember),
        Case(status: .done(at: now.addingTimeInterval(-120), unread: true), ring: .none, text: "Ready · 2m ago", word: "Ready", tone: .sage),
        Case(status: .done(at: now.addingTimeInterval(-2400), unread: false), ring: .none, text: "Done · 40m ago", word: nil, tone: .secondary),
        Case(status: .failed(SessionFailure(reason: .crashed, retryable: true)), ring: .failed, text: "Didn't finish", word: "Didn't finish", tone: .rose),
        Case(status: .interrupted(at: now), ring: .none, text: "Interrupted", word: "Interrupted", tone: .rose),
        // A seen ask still waits on its card, with no amber (owner, Oct 29).
        Case(status: .needsYou(NeedsYou(kind: .soft("Which?"), since: now, seen: true)), ring: .comet, text: "Waiting for you",
             word: "Running", tone: .ember),
    ]

    @Test("state → ring, status, word, tone", arguments: cases)
    func states(c: Case) {
        let s = SessionSnapshot(id: SessionID(rawValue: "a"), title: "Q3 burn model", color: .ember, harness: .open,
                                status: c.status, lastUsed: now.addingTimeInterval(-2400), turns: 2)
        let look = TileLook.make(s, now: now)
        #expect(look.ring == c.ring)
        #expect(look.status == c.text)
        #expect(look.word == c.word)
        #expect(look.tone == c.tone)
    }

    @Test("chip line: every chip says its state and age; the selected one the live step")
    func lines() {
        var running = snap("a", .thinking(since: now.addingTimeInterval(-180), progress: nil))
        running.liveLine = "Comparing 4 hotels"
        let look = TileLook.make(running, now: now)
        #expect(look.line(selected: false) == "Running · 3m")
        #expect(look.line(selected: true) == "Comparing 4 hotels")
        let asked = TileLook.make(snap("b", .needsYou(NeedsYou(kind: .permission(permission), since: now))), now: now)
        #expect(asked.line(selected: false) == "Needs your OK")
        #expect(asked.line(selected: true) == "Needs your OK")
        var done = snap("c", .done(at: now.addingTimeInterval(-600), unread: false))
        done.turns = 1
        let rest = TileLook.make(done, now: now)
        #expect(rest.line(selected: false) == "Done · 10m ago")
        #expect(rest.line(selected: true) == "Done · 10m ago")
        #expect(TileLook.make(snap("d"), now: now).status == "New") // no turns yet
    }

    @Test("count line: running, needs you, ready; nothing at rest")
    func counts() {
        let tiles = [snap("a", .thinking(since: now, progress: nil)), snap("b", .thinking(since: now, progress: nil)),
                     snap("c", .needsYou(NeedsYou(kind: .permission(permission), since: now))),
                     snap("d", .done(at: now, unread: true)), snap("e")]
        #expect(TileLook.counts(tiles, now: now).map(\.text) == ["2 running", "1 needs you", "1 ready"])
        #expect(TileLook.counts([snap("e")], now: now).isEmpty)
    }

    @Test("needs-you: amber ring, permission vs question wording, peek line is the ask")
    func needsYou() {
        let asked = snap("a", .needsYou(NeedsYou(kind: .permission(permission), since: now)))
        #expect(TileLook.make(asked, now: now).ring == .needsYou)
        #expect(TileLook.make(asked, now: now).status == "Needs your OK")
        #expect(TileLook.peekLine(asked) == "Edit AuthSession.swift")
        let soft = snap("b", .needsYou(NeedsYou(kind: .soft("Which hotel?"), since: now)))
        #expect(TileLook.make(soft, now: now).status == "Has a question")
        #expect(TileLook.peekLine(soft) == "Which hotel?")
    }

    @Test("peek: Stop on a running turn; Allow/Deny instead for a permission; none once it's over (V-15)")
    func peekStop() {
        #expect(PeekCardView.canStop(snap("a", .thinking(since: now, progress: nil))))
        #expect(!PeekCardView.canStop(snap("b", .needsYou(NeedsYou(kind: .permission(permission), since: now)))))
        #expect(!PeekCardView.canStop(snap("c", .needsYou(NeedsYou(kind: .soft("Which hotel?"), since: now)))))
        #expect(!PeekCardView.canStop(snap("d", .done(at: now, unread: true))))
        #expect(!PeekCardView.canStop(snap("e")))
    }

    @Test("peek line: the live step while running, else the last answer's say")
    func peekLine() {
        var s = snap("a", .done(at: now, unread: true))
        s.liveLine = "Reading 4 files"
        #expect(TileLook.peekLine(s) == "Reading 4 files") // no answer yet
        s.lastSay = "Draft ready: three short paragraphs."
        #expect(TileLook.peekLine(s) == "Draft ready: three short paragraphs.")
        s.status = .thinking(since: now, progress: nil)
        #expect(TileLook.peekLine(s) == "Reading 4 files")
        s.liveLine = nil
        #expect(TileLook.peekLine(s) == "Draft ready: three short paragraphs.")
    }

    @Test("fade by age: full, then 60% past 2 h; live and pinned stay full", arguments: [
        (10.0, 1.0), (60, 1), (180, 0.6), (420, 0.6),
    ])
    func fade(minutes: Double, opacity: Double) {
        let s = snap("a", used: now.addingTimeInterval(-minutes * 60))
        #expect(TileLook.make(s, now: now).opacity == opacity)
        #expect(TileLook.make(snap("p", used: now.addingTimeInterval(-minutes * 60), pinned: true), now: now).opacity == 1)
        let running = snap("r", .thinking(since: now, progress: nil), used: now.addingTimeInterval(-minutes * 60))
        #expect(TileLook.make(running, now: now).opacity == 1)
    }

    @Test("VoiceOver label: title, origin, state, teammates")
    func label() {
        let s = snap("a", .thinking(since: now.addingTimeInterval(-180), progress: nil), app: "Safari", teammates: 2)
        #expect(TileLook.make(s, now: now).accessibilityLabel == "Trip to Lisbon, from Safari, running, 3 minutes. 2 teammates.")
        #expect(TileLook.make(snap("b", title: "lecture notes"), now: now).monogram == "L")
    }

    @Test("short ages", arguments: [(TimeInterval(30), "now"), (TimeInterval(59 * 60), "59m"), (TimeInterval(3 * 3600), "3h"), (TimeInterval(50 * 3600), "2d")])
    func ages(seconds: TimeInterval, text: String) {
        #expect(TileLook.short(seconds) == text)
    }
}

@MainActor
@Suite("Switcher · live strip")
struct LiveSwitcherTests {
    @Test("prepare builds hidden; open flips to visible; Tab moves; refresh keeps order; close hides", .overlayExclusive)
    func lifecycle() async throws {
        let switcher = LiveSwitcher()
        let tiles = (0..<8).map { snap("s\($0)", used: now.addingTimeInterval(Double(-$0) * 60), title: "Session \($0)") }
        switcher.prepare(tiles: tiles)
        #expect(!switcher.model.isOpen)
        switcher.open(highlight: 1)
        #expect(switcher.model.isOpen)
        #expect(switcher.model.highlight == 1)
        switcher.move(to: 7)
        #expect(switcher.model.highlight == 7)
        switcher.move(to: 99)
        #expect(switcher.model.highlight == 8) // New
        var latest = tiles
        latest[3].status = .thinking(since: now, progress: nil)
        latest[5].archived = true
        latest.remove(at: 7)
        switcher.refresh(latest.reversed())
        #expect(switcher.model.tiles.map(\.id.rawValue) == ["s0", "s1", "s2", "s3", "s4", "s6"])
        #expect(switcher.model.tiles[3].status == .thinking(since: now, progress: nil))
        #expect(switcher.model.highlight == 6) // New follows the shorter strip
        switcher.close(commit: false)
        #expect(!switcher.model.isOpen)
    }

    /// The main-thread work Tab costs once the strip is prepared (budget 16.7 ms p95): `open` plus
    /// the window's display pass that frame would flush, with a sessions change landing between
    /// the press and the Tab (U65: 3 of 74 live opens ran 19–35 ms). Wall time to the render
    /// server's commit depends on machine load, so it's only checked to arrive; the app records
    /// the real Tab → frame time as `.switcherShown`.
    @Test("Tab after prepare and a sessions change: open plus its display pass within budget (p95 ≤ 16.7 ms), frame reported",
          .overlayExclusive)
    func openBudget() async throws {
        let switcher = LiveSwitcher()
        let tiles = (0..<7).map { snap("s\($0)", .thinking(since: now, progress: nil), used: now, title: "Session \($0)") }
        var samples: [Duration] = []
        let clock = ContinuousClock()
        for i in 0..<20 {
            switcher.prepare(tiles: tiles)
            let pressedAt = switcher.model.now
            var changed = tiles
            changed[i % 7].status = .done(at: now, unread: true)
            switcher.refresh(changed)
            #expect(switcher.model.now == pressedAt, "a sessions change keeps the press's ages (no full redraw)")
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                switcher.onShown = { c.resume() }
                let start = clock.now
                switcher.open(highlight: 1)
                switcher.stripPanel.displayIfNeeded()
                samples.append(clock.now - start)
            }
            switcher.close(commit: false)
        }
        samples.sort()
        let p95: Duration = samples[Int(Double(samples.count - 1) * 0.95)]
        let budget: Duration = .microseconds(16_700)
        #expect(p95 <= budget)
    }

    /// Owner, Oct 29: on Option+Tab the pill hid behind the strip, leaving an empty header row.
    /// `isFloatingPanel = true` had reset both panels to `.floating`, so the strip (ordered in at
    /// the press) covered the pill.
    @Test("levels: overlay ≥ peek > strip > Panel, all under pop-up menus", .overlayExclusive)
    func windowLevels() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let overlay = OverlayPanel(screen: screen, displayID: 0, root: Color.clear)
        let strip = SwitcherPanel(Color.clear, level: SwitcherPanel.stripLevel)
        let peek = SwitcherPanel(Color.clear)
        let panel = ConversationPanel(root: Color.clear)
        defer { [overlay, strip, peek, panel].forEach { $0.close() } }
        #expect(overlay.isFloatingPanel && strip.isFloatingPanel)
        // pill/overlay ≥ peek > strip > Panel and other floating windows; all below pop-up menus.
        #expect(overlay.level == .statusBar)
        #expect(overlay.level.rawValue >= peek.level.rawValue && peek.level.rawValue > strip.level.rawValue)
        #expect(strip.level.rawValue > panel.level.rawValue && panel.level.rawValue >= NSWindow.Level.floating.rawValue)
        for window in [overlay, strip, peek] as [NSPanel] {
            #expect(window.level.rawValue < NSWindow.Level.popUpMenu.rawValue, "never over a menu")
        }
    }

    @Test("the pill sits exactly in the strip's header row, top and bottom, even if it moved after the press; no pill, no row",
          .overlayExclusive)
    func pillFillsTheHeader() throws {
        let switcher = LiveSwitcher()
        let tiles = (0..<4).map { snap("s\($0)", title: "Session \($0)") }
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first).visibleFrame
        var pill: (frame: CGRect, atBottom: Bool)? = (CGRect(x: screen.midX - 100, y: screen.maxY - 50, width: 200, height: 36), false)
        switcher.pillAnchor = { pill }
        func check(_ label: String) {
            guard let p = pill, let row = switcher.headerRow else { Issue.record("no header row, \(label)"); return }
            #expect(row.contains(p.frame), "\(label): pill \(p.frame) outside the header \(row)")
            #expect(row.height == p.frame.height + 2 * SwitcherGeometry.headerInset, "\(label): nothing reserved beyond the pill")
            #expect(row.midY == p.frame.midY && row.midX == p.frame.midX, "\(label)")
            #expect(p.atBottom ? row.minY == switcher.plate.minY : row.maxY == switcher.plate.maxY, "\(label): the row is the plate's edge")
        }
        switcher.prepare(tiles: tiles)
        switcher.open(highlight: 1)
        check("top")
        switcher.close(commit: false)
        // Prepared around the pill, which then grew (thinking) and moved before the Tab.
        switcher.prepare(tiles: tiles)
        pill = (CGRect(x: screen.midX - 150, y: screen.maxY - 60, width: 300, height: 44), false)
        switcher.open(highlight: 1)
        check("moved")
        switcher.close(commit: false)
        pill = (CGRect(x: screen.midX - 100, y: screen.minY + 20, width: 200, height: 36), true)
        switcher.prepare(tiles: tiles)
        switcher.open(highlight: 1)
        check("bottom")
        switcher.close(commit: false)
        // The pill went before the Tab: no header row is kept for it.
        switcher.prepare(tiles: tiles)
        pill = nil
        switcher.open(highlight: 1)
        #expect(switcher.headerRow == nil && switcher.model.headerHeight == 0)
        switcher.close(commit: false)
    }

    @Test("the peek fills the model; nil hides", .overlayExclusive)
    func surfaces() async throws {
        let switcher = LiveSwitcher()
        let s = snap("a", .thinking(since: now, progress: nil))
        switcher.refresh([s])
        switcher.peek(s.id)
        #expect(switcher.model.peek?.id == s.id)
        #expect(!switcher.model.peekShowsKeys)
        switcher.peek(nil)
        #expect(switcher.model.peek == nil)
    }
}

@Suite("Switcher · contrast (QA U4)")
struct SwitcherContrastTests {
    nonisolated static let variants: [Tokens.Variant] = [false, true].flatMap { dark in
        [(false, false), (true, false), (false, true)].map {
            Tokens.Variant(dark: dark, reduceTransparency: $0.0, increaseContrast: $0.1)
        }
    }
    nonisolated static let backdrops = [TokenColor(1, 1, 1), TokenColor(0, 0, 0)]

    @Test("text ≥ 4.5:1 and rings ≥ 3:1 on the reading well, light and dark, over white and black")
    func ratios() {
        for v in Self.variants {
            let t = Tokens(v)
            for backdrop in Self.backdrops {
                let well = SwitcherSurface.over(SwitcherSurface.well(t), backdrop)
                let selected = SwitcherSurface.over(SwitcherSurface.selection(t), well)
                for (name, color) in SwitcherSurface.textColors(t) {
                    let onWell = SwitcherSurface.contrast(color, well)
                    let onSelected = SwitcherSurface.contrast(color, selected)
                    #expect(onWell >= 4.5, "\(name) \(v) over \(backdrop): \(onWell)")
                    #expect(onSelected >= 4.5, "\(name) selected \(v) over \(backdrop): \(onSelected)")
                }
                for (name, color) in SwitcherSurface.ringColors(t) {
                    let ratio = SwitcherSurface.contrast(color, well)
                    #expect(ratio >= 3, "ring \(name) \(v) over \(backdrop): \(ratio)")
                }
                for (name, color) in SwitcherSurface.ringColors(t) {
                    let ratio = SwitcherSurface.contrast(color, selected)
                    #expect(ratio >= 3, "dot \(name) selected \(v) over \(backdrop): \(ratio)")
                }
            }
        }
    }

    @Test("the reading well is opaque, so the backdrop can't lower it")
    func opaqueWell() {
        for v in Self.variants { #expect(SwitcherSurface.well(Tokens(v)).alpha == 1) }
    }

    @Test("WCAG math: black on white is 21:1, a colour on itself 1:1")
    func math() {
        #expect(abs(SwitcherSurface.contrast(TokenColor(0, 0, 0), TokenColor(1, 1, 1)) - 21) < 0.01)
        #expect(SwitcherSurface.contrast(TokenColor(hex: 0x7FD1A8), TokenColor(hex: 0x7FD1A8)) == 1)
    }
}

@MainActor
@Suite("Switcher · chip (QA U5, U26)")
struct TileTitleTests {
    private func chipHeight(_ s: SessionSnapshot, selected: Bool) -> CGFloat {
        let t = Tokens(.init(dark: false))
        let view = TileView(session: s, look: TileLook.make(s, now: now), selected: selected, icon: nil, animating: false, t: t)
        return NSHostingView(rootView: view).fittingSize.height
    }

    @Test("every chip is the same height, selected or not, and its two lines fit")
    func fits() {
        let long = SessionSnapshot(id: SessionID(rawValue: "a"), title: "Competitor pricing scan and the renewals",
                                   color: .amber, harness: .open, status: .interrupted(at: now), lastUsed: now)
        let g = SwitcherGeometry.self
        #expect(chipHeight(long, selected: false) == g.chipHeight)
        #expect(chipHeight(long, selected: true) == g.chipHeight)
        let lines = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 12, weight: .semibold))
            + NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 10.5, weight: .semibold)) + 1
        #expect(lines <= g.chipHeight - 8)
        #expect(g.markSize * g.selectedScale <= g.chipHeight - 4)
    }
}

@Suite("Switcher · peek text")
struct PeekTextTests {
    @Test("the peek's line is plain text: no raw Markdown from the answer or the ask (U49)")
    func peekLineIsPlain() {
        var s = snap("a")
        s.lastSay = SessionSnapshot.lastSay(say: nil, markdown: #"I took "Beautypass" to mean **Budapest**."#)
        #expect(TileLook.peekLine(s) == #"I took "Beautypass" to mean Budapest."#)
        // A soft ask written by the model.
        let soft = snap("b", .needsYou(NeedsYou(kind: .soft("Pick `main` or **dev**?"), since: now)))
        #expect(TileLook.peekLine(soft) == "Pick main or dev?")
    }

    @Test("the peek is as tall as its card: a longer line or teammates grow it, never cut it off")
    func peekSizeFollowsItsContent() {
        let switcher = LiveSwitcher()
        var short = snap("a")
        short.lastSay = "Three days."
        var long = short
        long.lastSay = String(repeating: "A longer answer that wraps. ", count: 6)
        let one = switcher.peekCardSize(short), four = switcher.peekCardSize(long)
        #expect(one.width == SwitcherGeometry.peekWidth)
        #expect(four.height >= one.height + 40)  // more lines, all shown
        #expect(switcher.peekCardSize(snap("c", teammates: 3)).height > switcher.peekCardSize(snap("c")).height)
    }
}
