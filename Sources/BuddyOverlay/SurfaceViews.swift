import AppKit
import BuddyCore
import SwiftUI

/// Resolves tokens from the environment (theme, appearance, Reduce Transparency, Increase Contrast).
public struct TokensReader<Content: View>: View {
    @Environment(\.lumiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder let content: (Tokens) -> Content

    public init(@ViewBuilder content: @escaping (Tokens) -> Content) { self.content = content }

    public var body: some View {
        content(Tokens(.init(dark: scheme == .dark, theme: theme, reduceTransparency: reduceTransparency,
                             increaseContrast: contrast == .increased)))
    }
}

/// Fonts: the macOS (HIG) scale, so answers read like a native panel (the
/// earlier sizes, 2 pt above the defaults, felt too big). Headline 15, body 13, labels 11
/// (buttons are 12, in `PillButtonStyle`).
enum Typeface {
    static let headline = Font.system(size: 15, weight: .semibold)
    static let chipHeadline = Font.system(size: 14, weight: .semibold)
    static let detail = Font.system(size: 13)
    static let label = Font.system(size: 11, weight: .medium, design: .rounded)
    static let labelStrong = Font.system(size: 11, weight: .semibold, design: .rounded)
}

/// The live ember outline on a surface: the mic's while listening, the reply's while speaking.
enum SurfaceRim {
    case listening(LevelBox)
    case speaking(LevelBox)
}

/// Where a surface (its glass) and its outlines were laid out, in global points (tests only;
/// nil in the app).
enum SurfacePart { case surface, outline }
typealias SurfaceProbe = @MainActor (SurfacePart, CGRect) -> Void

extension EnvironmentValues {
    @Entry var surfaceProbe: SurfaceProbe?
}

/// Glass (or the opaque surface with Reduce Transparency) plus the hairline, inner highlight,
/// shadow and live rim, all on one shape.
///
/// Every outline is drawn on the content itself, before the glass: glass transitions move and
/// scale their content (`.matchedGeometry`), so an outline added after the glass sat on a
/// different frame than the surface it belongs to (owner, Oct 29: the ember rim off to the
/// side of the pill and past the card).
struct SurfaceChrome<S: InsettableShape>: ViewModifier {
    /// The outline drawn over the surface. Liquid Glass draws its own edge, so over glass we add
    /// only what it can't: the bright-backdrop hairline, an explicit border, or the
    /// Increase Contrast hairline. Opaque surfaces (Reduce Transparency) keep the hairline.
    static func edge(_ t: Tokens, bright: Bool, border: TokenColor?) -> TokenColor? {
        if let border { return border }
        if !t.usesGlass || t.variant.increaseContrast { return bright ? t.hairlineBright : t.hairline }
        return bright ? t.hairlineBright : nil
    }

    /// The inner highlight imitates glass on opaque surfaces; real glass has its own.
    static func drawsHighlight(_ t: Tokens) -> Bool { !t.usesGlass }

    let t: Tokens
    let shape: S
    var hairline = true
    /// Over a bright backdrop the hairline goes from 16% to 30% and the shadow deepens.
    var bright = false
    /// Replaces the hairline, e.g. the approval card's amber outline.
    var border: TokenColor?
    var rim: SurfaceRim?
    @Environment(\.surfaceProbe) private var probe

    func body(content: Content) -> some View {
        let decorated = content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe?(.surface, $0) }
            .overlay { outlines }
            .background {
                // One soft shadow, deeper over bright backdrops, cast by the outline only: a
                // shadow on the container would shade every child (text halos).
                OutlineShadow(shape: shape, deep: bright)
            }
        Group {
            if t.usesGlass {
                decorated.glassEffect(.regular.tint(t.glassTint.color), in: shape)
            } else {
                decorated.background(shape.fill(t.opaqueSurface.color))
            }
        }
    }

    private var outlines: some View {
        ZStack {
            Color.clear  // the shape's full frame, even with nothing to draw
            if hairline, let edge = Self.edge(t, bright: bright, border: border) {
                shape.strokeBorder(edge.color, lineWidth: Tokens.hairlineWidth)
                if Self.drawsHighlight(t) {
                    shape.inset(by: 1).strokeBorder(t.innerHighlight.color, lineWidth: 1)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .clear, location: 0.25)],
                                             startPoint: .top, endPoint: .bottom))
                }
            }
            switch rim {
            case .listening(let level): ListeningRim(level: level, t: t, shape: shape)
            case .speaking(let level): SpeakingGlow(level: level, t: t, shape: shape).transition(.opacity)
            case nil: EmptyView()
            }
        }
        .allowsHitTesting(false)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe?(.outline, $0) }
    }
}

/// A soft shadow outside a shape, with the area under the shape cut away. `deep` is the
/// stronger one over bright backdrops.
struct OutlineShadow<S: InsettableShape>: View {
    let shape: S
    var deep = false
    var body: some View {
        shape.fill((deep ? Tokens.outlineShadowDeep : Tokens.outlineShadow).color)
            .blur(radius: deep ? 14 : 10)
            .offset(y: deep ? 6 : 5)
            .mask {
                ZStack {
                    Rectangle().padding(-40)
                    shape.blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

// MARK: Pill

struct PillContent: View {
    static let statusWidth: CGFloat = 360
    static let headlineWidth: CGFloat = 480
    @Bindable var model: OverlayModel
    let t: Tokens
    var onSubmit: () -> Void = {}
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            switch model.surface {
            case .textBox:
                TextField("", text: $model.draft, prompt: Text("Ask about this…").foregroundStyle(t.secondaryText.color))
                    .textFieldStyle(.plain)
                    .font(Typeface.detail)
                    .foregroundStyle(t.text.color)
                    .frame(width: 300)
                    .focused($fieldFocused)
                    .onSubmit(onSubmit)
                    .onAppear { fieldFocused = true }
                    .onChange(of: model.hasFocus) { _, focused in if focused { fieldFocused = true } }
                    .accessibilityLabel("Ask about this")
            case .listening(let hint):
                PillLead(target: model.pillTarget, icon: model.pillTargetIcon, working: false, t: t)
                if model.settings.dotField {
                    DotField(level: model.mic, t: t)
                } else {
                    LevelBars(level: model.mic, t: t)
                }
                let label = OverlayModel.listeningLabel(hint: hint, micReady: model.micReady,
                                                        gettingReady: model.showsGettingReady, showsHint: model.showsListeningHint)
                let quiet = model.showsListeningHint || !model.micReady
                Text(label.text)
                    .font(quiet ? Typeface.label : Typeface.labelStrong)
                    .foregroundStyle(quiet ? t.secondaryText.color : t.emberText.color)
                    .opacity(label.visible ? 1 : 0)
                    .contentTransition(.opacity)
            case .thinking(_, let status):
                // The live step is enough: no Quick/Deep chip (owner, Oct 29).
                if model.pillTarget == .none {
                    ThinkingOrb(t: t)
                } else {
                    PillLead(target: model.pillTarget, icon: model.pillTargetIcon, working: true, t: t)
                }
                if let status {
                    // A progress line is one line; the answer's headline gets two, wider and heavier,
                    // so it isn't cut off before the card arrives.
                    let headline = model.statusIsHeadline
                    // HugWrap, not .frame(maxWidth:): the pill is fixedSize, which proposes no
                    // width, so a plain frame would measure one unwrapped line.
                    HugWrap(maxWidth: headline ? PillContent.headlineWidth : PillContent.statusWidth) {
                        Text(status)
                            .font(headline ? Typeface.labelStrong : Typeface.label)
                            .foregroundStyle(t.text.color)
                            .lineLimit(headline ? 2 : 1)
                    }
                    .contentTransition(.opacity)
                }
            case .none, .answer:
                EmptyView()
            }
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, model.statusIsHeadline ? 6 : 0)  // two lines clear the capsule's ends
        .frame(minHeight: 28)
        .background(Capsule().fill(t.well.color))
        .padding(Tokens.pillWellInset)
    }
}

/// The pill's lead (63-SWITCHER-UX): who it talks to. A session's agent mark (its colour and
/// glyph, the origin app's badge, a comet orbit while it works) and its title; ＋ and "New session";
/// nothing when the send decides.
struct PillLead: View {
    static let orbSize: CGFloat = 24
    static let titleWidth: CGFloat = 200

    let target: PillTarget
    let icon: NSImage?
    let working: Bool
    let t: Tokens

    var body: some View {
        switch target {
        case .none:
            EmptyView()
        case .new:
            HStack(spacing: 7) {
                ZStack {
                    Circle().strokeBorder(t.secondaryText.color, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2.5]))
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(t.text.color)
                }
                .frame(width: Self.orbSize, height: Self.orbSize)
                title("New session")
            }
            .accessibilityElement(children: .combine)
        case .session(let s):
            HStack(spacing: 7) {
                ZStack {
                    AgentMark(id: s.id, symbol: s.symbol, monogram: AgentMark.monogram(s.title), color: s.color,
                              ring: working ? .comet : .none, size: Self.orbSize, animating: working)
                    if let icon {
                        Image(nsImage: icon).resizable().frame(width: 11, height: 11)
                            .offset(x: 9, y: 9)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: Self.orbSize, height: Self.orbSize)
                title(s.title)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// HugWrap, not a frame: the pill is fixedSize (see `PillContent`).
    private func title(_ text: String) -> some View {
        HugWrap(maxWidth: Self.titleWidth) {
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(t.text.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// Its content at its natural width when that fits, else wrapped at `maxWidth`, and as tall
/// as that needs, even with no width proposed (inside `.fixedSize()`).
struct HugWrap: Layout {
    var maxWidth: CGFloat

    private func width(_ subview: LayoutSubview) -> CGFloat {
        min(subview.sizeThatFits(.unspecified).width, maxWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        return s.sizeThatFits(ProposedViewSize(width: width(s), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let s = subviews.first else { return }
        s.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: width(s), height: nil))
    }
}

/// 18 dots (6 × 3) lit from the centre outward by the mic level; the middle row at full
/// gain, the outer rows at 0.7; idle breathing at 22% ± 8%.
struct DotField: View {
    let level: LevelBox
    let t: Tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let columns = 6, rows = 3
    static let dot: CGFloat = 4, gap: CGFloat = 2

    /// The idle glow under the level: 22% ± 8%, one breath per 2.4 s (`Motion.Loop.pulse`).
    nonisolated static func breath(phase: Double) -> Double { 0.22 + 0.08 * sin(phase * 2 * .pi) }

    static func brightness(column: Int, row: Int, level: Double, breath: Double) -> Double {
        let centre = Double(columns - 1) / 2
        let distance = abs(Double(column) - centre) / centre  // 0 at the centre, 1 at the ends
        let gain = row == rows / 2 ? 1.0 : 0.7
        // A column ramps in over 0.25 of level once the level passes 0.75 × its distance
        // from the centre, so full level lights every column.
        let lit = min(max((level - distance * 0.75) / 0.25, 0), 1) * gain
        return min(max(breath, lit), 1)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: Motion.levelFrameInterval)) { context in
            let loop = Motion.Loop.pulse
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loop.period) / loop.period
            let breath = reduceMotion ? Self.breath(phase: 0) : Self.breath(phase: phase)  // Reduce Motion: a steady glow
            let level = level.value
            Canvas { gc, _ in
                for r in 0..<Self.rows {
                    for c in 0..<Self.columns {
                        let rect = CGRect(x: CGFloat(c) * (Self.dot + Self.gap), y: CGFloat(r) * (Self.dot + Self.gap),
                                          width: Self.dot, height: Self.dot)
                        let b = Self.brightness(column: c, row: r, level: level, breath: breath)
                        gc.fill(Path(ellipseIn: rect), with: .color(t.emberMark.color.opacity(b)))
                    }
                }
            }
        }
        .frame(width: CGFloat(Self.columns) * (Self.dot + Self.gap) - Self.gap,
               height: CGFloat(Self.rows) * (Self.dot + Self.gap) - Self.gap)
        .accessibilityHidden(true)
    }
}

/// The thinking orb: a 9 pt ember dot whose ring grows to 2.2× and fades, once per 1.6 s
/// (`Motion.Loop.breathe`). Core Animation runs it, so thinking costs the app no CPU per frame;
/// it stops when the pill leaves thinking. Reduce Motion: the dot alone.
struct ThinkingOrb: View {
    let t: Tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size: CGFloat = 9
    nonisolated static let rippleScale: CGFloat = 2.2

    var body: some View {
        let room = Self.size * Self.rippleScale
        RippleOrb(color: t.emberMark.nsColor, size: Self.size,
                  ripples: Motion.loopRuns(visible: true, reduceMotion: reduceMotion))
            .frame(width: room, height: room)
            .padding(-(room - Self.size) / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The dot and its ripple ring, as layers.
struct RippleOrb: NSViewRepresentable {
    let color: NSColor
    let size: CGFloat
    let ripples: Bool

    final class OrbView: NSView {
        let dot = CALayer()
        let ring = CAShapeLayer()
        var applied: (color: NSColor, ripples: Bool)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            ring.fillColor = nil
            ring.lineWidth = 2
            layer?.addSublayer(ring)
            layer?.addSublayer(dot)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        var size: CGFloat = ThinkingOrb.size

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let r = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
            dot.frame = r
            dot.cornerRadius = size / 2
            ring.frame = r
            ring.path = CGPath(ellipseIn: CGRect(origin: .zero, size: r.size), transform: nil)
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> OrbView {
        let v = OrbView(frame: .zero)
        v.size = size
        return v
    }

    func updateNSView(_ view: OrbView, context: Context) {
        if let a = view.applied, a.color == color, a.ripples == ripples { return }
        view.applied = (color, ripples)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.dot.backgroundColor = color.cgColor
        view.ring.strokeColor = color.cgColor
        view.ring.removeAllAnimations()
        view.ring.opacity = 0
        if ripples { view.ring.add(Self.ripple(), forKey: "ripple") }
        CATransaction.commit()
    }

    /// Grow to 2.2× while fading from .5 to 0, eased out, forever.
    nonisolated static func ripple() -> CAAnimationGroup {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = ThinkingOrb.rippleScale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.5
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = Motion.Loop.breathe.period
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return group
    }
}

// MARK: Answer

/// Card or chip contents inside the reading well. `sizing` swaps the live web view for a
/// spacer of the same height, so the layout can be measured offscreen first.
struct AnswerContent: View {
    let answer: Answer
    let style: Placer.Style
    let t: Tokens
    let web: CardWebContent?
    let webHeight: CGFloat
    var speaking = false
    var inkIn = false
    var fullScreen = false
    var sizing = false
    /// Taller than the card may be (the controller's cap): the body scrolls between the header
    /// and the reply line, so nothing is cut off.
    var scrolls = false
    var reduceMotion = false
    var onEvent: (OverlayEvent) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onToggleFullScreen: () -> Void = {}
    /// Copy in the header (and ⌘C): the overlay copies the answer itself.
    var onCopy: () -> Void = {}
    /// Non-nil while the card has keyboard focus: the reply line becomes a field.
    var reply: Binding<String>?
    /// Typed conversations focus the field at once; voice ones wait for a click on it.
    var replyAutoFocus = false
    var onSubmitReply: () -> Void = {}

    var isChip: Bool { style == .chip }
    /// "Needs approval": amber outline and label, the verb in sage with ⌘↵, and Cancel.
    var needsApproval: Bool { answer.block.needsApproval && !isChip }

    /// The model's actions shown: at most 3, or 2 beside Cancel on an approval card; chips get one.
    /// The model's actions shown: at most 3 in all, counting the main button or the approval
    /// card's Cancel; a chip shows one button, the main one if it has it.
    static func shownActions(_ block: BuddyBlock, isChip: Bool, mainAction: MainAction? = nil) -> [BuddyBlock.Action] {
        let reserved = (mainAction != nil || block.needsApproval ? 1 : 0) + (showsLink(block, isChip: isChip) ? 1 : 0)
        let limit = max(0, (isChip ? 1 : BuddyBlock.maxActions) - reserved)
        return Array(block.actions.prefix(limit))
    }

    /// The answer's link (a draft the turn made elsewhere) gets a button on cards; a chip's one
    /// slot goes to its main action or first action instead.
    static func showsLink(_ block: BuddyBlock, isChip: Bool) -> Bool { block.link != nil && !isChip }

    /// A chip's own Copy beside its line: always, unless its main button already copies.
    static func showsChipCopy(mainAction: MainAction?) -> Bool { mainAction != .copy }

    /// "Open draft · mail.google.com": the label, and where it goes.
    static func linkTitle(_ link: BuddyBlock.Link) -> String {
        let domain = link.domain.hasPrefix("www.") ? String(link.domain.dropFirst(4)) : link.domain
        // The label is capped so the one-line button always shows where it goes.
        let label = link.label.count > 24 ? link.label.prefix(23) + "…" : link.label
        return domain.isEmpty ? label : "\(label) · \(domain)"
    }

    static func kind(ofAction index: Int, block: BuddyBlock, isChip: Bool, mainAction: MainAction? = nil) -> ActionButton.Kind {
        guard index == 0, !isChip, mainAction == nil else { return .quiet }
        return block.needsApproval ? .approve : .primary
    }

    /// The headline is content row 1 (after the header); ink starts when that row arrives
    /// (140 ms + 55 ms × index).
    static let headlineRow = 1
    static var headlineInkDelay: Double { Motion.rowDelay(headlineRow) }

    /// Ink-in runs only when it's on, the card is shown (not measured) and motion is allowed.
    static func inksIn(setting: Bool, sizing: Bool, reduceMotion: Bool) -> Bool { setting && !sizing && !reduceMotion }

    /// Full screen with earlier turns: the conversation scrolls, oldest first, and opens on
    /// the latest answer. Without earlier turns full screen is the card, larger.
    var showsTranscript: Bool { fullScreen && !isChip && !answer.earlier.isEmpty }
    /// The latest answer's row in the transcript, scrolled to on open.
    static let latestRowID = "latest"

    /// Set once the card has been in the transcript, so coming back out doesn't replay its entry.
    @State private var leftCard = false
    @State private var replyEditing = false

    /// "1", "2", "3" on the actions while those keys pick them: a focused card (the reply line is
    /// a field) whose field isn't being edited. Never on chips.
    static func showsKeyHints(isChip: Bool, cardFocused: Bool, replyEditing: Bool) -> Bool {
        !isChip && cardFocused && !replyEditing
    }
    private var keyHints: Bool { Self.showsKeyHints(isChip: isChip, cardFocused: reply != nil, replyEditing: replyEditing) }

    /// The hint before an action's title: its number key. Approve keeps ⌘↵, the shortcut it
    /// teaches (1 still picks it).
    static func keyHint(forAction index: Int, kind: ActionButton.Kind, shown: Bool) -> String? {
        guard shown, kind != .approve else { return nil }
        return "\(index + 1)"
    }
    /// Rows rise and ink in only when the card first shows: not in the transcript, and not
    /// again after it (the card's rows are new views there).
    private var settled: Bool { sizing || showsTranscript || leftCard }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isChip {
                CardHeader(answer: answer, t: t, speaking: speaking, fullScreen: fullScreen, onEvent: onEvent,
                           onClose: onClose, onToggleFullScreen: onToggleFullScreen, onCopy: onCopy)
                    .rowRise(0, reduceMotion: reduceMotion, animates: !settled)
            }
            if showsTranscript {
                transcript
            } else if scrolls {
                // Only the reading part scrolls; the actions and reply line stay in view below it.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) { answerRows(inScroll: true) }
                        .padding(.horizontal, 14)
                        .padding(.top, isChip ? 10 : 6)
                        .padding(.bottom, 10)
                }
                .scrollBounceBehavior(.basedOnSize)
                VStack(alignment: .leading, spacing: 10) {
                    actionRow
                    if !isChip { replyRow }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, isChip ? 10 : 12)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    answerRows(inScroll: false)
                    actionRow
                    if !isChip { replyRow }
                }
                .padding(.horizontal, 14)
                .padding(.top, isChip ? 10 : 6)
                .padding(.bottom, isChip ? 10 : 12)
            }
        }
        .frame(maxWidth: isChip ? nil : .infinity, maxHeight: fullScreen || scrolls ? .infinity : nil, alignment: .topLeading)
        .background {
            let well = RoundedRectangle(cornerRadius: isChip && !fullScreen ? Tokens.chipWellRadius : Tokens.wellRadius, style: .continuous)
            well.fill(t.well.color).overlay(well.fill(t.washGradient))
        }
        .padding(Tokens.rimInset)
        .onChange(of: showsTranscript) { _, on in if on { leftCard = true } }
    }

    /// Earlier turns, then the latest question and answer, lazily, starting at the bottom and
    /// then aligned to the latest answer's top; the reply line stays below the scroll.
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(answer.earlier) { turn in
                            PastTurnRows(turn: turn, t: t)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            if let question = answer.question {
                                QuestionBubble(text: question, t: t)
                            }
                            Text(answer.lane.label)
                                .font(Typeface.label)
                                .foregroundStyle(answer.lane.isEmphasized ? t.emberText.color : t.secondaryText.color)
                            answerRows(inScroll: true)
                            actionRow
                        }
                        .id(Self.latestRowID)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
                .onAppear {
                    // After the first layout, so the latest row has its size.
                    Task { @MainActor in proxy.scrollTo(Self.latestRowID, anchor: .top) }
                }
            }
            replyRow
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
    }

    /// The approval label, headline and card HTML. `inScroll`: inside a scroll view
    /// (the transcript, or a card past its height cap), where the HTML shows at its full height
    /// and the wheel scrolls the scroll view instead.
    @ViewBuilder private func answerRows(inScroll: Bool) -> some View {
        if needsApproval {
            Text("Needs your OK")
                .font(Typeface.labelStrong)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(t.amber.color)
                .accessibilityAddTraits(.isHeader)
                .rowRise(Self.headlineRow, reduceMotion: reduceMotion, animates: !settled)
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            InkText(text: answer.block.say, enabled: Self.inksIn(setting: inkIn, sizing: settled, reduceMotion: reduceMotion),
                    caret: t.emberMark.color, delay: Self.headlineInkDelay)
                .font(isChip ? Typeface.chipHeadline : Typeface.headline)
                .foregroundStyle(t.text.color)
                .fixedSize(horizontal: false, vertical: true)
            if isChip {
                // A chip has no header, so its Copy sits by the line, unless its one button is Copy.
                if Self.showsChipCopy(mainAction: answer.block.needsApproval ? nil : answer.mainAction) {
                    HeaderIcon(symbol: "doc.on.doc", label: "Copy", action: onCopy)
                }
                // A chip has no header: its stop control sits by the line. The slot is always
                // laid out, so the measured chip doesn't change size when speech starts or ends.
                HeaderIcon(symbol: "speaker.wave.2.fill", label: "Stop speaking") { onEvent(.stopSpeaking) }
                    .opacity(speaking ? 1 : 0)
                    .disabled(!speaking)
                    .allowsHitTesting(speaking)  // no tooltip or swallowed click on the empty slot
                    .accessibilityHidden(!speaking)
            }
        }
        .rowRise(Self.headlineRow, reduceMotion: reduceMotion, animates: !settled)
        if answer.block.cardHTML != nil, webHeight > 0 {
            Group {
                if sizing || web == nil {
                    Color.clear
                } else if let web {
                    // Until its height is known the HTML has a fallback height and scrolls itself.
                    CardWebView(content: web, dark: t.variant.dark, forwardsScrollWheel: inScroll && web.contentHeight != nil)
                }
            }
            .frame(height: webHeight)
            .rowRise(2, reduceMotion: reduceMotion, animates: !settled)
        }
    }

    /// The main button, the model's actions, the link and Cancel.
    @ViewBuilder private var actionRow: some View {
        let main = answer.block.needsApproval ? nil : answer.mainAction
        let actions = Self.shownActions(answer.block, isChip: isChip, mainAction: main)
        let link = Self.showsLink(answer.block, isChip: isChip) ? answer.block.link : nil
        if !actions.isEmpty || main != nil || link != nil {
            // One row when the buttons fit at their full labels, else one button per line, whose
            // label wraps, so a label is never cut short.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { actionButtons(main: main, actions: actions, link: link, wraps: false) }
                VStack(alignment: .leading, spacing: 6) { actionButtons(main: main, actions: actions, link: link, wraps: true) }
            }
            .rowRise(3, reduceMotion: reduceMotion, animates: !settled)
        }
    }

    @ViewBuilder private func actionButtons(main: MainAction?, actions: [BuddyBlock.Action], link: BuddyBlock.Link?,
                                            wraps: Bool) -> some View {
        if let main {
            ActionButton(title: main.label, kind: isChip ? .quiet : .primary, shortcut: isChip ? nil : "⌘↵", wraps: wraps) {
                onEvent(.mainAction(main))
            }
        }
        ForEach(Array(actions.enumerated()), id: \.offset) { i, action in
            let kind = Self.kind(ofAction: i, block: answer.block, isChip: isChip, mainAction: main)
            ActionButton(title: action.label, kind: kind,
                         shortcut: Self.keyHint(forAction: i, kind: kind, shown: keyHints), wraps: wraps) {
                onEvent(.action(index: i))
            }
        }
        if let link {
            ActionButton(title: Self.linkTitle(link), kind: .quiet, wraps: wraps) { onEvent(.openLink(link.url)) }
                .help(link.url.absoluteString)
        }
        // The model never authors Cancel; it closes the card, and never means yes.
        if needsApproval {
            ActionButton(title: "Cancel", kind: .quiet, wraps: wraps, action: onClose)
        }
    }

    @ViewBuilder private var replyRow: some View {
        HStack(spacing: 6) {
            if let reply {
                ReplyField(text: reply, t: t, autoFocus: replyAutoFocus, onSubmit: onSubmitReply,
                           onEditingChange: { replyEditing = $0 })
            } else if !answer.replyHint.isEmpty { // learned: no hint, no blank row
                Text(answer.replyHint)
                    .font(Typeface.label)
                    .foregroundStyle(t.secondaryText.color)
            }
            if Self.showsContinue(isChip: isChip, enabled: ContinueInPanel.enabled) {
                Spacer(minLength: 0)
                // ⤢ Continue, labelled, "6 steps" after work, ⌘↩ when no button has it (QA U14).
                ContinueButton(title: CardHeader.continueTitle(answer.reviewSteps), t: t) { onEvent(.popOut) }
            }
        }
        .rowRise(4, reduceMotion: reduceMotion, animates: !settled)
    }

    /// Cards offer ⤢ Continue with the Panel on; chips don't.
    static func showsContinue(isChip: Bool, enabled: Bool) -> Bool { enabled && !isChip }
}

extension View {
    /// `rowRise`, or the row as it is when it shouldn't animate in (not even a crossfade).
    @ViewBuilder func rowRise(_ index: Int, reduceMotion: Bool, animates: Bool) -> some View {
        if animates { rowRise(index, reduceMotion: reduceMotion) } else { self }
    }
}

/// The card's reply field: "Reply…", ↵ sends a follow-up (Reply line). Same height as
/// the hint line it replaces, so the card doesn't jump.
struct ReplyField: View {
    @Binding var text: String
    let t: Tokens
    var autoFocus = true
    let onSubmit: () -> Void
    /// Whether the field is being edited (then 1–3 type into it rather than pick an action).
    var onEditingChange: (Bool) -> Void = { _ in }
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text("Reply…").foregroundStyle(t.secondaryText.color))
            .textFieldStyle(.plain)
            .font(Typeface.label)
            .foregroundStyle(t.text.color)
            .focused($focused)
            .onSubmit(onSubmit)
            .onAppear { if autoFocus { focused = true } }
            .onChange(of: focused, initial: true) { _, now in onEditingChange(now) }
            .accessibilityLabel("Reply")
    }
}

/// Conversation dot, "new" / "continuing · N", the lane, Go deeper (Quick only), stop
/// speaking (only while speaking), ＋ new conversation, ✕ close.
struct CardHeader: View {
    let answer: Answer
    let t: Tokens
    let speaking: Bool
    var fullScreen = false
    let onEvent: (OverlayEvent) -> Void
    let onClose: () -> Void
    var onToggleFullScreen: () -> Void = {}
    var onCopy: () -> Void = {}

    var body: some View {
        // Whole rows, tried in order, so the first that fits wins: "Go deeper" collapses to an
        // icon before the turn label shortens, and the label shortens ("long" first, then
        // "continuing · 12" → "turn 12") before it would truncate. The lane label never
        // truncates.
        ViewThatFits(in: .horizontal) {
            row(label: answer.headerLabel, goDeeperAsText: true)
            row(label: answer.headerLabel, goDeeperAsText: false)
            row(label: answer.shortHeaderLabel, goDeeperAsText: false)
            row(label: answer.compactHeaderLabel, goDeeperAsText: false)
            // Last, with 28 pt hit squares (QA U15/U37): the lane drops its model before the turn
            // label would truncate.
            row(label: answer.compactHeaderLabel, goDeeperAsText: false, shortLane: true)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

extension CardHeader {
    /// `shownMain`: the main button actually on the card (approval cards show none).
    static func showsCopy(shownMain: MainAction?) -> Bool { shownMain != .copy }

    /// "Quick · Haiku 5.5", or just "Quick" in the tightest row.
    static func laneLabel(_ lane: Lane, short: Bool) -> String { short ? lane.mode.displayName : lane.label }

    func row(label: String, goDeeperAsText: Bool, shortLane: Bool = false) -> some View {
        HStack(spacing: 4) {
            Circle().fill(t.conversationColor(answer.conversation).color).frame(width: 8, height: 8)
                .padding(.trailing, 2)
            Text(label).font(Typeface.label).foregroundStyle(t.secondaryText.color).lineLimit(1)
                .truncationMode(.tail)
            Text("· \(Self.laneLabel(answer.lane, short: shortLane))")
                .font(Typeface.label)
                .foregroundStyle(answer.lane.isEmphasized ? t.emberText.color : t.secondaryText.color)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
            Spacer(minLength: 4)
            HStack(spacing: HeaderIcon.pitch - HeaderIcon.hitTarget) {
                controls(goDeeperAsText: goDeeperAsText)
                HeaderIcon(symbol: "xmark", label: "Close", action: onClose)
            }
        }
    }

    @ViewBuilder
    func controls(goDeeperAsText: Bool) -> some View {
        // 28 pt hit squares (QA U15) at a 24 pt pitch: neighbours share 4 pt, the glyphs keep
        // their size, and the header still fits the 330 pt card.
        HStack(spacing: HeaderIcon.pitch - HeaderIcon.hitTarget) {
            if answer.lane.mode == .quick {
                if goDeeperAsText {
                    Button("Go deeper") { onEvent(.goDeeper) }
                        .buttonStyle(.plain)
                        .font(Typeface.label)
                        .foregroundStyle(t.secondaryText.color)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, 2)
                } else {
                    HeaderIcon(symbol: "arrow.down.forward.circle", label: "Go deeper") {
                        onEvent(.goDeeper)
                    }
                }
            }
            // The slot is always laid out (as on chips), so speech starting or ending never shifts
            // the controls or flips the header to another row.
            HeaderIcon(symbol: "speaker.wave.2.fill", label: "Stop speaking") { onEvent(.stopSpeaking) }
                .opacity(speaking ? 1 : 0)
                .disabled(!speaking)
                .allowsHitTesting(speaking)
                .accessibilityHidden(!speaking)
            // The main button already copies (and ⌘C): no second Copy in the header.
            if Self.showsCopy(shownMain: answer.block.needsApproval ? nil : answer.mainAction) {
                HeaderIcon(symbol: "doc.on.doc", label: "Copy", action: onCopy)
            }
            HeaderIcon(symbol: "plus", label: "New session") { onEvent(.newConversation) }
            HeaderIcon(symbol: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       label: fullScreen ? "Exit full screen" : "Full screen", action: onToggleFullScreen)
            // ⤢ Continue (LumiFeatures.panel) sits labelled in the reply row (QA U14).
            if !ContinueInPanel.enabled, answer.block.shape == .rich {
                HeaderIcon(symbol: "arrow.up.forward.square", label: "Open in Lumi") { onEvent(.popOut) }
            }
        }
        .fixedSize()
    }
}

extension CardHeader {
    /// "Continue", or "6 steps" after a turn with work worth reviewing.
    nonisolated static func continueTitle(_ steps: Int?) -> String {
        guard let steps, steps > 0 else { return "Continue" }
        return steps == 1 ? "1 step" : "\(steps) steps"
    }
}

/// ⤢ Continue in the card header: the Panel glyph and a short word, one 28 pt hit target.
struct ContinueButton: View {
    let title: String
    let t: Tokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "rectangle.righthalf.inset.filled.arrow.right").font(.system(size: 11, weight: .semibold))
                Text(title).font(Typeface.label).lineLimit(1)
            }
            .foregroundStyle(t.secondaryText.color)
            .padding(.horizontal, 5)
            .frame(minWidth: HeaderIcon.hitTarget, minHeight: HeaderIcon.hitTarget)
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Continue in Panel")
        .accessibilityLabel(title == "Continue" ? "Continue in Panel" : "Continue in Panel, \(title)")
    }
}

/// Whether answer cards offer "⤢ Continue" (it sends `.popOut`, which the shell turns into
/// the Panel). Set once at launch from `LumiFeatures.panel`.
public enum ContinueInPanel {
    public static var enabled = false
}

struct HeaderIcon: View {
    /// 04 §7.4: every hit target is at least 28 × 28 pt.
    static let hitTarget: CGFloat = 28
    /// Glyph to glyph in the card header.
    static let pitch: CGFloat = 24

    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.lumiSecondary)
                .frame(width: Self.hitTarget, height: Self.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// An answer card's action: the main one an ember pill, the rest plain pills (`PillButtonStyle`).
/// Approve is the ember pill too, like Allow everywhere else, and shows its ⌘↵ shortcut, which
/// the key handler already maps to the first action.
struct ActionButton: View {
    enum Kind { case primary, approve, quiet }

    let title: String
    let kind: Kind
    /// A shortcut shown before the title ("⌘↵"); the approve verb always shows ⌘↵.
    var shortcut: String? = nil
    /// The title wraps onto more lines rather than being cut short (one button per line).
    var wraps = false
    let action: () -> Void

    private var shownShortcut: String? { shortcut ?? (kind == .approve ? "⌘↵" : nil) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let shownShortcut {
                    Text(shownShortcut).font(.system(size: 11, design: .monospaced)).opacity(0.6).accessibilityHidden(true)
                }
                Text(title)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: wraps)
            }
            .lineLimit(wraps ? nil : 1)
        }
        .buttonStyle(kind == .quiet ? .pill : .pillProminent)
    }
}
