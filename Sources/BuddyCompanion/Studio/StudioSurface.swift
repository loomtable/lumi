import BuddyOverlay
import SwiftUI

/// The Lumi window's content look, in one place (04 §7.1–7.2, the canvas boards): an opaque window
/// background, cards and sections on `panel` with a quiet outline, ember for every accent.
extension View {
    /// The window's content background behind Home, a session's column and Settings pages, with the
    /// theme's wash at the top. In Liquid Glass it is a thin veil over `Material.regular`, the
    /// standard material Apple puts under the content layer (opaque again with Reduce Transparency
    /// or Increase Contrast, where the tokens are solid). The sidebar is the system's own glass.
    func studioBackground() -> some View {
        TokensReader { t in
            self.background {
                t.windowBackground.color.overlay(t.washGradient).ignoresSafeArea()
            }
            .containerBackground(t.windowBackground.alpha < 1 ? AnyShapeStyle(Material.regular) : AnyShapeStyle(t.windowBackground.color),
                                 for: .window)
        }
    }
}

/// A card on the window background: `panel`, a quiet outline (or a state rim), 14 pt corners. Content,
/// so no glass (04 §7.2).
struct StudioCard<Content: View>: View {
    var rim: TokenColor?
    var padding: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        TokensReader { t in
            let shape = RoundedRectangle(cornerRadius: Tokens.windowCardRadius, style: .continuous)
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(t.panel.color))
                .overlay { shape.strokeBorder((rim ?? t.cardHairline).color, lineWidth: Tokens.hairlineWidth) }
        }
    }
}

/// A small uppercase group label ("RUNNING", "RECENT"): 11 pt semibold, tracked, secondary.
struct StudioGroupLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        TokensReader { t in
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(t.secondaryText.color)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A 3 pt progress line: an ember fill on a faint track (Home's running cards).
struct StudioProgressLine: View {
    let fraction: Double

    var body: some View {
        TokensReader { t in
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.text.opacity(0.08).color)
                    Capsule().fill(t.emberMark.color)
                        .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 3)
            .animation(Motion.crossfade, value: fraction)
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(1, max(0, fraction)) * 100).rounded())) percent")
    }
}

/// A row of quiet tabs (the inspector's Team · Files · Context · Details): the selected one sits on a
/// faint fill, the rest are secondary text. Each is a real button, so it takes keyboard focus.
struct StudioTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String

    var body: some View {
        TokensReader { t in
            HStack(spacing: 2) {
                ForEach(tabs) { tab in
                    let on = tab == selection
                    Button { selection = tab } label: {
                        Text(title(tab))
                            .font(.system(size: 12, weight: on ? .semibold : .regular))
                            .foregroundStyle((on ? t.text : t.secondaryText).color)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule().fill(on ? t.text.opacity(0.08).color : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .animation(Motion.crossfade, value: selection)
        }
    }
}
