import BuddyOverlay
import SwiftUI

/// Settings › Appearance: the theme, each effect on or off, placement.
/// Nothing here talks to the overlay directly: the shell maps these
/// (EnginePreferences) onto BuddyOverlay's `OverlaySettings` and the coordinator's settings, live.
struct AppearancePane: View {
    @Binding var settings: AppearancePreferences

    var body: some View {
        PaneForm {
            Section {
                ThemePicker(selection: $settings.theme)
            } header: {
                Text("Theme")
            } footer: {
                Text("Every window, card and capsule changes together. The research capsule by the notch stays dark. Reduce Transparency and Increase Contrast in System Settings still apply.")
            }

            Section("Effects") {
                Toggle(isOn: $settings.speakingGlow) {
                    Text("Glow follows its voice")
                    Text("The card's edge brightens with the reply's loudness.")
                }
                Toggle(isOn: $settings.dotField) {
                    Text("Dot field while you talk")
                    Text("Off shows six plain level bars instead.")
                }
                Toggle(isOn: $settings.inkIn) {
                    Text("Text inks in")
                    Text("The headline appears word by word, from blur to sharp.")
                }
                Toggle(isOn: $settings.sounds) {
                    Text("Sounds")
                    Text("Short tones on summon, ready, discard and when research is done.")
                }
            }

            Section {
                Picker("Placement", selection: $settings.placement) {
                    ForEach(AppearancePreferences.Placement.allCases, id: \.self) { placement in
                        Text(Self.title(placement)).tag(placement)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(Self.placementHelp(settings.placement))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Chips always stay next to what you asked about. Follow-ups appear where the first answer did; drag an answer to move that spot for the rest of the conversation.")
            }

            Section("Answer actions") {
                Toggle(isOn: $settings.showRings) {
                    Text("Rings on screen")
                    Text("Mark things on screen that the answer refers to.")
                }
                Toggle(isOn: $settings.insertAndReplace) {
                    Text("Insert & Replace")
                    Text("Put drafts into the field you were typing in. Off, the main button is Copy.")
                }
            }

            Section {
                Picker("Listening and status", selection: $settings.statusPosition) {
                    Text("Top centre").tag(AppearancePreferences.StatusPosition.top)
                    Text("Bottom centre").tag(AppearancePreferences.StatusPosition.bottom)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Where the listening pill and what Lumi is doing appear, wherever your pointer is.")
            }

            Section {
                Button("Restore defaults") { settings = AppearancePreferences() }
                    .disabled(settings == AppearancePreferences())
            }
        }
    }

    static func title(_ placement: AppearancePreferences.Placement) -> String {
        switch placement {
        case .smart: "Smart"
        case .nextToIt: "Next to it"
        case .centre: "Centre"
        }
    }

    /// What each mode does ("Where things appear"; BuddyOverlay's `Placer.style(for:mode:)`).
    static func placementHelp(_ placement: AppearancePreferences.Placement) -> String {
        switch placement {
        case .smart:
            "Short answers appear next to your selection or pointer. Rich answers are centred."
        case .nextToIt:
            "Every answer appears next to your selection or pointer: below it, then above, then to the side."
        case .centre:
            "Cards and rich answers are centred."
        }
    }
}

/// Six swatches, each a tiny window drawn from that theme's own tokens. Choosing one applies at once.
struct ThemePicker: View {
    @Binding var selection: Theme

    var body: some View {
        TokensReader { t in
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                ForEach(Theme.allCases, id: \.self) { theme in
                    Button { selection = theme } label: {
                        VStack(spacing: 6) {
                            ThemeSwatch(theme: theme)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Tokens.rowRadius + 3, style: .continuous)
                                        .strokeBorder(selection == theme ? t.emberMark.color : t.cardHairline.color,
                                                      lineWidth: selection == theme ? 2 : Tokens.hairlineWidth)
                                        .padding(-3)
                                }
                            VStack(spacing: 1) {
                                Text(theme.title).font(.system(size: 12, weight: .medium)).foregroundStyle(t.text.color)
                                if theme == .system {
                                    Text("Follows your Mac").font(.system(size: 11)).foregroundStyle(t.secondaryText.color)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme == .system ? "System, follows your Mac" : theme.title)
                    .accessibilityAddTraits(selection == theme ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// A theme in miniature: its window background and wash, a card with two lines of text, and its
/// accent. System shows its light and dark halves.
private struct ThemeSwatch: View {
    let theme: Theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.rowRadius, style: .continuous)
        Group {
            if theme == .system {
                MiniWindow(t: Tokens(.init(dark: false, theme: theme)))
                    .overlay {
                        MiniWindow(t: Tokens(.init(dark: true, theme: theme)))
                            .mask(alignment: .trailing) { Rectangle().frame(width: 48) }
                    }
            } else {
                MiniWindow(t: Tokens(.init(dark: scheme == .dark, theme: theme)))
            }
        }
        .frame(width: 96, height: 62)
        .background(theme.isGlass ? AnyShapeStyle(Material.regular) : AnyShapeStyle(.clear), in: shape)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

private struct MiniWindow: View {
    let t: Tokens

    var body: some View {
        ZStack(alignment: .topLeading) {
            t.windowBackground.color.overlay(t.washGradient)
            VStack(alignment: .leading, spacing: 4) {
                Circle().fill(t.emberMark.color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(t.text.color).frame(width: 34, height: 3)
                    Capsule().fill(t.secondaryText.color).frame(width: 24, height: 3)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(t.panel.color))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(t.cardHairline.color, lineWidth: 1))
            }
            .padding(8)
        }
    }
}
