import AppKit
import BuddyCore
import SwiftUI

/// The Panel's chrome state beside the page.
@MainActor @Observable
final class PanelChrome {
    var pinned = false
    var hovering = false
}

/// The Panel (04 §3.2): Regular glass shell (22 pt corner, hairline, 0 8 24 shadow), the 44 pt
/// header, the roster lane when there are teammates, and the page on a reading well inset
/// 5 pt (17 pt corner). A 1 pt ember working light runs across the top while a turn runs.
struct PanelRootView: View {
    let model: ConversationPageModel
    let chrome: PanelChrome
    let onPin: () -> Void
    let onExpand: () -> Void
    let onMinimise: () -> Void
    let onClose: () -> Void
    let onComposerFocus: (Bool) -> Void
    let onContentHeight: (CGFloat) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TokensReader { t in
            let shell = RoundedRectangle(cornerRadius: PageShape.panelRadius, style: .continuous)
            VStack(spacing: 0) {
                header(t)
                if model.page.team.isLive {
                    TeamLane(team: model.page.team.members, selected: model.openLane) { mate in
                        model.openLane = model.openLane == mate.id ? nil : mate.id
                    }
                    .padding(.bottom, 4)
                    .transition(Motion.transition(y: -6, reduceMotion: reduceMotion))
                }
                ConversationPageView(model: model, density: .compact, onComposerFocus: onComposerFocus,
                                     onContentHeight: { onContentHeight($0 + headerHeight) })
                    .background(t.well.color,
                                in: RoundedRectangle(cornerRadius: PageShape.panelWellRadius, style: .continuous))
                    .padding([.horizontal, .bottom], PageShape.panelWellInset)
            }
            // The lane tucks away once the lead has answered after the team (04 §5.3).
            .animation(Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: model.page.team.isLive)
            .modifier(SurfaceChrome(t: t, shape: shell))
            .overlay(alignment: .top) {
                if model.page.isRunning || model.page.team.isWorking {
                    WorkingLight(color: t.emberMark, reduceMotion: reduceMotion)
                        .clipShape(shell)
                        .allowsHitTesting(false)
                }
            }
            .onHover { chrome.hovering = $0 }
        }
    }

    private var headerHeight: CGFloat { PageDensity.headerHeight + (model.page.team.isLive ? 36 : 0) + PageShape.panelWellInset }

    private func header(_ t: Tokens) -> some View {
        HStack(spacing: 10) {
            SessionDisc(id: model.page.session, symbol: model.page.symbol, color: model.page.color, teammates: model.page.team.live,
                        working: model.page.isRunning || model.page.team.isWorking, needsYou: model.page.needsYou, size: PageDensity.headerDisc, title: model.page.title)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.page.title)
                    .font(Typeface.headline)
                    .foregroundStyle(t.text.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let sub = model.page.subtitle {
                    Text(sub).font(.system(size: 11)).foregroundStyle(t.secondaryText.color).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if chrome.hovering, !model.page.isRunning {
                headerButton("xmark", label: "Close", action: onClose)
            }
            headerButton(chrome.pinned ? "pin.fill" : "pin", label: chrome.pinned ? "Unpin" : "Pin", action: onPin)
            headerButton("arrow.up.left.and.arrow.down.right", label: "Open in Lumi", action: onExpand)
                .keyboardShortcut("e", modifiers: [.command, .shift])
            headerButton("minus", label: "Minimise", action: onMinimise)
                .keyboardShortcut("m", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .frame(height: PageDensity.headerHeight)
    }

    private func headerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.roundIcon)
            .accessibilityLabel(label)
            .help(label)
    }
}

/// A running page's working light: a 1 pt ember sweep along the top edge every 2.4 s, a static
/// line with Reduce Motion (04 §7.1). The Panel and the Studio column both use it (QA U22).
/// Core Animation runs the sweep, so a working page costs the app no CPU per frame.
public struct WorkingLight: View {
    let color: TokenColor
    let reduceMotion: Bool
    nonisolated static let sweepWidth: CGFloat = 160

    public init(color: TokenColor, reduceMotion: Bool) {
        self.color = color
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        Group {
            if reduceMotion {
                Rectangle().fill(color.opacity(0.6).color).frame(height: 1)
            } else {
                SweepLayer(color: color.nsColor, glow: color.opacity(0.14).nsColor)
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// From just off the leading edge to just off the trailing edge, once per sweep, linear.
    nonisolated static func sweep(width: CGFloat) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = -sweepWidth / 2
        a.toValue = width + sweepWidth / 2
        a.duration = Motion.workingSweep
        a.repeatCount = .infinity
        return a
    }
}

/// The sweep as a gradient layer: added once per width, never per frame.
private struct SweepLayer: NSViewRepresentable {
    let color: NSColor
    let glow: NSColor

    final class SweepView: NSView {
        let line = CAGradientLayer()
        var sweptWidth: CGFloat = -1

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            line.startPoint = CGPoint(x: 0, y: 0.5)
            line.endPoint = CGPoint(x: 1, y: 0.5)
            line.shadowRadius = 10
            line.shadowOpacity = 1
            line.shadowOffset = .zero
            layer?.addSublayer(line)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            line.bounds = CGRect(x: 0, y: 0, width: WorkingLight.sweepWidth, height: 1)
            line.position = CGPoint(x: -WorkingLight.sweepWidth / 2, y: bounds.midY)
            CATransaction.commit()
            // A new width restarts the sweep at the new span; the same width keeps it running.
            guard bounds.width != sweptWidth, bounds.width > 0 else { return }
            sweptWidth = bounds.width
            line.add(WorkingLight.sweep(width: bounds.width), forKey: "sweep")
        }
    }

    func makeNSView(context: Context) -> SweepView { SweepView(frame: .zero) }

    func updateNSView(_ view: SweepView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.line.colors = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
        view.line.shadowColor = glow.cgColor
        CATransaction.commit()
    }
}
