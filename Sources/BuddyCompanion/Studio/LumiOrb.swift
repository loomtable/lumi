import BuddyOverlay
import SwiftUI

/// Lumi: the ember orb with a face, as on the menu bar mark. Studio shows it in exactly one place at
/// a time (Home, or a Settings hero row); sessions are never drawn as orbs.
/// When its expression changes, the eyes blink into the new one (as on the site): they close
/// over 70 ms and open over 70 ms. Nothing moves at rest; Reduce Motion swaps without a blink.
struct LumiOrb: View {
    let expression: LumiExpression
    /// The orb's diameter. Its glow reaches a third of that again on each side.
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The blink: eyes squash to `closed` of their height and reopen, in `duration` seconds.
    nonisolated static let blink = (closed: 0.1, duration: 0.14)

    var body: some View {
        TokensReader { t in
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [t.emberMark.opacity(0.45).color, t.emberMark.opacity(0).color],
                                         center: .center, startRadius: 0, endRadius: size * 5 / 6))
                    .frame(width: size * 5 / 3, height: size * 5 / 3)
                Circle()
                    .fill(t.emberMark.color)
                    .overlay {
                        Circle().fill(RadialGradient(colors: [Color.white.opacity(0.45), .clear],
                                                     center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0,
                                                     endRadius: size * 0.55))
                    }
                    .overlay { Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.7) }
                    .overlay { face(t) }
                    .frame(width: size, height: size)
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }

    private func face(_ t: Tokens) -> some View {
        ZStack {
            OrbFace(expression: expression).stroke(t.onEmber.color, style: Self.ink(size))
            OrbFace(expression: expression, filled: true).fill(t.onEmber.color)
        }
        .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? nil : expression) { eyes, open in
            // Squashed toward the eye line (about 47% down the orb).
            eyes.scaleEffect(x: 1, y: open, anchor: UnitPoint(x: 0.5, y: 0.47))
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(Self.blink.closed, duration: Self.blink.duration / 2)
                CubicKeyframe(1, duration: Self.blink.duration / 2)
            }
        }
    }

    static func ink(_ size: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: max(1.2, size * 0.053), lineCap: .round)
    }
}

/// The eyes, in the orb's unit square. Arcs and lines are stroked; round eyes are filled.
nonisolated struct OrbFace: Shape {
    let expression: LumiExpression
    var filled = false

    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        func eye(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGRect {
            CGRect(x: rect.minX + (x - r) * rect.width, y: rect.minY + (y - r) * rect.height,
                   width: 2 * r * rect.width, height: 2 * r * rect.height)
        }
        var path = Path()
        switch (expression, filled) {
        case (.happy, false):
            for x in [0.293, 0.567] as [CGFloat] {
                path.move(to: p(x, 0.525))
                path.addQuadCurve(to: p(x + 0.14, 0.525), control: p(x + 0.07, 0.437))
            }
        case (.sleepy, false):
            for x in [0.32, 0.56] as [CGFloat] {
                path.move(to: p(x, 0.52))
                path.addLine(to: p(x + 0.12, 0.52))
            }
        case (.open, true):
            path.addEllipse(in: eye(0.39, 0.45, 0.053))
            path.addEllipse(in: eye(0.61, 0.45, 0.053))
        case (.curious, true):
            path.addEllipse(in: eye(0.39, 0.46, 0.05))
            path.addEllipse(in: eye(0.61, 0.43, 0.066))
        case (.look, true):
            path.addEllipse(in: eye(0.45, 0.45, 0.053))
            path.addEllipse(in: eye(0.67, 0.45, 0.053))
        default:
            break
        }
        return path
    }
}
