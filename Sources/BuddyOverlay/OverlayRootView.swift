import BuddyCore
import SwiftUI

/// Everything on one display's panel. The pill and the answer share one glassEffectID in
/// one GlassEffectContainer, so the pill morphs into the card or chip (Motion).
struct OverlayRootView: View {
    let model: OverlayModel
    /// The display this panel covers. The pill and answers render only on the active
    /// display; the capsule only on the display with the active menu bar.
    let displayID: CGDirectDisplayID
    let onEvent: (OverlayEvent) -> Void
    let onClose: () -> Void
    let onToggleFullScreen: () -> Void
    let onSubmit: (SubmitSource) -> Void
    let onCapsuleTap: () -> Void
    var onDrag: (DragTarget, DragPhase, CGSize, CGPoint) -> Void = { _, _, _, _ in }
    var onCopy: () -> Void = {}
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayFrame: CGRect { model.displayFrames[displayID] ?? .zero }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if displayFrame == model.screenFrame {
                surfaces
            }
            RingsLayer(model: model, displayFrame: displayFrame)
            ToastLayer(model: model, displayFrame: displayFrame, onEvent: onEvent)
            if model.capsuleVisible, displayFrame == model.capsuleScreenFrame {
                CapsuleLayer(model: model, displayFrame: displayFrame, onEvent: onEvent, onTap: onCapsuleTap,
                             onDrag: { onDrag(.capsule, $0, $1, $2) })
            }
        }
        .frame(width: displayFrame.width, height: displayFrame.height, alignment: .topLeading)
    }

    private var surfaces: some View {
        TokensReader { t in
            // Pop and fold transform the whole container; only one surface is visible
            // at a time, and transforms inside the container don't reach the glass.
            SurfaceStage(size: model.screenFrame.size, popTrigger: model.popTrigger, folding: model.folding,
                         foldScale: model.foldScale, anchor: sourceAnchor, reduceMotion: reduceMotion) {
                GlassEffectContainer(spacing: 24) {
                    ZStack(alignment: .topLeading) {
                        if model.surface.isPill {
                            pill(t)
                        }
                        if case .answer(let answer, let placement, let style) = model.surface {
                            answerView(t, answer: answer, placement: placement, style: style)
                        }
                    }
                }
            }
        }
    }

    /// The source point (pill or anchor) as a unit point of the panel.
    private var sourceAnchor: UnitPoint {
        let size = model.screenFrame.size
        let p = model.local(model.surface.isPill ? CGPoint(x: model.pillFrame.minX, y: model.pillFrame.midY) : model.source)
        return unitPoint(p, in: CGRect(origin: .zero, size: size))
    }

    private func pill(_ t: Tokens) -> some View {
        let local = model.local(model.pillFrame)
        let listening = if case .listening = model.surface { true } else { false }
        return PillContent(model: model, t: t, onSubmit: { onSubmit(.textBox) })
            .modifier(SurfaceChrome(t: t, shape: Capsule(), hairline: !listening, bright: model.brightBackdrop))
            .overlay { if listening { ListeningRim(level: model.mic, t: t) } }
            // Speech can start while only the pill is up (Quick's first sentence): it glows too.
            .modifier(SpeakingGlow(level: listening ? 0 : Self.glowLevel(speaking: model.speaking, glow: model.settings.glow,
                                                                           speech: model.speech),
                                   t: t, shape: Capsule()))
            .surfaceDrag { onDrag(.pill, $0, $1, $2) }
            .glassEffectID("surface", in: glass)
            .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.pillSize = $0 }
            .padding(.leading, local.minX)
            .padding(.top, local.minY)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
    }

    private func answerView(_ t: Tokens, answer: Answer, placement: Placement, style: Placer.Style) -> some View {
        let full = model.fullScreen
        let side = full ? nil : OverlayModel.tailSide(placement, style: style)
        let body = full ? model.fullScreenFrame : placement.frame
        let outer = full ? body : OverlayModel.outerFrame(placement, style: style)
        let local = model.local(outer)
        let shape = CardShape(cornerRadius: style == .chip && !full ? Tokens.chipRadius : Tokens.cardRadius,
                              tailSide: side, tailOffset: placement.tailOffset ?? 0)
        return AnswerContent(answer: answer, style: style, t: t, web: model.web,
                             webHeight: full ? model.fullScreenWebHeight : model.webHeight,
                             speaking: model.speaking, inkIn: model.settings.inkIn && !model.headlineAlreadyShown, fullScreen: full,
                             reduceMotion: reduceMotion,
                             onEvent: onEvent, onClose: onClose, onToggleFullScreen: onToggleFullScreen, onCopy: onCopy,
                             reply: model.hasFocus ? Bindable(model).reply : nil,
                             replyAutoFocus: model.typed,
                             onSubmitReply: { onSubmit(.reply) })
            // Top-aligned: in full screen the content sits at the top, actions right under it.
            .frame(width: body.width, height: body.height, alignment: .top)
            .padding(Self.tailPadding(side))
            .modifier(SurfaceChrome(t: t, shape: shape, bright: model.brightBackdrop,
                                    border: answer.block.needsApproval && style != .chip ? Tokens.amberBorder : nil))
            .modifier(SpeakingGlow(level: Self.glowLevel(speaking: model.speaking, glow: model.settings.glow, speech: model.speech),
                                   t: t, shape: shape))
            .surfaceDrag(enabled: !full) { onDrag(.answer, $0, $1, $2) }
            .glassEffectID("surface", in: glass)
            .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
            .id(model.answerID)
            .padding(.leading, local.minX)
            .padding(.top, local.minY)
    }

    /// The speaking glow's level: zero (no glow work) when not speaking or turned off. The
    /// level is an autoclosure so `model.speech` isn't even read (observed) when the glow is
    /// off: otherwise the whole root re-renders ~30 times a second while speaking.
    static func glowLevel(speaking: Bool, glow: Bool, speech: @autoclosure () -> Double) -> Double {
        speaking && glow ? speech() : 0
    }

    static func tailPadding(_ side: CardShape.Side?) -> EdgeInsets {
        let l = CardShape.tailLength
        switch side {
        case .top: return EdgeInsets(top: l, leading: 0, bottom: 0, trailing: 0)
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: l, trailing: 0)
        case .left: return EdgeInsets(top: 0, leading: l, bottom: 0, trailing: 0)
        case .right: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: l)
        case nil: return EdgeInsets()
        }
    }
}

/// Listening rim: a 1.5 pt inset ember stroke at alpha .35 + .65 × mic, plus a bloom of
/// 10 pt × mic (alpha .45 dark, .30 light).
struct ListeningRim: View {
    let level: LevelBox
    let t: Tokens

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let v = level.value
            Capsule()
                .strokeBorder(t.emberMark.color.opacity(0.35 + 0.65 * v), lineWidth: 1.5)
                .shadow(color: t.emberMark.color.opacity((t.variant.dark ? 0.45 : 0.30) * v), radius: 10 * v)
        }
        .allowsHitTesting(false)
    }
}

/// Speaking glow: brightness follows the reply's loudness (Effects).
struct SpeakingGlow<S: InsettableShape>: ViewModifier {
    let level: Double
    let t: Tokens
    let shape: S

    func body(content: Content) -> some View {
        content
            .overlay {
                if level > 0.001 {
                    shape.strokeBorder(t.emberMark.color.opacity(0.10 + 0.5 * level), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: t.emberMark.color.opacity(0.42 * level), radius: level > 0.001 ? 6 + 52 * level : 0)
    }
}

extension View {
    /// Drags a surface by its background or rim: buttons, links and text fields keep their own
    /// clicks. Global coordinates, so the translation stays steady while the surface follows.
    func surfaceDrag(enabled: Bool = true, _ onDrag: @escaping (DragPhase, CGSize, CGPoint) -> Void) -> some View {
        gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { onDrag(.changed, $0.translation, $0.startLocation) }
            .onEnded { onDrag(.ended, $0.translation, $0.startLocation) },
                isEnabled: enabled)
    }
}
