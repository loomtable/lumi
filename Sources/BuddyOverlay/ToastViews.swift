import SwiftUI

/// Toasts and the ↩ Back / Resume chips on one display's panel (UI inventory).
struct ToastLayer: View {
    let model: OverlayModel
    let displayFrame: CGRect
    let onEvent: (OverlayEvent) -> Void

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
                        .transition(.opacity.combined(with: .offset(y: 4)))
                        .allowsHitTesting(false)
                }
                if let chip = model.conversationChip, displayFrame.contains(chip.origin) {
                    let o = local(chip.origin)
                    Button {
                        onEvent(chip.kind == .back ? .backToPrevious : .resumeConversation)
                    } label: {
                        HStack(spacing: 0) {
                            Text(chip.label)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let detail = chip.detail {
                                Text(" · \(detail)").lineLimit(1).fixedSize()
                            }
                        }
                        .font(Typeface.labelStrong)
                        .foregroundStyle(t.emberText.color)
                        .frame(maxWidth: 340, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(t.well.color))
                            .padding(Tokens.pillWellInset)
                            .modifier(SurfaceChrome(t: t, shape: Capsule(), bright: model.brightBackdrop))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { model.conversationChipSize = $0 }
                    .id(chip.id)
                    .padding(.leading, o.x)
                    .padding(.top, o.y)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
            }
        }
    }

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - displayFrame.minX, y: p.y - displayFrame.minY) }
}
