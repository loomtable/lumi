import AppKit
import BuddyCore
import SwiftUI

/// The strip: a grid of agent chips, three across, in strip order, then New, on one glass
/// plate under the pill, with the keys and the count line in its footer (63-SWITCHER-UX,
/// agentlook). Order is frozen while open; the highlight moves with Motion's `quick`.
struct StripView: View {
    let model: SwitcherModel
    let onEvent: (SwitcherEvent) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TokensReader { t in
            plate(t)
            .padding(SwitcherPanelLayout.shadowRoom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Showing and hiding is the panel's alpha plus a layer animation (LiveSwitcher), so
            // the Tab never waits on a SwiftUI pass.
        }
    }

    private func divider(_ t: Tokens) -> some View {
        Rectangle().fill(t.hairline.color).frame(height: Tokens.hairlineWidth)
            .padding(.horizontal, 2 * SwitcherGeometry.paddingX)
    }

    private func plate(_ t: Tokens) -> some View {
        let shape = RoundedRectangle(cornerRadius: SwitcherGeometry.stripRadius, style: .continuous)
        // The pill's row (the overlay draws the pill itself on top) and a hairline.
        let header = model.headerHeight > 0
        return VStack(spacing: 0) {
            if header, !model.headerAtBottom {
                Color.clear.frame(height: model.headerHeight)
                divider(t)
            }
            chips(t)
            footer(t)
            if header, model.headerAtBottom {
                divider(t)
                Color.clear.frame(height: model.headerHeight)
            }
        }
        .frame(width: model.plateWidth > 0 ? model.plateWidth : SwitcherGeometry.stripWidth)
        .switcherWell(shape, t: t)
        .modifier(SurfaceChrome(t: t, shape: shape))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions")
    }

    private func chips(_ t: Tokens) -> some View {
        let g = SwitcherGeometry.self
        let cells = model.tiles.count + 1
        return VStack(alignment: .leading, spacing: g.gap) {
            ForEach(0..<SwitcherGeometry.rows(sessions: model.tiles.count), id: \.self) { row in
                HStack(spacing: g.gap) {
                    ForEach(row * g.columns..<min(cells, (row + 1) * g.columns), id: \.self) { index in
                        cell(index, t: t)
                    }
                }
            }
        }
        .frame(width: g.stripWidth - 2 * g.paddingX, alignment: .leading)
        .animation(Motion.animation(Motion.quick, reduceMotion: reduceMotion), value: model.highlight)
        .padding(.top, g.paddingY)
    }

    @ViewBuilder private func cell(_ index: Int, t: Tokens) -> some View {
        let selected = model.highlight == index
        Group {
            if index < model.tiles.count {
                let s = model.tiles[index]
                TileView(session: s, look: TileLook.make(s, now: model.now), selected: selected,
                         icon: s.origin.flatMap { model.icons[$0.key.bundleID] }, animating: true, t: t)
                    .onTapGesture { onEvent(.tileClicked(s.id)) }
            } else {
                PlusTile(selected: selected, t: t)
                    .onTapGesture { onEvent(.newSessionClicked) }
            }
        }
        .onHover { if $0, model.isOpen { onEvent(.highlighted(index)) } }
        .opacity(model.committed && !selected ? 0 : 1)
    }

    private func footer(_ t: Tokens) -> some View {
        HStack(spacing: 12) {
            HintLine(t: t)
            Spacer(minLength: 0)
            CountLine(counts: TileLook.counts(model.tiles, now: model.now), t: t)
        }
        .padding(.horizontal, 2 * SwitcherGeometry.paddingX)
        .frame(height: SwitcherGeometry.footerHeight)
    }
}

/// The keys, always, in one quiet line under the tiles: peek and Esc stay discoverable.
struct HintLine: View {
    static let items = [("tab", "next"), ("release", "talk"), ("space", "peek"), ("esc", "cancel")]
    let t: Tokens

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.items, id: \.0) { key, label in
                HStack(spacing: 3) {
                    Text(key).fontWeight(.semibold)
                    Text(label)
                }
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(t.secondaryText.color)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// "2 running · 1 needs you · 1 ready", each in its state's colour; empty when all rest.
struct CountLine: View {
    let counts: [(text: String, tone: TileLook.Tone)]
    let t: Tokens

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(counts.enumerated()), id: \.offset) { i, item in
                if i > 0 { Text("·").foregroundStyle(t.secondaryText.color) }
                Text(item.text).foregroundStyle(item.tone.text(t).color).lineLimit(1)
            }
        }
        .font(.system(size: 11.5, weight: .semibold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(counts.map(\.text).joined(separator: ", "))
    }
}

/// One session as an agent chip: its mark (identity and state, the origin app's badge), the
/// title on one line, and one state line in the state's colour ("Running · 3m", "Needs your
/// OK", "Done · 10h ago"); the selected chip shows the live step instead.
struct TileView: View {
    let session: SessionSnapshot
    let look: TileLook
    let selected: Bool
    let icon: NSImage?
    let animating: Bool
    let t: Tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let g = SwitcherGeometry.self
        HStack(spacing: 9) {
            AgentMark(id: session.id, symbol: session.symbol, monogram: look.monogram, color: session.color,
                      ring: look.ring, ready: look.tone == .sage, size: g.markSize, animating: animating)
                .overlay(alignment: .bottomTrailing) {
                    if let icon {
                        Image(nsImage: icon).resizable().frame(width: g.badgeSize, height: g.badgeSize)
                            .shadow(color: Tokens.outlineShadowDeep.color, radius: 1, y: 0.5)
                            .offset(x: 4, y: 4)
                            .accessibilityHidden(true)
                    }
                }
                // Age dims the mark only; text keeps ≥ 4.5:1.
                .opacity(look.opacity)
                .scaleEffect(selected && !reduceMotion ? g.selectedScale : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle((look.opacity < 1 && !selected ? t.secondaryText : t.text).color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(look.line(selected: selected))
                    .font(.system(size: 10.5, weight: look.tone == .secondary ? .regular : .semibold))
                    .foregroundStyle(look.tone.text(t).color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: g.chipWidth, height: g.chipHeight)
        .background { if selected { SelectionPlate(t: t) } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(look.accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The selected chip: an ember plate, edge and glow. Static: no loop, nothing per frame.
struct SelectionPlate: View {
    let t: Tokens

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SwitcherGeometry.chipRadius, style: .continuous)
        shape.fill(SwitcherSurface.selection(t).color)
            .overlay(shape.strokeBorder(SwitcherSurface.selectionEdge(t).color, lineWidth: 1.5))
            .shadow(color: SwitcherSurface.selectionGlow(t).color, radius: 10, y: 3)
    }
}

/// One state, as a dot and a word in the state's colour ("Running", "Needs you"); a quiet
/// state (done, new) is the word alone in secondary.
struct StateLine: View {
    let look: TileLook
    let text: String?
    let t: Tokens

    var body: some View {
        if let text {
            HStack(spacing: 4) {
                if let dot = look.tone.mark(t) {
                    Circle().fill(dot.color).frame(width: 6, height: 6)
                }
                Text(text)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(look.tone.text(t).color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

extension TileLook.Tone {
    /// The state's text colour (each ≥ 4.5:1 on the well and the selected plate).
    func text(_ t: Tokens) -> TokenColor {
        switch self {
        case .secondary: t.secondaryText
        case .ember: t.emberText
        case .amber: t.amber
        case .rose: t.rose
        case .sage: t.sage
        }
    }

    /// The state's dot, matching its ring; none for a quiet state.
    func mark(_ t: Tokens) -> TokenColor? {
        switch self {
        case .secondary: nil
        case .ember: t.emberMark
        case .amber: t.amber
        case .rose: t.rose
        case .sage: t.sage
        }
    }
}

/// New: release talks into a new session. The last cell.
struct PlusTile: View {
    let selected: Bool
    let t: Tokens

    var body: some View {
        let g = SwitcherGeometry.self
        HStack(spacing: 9) {
            ZStack {
                Circle().strokeBorder(t.secondaryText.color, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(t.text.color)
            }
            .frame(width: g.markSize * 0.82, height: g.markSize * 0.82)
            .frame(width: g.markSize, height: g.markSize)
            VStack(alignment: .leading, spacing: 1) {
                Text("New session").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.text.color)
                if selected {
                    Text("Release to talk").font(.system(size: 10.5)).foregroundStyle(t.secondaryText.color)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: g.chipWidth, height: g.chipHeight)
        .background { if selected { SelectionPlate(t: t) } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New session")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A row of key caps and what they do.
struct KeyHints: View {
    let t: Tokens
    let items: [(key: String, label: String)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.key) { item in
                HStack(spacing: 4) {
                    Text(item.key)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .frame(minWidth: 20, minHeight: 18)
                        .background(RoundedRectangle(cornerRadius: 5).fill(SwitcherSurface.neutral(t, 0.08).color))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(t.hairline.color, lineWidth: 1))
                    Text(item.label).font(.system(size: 10))
                }
            }
        }
        .foregroundStyle(t.secondaryText.color)
        .accessibilityElement(children: .combine)
    }
}
