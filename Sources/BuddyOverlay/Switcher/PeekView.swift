import AppKit
import BuddyCore
import SwiftUI

/// The peek: a 300 pt card out of the highlighted tile (03 §3.6).
/// Header, the live step or the waiting ask, progress, inline Allow/Deny for a permission,
/// teammates, and the key hints while the strip is open. Lumi's own summary lines only,
/// never raw screen text.
struct PeekView: View {
    let model: SwitcherModel
    let onEvent: (SwitcherEvent) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TokensReader { t in
            Group {
                if let s = model.peek {
                    PeekCardView(session: s, look: TileLook.make(s, now: model.now), showsKeys: model.peekShowsKeys, t: t, onEvent: onEvent)
                        .transition(Motion.transition(scale: 0.96, anchor: .bottom, reduceMotion: reduceMotion))
                }
            }
            .padding(SwitcherPanelLayout.shadowRoom)
            .animation(Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: model.peek?.id)
        }
    }
}

struct PeekCardView: View {
    static let maxTeammates = 4

    let session: SessionSnapshot
    let look: TileLook
    let showsKeys: Bool
    let t: Tokens
    let onEvent: (SwitcherEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                AgentMark(id: session.id, symbol: session.symbol, monogram: look.monogram, color: session.color, ring: look.ring,
                          ready: look.tone == .sage, size: 32, animating: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(t.text.color).lineLimit(1)
                    HStack(spacing: 5) {
                        StateLine(look: look, text: look.status, t: t).fixedSize()
                        if let origin = originLine {
                            Text("· " + origin).font(.system(size: 11)).foregroundStyle(t.secondaryText.color).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            let line = TileLook.peekLine(session)
            if !line.isEmpty {
                // Up to four lines: the whole `lastSay` (160 characters) fits.
                Text(line).font(.system(size: 13)).foregroundStyle(t.text.color).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
            if case .thinking(_, let progress?) = session.status, progress.total > 0 {
                ProgressBar(fraction: Double(progress.done) / Double(progress.total), t: t).padding(.top, 10)
            }
            if case .needsYou(let needs) = session.status, case .permission(let ask) = needs.kind {
                HStack(spacing: 8) {
                    ActionButton(title: "Allow", kind: .primary) {
                        onEvent(.approve(requestID: ask.id, session: session.id, allow: true))
                    }
                    ActionButton(title: "Deny", kind: .quiet) {
                        onEvent(.approve(requestID: ask.id, session: session.id, allow: false))
                    }
                }
                .padding(.top, 12)
            } else if Self.canStop(session) {
                ActionButton(title: "Stop", kind: .quiet) { onEvent(.stop(session.id)) }
                    .padding(.top, 12)
            }
            if !session.liveTeam.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.liveTeam.prefix(Self.maxTeammates)) { mate in
                        TeammateRow(mate: mate, t: t)
                    }
                    if session.liveTeam.count > Self.maxTeammates {
                        Text("+\(session.liveTeam.count - Self.maxTeammates) more")
                            .font(.system(size: 11)).foregroundStyle(t.secondaryText.color)
                    }
                }
                .padding(.top, 12)
            }
            if showsKeys {
                KeyHints(t: t, items: [("↩", "talk"), ("⌫", "archive"), ("P", session.pinned ? "unpin" : "pin")])
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: SwitcherGeometry.peekWidth, alignment: .leading)
        .switcherWell(RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous), t: t)
        .modifier(SurfaceChrome(t: t, shape: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(look.accessibilityLabel)
    }

    /// A running turn can be stopped from its peek (00-PLAN: stop lives in the peek): working, or
    /// waiting on a question mid-turn. A permission shows Allow and Deny instead; a soft ask's turn
    /// is already over.
    static func canStop(_ s: SessionSnapshot) -> Bool {
        switch s.status {
        case .thinking: return true
        case .needsYou(let needs):
            if case .question = needs.kind { return true }
            return false
        default: return false
        }
    }

    private var originLine: String? {
        [session.origin?.appName, session.origin?.windowTitle].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ").nilIfEmpty
    }
}

struct TeammateRow: View {
    let mate: TeammateSnapshot
    let t: Tokens

    var body: some View {
        HStack(spacing: 8) {
            Circle().strokeBorder(color.color, lineWidth: 1.5).frame(width: 8, height: 8)
            Text(mate.name).font(.system(size: 12)).foregroundStyle(t.text.color).lineLimit(1)
            Text("· " + Self.line(mate)).font(.system(size: 12)).foregroundStyle(t.secondaryText.color).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// Every rim has a word (QA U16): a live line only while working; a needs-you, done or failed
    /// teammate always says so, even with a live line.
    static func line(_ mate: TeammateSnapshot) -> String {
        mate.state == .working ? mate.liveLine ?? "Working" : word(mate.state)
    }

    private static func word(_ state: TeammateSnapshot.State) -> String {
        switch state {
        case .working: "Working"
        case .needsYou: "Needs your OK"
        case .done: "Done"
        case .failed: "Didn't finish"
        case .stopped: "Stopped"
        }
    }

    private var color: TokenColor {
        mate.state.color(t)
    }
}

struct ProgressBar: View {
    let fraction: Double
    let t: Tokens

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(SwitcherSurface.neutral(t, 0.1).color)
                Capsule().fill(t.emberMark.color).frame(width: g.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
