import BuddyCore
import SwiftUI

/// Resolves tokens from the environment (appearance, Reduce Transparency, Increase Contrast).
struct TokensReader<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder let content: (Tokens) -> Content

    var body: some View {
        content(Tokens(.init(dark: scheme == .dark, reduceTransparency: reduceTransparency,
                             increaseContrast: contrast == .increased)))
    }
}

/// Fonts: the macOS (HIG) scale, so answers read like a native panel (the
/// earlier sizes, 2 pt above the defaults, felt too big). Headline 15, body 13, buttons 12,
/// labels 11.
enum Typeface {
    static let headline = Font.system(size: 15, weight: .semibold)
    static let chipHeadline = Font.system(size: 14, weight: .semibold)
    static let detail = Font.system(size: 13)
    static let label = Font.system(size: 11, weight: .medium, design: .rounded)
    static let labelStrong = Font.system(size: 11, weight: .semibold, design: .rounded)
    static let button = Font.system(size: 12, weight: .medium)
}

/// Glass (or the opaque surface with Reduce Transparency) plus the hairline and inner
/// highlight, in one shape.
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

    func body(content: Content) -> some View {
        Group {
            if t.usesGlass {
                content.glassEffect(.regular.tint(t.glassTint.color), in: shape)
            } else {
                content.background(shape.fill(t.opaqueSurface.color))
            }
        }
        .overlay {
            if hairline, let edge = Self.edge(t, bright: bright, border: border) {
                ZStack {
                    shape.strokeBorder(edge.color, lineWidth: Tokens.hairlineWidth)
                    if Self.drawsHighlight(t) {
                        shape.inset(by: 1).strokeBorder(t.innerHighlight.color, lineWidth: 1)
                            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .clear, location: 0.25)],
                                                 startPoint: .top, endPoint: .bottom))
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .background {
            // One soft shadow, deeper over bright backdrops, cast by the outline only: a
            // shadow on the container would shade every child (text halos).
            OutlineShadow(shape: shape, deep: bright)
        }
    }
}

/// A soft shadow outside a shape, with the area under the shape cut away. `deep` is the
/// stronger one over bright backdrops.
struct OutlineShadow<S: InsettableShape>: View {
    let shape: S
    var deep = false
    var body: some View {
        shape.fill(Color.black.opacity(deep ? 0.22 : 0.12))
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
                if model.settings.dotField {
                    DotField(level: model.mic, t: t)
                } else {
                    LevelBars(level: model.mic, t: t)
                }
                Text(model.showsListeningHint ? hint : "Listening")
                    .font(model.showsListeningHint ? Typeface.label : Typeface.labelStrong)
                    .foregroundStyle(model.showsListeningHint ? t.secondaryText.color : t.emberText.color)
                    .contentTransition(.opacity)
            case .thinking(let lane, let status):
                ThinkingOrb(t: t)
                ModeChip(lane: lane, t: t)
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
    static let columns = 6, rows = 3
    static let dot: CGFloat = 4, gap: CGFloat = 2

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
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            let breath = 0.22 + 0.08 * sin(phase * 2 * .pi)
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

/// Breathing ember orb (thinking): a ring grows and fades every 1.6 s.
struct ThinkingOrb: View {
    let t: Tokens
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(t.emberMark.color)
            .frame(width: 9, height: 9)
            .background {
                Circle()
                    .stroke(t.emberMark.color.opacity(breathe ? 0 : 0.5), lineWidth: 2)
                    .scaleEffect(breathe ? 2.2 : 1)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { breathe = true }
            }
            .accessibilityHidden(true)
    }
}

/// Quick: ember text on a 16% ember tint. Deep and Research: solid ember.
struct ModeChip: View {
    let lane: Lane
    let t: Tokens

    var body: some View {
        Text(lane.label)
            .font(Font.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(lane.isEmphasized ? t.onEmber.color : t.emberText.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(lane.isEmphasized ? t.emberMark.color : t.emberMark.color.opacity(0.16)))
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
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    answerRows
                    if !isChip { replyRow }
                }
                .padding(.horizontal, 14)
                .padding(.top, isChip ? 10 : 6)
                .padding(.bottom, isChip ? 10 : 12)
            }
        }
        .frame(maxWidth: isChip ? nil : .infinity, maxHeight: fullScreen ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: isChip && !fullScreen ? Tokens.chipWellRadius : Tokens.wellRadius,
                                     style: .continuous).fill(t.well.color))
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
                            answerRows
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

    /// The approval label, headline, card HTML and actions.
    @ViewBuilder private var answerRows: some View {
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
                    HeaderIcon(symbol: "doc.on.doc", label: "Copy", t: t, action: onCopy)
                }
                // A chip has no header: its stop control sits by the line. The slot is always
                // laid out, so the measured chip doesn't change size when speech starts or ends.
                HeaderIcon(symbol: "speaker.wave.2.fill", label: "Stop speaking", t: t) { onEvent(.stopSpeaking) }
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
                    CardWebView(content: web, dark: t.variant.dark, forwardsScrollWheel: showsTranscript)
                }
            }
            .frame(height: webHeight)
            .rowRise(2, reduceMotion: reduceMotion, animates: !settled)
        }
        let main = answer.block.needsApproval ? nil : answer.mainAction
        let actions = Self.shownActions(answer.block, isChip: isChip, mainAction: main)
        let link = Self.showsLink(answer.block, isChip: isChip) ? answer.block.link : nil
        if !actions.isEmpty || main != nil || link != nil {
            HStack(spacing: 6) {
                if let main {
                    ActionButton(title: main.label, kind: isChip ? .quiet : .primary, t: t, shortcut: isChip ? nil : "⌘↵") {
                        onEvent(.mainAction(main))
                    }
                }
                ForEach(Array(actions.enumerated()), id: \.offset) { i, action in
                    let kind = Self.kind(ofAction: i, block: answer.block, isChip: isChip, mainAction: main)
                    ActionButton(title: action.label, kind: kind, t: t,
                                 shortcut: Self.keyHint(forAction: i, kind: kind, shown: keyHints)) {
                        onEvent(.action(index: i))
                    }
                }
                if let link {
                    ActionButton(title: Self.linkTitle(link), kind: .quiet, t: t) { onEvent(.openLink(link.url)) }
                        .help(link.url.absoluteString)
                }
                // The model never authors Cancel; it closes the card, and never means yes.
                if needsApproval {
                    ActionButton(title: "Cancel", kind: .quiet, t: t, action: onClose)
                }
            }
            .rowRise(3, reduceMotion: reduceMotion, animates: !settled)
        }
    }

    @ViewBuilder private var replyRow: some View {
        Group {
            if let reply {
                ReplyField(text: reply, t: t, autoFocus: replyAutoFocus, onSubmit: onSubmitReply,
                           onEditingChange: { replyEditing = $0 })
            } else if !answer.replyHint.isEmpty { // learned: no hint, no blank row
                Text(answer.replyHint)
                    .font(Typeface.label)
                    .foregroundStyle(t.secondaryText.color)
            }
        }
        .rowRise(4, reduceMotion: reduceMotion, animates: !settled)
    }
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

    private func row(label: String, goDeeperAsText: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(t.conversationColor(answer.conversation).color).frame(width: 8, height: 8)
                .padding(.trailing, 2)
            Text(label).font(Typeface.label).foregroundStyle(t.secondaryText.color).lineLimit(1)
                .truncationMode(.tail)
            Text("· \(answer.lane.label)")
                .font(Typeface.label)
                .foregroundStyle(answer.lane.isEmphasized ? t.emberText.color : t.secondaryText.color)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
            Spacer(minLength: 4)
            controls(goDeeperAsText: goDeeperAsText)
            HeaderIcon(symbol: "xmark", label: "Close", t: t, action: onClose)
        }
    }

    @ViewBuilder
    func controls(goDeeperAsText: Bool) -> some View {
        HStack(spacing: 4) {
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
                    HeaderIcon(symbol: "arrow.down.forward.circle", label: "Go deeper", t: t) {
                        onEvent(.goDeeper)
                    }
                }
            }
            if speaking {
                HeaderIcon(symbol: "speaker.wave.2.fill", label: "Stop speaking", t: t) { onEvent(.stopSpeaking) }
            }
            // The main button already copies (and ⌘C): no second Copy in the header.
            if Self.showsCopy(shownMain: answer.block.needsApproval ? nil : answer.mainAction) {
                HeaderIcon(symbol: "doc.on.doc", label: "Copy", t: t, action: onCopy)
            }
            HeaderIcon(symbol: "plus", label: "New conversation", t: t) { onEvent(.newConversation) }
            HeaderIcon(symbol: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       label: fullScreen ? "Exit full screen" : "Full screen", t: t, action: onToggleFullScreen)
            if answer.block.shape == .rich {
                HeaderIcon(symbol: "arrow.up.forward.square", label: "Open in Conversations", t: t) { onEvent(.popOut) }
            }
        }
        .fixedSize()
    }
}

struct HeaderIcon: View {
    let symbol: String
    let label: String
    let t: Tokens
    var tint: TokenColor?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle((tint ?? t.secondaryText).color)
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Primary in ember, approve in sage, both with dark text; others quiet.
/// Approve shows its ⌘↵ shortcut, which the key handler already maps to the first action.
struct ActionButton: View {
    enum Kind { case primary, approve, quiet }

    let title: String
    let kind: Kind
    let t: Tokens
    /// A shortcut shown before the title ("⌘↵"); the approve verb always shows ⌘↵.
    var shortcut: String? = nil
    let action: () -> Void

    private var primary: Bool { kind != .quiet }
    private var shownShortcut: String? { shortcut ?? (kind == .approve ? "⌘↵" : nil) }
    private var fill: Color {
        switch kind {
        case .primary: t.emberMark.color
        case .approve: t.sage.color
        case .quiet: t.variant.dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let shownShortcut {
                    Text(shownShortcut).font(.system(size: 11, design: .monospaced)).opacity(0.6).accessibilityHidden(true)
                }
                Text(title)
            }
                .font(Typeface.button)
                .lineLimit(1)
                .foregroundStyle(kind == .approve ? t.onSage.color : primary ? t.onEmber.color : t.text.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(fill)
                }
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(t.variant.dark ? Color.white.opacity(0.13) : Color.black.opacity(0.12), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
