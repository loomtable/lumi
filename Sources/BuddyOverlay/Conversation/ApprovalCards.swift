import BuddyCore
import SwiftUI

/// "Needs your OK" (04 §4.3): what goes out, exactly (the command, the file with "+12 −3", the
/// address), then the agent's reason, its detail, then Allow ⌘↩, Always for this session, Deny,
/// and "Tell Lumi something instead". With the card focused, 1 · 2 · 3 answer (inspire #2). It
/// waits with no timeout; the waiting clock counts up. Once answered, it's one receipt line
/// ("Allowed · npm test · 14:02", inspire #5).
struct ApprovalCard: View {
    let approval: PageApproval
    let density: PageDensity
    let t: Tokens
    /// allow, always, message.
    let onAnswer: (Bool, Bool, String?) -> Void
    @State private var telling = false
    @State private var message = ""
    @FocusState private var messageFocused: Bool
    @FocusState private var cardFocused: Bool

    var body: some View {
        if let receipt = Self.receipt(approval) {
            Text(receipt)
                .font(density.caption.font)
                .foregroundStyle(t.secondaryText.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(receipt)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NEEDS YOUR OK")
                    .font(.system(size: density.caption.size, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(t.amber.color)
                Spacer()
                if let asker = approval.ask.asker {
                    Text(asker).font(density.caption.font).foregroundStyle(t.secondaryText.color)
                } else if approval.state == .pending {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("waiting " + TrailCopy.clock(ctx.date.timeIntervalSince(approval.since)))
                            .font(density.caption.font.monospacedDigit())
                            .foregroundStyle(t.secondaryText.color)
                    }
                }
            }
            Text(approval.ask.payload)
                .font(isCommand ? density.mono.mono.weight(.semibold)
                                : .system(size: density.headline.size - 1, weight: .semibold))
                .foregroundStyle(t.text.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let reason = approval.ask.reason {
                Text(reason)
                    .font(density.callout.font)
                    .foregroundStyle(t.secondaryText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            detail
            if approval.state == .pending {
                buttons
                if approval.ask.tier == .needsClick {
                    Text("This one needs a click.")
                        .font(density.caption.font)
                        .foregroundStyle(t.secondaryText.color)
                }
                if cardFocused {
                    Text(Self.keysHint).font(density.caption.font).foregroundStyle(t.secondaryText.color)
                }
                if telling {
                    TextField("Tell Lumi something instead", text: $message)
                        .textFieldStyle(.plain)
                        .font(density.body.font)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(PageColors(t: t).tile.color, in: Capsule())
                        .focused($messageFocused)
                        .onSubmit { send(allow: false, always: false, message: message) }
                        .onAppear { messageFocused = true }
                } else {
                    Button("Tell Lumi something instead…") { telling = true }
                        .buttonStyle(.plain)
                        .font(density.caption.font)
                        .foregroundStyle(t.secondaryText.color)
                }
            } else {
                Text(resolvedLine)
                    .font(density.caption.font)
                    .foregroundStyle(t.secondaryText.color)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(PageColors(t: t).amberWash.color, in: RoundedRectangle(cornerRadius: PageShape.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PageShape.cardRadius, style: .continuous)
            .strokeBorder(approval.isOpen ? Tokens.amberBorder.color : t.hairline.color, lineWidth: 1.5))
        .focusable(approval.state == .pending)
        .focused($cardFocused)
        .focusEffectDisabled()
        .onKeyPress(characters: CharacterSet(charactersIn: "123")) { press in
            guard approval.state == .pending, let answer = Self.answer(forKey: press.characters) else { return .ignored }
            send(allow: answer.allow, always: answer.always, message: nil)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Needs your OK: \(approval.ask.payload)")
    }

    private var isCommand: Bool {
        if case .command = approval.ask.detail { return true }
        return false
    }

    static let keysHint = "1 Allow · 2 Always for this session · 3 Deny"

    /// 1 Allow, 2 Always for this session, 3 Deny.
    static func answer(forKey key: String) -> (allow: Bool, always: Bool)? {
        switch key {
        case "1": (true, false)
        case "2": (true, true)
        case "3": (false, false)
        default: nil
        }
    }

    /// "Allowed · npm test · 14:02" once a reply went out; nil while it waits or was withdrawn.
    static func receipt(_ approval: PageApproval) -> String? {
        let word: String
        switch approval.state {
        case .allowed: word = "Allowed"
        case .denied: word = "Denied"
        case .pending, .sending, .cancelled: return nil
        }
        let at = approval.resolvedAt.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return "\(word) · \(approval.ask.payload)\(at)"
    }

    @ViewBuilder private var detail: some View {
        switch approval.ask.detail {
        case .diff(let path, let old, let new):
            DiffTile(diff: DiffModel(path: path, old: old, new: new), density: density, t: t)
        case .command(let command) where command.contains(where: \.isNewline):
            // The first line is the headline; a longer script shows whole.
            Text(command)
                .font(density.mono.mono)
                .foregroundStyle(t.text.color)
                .lineLimit(8)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PageColors(t: t).tile.color, in: RoundedRectangle(cornerRadius: PageShape.codeRadius, style: .continuous))
                .textSelection(.enabled)
        case .command, .url, .plain:
            EmptyView()
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            // Flat capsules: the card sits on the Panel's glass, so no glass on glass (04 §7.2).
            Button("Allow ⌘↩") { send(allow: true, always: false, message: nil) }
                .buttonStyle(.pillProminent)
                .keyboardShortcut(.return, modifiers: .command)
            Button("Always for this session") { send(allow: true, always: true, message: nil) }
                .buttonStyle(.pill)
            Button("Deny") { send(allow: false, always: false, message: nil) }
                .buttonStyle(.pill)
        }
    }

    private var resolvedLine: String {
        switch approval.state {
        case .pending, .allowed, .denied: ""
        case .sending: "Sending…"
        case .cancelled: "No longer needed"
        }
    }

    private func send(allow: Bool, always: Bool, message: String?) {
        let m = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        onAnswer(allow, always, m?.isEmpty == false ? m : nil)
    }
}

/// AskUserQuestion (04 §4.3): the question, 2–4 option chips (the first, recommended, with an
/// ember outline), and "Something else…" which opens the composer. Multi-select chips toggle
/// and a Send button appears.
struct QuestionCard: View {
    let question: PageQuestion
    let density: PageDensity
    let t: Tokens
    let onAnswer: ([String: String]) -> Void
    let onSomethingElse: () -> Void
    @State private var picked: [String: Set<String>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(question.ask.items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.question)
                        .font(.system(size: density.headline.size, weight: .semibold))
                        .foregroundStyle(t.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(item.options.enumerated()), id: \.offset) { index, option in
                        chip(item: item, option: option, recommended: index == 0)
                    }
                }
            }
            if question.answers == nil {
                HStack {
                    Button("Something else…", action: onSomethingElse)
                        .buttonStyle(.plain)
                        .font(density.callout.font)
                        .foregroundStyle(t.secondaryText.color)
                    Spacer()
                    if needsSend {
                        Button("Send") { onAnswer(collected) }
                            .buttonStyle(.pillProminent)
                            .disabled(!complete)
                    }
                }
            }
        }
        .padding(14)
        .background(PageColors(t: t).tile.color, in: RoundedRectangle(cornerRadius: PageShape.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lumi asks: \(question.ask.items.first?.question ?? "")")
    }

    /// Single-select with one question answers on the tap; anything else needs Send.
    private var needsSend: Bool {
        question.ask.items.count > 1 || question.ask.items.contains(where: \.multiSelect)
    }

    private var complete: Bool {
        question.ask.items.allSatisfy { !(picked[$0.question] ?? []).isEmpty }
    }

    private var collected: [String: String] {
        var out: [String: String] = [:]
        for item in question.ask.items {
            let labels = item.options.map(\.label).filter { picked[item.question]?.contains($0) == true }
            out[item.question] = labels.joined(separator: ", ")
        }
        return out
    }

    private func chip(item: QuestionAsk.Item, option: QuestionAsk.Option, recommended: Bool) -> some View {
        let chosen = isChosen(item, option.label)
        return Button {
            guard question.answers == nil else { return }
            var set = picked[item.question] ?? []
            if item.multiSelect {
                if set.contains(option.label) { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = [option.label]
            }
            picked[item.question] = set
            if !needsSend { onAnswer([item.question: option.label]) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(option.label).font(density.body.font.weight(.medium)).foregroundStyle(t.text.color)
                    // The outline alone is colour; the word says it (QA U16).
                    if recommended, Self.needsRecommendedWord(option.label) {
                        Text("Recommended").font(density.caption.font).foregroundStyle(t.emberText.color)
                    }
                }
                if let d = option.description, !d.isEmpty {
                    Text(d).font(density.caption.font).foregroundStyle(t.secondaryText.color).lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background((chosen ? t.selection : t.well).color,
                        in: RoundedRectangle(cornerRadius: Tokens.chipRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.chipRadius, style: .continuous)
                .strokeBorder(recommended || chosen ? t.emberMark.color : t.hairline.color, lineWidth: recommended || chosen ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .disabled(question.answers != nil && !chosen)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// Claude often writes "(Recommended)" into the label itself; don't say it twice.
    nonisolated static func needsRecommendedWord(_ label: String) -> Bool {
        !label.localizedCaseInsensitiveContains("recommended")
    }

    private func isChosen(_ item: QuestionAsk.Item, _ label: String) -> Bool {
        if let answers = question.answers {
            return answers[item.question]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(label) == true
        }
        return picked[item.question]?.contains(label) == true
    }
}

/// The plan tile (04 §4.3, §5.4): the session's todo list, ticking live.
struct PlanTile: View {
    let todos: [StepDetail.Todo]
    let density: PageDensity
    let t: Tokens

    var body: some View {
        // One card, as on the canvas: "Plan" with the count trailing, then quiet rows (no tile per row).
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Plan")
                    .font(.system(size: density.callout.size + 1, weight: .semibold))
                    .foregroundStyle(t.text.color)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                let done = todos.filter { $0.state == .completed }.count
                Text("\(done) of \(todos.count) done")
                    .font(density.caption.font.monospacedDigit())
                    .foregroundStyle(t.secondaryText.color)
            }
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .top, spacing: 10) {
                    mark(todo.state).frame(height: density.body.line)
                    Text(todo.content)
                        .font(density.body.font)
                        .foregroundStyle(todo.state == .completed ? t.secondaryText.color : t.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(todo.state.label)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(PageColors(t: t).tile.color, in: RoundedRectangle(cornerRadius: PageShape.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PageShape.cardRadius, style: .continuous)
            .strokeBorder(t.text.opacity(0.07).color, lineWidth: Tokens.hairlineWidth))
        .animation(Motion.crossfade, value: todos.map(\.state))
    }

    @ViewBuilder private func mark(_ state: StepDetail.Todo.State) -> some View {
        switch state {
        case .completed:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(t.sage.color).frame(width: 14)
        case .inProgress:
            Circle().strokeBorder(t.emberMark.color, lineWidth: 1.5).frame(width: 14, height: 14)
        case .pending:
            Circle().strokeBorder(t.hairline.color, lineWidth: 1.5).frame(width: 14, height: 14)
        }
    }
}

extension StepDetail.Todo.State {
    var label: String {
        switch self {
        case .pending: "To do"
        case .inProgress: "In progress"
        case .completed: "Done"
        }
    }
}
