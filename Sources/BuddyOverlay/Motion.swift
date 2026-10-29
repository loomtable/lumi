import QuartzCore
import SwiftUI

/// Motion for the overlay and Studio (docs/v2-sessions/60-MOTION.md): a few named animations,
/// used everywhere. Reduce Motion swaps any of them for `crossfade` (views drop their scale,
/// blur and offset) and stops every loop.
public enum Motion {
    /// Pop: ease (.2,.8,.2,1) over 560 ms.
    public static let pop = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.56)
    static let popCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0.8),
                                           endControlPoint: UnitPoint(x: 0.2, y: 1))
    /// Fold: ease (.4,0,1,1) over 200 ms.
    public static let fold = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.2)
    static let foldDuration: Duration = .milliseconds(200)
    /// Tuck: the same curve, a little longer for the trip to the menu-bar orb, down to a speck.
    public static let tuck = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.3)
    static let tuckDuration: Duration = .milliseconds(300)
    static let tuckScale: CGFloat = 0.06
    static let foldScale: CGFloat = 0.55
    /// Full screen and back: one FLIP morph over 500 ms, ease (.2,.9,.25,1).
    public static let fullScreen = Animation.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.5)
    /// Pill appearance: spring (.2,1.15,.35,1) over 400 ms.
    public static let pillIn = Animation.timingCurve(0.2, 1.15, 0.35, 1, duration: 0.4)
    /// Moves, resizes, reflows and peeks: a spring, so a new target mid-flight bends the path
    /// instead of restarting it.
    public static let settle = Animation.smooth(duration: 0.25)
    /// Text swaps, hints, toasts, the switcher's selection: quick and quiet.
    public static let quick = Animation.easeInOut(duration: 0.15)
    /// Crossfades (Studio switches, rings and edges leaving), and every animation under Reduce Motion.
    public static let crossfade = Animation.easeInOut(duration: 0.2)
    /// A ring (wash) landing, slow enough for the eye to find it.
    static let ring = Animation.easeOut(duration: 0.45)
    /// Header and content rows enter at 140 ms + 55 ms × index, rising 8 pt over 360 ms.
    static func rowDelay(_ index: Int) -> Double { 0.14 + 0.055 * Double(index) }
    static let rowRise: CGFloat = 8
    static let rowDuration = 0.36

    /// `animation`, or the crossfade with Reduce Motion.
    public static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? crossfade : animation
    }

    /// Fade in or out, moving `y` and growing from `scale` on the way, unless Reduce Motion is on.
    public static func transition(y: CGFloat = 0, scale: CGFloat = 1, anchor: UnitPoint = .center,
                                  reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        var t = AnyTransition.opacity
        if y != 0 { t = t.combined(with: .offset(y: y)) }
        if scale != 1 { t = t.combined(with: .scale(scale: scale, anchor: anchor)) }
        return t
    }

    /// Level visuals (dots, rim, speaking glow) redraw at the meter's rate, no faster.
    nonisolated static let levelFrameInterval = 1.0 / 30

    // MARK: Loops: only while working, on Core Animation, never with Reduce Motion

    /// One full cycle, and the opacity it dips to.
    nonisolated public struct Loop: Sendable, Equatable {
        public var period: Double
        public var low: Double
        /// Working: needs-you rings, the trail's live dot, the thinking ripple.
        public static let breathe = Loop(period: 1.6, low: 0.55)
        /// Slow: the menu-bar orb while Lumi works.
        public static let pulse = Loop(period: 2.4, low: 0.3)
    }

    /// A running tile's comet ring turns once in this time.
    nonisolated static let spinPeriod = 1.2
    /// The working light's sweep along a page's top edge (04 §7.1).
    nonisolated public static let workingSweep: TimeInterval = 2.4

    nonisolated public static func loopRuns(visible: Bool, reduceMotion: Bool) -> Bool { visible && !reduceMotion }

    /// Opacity `from` ↔ `loop.low`, eased, forever.
    nonisolated public static func caBreathe(_ loop: Loop, from: Float = 1) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = Float(loop.low)
        a.duration = loop.period / 2
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }

    /// Opens (or closes) a window-sized surface, the switcher strip or the Panel, in the render
    /// server: fade in over 180 ms and spring from `scale` (response .24, damping .86) around
    /// `anchor`; close fades in 120 ms (220 ms after a pick). Reduce Motion: fades only.
    nonisolated static func animateWindow(_ layer: CALayer, opening: Bool, scale: CGFloat, anchor: CGPoint,
                                          afterPick: Bool = false, reduceMotion: Bool) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opening ? 0 : 1
        fade.toValue = opening ? 1 : 0
        fade.duration = opening ? (reduceMotion ? 0.12 : 0.18) : (afterPick && !reduceMotion ? 0.22 : 0.12)
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.opacity = opening ? 1 : 0
        layer.add(fade, forKey: "fade")
        guard opening, !reduceMotion else { return }
        var from = CATransform3DMakeTranslation(anchor.x, anchor.y, 0)
        from = CATransform3DScale(from, scale, scale, 1)
        from = CATransform3DTranslate(from, -anchor.x, -anchor.y, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.stiffness = pow(2 * .pi / 0.24, 2)
        spring.damping = 0.86 * 2 * sqrt(spring.stiffness)
        spring.duration = spring.settlingDuration
        spring.fromValue = from
        spring.toValue = CATransform3DIdentity
        layer.add(spring, forKey: "scale")
    }
}

/// Pop for answers that don't morph out of a visible pill or answer: from scale .06 and
/// blur 12 to 1.035 at 55%, then 1, over 560 ms, growing from the source point. Runs each
/// time `trigger` changes; at rest it is the identity.
///
/// Applied to the whole GlassEffectContainer: render transforms placed after
/// `.glassEffect` inside the container are not applied to the glass.
struct PopOnTrigger: ViewModifier {
    let trigger: Int
    let anchor: UnitPoint
    let reduceMotion: Bool

    struct Values: Sendable {
        var scale: CGFloat = 1
        var blur: CGFloat = 0
        var opacity: Double = 1
    }

    func body(content: Content) -> some View {
        let anchor = anchor
        // The overshoot lands at 55% of the pop, then it settles.
        let rise = 0.308, settle = 0.252
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: Values(), trigger: trigger) { view, v in
                view.scaleEffect(v.scale, anchor: anchor).blur(radius: v.blur).opacity(v.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    MoveKeyframe(0.06)
                    LinearKeyframe(1.035, duration: rise, timingCurve: Motion.popCurve)
                    LinearKeyframe(1, duration: settle, timingCurve: Motion.popCurve)
                }
                KeyframeTrack(\.blur) {
                    MoveKeyframe(12)
                    LinearKeyframe(0, duration: rise, timingCurve: Motion.popCurve)
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: rise, timingCurve: Motion.popCurve)
                }
            }
        }
    }
}

/// One content row entering after the surface pops.
struct RowRise: ViewModifier {
    let index: Int
    let reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : Motion.rowRise)
            .onAppear {
                withAnimation(reduceMotion ? Motion.crossfade : .easeOut(duration: Motion.rowDuration)
                    .delay(Motion.rowDelay(index))) { shown = true }
            }
    }
}

/// Fold toward the source: scale .55 (a tuck into the orb: .06), blur 8, opacity 0.
struct FoldOut: ViewModifier {
    let folding: Bool
    var scale: CGFloat = Motion.foldScale
    let anchor: UnitPoint
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(folding && !reduceMotion ? scale : 1, anchor: anchor)
            .blur(radius: folding && !reduceMotion ? 8 : 0)
            .opacity(folding ? 0 : 1)
    }
}

/// The surfaces, laid out on the whole panel before pop and fold scale them. The source point
/// is a unit point of the panel, so the scaled view must be the panel too: scaled around a
/// box only as big as its content, an answer folded toward the wrong place (the menu-bar orb
/// at the top right came out near the top centre).
struct SurfaceStage<Content: View>: View {
    let size: CGSize
    let popTrigger: Int
    let folding: Bool
    let foldScale: CGFloat
    let anchor: UnitPoint
    let reduceMotion: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .modifier(PopOnTrigger(trigger: popTrigger, anchor: anchor, reduceMotion: reduceMotion))
            .modifier(FoldOut(folding: folding, scale: foldScale, anchor: anchor, reduceMotion: reduceMotion))
    }
}

extension View {
    func rowRise(_ index: Int, reduceMotion: Bool) -> some View { modifier(RowRise(index: index, reduceMotion: reduceMotion)) }
}

/// A unit point for `point` inside `frame` (both in the same space), for scale anchors.
func unitPoint(_ point: CGPoint, in frame: CGRect) -> UnitPoint {
    guard frame.width > 0, frame.height > 0 else { return .center }
    return UnitPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
}
