import AppKit
import BuddyCore
import SwiftUI

/// The running queries' capsules, stacked and centred at the top of one display's visible
/// frame (`OverlayModel.progressOrigin`). They never take focus; only a capsule that needs the
/// user takes a click, which opens its approval or question.
struct ProgressLayer: View {
    let model: OverlayModel
    let displayFrame: CGRect
    let onEvent: (OverlayEvent) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TokensReader { t in
            ProgressColumn(shown: model.progress, t: t, bright: model.brightBackdrop, reduceMotion: reduceMotion,
                           onOpen: { item in item.session.map { onEvent(.progressClicked($0)) } },
                           onRowFrame: { id, local in
                               // Panel-local → global top-left, for click-through.
                               model.progressRowFrames[id] = local.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY)
                           })
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.progressSize = $0 }
                .padding(.leading, model.progressOrigin.x - displayFrame.minX)
                .padding(.top, model.progressOrigin.y - displayFrame.minY)
        }
    }
}

/// The capsules, top to bottom, then "+N more".
struct ProgressColumn: View {
    let shown: ProgressStack.Shown
    let t: Tokens
    var bright = false
    var reduceMotion = false
    var onOpen: (ProgressItem) -> Void = { _ in }
    /// Each capsule's frame in the panel, so a needs-you one can take clicks.
    var onRowFrame: (Int, CGRect) -> Void = { _, _ in }

    var body: some View {
        VStack(spacing: OverlayModel.progressGap) {
            ForEach(shown.rows) { item in
                capsule(item)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onRowFrame(item.id, $0) }
                    .transition(Motion.transition(y: -6, reduceMotion: reduceMotion))
            }
            if let more = shown.moreLabel {
                Text(more)
                    .font(Typeface.label)
                    .foregroundStyle(t.secondaryText.color)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 22)
                    .background(Capsule().fill(t.well.color))
                    .padding(Tokens.pillWellInset)
                    .modifier(SurfaceChrome(t: t, shape: Capsule(), bright: bright))
                    .accessibilityLabel("\(shown.more) more running")
            }
        }
        .fixedSize()
        .animation(Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: shown)
    }

    @ViewBuilder private func capsule(_ item: ProgressItem) -> some View {
        let chrome = SurfaceChrome(t: t, shape: Capsule(), bright: bright, border: item.needsYou ? Tokens.amberBorder : nil)
        if item.needsYou {
            ProgressCapsule(item: item, t: t)
                .modifier(chrome)
                .contentShape(Capsule())
                .onTapGesture { onOpen(item) }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens it")
                .accessibilityAction { onOpen(item) }
        } else {
            ProgressCapsule(item: item, t: t)
                .modifier(chrome)
                .allowsHitTesting(false)
        }
    }
}

/// One query: the session's glyph and title, then what it's doing now.
struct ProgressCapsule: View {
    let item: ProgressItem
    let t: Tokens

    /// The pill's status width: the stack lines up with it.
    static let maxWidth: CGFloat = 360

    var body: some View {
        // HugWrap: inside `.fixedSize()` a plain maxWidth frame would not cut the line.
        HugWrap(maxWidth: Self.maxWidth - 2 * Tokens.pillWellInset - 20) {
            row
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(Capsule().fill(t.well.color))
        .padding(Tokens.pillWellInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.teammates > 0
            ? "\(item.title), with \(item.teammates) \(item.teammates == 1 ? "teammate" : "teammates"): \(item.line)"
            : "\(item.title): \(item.line)")
    }

    private var row: some View {
        HStack(spacing: 6) {
            AgentMark(id: item.session ?? SessionID(rawValue: "query-\(item.id)"), symbol: item.symbol, monogram: item.monogram,
                      color: item.color, ring: item.needsYou ? .needsYou : .none, size: 18)
            Text(item.title)
                .font(Typeface.labelStrong)
                .foregroundStyle(t.text.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let note = item.teammatesNote {
                Text("· " + note)
                    .font(Typeface.label.monospacedDigit())
                    .foregroundStyle(t.secondaryText.color)
                    .fixedSize()
                    .contentTransition(.numericText())
            }
            // Quiet for 90 s: the line says for how long (inspire #4), checked every 30 s.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(item.needsYou ? item.line : Liveness.line(item.line, since: item.lastEventAt, now: context.date))
                    .font(item.needsYou ? Typeface.labelStrong : Typeface.label)
                    .foregroundStyle((item.needsYou ? t.amber : t.secondaryText).color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    .animation(Motion.quick, value: item.line)
            }
        }
    }
}
