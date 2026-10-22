import AppKit
import SwiftUI

/// The research capsule and its peek on one display's panel (Background task).
struct CapsuleLayer: View {
    let model: OverlayModel
    let displayFrame: CGRect
    let onEvent: (OverlayEvent) -> Void
    let onTap: () -> Void
    var onDrag: (DragPhase, CGSize, CGPoint) -> Void = { _, _, _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        // The capsule is always dark, and follows Reduce Transparency / Increase Contrast.
        let t = Tokens(.init(dark: true, reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased))
        let capsule = model.capsuleFrame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        let peek = model.peekFrame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        ZStack(alignment: .topLeading) {
            if let job = model.displayedCapsule {
                CapsuleView(job: job, others: model.otherRunningJobs, t: t, nudge: model.capsuleNudge, onTap: onTap)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { model.capsuleSize = $0 }
                    .surfaceDrag(onDrag)
                    .padding(.leading, capsule.minX)
                    .padding(.top, capsule.minY)
                if model.peekOpen, let peeked = model.peekJob {
                    PeekCard(job: peeked, t: t, onStop: { onEvent(.stopResearch(peeked.id)) })
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.peekSize = $0 }
                        .padding(.leading, peek.minX)
                        .padding(.top, peek.minY)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Capsule tokens: rgba(11,12,15,.94) with a white hairline at 18%.
private enum CapsuleTokens {
    static let fill = TokenColor(11 / 255, 12 / 255, 15 / 255, 0.94)
    static let hairline = TokenColor(1, 1, 1, 0.18)
    static let font = Font.system(size: 12, weight: .medium, design: .rounded)
}

struct CapsuleView: View {
    let job: CapsuleState
    let others: Int
    let t: Tokens
    let nudge: Int
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            switch job.status {
            case .done:
                Text("✓").font(CapsuleTokens.font.weight(.bold)).foregroundStyle(t.sage.color)
            case .failed:
                Circle().fill(t.rose.color).frame(width: 6, height: 6)
            case .queued, .running, .cancelled:
                IndeterminateBar(fill: t.emberMark.nsColor, track: NSColor(white: 1, alpha: 0.15),
                                 running: job.isRunning && !job.reconnecting)
                    .frame(width: 50, height: 4)
            }
            Text(job.line)
                .font(CapsuleTokens.font)
                .foregroundStyle(t.text.color)
                .lineLimit(1)
                .contentTransition(.numericText())
            if others > 0 {
                Text("+\(others)")
                    .font(CapsuleTokens.font)
                    .foregroundStyle(t.secondaryText.color)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(t.usesGlass ? CapsuleTokens.fill.color : t.opaqueSurface.color))
        .overlay(Capsule().strokeBorder((t.variant.increaseContrast ? t.hairlineBright : CapsuleTokens.hairline).color, lineWidth: 1))
        .modifier(CapsuleGlass(enabled: t.usesGlass))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
        .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : nudge) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            // The done nudge ("one nudge").
            KeyframeTrack {
                LinearKeyframe(1.12, duration: 0.18, timingCurve: .easeOut)
                SpringKeyframe(0.97, duration: 0.25)
                SpringKeyframe(1.0, duration: 0.47)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(job.topic): \(job.line)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { onTap() }
    }
}

/// Regular glass under the capsule, except with Reduce Transparency (opaque only).
private struct CapsuleGlass: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(.regular.tint(CapsuleTokens.fill.opacity(0.45).color), in: .capsule)
        } else {
            content
        }
    }
}

/// The peek card under a running (or failed) capsule: topic, live steps, Stop.
struct PeekCard: View {
    let job: CapsuleState
    let t: Tokens
    let onStop: () -> Void
    static let maxSteps = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.topic)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(t.text.color)
                .lineLimit(2)
            if case .failed(let reason) = job.status {
                Text(reason).font(Typeface.label).foregroundStyle(t.amber.color)
            } else {
                let steps = job.steps.suffix(Self.maxSteps)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    Text(step)
                        .font(Typeface.label)
                        .foregroundStyle(i == steps.count - 1 ? t.text.color : t.secondaryText.color)
                        .lineLimit(1)
                }
                if job.isRunning {
                    ActionButton(title: "Stop", kind: .quiet, t: t, action: onStop)
                }
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.wellRadius, style: .continuous).fill(CapsuleTokens.fill.color))
        .overlay(RoundedRectangle(cornerRadius: Tokens.wellRadius, style: .continuous)
            .strokeBorder(CapsuleTokens.hairline.color, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
    }
}

/// An indeterminate progress bar (no honest percentage, so no percentage). Animated by
/// Core Animation in the render server, so a research job running for minutes costs the app
/// no CPU per frame: 35% fill sliding across every 1.3 s.
struct IndeterminateBar: NSViewRepresentable {
    let fill: NSColor
    let track: NSColor
    let running: Bool

    final class BarView: NSView {
        let fillLayer = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 2
            layer?.masksToBounds = true
            fillLayer.cornerRadius = 2
            layer?.addSublayer(fillLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            let w = bounds.width * 0.35
            fillLayer.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            fillLayer.anchorPoint = CGPoint(x: 0, y: 0)
            fillLayer.position = CGPoint(x: -w, y: 0)
        }

        func setRunning(_ running: Bool) {
            if running, fillLayer.animation(forKey: "slide") == nil {
                let anim = CABasicAnimation(keyPath: "position.x")
                anim.fromValue = -bounds.width * 0.35
                anim.toValue = bounds.width * 1.0
                anim.duration = 1.3
                anim.repeatCount = .infinity
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                fillLayer.add(anim, forKey: "slide")
            } else if !running {
                fillLayer.removeAnimation(forKey: "slide")
            }
        }
    }

    func makeNSView(context: Context) -> BarView {
        let v = BarView(frame: NSRect(x: 0, y: 0, width: 50, height: 4))
        v.layer?.backgroundColor = track.cgColor
        v.fillLayer.backgroundColor = fill.cgColor
        return v
    }

    func updateNSView(_ view: BarView, context: Context) {
        view.layer?.backgroundColor = track.cgColor
        view.fillLayer.backgroundColor = fill.cgColor
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.setRunning(running)
    }
}
