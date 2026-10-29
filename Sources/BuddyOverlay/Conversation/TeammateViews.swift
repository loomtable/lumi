import BuddyCore
import SwiftUI

/// The session's agent mark with its teammates' status beads on a fixed lower arc (04 §5.1).
/// Eyeless: neither the mark nor the beads ever has a face, so there's one Lumi on screen.
/// Beads don't orbit.
public struct SessionDisc: View {
    let id: SessionID
    let symbol: String?
    let color: ConversationColor
    let teammates: [TeammateSnapshot]
    let working: Bool
    let needsYou: Bool
    /// 24 in the Panel header, 40 in the Studio's.
    let size: CGFloat
    /// The session's title, for VoiceOver.
    let title: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(id: SessionID, symbol: String?, color: ConversationColor, teammates: [TeammateSnapshot], working: Bool,
                needsYou: Bool, size: CGFloat = 24, title: String? = nil) {
        self.id = id
        self.symbol = symbol
        self.color = color
        self.teammates = teammates
        self.working = working
        self.needsYou = needsYou
        self.size = size
        self.title = title
    }

    public var body: some View {
        TokensReader { t in
            let bead: CGFloat = size >= 40 ? 10 : 7
            let radius: CGFloat = size >= 40 ? 30 : 19
            let frame = Self.slotWidth(size: size)
            ZStack {
                AgentMark(id: id, title: title ?? "", symbol: symbol, color: color, working: working, needsYou: needsYou,
                          size: size)
                ForEach(Array(Self.beads(teammates).enumerated()), id: \.offset) { i, b in
                    let angle = Angle.degrees(200 + 35 * Double(i))
                    BeadView(state: b.state, overflow: b.overflow, size: bead, t: t)
                        .offset(x: radius * CGFloat(cos(angle.radians)), y: -radius * CGFloat(sin(angle.radians)))
                        // Spawn pops out of the disc; the fold goes back into it (04 §5.3).
                        .transition(Motion.transition(scale: 0.4, reduceMotion: reduceMotion))
                }
            }
            .animation(Motion.animation(Motion.pop, reduceMotion: reduceMotion), value: teammates.count)
            .animation(Motion.quick, value: teammates.map(\.state))
            .frame(width: teammates.isEmpty ? size : frame, height: teammates.isEmpty ? size : frame)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(title: title, working: working, needsYou: needsYou, teammates: teammates))
        }
    }

    /// "Fix login, needs you, with Writer working and Scout done" (QA U17): the title, the state
    /// and every bead, since the beads aren't elements of their own.
    static func spoken(title: String?, working: Bool, needsYou: Bool, teammates: [TeammateSnapshot]) -> String {
        var parts = [title.flatMap { $0.isEmpty ? nil : $0 } ?? "Session"]
        if needsYou { parts.append("needs you") } else if working { parts.append("working") }
        let mates = teammates.map { "\($0.name) \($0.state.label)" }
        if !mates.isEmpty {
            let list = mates.count == 1 ? mates[0] : mates.dropLast().joined(separator: ", ") + " and " + mates.last!
            parts.append("with " + list)
        }
        return parts.joined(separator: ", ")
    }

    /// The disc's frame once it has beads; a fixed slot of this width keeps a header's title from
    /// moving when teammates appear (QA U39).
    public static func slotWidth(size: CGFloat) -> CGFloat {
        let bead: CGFloat = size >= 40 ? 10 : 7
        let radius: CGFloat = size >= 40 ? 30 : 19
        return (radius + bead) * 2
    }

    /// Up to 5 beads; a 6th and beyond collapse into "+N".
    static func beads(_ mates: [TeammateSnapshot]) -> [(state: TeammateSnapshot.State, overflow: Int?)] {
        if mates.count <= 5 { return mates.map { ($0.state, nil) } }
        return mates.prefix(4).map { ($0.state, nil) } + [(.working, mates.count - 4)]
    }
}

/// An eyeless status bead: a 1.5 pt rim in the status colour over a 30% tint.
struct BeadView: View {
    let state: TeammateSnapshot.State
    var overflow: Int?
    let size: CGFloat
    let t: Tokens

    var body: some View {
        let c = state.color(t)
        ZStack {
            Circle().fill(c.opacity(0.3).color)
            Circle().strokeBorder(c.color, lineWidth: 1.5)
            if let overflow {
                Text("+\(overflow)").font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(t.text.color).fixedSize()
            }
        }
        .frame(width: size, height: size)
        .opacity(state == .stopped ? 0.5 : state == .done ? 0.8 : 1)
    }
}

extension TeammateSnapshot.State {
    public func color(_ t: Tokens) -> TokenColor {
        switch self {
        case .working: t.emberMark
        case .needsYou: t.amber
        case .done: t.sage
        case .failed: t.rose
        case .stopped: t.mist
        }
    }

    /// Colour is never the only signal (04 §8).
    public var glyph: String {
        switch self {
        case .working: "ellipsis"
        case .needsYou: "exclamationmark"
        case .done: "checkmark"
        case .failed: "xmark"
        case .stopped: "stop.fill"
        }
    }

    public var label: String {
        switch self {
        case .working: "working"
        case .needsYou: "needs you"
        case .done: "done"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }

}

/// The roster lane (04 §5.1): "2 of 3 done", then one chip per teammate in the order they
/// started: bead, glyph, name, its current step, steps so far and time. A chip keeps its place
/// and its width from start to end, so nothing jumps or vanishes mid-run; the line changes at
/// most four times a second. The caller shows the lane while the team is live and tucks it away
/// once the lead has answered after it. A click opens the teammate's lane.
public struct TeamLane: View {
    let team: [TeammateSnapshot]
    let selected: String?
    let onSelect: (TeammateSnapshot) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(team: [TeammateSnapshot], selected: String? = nil, onSelect: @escaping (TeammateSnapshot) -> Void) {
        self.team = team
        self.selected = selected
        self.onSelect = onSelect
    }

    /// The chips' own side inset.
    public static let inset: CGFloat = 14

    /// The step line's fixed width: a new step never moves the chips after it.
    static let lineWidth: CGFloat = 150

    public var body: some View {
        TokensReader { t in
            // Elapsed times tick each second while a teammate works; a finished lane never ticks.
            TimelineView(WorkingClock(running: team.contains { $0.state.isRunning })) { context in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        if let summary = TeamRoster.summary(of: team), team.count > 1 {
                            Text(summary)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(t.secondaryText.color)
                                .contentTransition(.numericText())
                                .fixedSize()
                        }
                        ForEach(team) { mate in
                            Button { onSelect(mate) } label: { chip(mate, now: context.date, t) }
                                .buttonStyle(.plain)
                                .transition(Motion.transition(scale: 0.85, reduceMotion: reduceMotion))
                        }
                    }
                    .padding(.horizontal, Self.inset)
                    .animation(Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: team.map(\.id))
                    .animation(Motion.quick, value: team.map(\.state))
                }
                .scrollIndicators(.never)
            }
            .frame(height: 32)
        }
    }

    /// One entry per second from the start while `running`; otherwise just the start, so the
    /// lane draws once and stays still. One schedule type either way, so the lane keeps its
    /// identity (and scroll position) when the last teammate finishes.
    struct WorkingClock: TimelineSchedule {
        let running: Bool

        func entries(from startDate: Date, mode: TimelineScheduleMode) -> UnfoldFirstSequence<Date> {
            let running = running
            return sequence(first: startDate) { running ? $0.addingTimeInterval(1) : nil }
        }
    }

    /// What it's doing now: its step while it runs (with its age once quiet for 90 s, inspire
    /// #4), else how it ended.
    static func line(_ mate: TeammateSnapshot, now: Date) -> String {
        let word = mate.state.label.prefix(1).uppercased() + mate.state.label.dropFirst()
        let line = mate.liveLine.flatMap { $0.isEmpty ? nil : $0 } ?? word
        return mate.state == .working ? Liveness.line(line, since: mate.lastEventAt, now: now) : line
    }

    /// "3 steps · 0:42"; nothing before it starts.
    static func meta(_ mate: TeammateSnapshot, now: Date) -> String? {
        guard let elapsed = mate.elapsed(at: now) else { return nil }
        let clock = TrailCopy.clock(elapsed)
        switch mate.steps {
        case 0: return clock
        case 1: return "1 step · " + clock
        default: return "\(mate.steps) steps · " + clock
        }
    }

    private func chip(_ mate: TeammateSnapshot, now: Date, _ t: Tokens) -> some View {
        let isSelected = selected == mate.id
        let meta = Self.meta(mate, now: now)
        return HStack(spacing: 6) {
            BeadView(state: mate.state, size: 7, t: t)
            Image(systemName: TeammateGlyph.symbol(for: mate.name + " " + (mate.brief ?? ""))).font(.system(size: 10))
            Text(mate.name).font(.system(size: 12)).lineLimit(1).fixedSize()
            SteadyText(text: Self.line(mate, now: now))
                .font(.system(size: 11))
                .foregroundStyle(t.secondaryText.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: Self.lineWidth, alignment: .leading)
            if let meta {
                Text(meta).font(.system(size: 11).monospacedDigit()).foregroundStyle(t.secondaryText.color).fixedSize()
            }
        }
        .foregroundStyle(t.text.color)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background((isSelected ? t.selection : t.opaqueSurface).color, in: Capsule())
        .overlay(Capsule().strokeBorder(mate.state == .needsYou ? Tokens.amberBorder.color : t.cardHairline.color,
                                        lineWidth: Tokens.hairlineWidth))
        .opacity(mate.state.isRunning ? 1 : 0.8)
        .frame(minHeight: PageShape.hitTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([mate.name, Self.line(mate, now: now), meta].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

/// Text that changes at most four times a second and crossfades when it does, so a burst of
/// progress lines reads as one calm update.
struct SteadyText: View {
    let text: String
    @State private var shown: String?
    @State private var changedAt = ContinuousClock.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let interval: Duration = .milliseconds(250)

    var body: some View {
        Text(shown ?? text)
            .contentTransition(.opacity)
            .task(id: text) {
                guard shown != text else { return }
                let wait = changedAt + Self.interval - .now
                if shown != nil, wait > .zero { try? await Task.sleep(for: wait) }
                // A newer line replaced this one while it waited.
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : Motion.quick) { shown = text }
                changedAt = .now
            }
    }
}

/// A teammate's lane: its brief, its own Trail and its words, with "via Lumi" under what the
/// user relayed. The composer addresses it while it's open.
struct TeammateLane: View {
    let mate: PageTeammate
    let model: ConversationPageModel
    let density: PageDensity
    let t: Tokens
    @State private var showBrief = false

    var body: some View {
        VStack(alignment: .leading, spacing: density.blockGap) {
            HStack(spacing: 8) {
                Button { model.openLane = nil } label: {
                    Image(systemName: "chevron.left").frame(width: PageShape.hitTarget, height: PageShape.hitTarget)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Back to the session")
                Text("Session › \(mate.name)")
                    .font(.system(size: density.callout.size, weight: .semibold))
                    .foregroundStyle(t.text.color)
                Spacer()
                if mate.state == .working || mate.state == .needsYou {
                    Menu {
                        Button("Stop teammate") { model.stopTeammate(mate.id) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .frame(width: PageShape.hitTarget)
                    .accessibilityLabel("More")
                }
            }
            if let brief = mate.brief, !brief.isEmpty {
                Button { showBrief.toggle() } label: {
                    Text(showBrief ? brief : "Brief ⌄")
                        .font(density.callout.font)
                        .foregroundStyle(t.secondaryText.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
            }
            TrailView(trail: mate.lane, density: density, t: t, showThinking: model.showThinking)
            if !mate.laneText.isEmpty {
                MarkdownView(markdown: mate.laneText, density: density, t: t)
            }
        }
        .onKeyPress(.escape) {
            guard mate.state == .working else { return .ignored }
            model.stopTeammate(mate.id)
            return .handled
        }
    }
}
