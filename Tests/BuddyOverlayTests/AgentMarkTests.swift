import BuddyCore
import Foundation
import Testing
@testable import BuddyOverlay

@Suite("Agent mark")
struct AgentMarkTests {
    static let themes: [Tokens] = Theme.allCases.flatMap { theme in
        [false, true].flatMap { dark in [false, true].map { Tokens(.init(dark: dark, theme: theme, increaseContrast: $0)) } }
    }

    @Test("the tones are stable, two different hues, and from the theme's conversation colours")
    func tones() {
        for t in Self.themes {
            let hues = ConversationColor.allCases.map { t.conversationColor($0).opacity(1) }
            for id in ["a", "session-1", "7F3C2B9A-0D4E-4C1B-9E55-2A9C1E0B7D31", ""] {
                for color in ConversationColor.allCases {
                    let tones = AgentTones(id, color: color, t: t)
                    #expect(tones == AgentTones(id, color: color, t: t))
                    #expect(tones.lead != tones.second)
                    #expect(hues.contains(tones.lead) && hues.contains(tones.second))
                    #expect([tones.lead, tones.second].contains(t.conversationColor(color).opacity(1)))
                }
            }
        }
    }

    @Test("no pebble is pure ember, and ember or amber sessions pair with a cool hue")
    func apartFromState() {
        for t in Self.themes {
            let cool = [t.mist, t.sage].map { $0.opacity(1) }
            for n in 0..<20 {
                let ember = AgentTones("s\(n)", color: .ember, t: t)
                #expect(cool.contains(ember.lead) && ember.second == t.emberMark.opacity(1))
                #expect(cool.contains(AgentTones("s\(n)", color: .amber, t: t).second))
            }
        }
    }

    @Test("the glyph keeps 4.5:1 on the pebble's body in every theme")
    func glyphContrast() {
        for t in Self.themes {
            for color in ConversationColor.allCases {
                for n in 0..<8 {
                    let tones = AgentTones("s\(n)", color: color, t: t)
                    let body = SwitcherSurface.over(SwitcherSurface.mix(tones.lead, tones.second, 0.5).opacity(tones.tint),
                                                    t.well.opacity(1))
                    let ratio = SwitcherSurface.contrast(tones.glyph, body)
                    #expect(ratio >= 4.5, "\(color) in \(t.variant): \(ratio)")
                }
            }
        }
    }

    @Test("different sessions meet their tones at different angles")
    func distinct() {
        let t = Tokens(.init(dark: true))
        let angles = Set((0..<40).map { Int(AgentTones("session-\($0)", color: .mist, t: t).angle) })
        #expect(angles.count >= 30)
    }

    @Test("a chat bubble, a missing or an unknown symbol shows the monogram")
    func symbols() {
        #expect(AgentMark.shownSymbol("cart") == "cart")
        #expect(AgentMark.shownSymbol("bubble.left") == nil)
        #expect(AgentMark.shownSymbol("bubble.left.and.bubble.right") == nil)
        #expect(AgentMark.shownSymbol(nil) == nil)
        #expect(AgentMark.shownSymbol("no.such.symbol.anywhere") == nil)
        #expect(AgentMark.monogram("german videos") == "G")
        #expect(AgentMark.monogram("") == "·")
    }

    @Test("a state ring takes the rim inside the frame, heavier than the resting thread")
    func metrics() {
        for size: CGFloat in [16, 20, 24, 34, 40, 56] {
            let m = AgentMarkMetrics(size: size)
            #expect(m.line > m.rim)
            #expect(size * m.glyphScale >= 7)
            #expect(m.dotOffset + m.dot / 2 <= size / 2 + 0.5, "ready dot inside \(size)")
            #expect(m.innerThread == (size >= 28))
        }
        #expect(AgentMarkMetrics(size: 40, thick: true).line > AgentMarkMetrics(size: 40).line)
    }

    @Test("state comes from the tile's look: running, needs you, ready")
    @MainActor
    func state() {
        let now = Date()
        func snap(_ status: SessionStatus) -> SessionSnapshot {
            SessionSnapshot(id: SessionID(rawValue: "s"), title: "Trip", color: .mist, harness: .open, status: status,
                            lastUsed: now)
        }
        #expect(AgentMark(session: snap(.thinking(since: now, progress: nil)), size: 20, now: now).ring == .comet)
        let needs = SessionStatus.needsYou(NeedsYou(kind: .soft("Which?"), since: now))
        #expect(AgentMark(session: snap(needs), size: 20, now: now).ring == .needsYou)
        let ready = AgentMark(session: snap(.done(at: now, unread: true)), size: 20, now: now)
        #expect(ready.ready && ready.ring == .none)
        let rest = AgentMark(session: snap(.done(at: now, unread: false)), size: 20, now: now)
        #expect(!rest.ready && rest.ring == .none)
    }
}
