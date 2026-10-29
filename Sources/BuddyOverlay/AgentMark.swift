import AppKit
import BuddyCore
import SwiftUI

/// A session as an agent, drawn the same wherever it appears: the switcher's chips, the pill,
/// the peek, the progress capsules, the Studio's sidebar and Home, and the conversation header.
///
/// A pebble of tinted glass in two theme hues (`AgentTones`: the session's colour and a second
/// one from its id) holds the topic glyph (or the title's first letter) in the session's colour.
/// Its rim is a thin thread in the same two tones; from 28 pt a fainter thread winds inside it.
/// State takes the rim, inside the same frame: an ember comet while running, amber when it needs
/// you, rose when it didn't finish; a sage dot says ready. Nothing extra at rest. Ember sessions
/// lead with their second hue, so no pebble reads as Lumi's ember orb. Eyeless, so there is one
/// Lumi. Static at rest: the ring is Core Animation and runs only while working (60-MOTION).
/// Readable from 16 pt (sidebar) to 56 pt.
public struct AgentMark: View {
    let id: SessionID
    let symbol: String?
    let monogram: String
    let color: ConversationColor
    let ring: TileLook.Ring
    let ready: Bool
    let size: CGFloat
    let animating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(id: SessionID, symbol: String?, monogram: String, color: ConversationColor, ring: TileLook.Ring = .none,
         ready: Bool = false, size: CGFloat, animating: Bool = true) {
        self.id = id
        self.symbol = symbol
        self.monogram = monogram
        self.color = color
        self.ring = ring
        self.ready = ready
        self.size = size
        self.animating = animating
    }

    /// The session's mark with its state as the tiles show it (`TileLook`).
    public init(session s: SessionSnapshot, size: CGFloat, now: Date = Date()) {
        let look = TileLook.make(s, now: now)
        self.init(id: s.id, symbol: s.symbol, monogram: look.monogram, color: s.color, ring: look.ring,
                  ready: look.tone == .sage, size: size)
    }

    /// A page header's mark, from what the page knows: running and needs-you only.
    public init(id: SessionID, title: String, symbol: String?, color: ConversationColor, working: Bool, needsYou: Bool,
                size: CGFloat) {
        self.init(id: id, symbol: symbol, monogram: Self.monogram(title), color: color,
                  ring: needsYou ? .needsYou : working ? .comet : .none, size: size)
    }

    public var body: some View {
        TokensReader { t in
            let m = AgentMarkMetrics(size: size, thick: t.variant.increaseContrast)
            let tones = AgentTones(id.rawValue, color: color, t: t)
            let well = t.well.opacity(1)
            let (from, to) = Self.ends(tones.angle)
            ZStack {
                Circle().fill(well.color)
                Circle().fill(LinearGradient(colors: [tones.lead.opacity(tones.tint).color, tones.second.opacity(tones.tint).color],
                                             startPoint: from, endPoint: to))
                Circle().fill(LinearGradient(colors: [t.innerHighlight.color, t.innerHighlight.opacity(0).color],
                                             startPoint: .top, endPoint: .center))
                if case .none = ring {
                    Circle().strokeBorder(Self.thread(tones, alpha: m.thick ? 1 : 0.7), lineWidth: m.rim)
                } else {
                    Circle().inset(by: m.line + m.gap / 2).stroke(well.color, lineWidth: m.gap)
                    Circle().inset(by: m.line / 2).stroke(well.color, lineWidth: m.line)
                    Circle().inset(by: m.line / 2).stroke(ringColor(t).opacity(0.25).color, lineWidth: m.line)
                    StateRing(ring: ring, ember: t.emberMark.nsColor, amber: t.amber.nsColor, rose: t.rose.nsColor,
                              track: .clear, lineWidth: m.line, animating: animating, reduceMotion: reduceMotion)
                        .allowsHitTesting(false)
                }
                if m.innerThread {
                    Circle().inset(by: m.line + m.gap + m.threadInset).trim(from: 0, to: 0.82)
                        .stroke(Self.thread(tones, alpha: 0.55), style: StrokeStyle(lineWidth: m.threadWidth, lineCap: .round))
                        .rotationEffect(.degrees(tones.angle))
                }
                glyph(m, tones.glyph)
                if ready {
                    Circle()
                        .fill(t.sage.color)
                        .overlay(Circle().strokeBorder(well.color, lineWidth: m.dotRim))
                        .frame(width: m.dot, height: m.dot)
                        .offset(x: m.dotOffset, y: -m.dotOffset)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: size >= 24 && t.variant.dark ? tones.lead.opacity(0.35).color : .clear, radius: size * 0.08)
        }
        .accessibilityHidden(true)
    }

    /// The two tones round the rim, meeting at the session's angle.
    private static func thread(_ tones: AgentTones, alpha: Double) -> AngularGradient {
        let a = tones.lead.opacity(alpha).color, b = tones.second.opacity(alpha).color
        return AngularGradient(colors: [a, b, a], center: .center, angle: .degrees(tones.angle))
    }

    /// The body's gradient runs across the pebble at `degrees`.
    private static func ends(_ degrees: Double) -> (UnitPoint, UnitPoint) {
        let r = degrees * .pi / 180
        let u = UnitPoint(x: 0.5 + 0.5 * cos(r), y: 0.5 + 0.5 * sin(r))
        return (u, UnitPoint(x: 1 - u.x, y: 1 - u.y))
    }

    @ViewBuilder private func glyph(_ m: AgentMarkMetrics, _ ink: TokenColor) -> some View {
        if let symbol = Self.shownSymbol(symbol) {
            Image(systemName: symbol)
                .font(.system(size: size * m.glyphScale, weight: .bold))
                .foregroundStyle(ink.color)
        } else {
            Text(monogram)
                .font(.system(size: size * m.glyphScale * 1.1, weight: .heavy, design: .rounded))
                .foregroundStyle(ink.color)
        }
    }

    private func ringColor(_ t: Tokens) -> TokenColor {
        switch ring {
        case .needsYou: t.amber
        case .failed: t.rose
        case .none, .comet, .progress: t.emberMark
        }
    }

    /// The symbol the pebble shows: nil (the monogram) when missing, unknown to this Mac, or a
    /// chat bubble, which names no topic (sessions stored one before the allowlist dropped it).
    static func shownSymbol(_ symbol: String?) -> String? {
        guard let symbol, !symbol.hasPrefix("bubble."),
              NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil else { return nil }
        return symbol
    }

    static func monogram(_ title: String) -> String { title.first.map { String($0).uppercased() } ?? "·" }
}

/// Sizes inside a mark. The pebble fills the frame; a state ring takes its rim, so nothing
/// moves or grows when the state changes.
nonisolated struct AgentMarkMetrics {
    let size: CGFloat
    /// Increase Contrast: a heavier ring and a full-strength thread.
    var thick = false
    /// The state ring.
    var line: CGFloat { max(1.5, size * 0.06) * (thick ? 1.4 : 1) }
    /// The well-coloured hairline that parts a state ring from the body.
    var gap: CGFloat { max(0.75, size * 0.025) }
    /// The resting thread round the rim: thinner than any state ring.
    var rim: CGFloat { max(1, size * 0.04) }
    var glyphScale: CGFloat { size < 24 ? 0.5 : 0.42 }
    /// The inner thread, only where it reads.
    var innerThread: Bool { size >= 28 }
    var threadInset: CGFloat { max(1.5, size * 0.06) }
    var threadWidth: CGFloat { max(0.75, size * 0.022) }
    /// The ready dot, at the top right, inside the frame.
    var dot: CGFloat { max(5, size * 0.26) }
    var dotRim: CGFloat { max(1, size * 0.035) }
    var dotOffset: CGFloat { size * 0.36 }
}

/// An agent's two tones, from its id and the theme's tokens: its own colour and a second
/// conversation hue. Ember sessions lead with the second hue, so no pebble is pure ember (Lumi's
/// orb); ember and amber sessions always pair with a cool hue, so their rim never reads as the
/// running or Needs-you ring. The glyph is the lead tone, moved toward the text colour until it
/// keeps 4.5:1 on the body. Stable across launches (FNV-1a, not `hashValue`). Pure.
nonisolated struct AgentTones: Equatable {
    let lead: TokenColor
    let second: TokenColor
    /// Where the two tones meet, degrees clockwise.
    let angle: Double
    /// The tones' strength in the body over the well.
    let tint: Double
    let glyph: TokenColor

    init(_ id: String, color: ConversationColor, t: Tokens) {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 }
        let warm: Set<ConversationColor> = [.ember, .amber]
        let others = warm.contains(color) ? [ConversationColor.mist, .sage] : ConversationColor.allCases.filter { $0 != color }
        let pick = t.conversationColor(others[Int((h >> 7) % UInt64(others.count))]).opacity(1)
        let own = t.conversationColor(color).opacity(1)
        (lead, second) = color == .ember ? (pick, own) : (own, pick)
        angle = Double(h % 360)
        tint = t.variant.dark ? 0.4 : 0.26
        let body = SwitcherSurface.over(SwitcherSurface.mix(lead, second, 0.5).opacity(tint), t.well.opacity(1))
        var ink = lead
        for _ in 0..<20 where SwitcherSurface.contrast(ink, body) < 4.5 { ink = SwitcherSurface.mix(ink, t.text, 0.12) }
        glyph = ink
    }
}
