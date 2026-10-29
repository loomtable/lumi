import AppKit
import BuddyCore
import BuddyKeys
import BuddyOverlay
import SwiftUI

/// Home (04 §6.2): the orb with its one glow, the composer, Running and Recent cards, and the
/// health strip. With no history yet: the sleepy orb, one line and the composer.
struct HomeView: View {
    let model: StudioModel
    let store: SettingsStore
    @State private var sending = false
    @State private var dictating = false
    /// Home's brand moment: the orb peeks up once when Home opens (none with Reduce Motion).
    @State private var peeked = false
    @State private var composerFocused = false
    /// Bumped to focus the field: on appear and on the model's requests.
    @State private var focusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TokensReader { t in
            // The health strip sits under the scroll area, in the layout, so it never covers a card.
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        LumiOrb(expression: model.isEmpty ? .sleepy : .happy, size: 88)
                            .offset(y: peeked || reduceMotion ? 0 : 12)
                            .opacity(peeked || reduceMotion ? 1 : 0)
                            .padding(.top, 72)
                        composer(t).padding(.top, 24)
                        hint.padding(.top, 16)
                        if model.isEmpty {
                            Text("Your sessions will show up here.")
                                .font(.system(size: 13)).foregroundStyle(t.secondaryText.color).padding(.top, 40)
                        } else {
                            cards(t).padding(.top, 40)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
                HealthStripView(store: store)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
            }
            .background(alignment: .top) {
                // The screen's single focal glow, behind the orb.
                RadialGradient(colors: [t.emberMark.opacity(t.variant.dark ? 0.16 : 0.10).color, t.emberMark.opacity(0).color],
                               center: .center, startRadius: 0, endRadius: 260)
                    .frame(width: 520, height: 520)
                    .offset(y: -260 + 72 + 44)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: composerFocused) { _, focused in model.homeComposerFocused = focused }
        .onAppear {
            focusRequest += 1
            withAnimation(reduceMotion ? nil : Motion.pop) { peeked = true }
        }
        .onChange(of: model.composerFocusRequests) { focusRequest += 1 }
    }

    /// The canvas Home composer (QA U23): the field on top, the full width; under it ＋ for files,
    /// then the mic (hold to dictate into the field, when the dictation key's path is on) and send.
    /// As the page composer, the text never shares a line with a button.
    private func composer(_ t: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.homeAttachments.isEmpty { attachmentRow(t) }
            field(t)
                .padding(.horizontal, 8)
                .padding(.top, 8)
            HStack(spacing: 10) {
                Menu {
                    Button("Files…") { pickFiles() }
                } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(t.secondaryText.color)
                .accessibilityLabel("Attach")
                Spacer(minLength: 0)
                controls(t)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 640)
        .background { RoundedRectangle(cornerRadius: 28, style: .continuous).fill(t.usesGlass ? Color.clear : t.opaqueSurface.color) }
        .glassEffect(t.usesGlass ? .regular.interactive() : .identity, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder((composerFocused ? t.emberMark.opacity(0.45) : t.text.opacity(0.14)).color, lineWidth: Tokens.hairlineWidth)
        }
        // The canvas lifts the Home composer off the page: the screen's one raised object.
        .shadow(color: t.shadow.opacity(t.variant.dark ? 0.30 : 0.08).color, radius: 20, y: 10)
        .animation(Motion.crossfade, value: composerFocused)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.homeComposer.append(model.homeComposer.take(files))
            return !files.isEmpty
        }
        // The `/` menu floats above the field.
        .floatingAbove {
            if let menu = model.homeComposer.menu {
                CompletionMenuView(menu: menu, t: t, onPick: model.homeComposer.pick)
                    .padding(.leading, 16)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.homeComposer.menu != nil)
        .zIndex(1)
    }

    private func field(_ t: Tokens) -> some View {
        ComposerField(state: model.homeComposer, placeholder: "Ask anything", font: .systemFont(ofSize: 15), lineHeight: 20,
                      textColor: t.text.nsColor, tokenColor: t.emberText.nsColor, chipFill: t.opaqueSurface.nsColor,
                      placeholderColor: t.secondaryText.nsColor, focusRequest: focusRequest,
                      onFocus: { composerFocused = $0 }, onSubmit: send)
    }

    @ViewBuilder private func controls(_ t: Tokens) -> some View {
        if model.source.canDictate {
            Image(systemName: dictating ? "mic.fill" : "mic")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle((dictating ? t.emberMark : t.text).color)
                .frame(width: 36, height: 36)
                .overlay {
                    Circle().strokeBorder((dictating ? t.emberMark : t.text.opacity(0.12)).color, lineWidth: Tokens.hairlineWidth)
                }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in startDictating() }
                    .onEnded { _ in stopDictating() })
                .help("Hold to dictate")
                .accessibilityElement()
                .accessibilityLabel("Dictate")
                .accessibilityAddTraits(.isButton)
        }
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(t.onEmber.color)
                .frame(width: 36, height: 36)
                .background(Circle().fill(t.emberMark.color))
        }
        .buttonStyle(.plain)
        .disabled(model.homeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel("Send")
    }

    private func attachmentRow(_ t: Tokens) -> some View {
        AttachmentTokens(composer: model.homeComposer, density: .comfortable, t: t, width: 640)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { attach(panel.urls) }
    }

    private func attach(_ urls: [URL]) { model.homeComposer.attach(urls) }

    /// The mic is held: the field keeps focus, so the words land in it.
    private func startDictating() {
        guard !dictating else { return }
        dictating = true
        focusRequest += 1
        Task { await model.source.dictate(true) }
    }

    private func stopDictating() {
        guard dictating else { return }
        dictating = false
        Task { await model.source.dictate(false) }
    }

    private var hint: some View {
        TokensReader { t in
            HStack(spacing: 4) {
                Text("Or hold")
                Text(Self.keyName(store.keys.key))
                    .fontWeight(.semibold)
                    .foregroundStyle(t.text.color)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.text.opacity(0.08).color))
                Text("in any app")
            }
            .font(.system(size: 12))
            .foregroundStyle(t.secondaryText.color)
        }
    }

    @ViewBuilder
    private func cards(_ t: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.running.isEmpty {
                StudioGroupLabel("Running")
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 14) {
                    ForEach(model.running) { RunningCard(session: $0, model: model).transition(.opacity) }
                }
            }
            if !model.recent.isEmpty {
                StudioGroupLabel("Recent").padding(.top, model.running.isEmpty ? 0 : 18)
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 14) {
                    ForEach(model.recent) { RecentCard(session: $0, model: model).transition(.opacity) }
                }
            }
        }
        .frame(maxWidth: 940, alignment: .leading)
        .animation(Motion.crossfade, value: model.running.map(\.id))
        .animation(Motion.crossfade, value: model.recent.map(\.id))
    }

    /// "Right ⌥": the side and the keycap, as on the canvas (no picker tags like "(recommended)").
    static func keyName(_ key: BuddyKey) -> String { key.shortName }

    /// As many cards per row as fit, each at least 260 pt: three at full width, fewer when narrow.
    static let columns = [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)]

    private func send() {
        let text = model.homeComposer.expandedText
        guard !sending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        Task {
            if await model.ask(text) { model.homeComposer.clear(sent: text) }
            sending = false
        }
    }
}

/// A running session: disc, title, live verb; one that needs you shows its question, and a
/// permission ask gets Allow / Deny right here.
struct RunningCard: View {
    let session: SessionSnapshot
    let model: StudioModel

    var body: some View {
        TokensReader { t in
            StudioCard(rim: ask == nil ? nil : Tokens.amberBorder.opacity(0.45)) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        SessionGlyph(session: session, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(line).font(.system(size: 12)).lineLimit(1)
                                .foregroundStyle(ask == nil ? t.secondaryText.color : t.amber.color)
                        }
                    }
                    if let fraction = StudioModel.progress(session.status) {
                        StudioProgressLine(fraction: fraction)
                    }
                    // The whole card opens the session (canvas: no "Open" link); a permission ask
                    // gets Allow / Deny right here.
                    if case .permission(let permission)? = ask {
                        HStack(spacing: 8) {
                            Button("Allow") { decide(permission, allow: true) }.buttonStyle(.pillProminent)
                            Button("Deny") { decide(permission, allow: false) }.buttonStyle(.pill)
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(session.id) }
        .pointerStyle(.link)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open") { model.select(session.id) }
    }

    private var ask: NeedsYou.Kind? {
        if case .needsYou(let needs) = session.status { needs.kind } else { nil }
    }

    private var line: String {
        switch ask {
        case .permission(let p): p.title
        case .question(let q): q.items.first?.question ?? "Has a question for you"
        case .soft(let text): text
        case nil:
            [session.liveLine ?? "Working", session.liveTeam.isEmpty ? nil : StudioCopy.teammates(session.liveTeam.count)]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    private func decide(_ permission: PermissionAsk, allow: Bool) {
        Task { await model.source.handle(.action(session.id, .approve(requestID: permission.id, allow: allow, always: false, message: nil))) }
    }
}

/// A recent session: origin app, title, and when.
struct RecentCard: View {
    let session: SessionSnapshot
    let model: StudioModel

    var body: some View {
        // A real button, so it takes keyboard focus and Space/Return (QA U17).
        Button { model.select(session.id) } label: { card }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
    }

    private var card: some View {
        StudioCard {
            HStack(spacing: 10) {
                if let icon = OriginIcon.image(session.origin) {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22).accessibilityHidden(true)
                } else {
                    SessionGlyph(session: session, size: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if case .done(_, unread: true) = session.status {
                            TokensReader { t in Circle().fill(t.emberMark.color).frame(width: 7, height: 7) }
                                .accessibilityLabel("Unread")
                        }
                    }
                    TokensReader { t in
                        Text([session.origin?.appName, StudioCopy.shortTime(session.lastUsed, now: Date())].compactMap { $0 }
                            .joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(t.secondaryText.color).lineLimit(1)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// The health strip: each item deep-links to the page that fixes it.
struct HealthStripView: View {
    let store: SettingsStore
    @Environment(\.claudeCodeStatus) private var claudeCode
    @Environment(\.voicePrepareState) private var voice
    @Environment(\.mcpServers) private var servers
    @Environment(\.permissionCenter) private var permissions
    @Environment(\.openStudioSettings) private var openSettings

    var body: some View {
        let strip = HealthStrip(inputs)
        TokensReader { t in
            // One line when it fits; two when the window is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) { items(strip.items, t) }
                VStack(spacing: 6) {
                    HStack(spacing: 22) { items(Array(strip.items.prefix(2)), t) }
                    HStack(spacing: 22) { items(Array(strip.items.dropFirst(2)), t) }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(t.secondaryText.color)
        }
    }

    private func items(_ items: [HealthStrip.Item], _ t: Tokens) -> some View {
        ForEach(items) { item in
            Button { openSettings(item.page) } label: {
                HStack(spacing: 6) {
                    Circle().fill(item.level.color(t).color).frame(width: 7, height: 7)
                    Text(item.text).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help("Open \(item.page.title) settings")
        }
    }

    private var inputs: HealthStrip.Inputs {
        let required = PermissionKind.allCases.filter { permissions?.policy.required.contains($0) == true }
        let missing = (permissions?.needsAttention == true) ? required.filter { permissions?.state($0) == .missing } : []
        return HealthStrip.Inputs(claudeCode: claudeCode, voiceChosen: store.voice.setup == .voice, voice: voice,
                                  servers: servers, missingPermissions: missing,
                                  permissionsNeedReopen: permissions?.needsAttention == true && permissions?.needsRelaunch == true)
    }
}

extension HealthStrip.Level {
    func color(_ t: Tokens) -> TokenColor {
        switch self {
        case .ok: t.sage
        case .attention: t.amber
        case .problem: t.rose
        case .neutral: t.secondaryText
        }
    }
}

extension EnvironmentValues {
    /// Opens a Studio Settings page (Home's health strip). The Studio window provides it.
    @Entry var openStudioSettings: StudioSettingsOpener = StudioSettingsOpener()
}

struct StudioSettingsOpener {
    var open: (SettingsPage) -> Void = { _ in }
    func callAsFunction(_ page: SettingsPage) { open(page) }
}

extension StudioCopy {
    static func teammates(_ n: Int) -> String { n == 1 ? "1 teammate" : "\(n) teammates" }
}
