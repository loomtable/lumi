import SwiftUI

/// The `/` and `@` menu (04 §4.5): rows 30 pt high with a glyph, the name, a one-line description
/// and the source. It floats above the composer; ↑/↓ move, ↩ or Tab take, a click takes. Text
/// stays text and secondary text on the selected row's ember wash (≥ 4.5:1 in light mode).
public struct CompletionMenuView: View {
    let menu: ComposerState.Menu
    let t: Tokens
    let onPick: (Int) -> Void
    @State private var hovered: Int?

    /// The tallest the menu gets: 8 rows and its padding.
    public static let maxHeight: CGFloat = 8 * 30 + 8

    public init(menu: ComposerState.Menu, t: Tokens, onPick: @escaping (Int) -> Void) {
        self.menu = menu
        self.t = t
        self.onPick = onPick
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
                Button { onPick(index) } label: { row(item, selected: index == menu.selected, hovered: index == hovered) }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
                    .accessibilityLabel([item.title, item.detail].compactMap(\.self).joined(separator: ", "))
                    .accessibilityAddTraits(index == menu.selected ? .isSelected : [])
            }
        }
        .padding(4)
        // 320 wide, or the composer's width in a narrow Panel, so it never runs off the window.
        .frame(maxWidth: 320, alignment: .leading)
        // Studio's card look: the panel fill, the card hairline, the card radius.
        .background(t.panel.color, in: RoundedRectangle(cornerRadius: Tokens.windowCardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.windowCardRadius, style: .continuous)
            .strokeBorder(t.cardHairline.color, lineWidth: Tokens.hairlineWidth))
        .shadow(color: t.shadow.color, radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(menu.query.trigger == .command ? "Commands" : "Mentions")
    }

    private func row(_ item: CompletionItem, selected: Bool, hovered: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: glyph(item.kind))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle((selected ? t.text : t.secondaryText).color)
                .frame(width: 16)
            Text(item.kind == .command ? "/" + item.title : item.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(t.text.color)
                .lineLimit(1)
                .truncationMode(item.kind == .file || item.kind == .folder ? .head : .tail)
                .layoutPriority(1)
            if let detail = item.detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(t.secondaryText.color).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let source = item.source {
                Text(source).font(.system(size: 10)).foregroundStyle(t.secondaryText.color).lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(selected ? t.emberMark.opacity(t.variant.dark ? 0.18 : 0.12).color : hovered ? t.text.opacity(0.06).color : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private func glyph(_ kind: CompletionItem.Kind) -> String {
        switch kind {
        case .command: "terminal"
        case .teammate: "person"
        case .file: "doc"
        case .folder: "folder"
        }
    }
}

extension View {
    /// `content` floats `gap` above this view, leading-aligned, over what's above it: its bottom
    /// sits on a zero-height line at this view's top, so it can only grow upward (qa-ui: an
    /// alignment guide on a top overlay drew the menu down over the field).
    public func floatingAbove<Content: View>(gap: CGFloat = 6, @ViewBuilder _ content: () -> Content) -> some View {
        overlay(alignment: .topLeading) {
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .bottomLeading) {
                    content().fixedSize(horizontal: false, vertical: true).padding(.bottom, gap)
                }
        }
    }
}
