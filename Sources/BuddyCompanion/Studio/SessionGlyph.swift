import BuddyCore
import BuddyOverlay
import SwiftUI

/// A session's agent mark (`AgentMark`) in the Studio, with its state for VoiceOver.
struct SessionGlyph: View {
    let session: SessionSnapshot
    let size: CGFloat
    /// The origin app's icon at the mark's corner (sidebar date groups).
    var originBadge = false

    var body: some View {
        AgentMark(session: session, size: size)
            .overlay(alignment: .bottomTrailing) {
                if originBadge, let icon = OriginIcon.image(session.origin) {
                    Image(nsImage: icon).resizable().frame(width: size * 0.55, height: size * 0.55)
                        .offset(x: size * 0.2, y: size * 0.15)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(session.status.spoken)
    }
}

/// A teammate: an eyeless bead with a status rim (04 §5.1). Working beads are hollow.
struct TeammateBead: View {
    let state: TeammateSnapshot.State
    let size: CGFloat

    var body: some View {
        TokensReader { t in
            let color = state.color(t).color
            Circle()
                .fill(state == .working ? Color.clear : color)
                .overlay { Circle().strokeBorder(color, lineWidth: 1.5) }
                .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

extension SessionStatus {
    var isLive: Bool {
        switch self {
        case .thinking, .needsYou: true
        default: false
        }
    }

    var isWorking: Bool {
        if case .thinking = self { return true }
        return false
    }

    var needsYou: Bool {
        if case .needsYou = self { return true }
        return false
    }

    /// For VoiceOver, so colour is never the only signal.
    var spoken: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Working"
        case .needsYou: "Needs you"
        case .done(_, let unread): unread ? "Ready, unread" : "Done"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        }
    }
}
