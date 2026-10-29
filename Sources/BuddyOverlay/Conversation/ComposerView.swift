import AppKit
import BuddyCore
import SwiftUI

/// The composer (04 §4.5): one glass capsule, the text on top (growing to 6 lines) and a row of
/// controls under it. Send becomes Stop while a turn runs, and the field stays live for steering.
struct ComposerView: View {
    @Bindable var model: ConversationPageModel
    let density: PageDensity
    let t: Tokens
    /// The composer has keyboard focus: the Panel becomes key only then.
    var onFocus: (Bool) -> Void = { _ in }
    @State private var width: CGFloat = 400
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Panel's widths: the hints shorten.
    private var narrow: Bool { width < 480 }

    var body: some View {
        let running = model.page.isRunning
        VStack(alignment: .leading, spacing: 6) {
            if let target = model.answering {
                Text(target.question)
                    .font(density.callout.font.weight(.medium))
                    .foregroundStyle(t.text.color)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .accessibilityLabel("Answering: \(target.question)")
            }
            if !model.attachments.isEmpty {
                AttachmentTokens(composer: model.composer, density: density, t: t, width: width)
                    .transition(.opacity)
            }
            // The text on its own row, the full width of the capsule; one row of controls under
            // it (+ and the ▣ chip, then mic and send), as in Claude and ChatGPT. The text never
            // shares a line with a button (owner, Oct 29: it wrapped at a third of the field).
            VStack(alignment: .leading, spacing: 2) {
                ComposerField(state: model.composer, placeholder: placeholder(running),
                              font: .systemFont(ofSize: density.composer.size), lineHeight: density.composer.line,
                              textColor: t.text.nsColor, tokenColor: t.emberText.nsColor, chipFill: PageColors(t: t).tile.nsColor,
                              placeholderColor: t.secondaryText.nsColor, focusRequest: model.focusRequest,
                              onFocus: onFocus, onSubmit: model.submit, onSubmitToNewSession: model.submitToNewSession,
                              onEscape: escape)
                    .padding(.horizontal, Self.textInset)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Menu {
                        Button("Files…") { pickFiles() }
                    } label: {
                        Image(systemName: "plus").frame(width: PageShape.hitTarget, height: PageShape.hitTarget)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(t.text.color)
                    .accessibilityLabel("Attach")
                    screenChip
                    Spacer(minLength: 0)
                    Button { model.toggleMic() } label: {
                        Image(systemName: model.listening ? "mic.fill" : "mic")
                            .foregroundStyle((model.listening ? t.emberMark : t.text).color)
                    }
                    .buttonStyle(.roundIcon)
                    .accessibilityLabel(model.listening ? "Stop listening" : "Talk")
                    sendOrStop(running)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
            .modifier(ComposerChrome(t: t, listening: model.listening))
            // A drop on the capsule outside the text: pictures attach, the rest is `@path` at the end.
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                model.composer.append(model.composer.take(files))
                return !files.isEmpty
            }
            // The `/` and `@` menu floats above the capsule, over the thread.
            .floatingAbove {
                if let menu = model.composer.menu {
                    CompletionMenuView(menu: menu, t: t, onPick: model.composer.pick)
                        .padding(.leading, 8)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: model.composer.menu != nil)
            // One line, never wrapped: the middle hint goes first when narrow. Only what works
            // (QA U13): / runs a command or skill; @ names a file, or a teammate this session has.
            // At the Panel's width the hints shorten instead of dropping @ (QA U38); inside an open
            // lane the composer already addresses that teammate, so the @ hint is files only.
            // Whole hints drop from the end when the row is too narrow, never cut mid-word.
            // After ⌘⇧↩ the row says where the text went for a few seconds, in the hints' place,
            // so nothing moves or covers the thread (qa-ui).
            Group {
                if model.startedSession != nil { startedNote } else { hints }
            }
            .animation(Motion.animation(Motion.crossfade, reduceMotion: reduceMotion), value: model.startedSession != nil)
        }
        .animation(.easeInOut(duration: 0.15), value: model.attachments.isEmpty)
        // ⌘. interrupts the running turn whatever the field holds (QA U12): a zero-size
        // button keeps the shortcut live while Send shows for a steer.
        .background {
            if running {
                Button("Stop", action: model.stop)
                    .keyboardShortcut(".", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    /// "Started in a new session ›": pressing it opens that session; it goes after a few seconds.
    private var startedNote: some View {
        Button("Started in a new session ›", action: model.openStartedSession)
            .buttonStyle(.plain)
            .font(density.caption.font.weight(.medium))
            .foregroundStyle(t.emberText.color)
            .padding(.horizontal, 12)
            .task(id: model.startedSession) {
                let shown = model.startedSession
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled, model.startedSession == shown { model.startedSession = nil }
            }
    }

    private var hints: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(Self.hintRows(narrow: narrow, teammate: model.openLane == nil ? model.page.teammates.first?.name : nil)
                .enumerated()), id: \.offset) { _, row in
                HStack(spacing: 14) {
                    ForEach(row.leading, id: \.self) { Text($0).lineLimit(1).fixedSize() }
                    if let trailing = row.trailing {
                        Spacer(minLength: 8)
                        Text(trailing).lineLimit(1).fixedSize()
                    }
                }
            }
        }
        .font(density.caption.font)
        .foregroundStyle(t.secondaryText.color)
        .padding(.horizontal, 12)
        .accessibilityHidden(true)
    }

    /// Esc with an empty field and no menu: leaves a question card waiting, else interrupts the
    /// running turn (as Esc does in Claude Code). False lets the Panel close.
    private func escape() -> Bool {
        if model.answering != nil { model.cancelAnswering(); return true }
        guard model.page.isRunning else { return false }
        model.stop()
        return true
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { model.attach(panel.urls) }
    }

    private func placeholder(_ running: Bool) -> String {
        // The question itself shows above the field; the placeholder stays short (QA U29).
        if let target = model.answering { return (target.step.map { $0 + " · " } ?? "") + "Answer…" }
        if let lane = model.openLane, let mate = model.page.teammates.first(where: { $0.id == lane }) {
            return "Message \(mate.name)"
        }
        return Self.placeholder(running: running, compact: density == .compact || narrow)
    }

    /// Short at the Panel's width, so it never wraps (QA U2).
    static func placeholder(running: Bool, compact: Bool) -> String {
        switch (running, compact) {
        case (true, true): "Add direction"
        case (true, false): "Add direction. Lumi reads it after this step."
        case (false, true): "Ask, / for commands"
        case (false, false): "Ask, or type / for a command or skill"
        }
    }

    /// The hint row's options, widest first: all of it (⌘⇧↩ only when not narrow), then without
    /// "Full Claude Code", then the "/" hint alone. `teammate`: the session's first teammate, when no lane is open (inside a lane
    /// the composer already addresses it).
    static func hintRows(narrow: Bool, teammate: String?) -> [(leading: [String], trailing: String?)] {
        let slash = narrow ? "/ commands" : "/ commands & your skills"
        let at = teammate.map { narrow ? "@ files, @\($0)" : "@ files, or @\($0) for a teammate" }
            ?? (narrow ? "@ files" : "@ files & folders")
        let rows: [(leading: [String], trailing: String?)] = [([slash, at], "Full Claude Code"), ([slash, at], nil), ([slash], nil)]
        return narrow ? rows : [([slash, at, "⌘⇧↩ new session"], "Full Claude Code")] + rows
    }

    /// The text's inset from the capsule's sides: the + glyph's left edge.
    static let textInset: CGFloat = 14

    /// ▣ and the app it reads, beside +: the controls row has room for the name at every width. No Quick/Deep chip: a typed turn in a page is the user's
    /// own Claude Code on their own model (owner).
    @ViewBuilder private var screenChip: some View {
        if let app = model.screenAppName {
            Button { model.withScreen.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.withScreen ? "rectangle.inset.filled" : "rectangle")
                    Text(model.withScreen ? app : "Text only").lineLimit(1)
                }
                .font(density.caption.font)
                .padding(.horizontal, narrow ? 6 : 8)
                .frame(minHeight: 24)
                .background(PageColors(t: t).tile.color, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(t.text.color)
            .accessibilityLabel(model.withScreen ? "Reads \(app) with each send" : "Text only")
            .help(model.withScreen ? "Each send reads \(app) again" : "Sends text only")
        }
    }

    @ViewBuilder private func sendOrStop(_ running: Bool) -> some View {
        if running, model.draft.isEmpty {
            Button(action: model.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(t.rose.color)
            }
            .buttonStyle(.roundIcon)
            .accessibilityLabel("Stop")
        } else {
            Button(action: model.submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(t.onEmber.color)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(t.emberMark.color))
            }
            .buttonStyle(.plain)
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(running ? "Send direction" : "Send")
        }
    }
}

/// The capsule's glass, or the opaque surface with Reduce Transparency; an ember ring while
/// the mic listens.
private struct ComposerChrome: ViewModifier {
    let t: Tokens
    let listening: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PageShape.composerRadius, style: .continuous)
        Group {
            if t.usesGlass {
                content.glassEffect(.regular.tint(t.glassTint.color).interactive(), in: shape)
            } else {
                content.background(shape.fill(t.opaqueSurface.color))
            }
        }
        .overlay(shape.strokeBorder(listening ? t.emberMark.color : t.hairline.color, lineWidth: listening ? 2 : 1))
    }
}

/// Attachments as 32 pt tokens above the text line: icon or thumbnail, name, ✕. Those that don't
/// fit fold into a "+N" token (QA U36); pressing it shows them all, scrolling under a trailing fade.
public struct AttachmentTokens: View {
    let composer: ComposerState
    let density: PageDensity
    let t: Tokens
    let width: CGFloat
    @State private var expanded = false

    public init(composer: ComposerState, density: PageDensity, t: Tokens, width: CGFloat) {
        self.composer = composer
        self.density = density
        self.t = t
        self.width = width
    }

    /// How many tokens show before "+N", for `names` in a composer `width` wide: all when they fit,
    /// else as many as fit beside the "+N" token, at least one. Widths are estimates (caption text
    /// about 6.5 pt a character, capped at 140, plus icon, ✕ and padding).
    static func shownCount(names: [String], width: CGFloat) -> Int {
        let spacing: CGFloat = 6, more: CGFloat = 44
        let available = width - 24
        let tokens = names.map { min(140, CGFloat($0.count) * 6.5) + 59 }
        if tokens.reduce(0, +) + spacing * CGFloat(max(0, tokens.count - 1)) <= available { return tokens.count }
        var used: CGFloat = 0, shown = 0
        for token in tokens {
            let next = used + (shown == 0 ? 0 : spacing) + token
            guard next + spacing + more <= available else { break }
            used = next
            shown += 1
        }
        return max(1, shown)
    }

    public var body: some View {
        let all = composer.attachments
        let fit = Self.shownCount(names: all.map(\.name), width: width)
        let shown = expanded ? all.count : fit
        let hidden = all.count - shown
        let fades = expanded && fit < all.count
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(all.prefix(shown)) { a in
                    HStack(spacing: 6) {
                        icon(a)
                        Text(a.name).font(density.caption.font).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140)
                        Button { composer.detach(a) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(a.name)")
                    }
                    .foregroundStyle(t.text.color)
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .background(PageColors(t: t).tile.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .transition(.opacity)
                }
                if hidden > 0 {
                    Button { expanded = true } label: {
                        Text("+\(hidden)")
                            .font(density.caption.font.weight(.semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(PageColors(t: t).tile.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(t.text.color)
                    .accessibilityLabel("\(hidden) more attached")
                    .help(all.suffix(hidden).map(\.name).joined(separator: ", "))
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.never)
        .animation(.easeInOut(duration: 0.15), value: all.map(\.id))
        .mask {
            // A trailing fade says the row scrolls on (only once it can).
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, fades ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 24)
            }
        }
        .onChange(of: all.count) { _, count in if count <= 1 { expanded = false } }
    }

    @ViewBuilder private func icon(_ a: PageAttachment) -> some View {
        // The thumbnail is made once, off the main actor, when the file is attached.
        if a.kind != .file, let image = composer.thumbnails[a.url] {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path)).resizable().frame(width: 18, height: 18)
        }
    }
}
