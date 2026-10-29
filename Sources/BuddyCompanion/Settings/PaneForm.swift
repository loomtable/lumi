import BuddyOverlay
import SwiftUI

extension EnvironmentValues {
    /// Set by Studio's Settings: the page whose hero row opens the pane's form. Nil in previews.
    @Entry var settingsHero: SettingsPage? = nil
}

/// Every pane's form: Studio's hero row first when one is set, then the pane's sections.
struct PaneForm<Content: View>: View {
    @Environment(\.settingsHero) private var hero
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            if let hero {
                // A header with no rows: the hero sits on the page, not in a section card (canvas
                // Settings board; a grouped Form ignores a clear row background).
                Section {} header: { SettingsHeroRow(page: hero) }
            }
            content
        }
        .formStyle(.grouped)
        // Studio's window background shows through, so the sections read as cards on the page.
        .scrollContentBackground(hero == nil ? .automatic : .hidden)
    }
}

/// 04 §6.4: a 40 pt orb whose face matches the page, the title, and one sentence of what it controls.
struct SettingsHeroRow: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 16) {
            LumiOrb(expression: page.expression, size: 40)
            TokensReader { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(t.text.color)
                    Text(page.summary).font(.system(size: 12)).foregroundStyle(t.secondaryText.color)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
