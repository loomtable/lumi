import SwiftUI

/// Motion values for the overlay.
enum Motion {
    /// Pop: ease (.2,.8,.2,1) over 560 ms.
    static let pop = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.56)
    static let popCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0.8),
                                           endControlPoint: UnitPoint(x: 0.2, y: 1))
    /// Fold: ease (.4,0,1,1) over 200 ms.
    static let fold = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.2)
    static let foldDuration: Duration = .milliseconds(200)
    /// Tuck: the same curve, a little longer for the trip to the menu-bar orb, down to a speck.
    static let tuck = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.3)
    static let tuckDuration: Duration = .milliseconds(300)
    static let tuckScale: CGFloat = 0.06
    static let foldScale: CGFloat = 0.55
    /// Full screen and back: one FLIP morph over 500 ms, ease (.2,.9,.25,1).
    static let fullScreen = Animation.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.5)
    /// Reduce Motion: crossfades only.
    static let crossfade = Animation.easeInOut(duration: 0.2)
    /// Pill appearance: spring (.2,1.15,.35,1) over 400 ms.
    static let pillIn = Animation.timingCurve(0.2, 1.15, 0.35, 1, duration: 0.4)
    /// Header and content rows enter at 140 ms + 55 ms × index, rising 8 pt over 360 ms.
    static func rowDelay(_ index: Int) -> Double { 0.14 + 0.055 * Double(index) }
    static let rowRise: CGFloat = 8
    static let rowDuration = 0.36
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
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: Values(), trigger: trigger) { view, v in
                view.scaleEffect(v.scale, anchor: anchor).blur(radius: v.blur).opacity(v.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    MoveKeyframe(0.06)
                    LinearKeyframe(1.035, duration: 0.308, timingCurve: Motion.popCurve)
                    LinearKeyframe(1, duration: 0.252, timingCurve: Motion.popCurve)
                }
                KeyframeTrack(\.blur) {
                    MoveKeyframe(12)
                    LinearKeyframe(0, duration: 0.308, timingCurve: Motion.popCurve)
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: 0.308, timingCurve: Motion.popCurve)
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
