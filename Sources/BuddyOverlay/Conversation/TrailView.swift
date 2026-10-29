import AppKit
import BuddyCore
import SwiftUI

/// The Trail (04 §4.2): one live row while working, the done line after, and the expanded
/// timeline on ⌄. Verbs come from the bridge's StatusMapper through `TrailReducer`.
struct TrailView: View {
    let trail: Trail
    let density: PageDensity
    let t: Tokens
    var showThinking = false
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel(trail.isWorking ? trail.live : trail.doneLine)
            .accessibilityHint(expanded ? "Hides the steps" : "Shows the steps")

            // Steers stay visible inside a running Trail, so it's clear when a correction landed.
            if !expanded, trail.isWorking {
                ForEach(trail.rows.filter(\.isSteer)) { row in SteerNote(text: row.line, density: density, t: t) }
            }
            if expanded {
                Timeline(trail: trail, density: density, t: t, showThinking: showThinking)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            if trail.isWorking {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 8) {
                        LiveDot(color: trail.phase == .needsYou ? t.amber : t.emberMark, live: trail.phase == .working)
                        Text(trail.liveLine(at: context.date))
                            .font(density.callout.font.monospacedDigit())
                            .foregroundStyle(t.text.color)
                            .contentTransition(.opacity)
                            .animation(Motion.quick, value: trail.live)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else {
                Image(systemName: trail.phase.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(trail.phase.color(t).color)
                    .frame(width: 12)
                Text(trail.doneLine)
                    .font(density.callout.font.monospacedDigit())
                    .foregroundStyle((trail.phase == .interrupted ? t.mist : t.secondaryText).color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(t.secondaryText.color)
                .rotationEffect(.degrees(expanded ? 180 : 0))
            Spacer(minLength: 0)
        }
        .frame(minHeight: PageShape.hitTarget)
        .contentShape(Rectangle())
    }
}

extension Trail.Phase {
    var symbol: String {
        switch self {
        case .done, .working, .needsYou: "checkmark"
        case .stopped: "stop.fill"
        case .interrupted: "pause.fill"
        case .failed: "exclamationmark"
        }
    }

    func color(_ t: Tokens) -> TokenColor {
        switch self {
        case .done, .working: t.sage
        case .needsYou: t.amber
        case .stopped: t.secondaryText
        case .interrupted: t.mist
        case .failed: t.rose
        }
    }
}

extension TrailRow {
    var isSteer: Bool {
        if case .steer = content { return true }
        return false
    }
}

/// The 8 pt live dot: breathes (Core Animation) while work runs, holds still with Reduce
/// Motion, and stops the moment work stops.
struct LiveDot: View {
    let color: TokenColor
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size: CGFloat = 8

    var body: some View {
        PulseDot(color: color.nsColor, opacity: 1, pulses: Motion.loopRuns(visible: live, reduceMotion: reduceMotion),
                glow: false, size: Self.size, loop: .breathe)
            .frame(width: Self.size, height: Self.size)
            .accessibilityHidden(true)
    }
}

/// The user's mid-turn note: indented, ↳, in a quiet bubble.
struct SteerNote: View {
    let text: String
    let density: PageDensity
    let t: Tokens

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("↳").foregroundStyle(t.secondaryText.color)
            Text(text)
                .font(density.callout.font)
                .foregroundStyle(t.text.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(PageColors(t: t).tile.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.leading, 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You added: \(text)")
    }
}

/// The expanded timeline: rows on a 1 pt spine at x = 11, same-kind runs folded.
private struct Timeline: View {
    let trail: Trail
    let density: PageDensity
    let t: Tokens
    let showThinking: Bool
    @State private var unfolded: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(visibleGroups) { group in
                if group.isFolded, !unfolded.contains(group.id) {
                    Button {
                        unfolded.insert(group.id)
                    } label: {
                        RowLine(icon: group.rows[0].icon, iconColor: group.status.color(t), text: group.title + " ⌄",
                                duration: groupDuration(group), density: density, t: t)
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(group.rows) { row in
                        StepRowView(row: row, density: density, t: t)
                            .rowRise(0, reduceMotion: reduceMotion)
                    }
                }
            }
        }
        .background(alignment: .leading) {
            Rectangle().fill(t.hairline.color).frame(width: 1).padding(.vertical, 12).offset(x: 10.5)
        }
    }

    private var visibleGroups: [TrailGroup] {
        trail.groups.filter { g in
            if case .thinking = g.rows.first?.content { return showThinking }
            return true
        }
    }

    private func groupDuration(_ g: TrailGroup) -> TimeInterval? {
        guard let start = g.rows.first?.startedAt, let end = g.rows.compactMap(\.finishedAt).max() else { return nil }
        return end.timeIntervalSince(start)
    }
}

extension TrailRow.Status {
    func color(_ t: Tokens) -> TokenColor {
        switch self {
        case .running: t.emberMark
        case .done: t.secondaryText
        case .failed: t.rose
        }
    }
}

extension TrailRow {
    /// The row's SF Symbol on the spine.
    var icon: String {
        switch content {
        case .step(let s): s.kind.icon
        case .steer: "arrow.turn.down.right"
        case .thinking: "ellipsis"
        case .retry: "clock.arrow.circlepath"
        case .handoff: "arrow.right"
        case .compacted: "arrow.down.right.and.arrow.up.left"
        }
    }
}

extension StepKind {
    var icon: String {
        switch self {
        case .read: "doc"
        case .search: "magnifyingglass"
        case .edit, .write: "pencil"
        case .bash: "terminal"
        case .web: "globe"
        case .mcp: "puzzlepiece.extension"
        case .agent: "person.2"
        case .plan: "checklist"
        case .ask: "questionmark.bubble"
        case .screen: "rectangle.dashed"
        case .other: "wrench.and.screwdriver"
        }
    }
}

/// One row: the 22 pt icon slot on the spine, the past-tense line, the duration trailing.
private struct RowLine: View {
    let icon: String
    let iconColor: TokenColor
    let text: String
    let duration: TimeInterval?
    let density: PageDensity
    let t: Tokens

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(iconColor.color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(PageColors(t: t).tile.color))
                .overlay(Circle().strokeBorder(t.hairline.color.opacity(0.5)))
            Text(text)
                .font(density.callout.font)
                .foregroundStyle(t.text.color)
                .lineLimit(2)
            Spacer(minLength: 4)
            if let duration {
                Text(Self.short(duration))
                    .font(density.caption.font.monospacedDigit())
                    .foregroundStyle(t.secondaryText.color)
            }
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
    }

    /// "2s", "1:04".
    static func short(_ d: TimeInterval) -> String {
        d < 60 ? "\(max(0, Int(d)))s" : TrailCopy.clock(d)
    }
}

private struct StepRowView: View {
    let row: TrailRow
    let density: PageDensity
    let t: Tokens
    @State private var showOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch row.content {
            case .steer(let text):
                SteerNote(text: text, density: density, t: t)
            case .retry(_, let until, _):
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = until.map { max(0, Int($0.timeIntervalSince(ctx.date))) }
                    RowLine(icon: row.icon, iconColor: t.amber,
                            text: left.map { $0 > 0 ? "Waiting to retry · \($0)s" : "Retrying" } ?? "Retrying",
                            duration: nil, density: density, t: t)
                }
            case .handoff(_, let summary):
                Button { showOutput.toggle() } label: {
                    RowLine(icon: row.icon, iconColor: t.sage, text: row.line + (summary == nil ? "" : " ⌄"),
                            duration: nil, density: density, t: t)
                }
                .buttonStyle(.plain)
                if showOutput, let summary { detailText(summary) }
            case .thinking(let summary):
                RowLine(icon: row.icon, iconColor: t.secondaryText,
                        text: row.duration.map { "Thought for \(Int($0))s" } ?? "Thinking", duration: nil, density: density, t: t)
                if let summary { detailText(summary).italic() }
            case .compacted:
                RowLine(icon: row.icon, iconColor: t.secondaryText, text: row.line, duration: nil, density: density, t: t)
            case .step(let step):
                Button { showOutput.toggle() } label: {
                    RowLine(icon: row.icon, iconColor: row.status.color(t),
                            text: row.line + (DiffModel(step.detail).map { " " + $0.counts } ?? ""), duration: row.duration,
                            density: density, t: t)
                }
                .buttonStyle(.plain)
                .disabled(row.preview == nil && step.commandText == nil)
                if let diff = DiffModel(step.detail) {
                    DiffTile(diff: diff, density: density, t: t).padding(.leading, 32)
                }
                if showOutput {
                    if let command = step.commandText {
                        Text(command).font(density.mono.mono).foregroundStyle(t.secondaryText.color)
                            .padding(.leading, 32).textSelection(.enabled)
                    }
                    if let preview = row.preview { OutputTail(text: preview, density: density, t: t).padding(.leading, 32) }
                }
            }
        }
    }

    private func detailText(_ s: String) -> some View {
        Text(s)
            .font(density.callout.font)
            .foregroundStyle(t.secondaryText.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 32)
    }
}

extension TrailStep {
    var commandText: String? {
        if case .command(_, let command)? = detail { return command }
        return nil
    }
}

/// The last 12 lines of a command's output, in mono.
private struct OutputTail: View {
    let text: String
    let density: PageDensity
    let t: Tokens

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(12).joined(separator: "\n")
        Text(lines)
            .font(density.mono.mono)
            .foregroundStyle(t.secondaryText.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PageColors(t: t).tile.color, in: RoundedRectangle(cornerRadius: PageShape.codeRadius, style: .continuous))
            .textSelection(.enabled)
    }
}

/// The inline diff tile: the first 8 changed lines with 3 lines of context, SF Mono, sage
/// and rose tints, line numbers off (04 §4.2).
struct DiffTile: View {
    let diff: DiffModel
    let density: PageDensity
    let t: Tokens

    var body: some View {
        let colors = PageColors(t: t)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.preview().enumerated()), id: \.offset) { _, row in
                switch row {
                case .gap:
                    Text("⋯").font(density.mono.mono).foregroundStyle(t.secondaryText.color).padding(.horizontal, 10)
                case .line(let line):
                    Text(Self.prefix(line.kind) + line.text)
                        .font(density.mono.mono)
                        .foregroundStyle(t.text.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Self.fill(line.kind, colors).color)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PageShape.codeRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PageShape.codeRadius, style: .continuous).strokeBorder(t.hairline.color.opacity(0.5)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Changes: \(diff.added) added, \(diff.removed) removed")
    }

    static func prefix(_ k: DiffModel.Kind) -> String {
        switch k {
        case .added: "+ "
        case .removed: "- "
        case .context: "  "
        }
    }

    static func fill(_ k: DiffModel.Kind, _ c: PageColors) -> TokenColor {
        switch k {
        case .added: c.added
        case .removed: c.removed
        case .context: TokenColor(0, 0, 0, 0)
        }
    }
}
