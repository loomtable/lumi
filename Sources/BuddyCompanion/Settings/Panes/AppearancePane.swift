import SwiftUI

/// Settings › Appearance: light and dark, each effect on or off, placement.
/// Nothing here talks to the overlay directly: the shell maps these
/// (EnginePreferences) onto BuddyOverlay's `OverlaySettings` and the coordinator's settings, live.
struct AppearancePane: View {
    @Binding var settings: AppearancePreferences

    var body: some View {
        Form {
            Section {
                LabeledContent("Light and dark", value: "Follows your Mac")
            } footer: {
                Text("Every surface follows the Mac's appearance together. The research capsule by the notch is always dark. Reduce Motion, Reduce Transparency and Increase Contrast in System Settings apply too.")
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
                Text("Chips always stay next to what you asked about. Drag any answer to move it; it stays there for the rest of the conversation.")
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
        .formStyle(.grouped)
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
            "Short answers appear next to your selection or pointer, moved clear of busy content. Rich answers are centred."
        case .nextToIt:
            "Every answer appears next to your selection or pointer: below it, then above, then to the side. Answers about the whole page go to the side of the screen."
        case .centre:
            "Cards and rich answers are centred."
        }
    }
}
