import BuddyCore
import Foundation

/// How one session looks on a chip, in the peek and to VoiceOver (63-SWITCHER-UX). The agent
/// mark's colour, glyph and orbit carry identity; its ring and one coloured status line carry
/// state, so colour is never the only signal. Pure, so it's tested without views.
nonisolated struct TileLook: Sendable, Equatable {
    enum Ring: Sendable, Equatable {
        case none
        /// A 90° ember arc turning once every 1.2 s (static with Reduce Motion).
        case comet
        /// A determinate ember arc, 0…1.
        case progress(Double)
        /// Amber full ring, breathing 0.55↔1 over 1.6 s (steady with Reduce Motion).
        case needsYou
        /// Rose full ring, static.
        case failed
    }

    enum Tone: Sendable, Equatable { case secondary, ember, amber, rose, sage }

    var ring: Ring
    /// The peek's state: "Running · 3m", "Needs your OK", "Ready · 2m ago", "Done · 40m ago".
    var status: String
    /// Every tile's state word: "Running", "Needs you", "Ready", "Didn't finish"; nil at rest.
    var word: String?
    /// The selected chip's line: the live step while running, else `status`.
    var detail: String
    var tone: Tone
    /// The glyph dims once a session has rested for 2 h: 100% or 60%.
    var opacity: Double
    /// The title's first letter, for a session without a usable symbol.
    var monogram: String
    /// "Trip to Lisbon, from Safari, running, 3 minutes. 2 teammates."
    var accessibilityLabel: String

    static func make(_ s: SessionSnapshot, now: Date) -> TileLook {
        let touched = max(s.lastUsed, s.finishedAt ?? s.lastUsed)
        let age = now.timeIntervalSince(touched)
        var ring = Ring.none
        var word: String?
        var tone = Tone.secondary
        var opacity = s.pinned ? 1 : fade(age: age)
        let status: String
        let spoken: String
        switch s.status {
        case .thinking(let since, let progress):
            opacity = 1
            tone = .ember
            word = "Running"
            if let progress, progress.total > 0 {
                ring = .progress(min(1, max(0, Double(progress.done) / Double(progress.total))))
                status = "Step \(progress.done) of \(progress.total)"
                spoken = "running, step \(progress.done) of \(progress.total)"
            } else {
                ring = .comet
                let ran = short(now.timeIntervalSince(since))
                status = ran == "now" ? "Running" : "Running · " + ran
                spoken = "running, " + long(now.timeIntervalSince(since))
            }
        case .needsYou(let needs) where needs.seen:
            // Seen: it waits on its card, with no more amber.
            opacity = 1
            ring = .comet
            tone = .ember
            word = "Running"
            status = TrailCopy.waitingForYou
            spoken = status.lowercased()
        case .needsYou(let needs):
            opacity = 1
            ring = .needsYou
            tone = .amber
            word = "Needs you"
            if case .permission = needs.kind {
                status = "Needs your OK"
            } else {
                status = "Has a question"
            }
            spoken = status.lowercased()
        case .done(let at, unread: true) where now.timeIntervalSince(at) < unseenFor:
            opacity = 1
            word = "Ready"
            tone = .sage
            status = "Ready · " + ago(now.timeIntervalSince(at))
            spoken = "ready, not seen yet"
        case .failed:
            ring = .failed
            tone = .rose
            word = "Didn't finish"
            status = "Didn't finish"
            spoken = "didn't finish"
        case .interrupted:
            tone = .rose
            word = "Interrupted"
            status = "Interrupted"
            spoken = "interrupted"
        case .idle where s.turns == 0:
            status = "New"
            spoken = "new"
        case .idle, .done:
            // Since it finished, when known.
            var since = age
            if case .done(let at, _) = s.status { since = now.timeIntervalSince(at) }
            let when = ago(since)
            status = when == "now" ? "Done" : "Done · " + when
            spoken = "done " + (when == "now" ? "just now" : long(since) + " ago")
        }
        // The selected chip: the live step while running, else the status.
        var detail = status
        if case .thinking = s.status, let live = s.liveLine, !live.isEmpty { detail = live }
        var label = s.title
        if let app = s.origin?.appName, !app.isEmpty { label += ", from \(app)" }
        label += ", \(spoken)."
        if !s.liveTeam.isEmpty {
            label += s.liveTeam.count == 1 ? " 1 teammate." : " \(s.liveTeam.count) teammates."
        }
        if s.pinned { label += " Pinned." }
        return TileLook(
            ring: ring, status: status, word: word, detail: detail, tone: tone, opacity: opacity,
            monogram: s.title.first.map { String($0).uppercased() } ?? "·", accessibilityLabel: label)
    }

    /// The chip's one state line: its status ("Running · 3m", "Done · 10h ago"), or on the
    /// selected chip the detail (the live step while running).
    func line(selected: Bool) -> String { selected ? detail : status }

    /// The count line beside the pill: how many run, need the user, or are ready to read.
    static func counts(_ tiles: [SessionSnapshot], now: Date) -> [(text: String, tone: Tone)] {
        // From each tile's look, so the line always agrees with the tiles.
        var running = 0, needs = 0, ready = 0
        for s in tiles {
            switch make(s, now: now).tone {
            case .ember: running += 1
            case .amber: needs += 1
            case .sage: ready += 1
            case .secondary, .rose: break
            }
        }
        return [("\(running) running", Tone.ember, running), ("\(needs) needs you", .amber, needs), ("\(ready) ready", .sage, ready)]
            .filter { $0.2 > 0 }.map { ($0.0, $0.1) }
    }

    /// The peek's line: the live step while running, the waiting ask, else the last answer's
    /// `say` (the live line before the first answer). Plain text: model-written asks and answers
    /// lose their Markdown marks (`MarkdownPreview`).
    static func peekLine(_ s: SessionSnapshot) -> String {
        MarkdownPreview.line(rawPeekLine(s))
    }

    private static func rawPeekLine(_ s: SessionSnapshot) -> String {
        switch s.status {
        case .needsYou(let needs):
            switch needs.kind {
            case .permission(let ask): return ask.title
            case .question(let ask): return ask.items.first?.question ?? "Has a question"
            case .soft(let text): return text
            }
        case .failed(let failure):
            return failure.lastStep.map { "Couldn't finish: \($0)" } ?? "Didn't finish"
        case .thinking:
            return s.liveLine ?? s.lastSay ?? ""
        case .idle, .done, .interrupted:
            return s.lastSay ?? s.liveLine ?? ""
        }
    }

    // MARK: -

    static let recentFor: TimeInterval = 2 * 3600
    static let unseenFor: TimeInterval = 4 * 3600

    static func fade(age: TimeInterval) -> Double { age < recentFor ? 1 : 0.6 }

    /// "now", "3m", "2h", "4d".
    static func short(_ t: TimeInterval) -> String {
        let m = Int(max(0, t) / 60)
        if m < 1 { return "now" }
        if m < 60 { return "\(m)m" }
        if m < 24 * 60 { return "\(m / 60)h" }
        return "\(m / (24 * 60))d"
    }

    /// "now", "3m ago".
    static func ago(_ t: TimeInterval) -> String {
        let s = short(t)
        return s == "now" ? s : s + " ago"
    }

    static func long(_ t: TimeInterval) -> String {
        let m = Int(max(0, t) / 60)
        func n(_ v: Int, _ unit: String) -> String { v == 1 ? "1 \(unit)" : "\(v) \(unit)s" }
        if m < 1 { return "under a minute" }
        if m < 60 { return n(m, "minute") }
        if m < 24 * 60 { return n(m / 60, "hour") }
        return n(m / (24 * 60), "day")
    }
}
