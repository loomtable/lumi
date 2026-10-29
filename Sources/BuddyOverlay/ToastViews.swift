import SwiftUI

/// Toasts on one display's panel (UI inventory).
struct ToastLayer: View {
    let model: OverlayModel
    let displayFrame: CGRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TokensReader { t in
            ZStack(alignment: .topLeading) {
                if let toast = model.toast, displayFrame.contains(toast.origin) {
                    let o = local(toast.origin)
                    Text(toast.text)
                        .font(Typeface.labelStrong)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(t.text.color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(t.well.color))
                        .padding(Tokens.pillWellInset)
                        .modifier(SurfaceChrome(t: t, shape: Capsule(), bright: model.brightBackdrop))
                        // Measured before the position padding, which would add the offset.
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.toastSize = $0 }
                        .id(toast.id)
                        .padding(.leading, o.x)
                        .padding(.top, o.y)
                        .transition(Motion.transition(y: 4, reduceMotion: reduceMotion))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - displayFrame.minX, y: p.y - displayFrame.minY) }
}
