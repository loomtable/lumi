import SwiftUI

/// One-shot rings on one display's panel. They never take clicks.
struct RingsLayer: View {
    let model: OverlayModel
    let displayFrame: CGRect

    var body: some View {
        TokensReader { t in
            ZStack(alignment: .topLeading) {
                ForEach(model.rings.filter { displayFrame.intersects($0.ring.rect) }) { active in
                    RingView(ring: active.ring, t: t, displayFrame: displayFrame)
                        .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A soft wash behind a spot: a feathered tint with no border, so nothing traces the words
/// (replaces the stroke-and-halo ring). Ember on light Macs, mist on
/// dark ones. Fades in over 450 ms, widening slightly, with a soft bloom as it lands (rises
/// for 250 ms, settles over 350 ms) so the eye finds it; Reduce Motion fades only.
struct RingView: View {
    let ring: Ring
    let t: Tokens
    let displayFrame: CGRect
    @State private var shown = false
    @State private var bloom = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bloom strength: peak, then where it rests.
    static let bloomPeak = 1.0
    static let bloomRest = 0.35
    /// The bloom rises as the wash lands, then settles (together, the ring's 450 ms and a bit).
    static let bloomRise = 0.25
    static let bloomSettle = 0.35

    var body: some View {
        let r = RingWash.washRect(for: ring.rect).offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        RingWash(label: ring.label, t: t)
            .background {
                // A wider, softer copy of the wash: the bloom. Borderless, like the wash.
                Capsule(style: .continuous)
                    .fill(RingWash.washColor(t).color)
                    .blur(radius: RingWash.feather * 2.5)
                    .opacity(bloom)
            }
            .frame(width: r.width, height: r.height)
            .scaleEffect(x: shown || reduceMotion ? 1 : 0.96, y: 1)
            .opacity(shown ? 1 : 0)
            .padding(.leading, r.minX)
            .padding(.top, r.minY)
            .onAppear {
                withAnimation(Motion.ring) { shown = true }
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: Self.bloomRise)) { bloom = Self.bloomPeak } completion: {
                    withAnimation(.easeInOut(duration: Self.bloomSettle)) { bloom = Self.bloomRest }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The wash itself, sized to the spot plus `padding`. With a label, a small ember number dot
/// sits just after the spot, in both appearances. Increase Contrast adds a thin ember line under the spot, never a
/// frame around it.
struct RingWash: View {
    let label: String?
    let t: Tokens

    /// The wash reaches this far past the spot before it feathers out.
    nonisolated static let padding = CGSize(width: 6, height: 3)
    static let feather: CGFloat = 6
    /// A caret is a zero-width rect; give it a visible wash.
    static let minWidth: CGFloat = 10
    static let dotSize: CGFloat = 16
    nonisolated static let dotGap: CGFloat = 5

    /// Wash colour: ember on light Macs; mist on dark ones, where an ember wash read as muddy.
    /// Light got stronger on Oct 17 (rings weren't visible enough);
    /// dark went back to a softer, greyer mist, 25%. Increase Contrast makes both stronger.
    static func washColor(_ t: Tokens) -> TokenColor {
        let v = t.variant
        return v.dark ? t.mist.opacity(v.increaseContrast ? 0.34 : 0.25)
                      : t.emberMark.opacity(v.increaseContrast ? 0.50 : 0.36)
    }

    static func washRect(for spot: CGRect) -> CGRect {
        let spot = spot.width < minWidth ? spot.insetBy(dx: (spot.width - minWidth) / 2, dy: 0) : spot
        return spot.insetBy(dx: -padding.width, dy: -padding.height)
    }

    var body: some View {
        Capsule(style: .continuous)
            .fill(Self.washColor(t).color)
            .blur(radius: Self.feather)
            .overlay(alignment: .bottom) {
                if t.variant.increaseContrast {
                    Capsule().fill(t.emberMark.color)
                        .frame(height: 2)
                        .padding(.horizontal, Self.padding.width)
                }
            }
            .overlay(alignment: .trailing) {
                if let label {
                    Text(label)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(t.onEmber.color)
                        .padding(.horizontal, 4)
                        .frame(minWidth: Self.dotSize, minHeight: Self.dotSize)
                        .background(Capsule().fill(t.emberMark.color))
                        .fixedSize()
                        .alignmentGuide(.trailing) { d in d[.leading] - Self.dotGap + Self.padding.width }
                }
            }
    }
}
