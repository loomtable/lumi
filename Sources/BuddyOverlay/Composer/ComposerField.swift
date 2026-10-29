import AppKit
import SwiftUI

/// The composer's text field (61-COMPOSER §3): a plain NSTextView, so system dictation, AX insertion
/// (Lumi's own dictation), IME, spelling and undo work as in any Mac field, with the hooks Claude
/// Code's input has. ⌘V of a picture attaches it; a long paste collapses into a chip; a drop attaches
/// pictures and writes `@path` for the rest; `/` and `@` open the menu; ↩ sends, ⇧↩ and ⌥↩ add a
/// line; ↑/↓ walk the session's history; Esc closes the menu, then clears, then interrupts.
public struct ComposerField: NSViewRepresentable {
    @Bindable var state: ComposerState
    var placeholder: String
    var font: NSFont
    var lineHeight: CGFloat
    var textColor: NSColor
    var tokenColor: NSColor
    var chipFill: NSColor
    var placeholderColor: NSColor
    var maxLines = 6
    /// Bumped by the host to move keyboard focus here.
    var focusRequest = 0
    var onFocus: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void
    /// ⌘⇧↩: send to a new session (a page's composer); nil where that means nothing (Home).
    var onSubmitToNewSession: (() -> Void)?
    /// Esc with nothing to close or clear: true when the host used it (interrupted a turn).
    var onEscape: () -> Bool = { false }

    public init(state: ComposerState, placeholder: String, font: NSFont, lineHeight: CGFloat, textColor: NSColor,
                tokenColor: NSColor, chipFill: NSColor, placeholderColor: NSColor, maxLines: Int = 6, focusRequest: Int = 0,
                onFocus: @escaping (Bool) -> Void = { _ in }, onSubmit: @escaping () -> Void,
                onSubmitToNewSession: (() -> Void)? = nil, onEscape: @escaping () -> Bool = { false }) {
        self.state = state
        self.placeholder = placeholder
        self.font = font
        self.lineHeight = lineHeight
        self.textColor = textColor
        self.tokenColor = tokenColor
        self.chipFill = chipFill
        self.placeholderColor = placeholderColor
        self.maxLines = maxLines
        self.focusRequest = focusRequest
        self.onFocus = onFocus
        self.onSubmit = onSubmit
        self.onSubmitToNewSession = onSubmitToNewSession
        self.onEscape = onEscape
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none

        let view = ComposerTextView(usingTextLayoutManager: false)
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        view.setAccessibilityLabel("Message")
        scroll.documentView = view
        context.coordinator.view = view
        context.coordinator.apply(self, force: true)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(self, force: false)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let text = context.coordinator.view?.textStorage else { return nil }
        let width = proposal.width ?? nsView.frame.width
        guard width > 0, width.isFinite else { return nil }
        let lines = min(Self.lines(in: text, width: width), maxLines)
        return CGSize(width: width, height: lineHeight * CGFloat(lines))
    }

    /// How many lines `text` takes at `width` (each line is `lineHeight` tall). Laid out apart from
    /// the text view: SwiftUI probes narrower widths too, and a probe that set the view's own
    /// container left typed text wrapping at a third of the field (owner, Oct 29).
    static func lines(in text: NSAttributedString, width: CGFloat) -> Int {
        let storage = NSTextStorage(attributedString: text)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var lines = manager.extraLineFragmentRect.isEmpty ? 0 : 1
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, _, _ in lines += 1 }
        return max(1, lines)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var field: ComposerField
        weak var view: ComposerTextView?
        private var focusRequest: Int
        private var pickRequests: Int
        private var applyingState = false
        /// The colours last styled with: a light/dark switch restyles.
        private var styled: [NSColor] = []

        init(_ field: ComposerField) {
            self.field = field
            focusRequest = field.focusRequest
            pickRequests = field.state.pickRequests
        }

        var state: ComposerState { field.state }

        /// Brings the view in line with the state (text set by the host: a history entry, a
        /// prefill, dictation, a restored draft).
        func apply(_ field: ComposerField, force: Bool) {
            self.field = field
            guard let view else { return }
            view.placeholder = field.placeholder
            var hint = baseAttributes
            hint[.foregroundColor] = field.placeholderColor
            view.placeholderAttributes = hint
            if force || view.font != field.font { view.font = field.font; view.typingAttributes = baseAttributes }
            view.insertionPointColor = field.tokenColor
            // Never while the input method is composing: its marked text isn't in the state yet.
            if view.string != state.text, !view.hasMarkedText() {
                applyingState = true
                view.string = state.text
                view.setSelectedRange(NSRange(location: (state.text as NSString).length, length: 0))
                applyingState = false
                restyle()
                view.needsDisplay = true
            } else if force || styled != [field.textColor, field.tokenColor, field.chipFill] {
                restyle()
            }
            if state.pickRequests != pickRequests {
                pickRequests = state.pickRequests
                accept()
                view.window?.makeFirstResponder(view)
            }
            if field.focusRequest != focusRequest {
                focusRequest = field.focusRequest
                DispatchQueue.main.async { [weak view] in view?.window?.makeFirstResponder(view) }
            }
        }

        private var baseAttributes: [NSAttributedString.Key: Any] {
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = field.lineHeight
            p.maximumLineHeight = field.lineHeight
            return [.font: field.font, .foregroundColor: field.textColor, .paragraphStyle: p,
                    .baselineOffset: (field.lineHeight - (field.font.ascender - field.font.descender)) / 2]
        }

        /// `/command`, `@mention` and paste chips in ember; chips on a tile. Attributes only, so
        /// undo and the caret are untouched.
        func restyle() {
            // Marked text keeps the input method's own attributes until it's committed.
            guard let view, let storage = view.textStorage, !view.hasMarkedText() else { return }
            styled = [field.textColor, field.tokenColor, field.chipFill]
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: all)
            for token in ComposerText.tokens(in: storage.string) where NSMaxRange(token.range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: field.tokenColor, range: token.range)
                if token.kind == .paste { storage.addAttribute(.backgroundColor, value: field.chipFill, range: token.range) }
            }
            storage.endEditing()
            view.typingAttributes = baseAttributes
        }

        // MARK: NSTextViewDelegate

        public func textDidChange(_ notification: Notification) {
            guard !applyingState, let view else { return }
            state.text = view.string
            state.history.stopWalking()
            restyle()
            state.caretChanged(view.selectedRange().location)
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !applyingState, let view, view.selectedRange().length == 0 else { return }
            state.caretChanged(view.selectedRange().location)
        }

        public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            switch selector {
            case #selector(NSResponder.insertNewline(_:)) where state.menu != nil && !shift,
                 #selector(NSResponder.insertTab(_:)) where state.menu != nil:
                accept()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                if shift { textView.insertText("\n", replacementRange: textView.selectedRange()); return true }
                field.onSubmit()
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.moveUp(_:)):
                if state.menu != nil { state.moveSelection(-1); return true }
                guard onFirstLine(textView), let older = state.historyBack() else { return false }
                show(older)
                return true
            case #selector(NSResponder.moveDown(_:)):
                if state.menu != nil { state.moveSelection(1); return true }
                guard onLastLine(textView), let newer = state.historyForward() else { return false }
                show(newer)
                return true
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                return escape()
            default:
                return false
            }
        }

        /// Esc: the menu closes, else a draft clears, else the host interrupts a running turn.
        @discardableResult func escape() -> Bool {
            if state.menu != nil { state.dismissMenu(); return true }
            if !state.text.isEmpty || !state.attachments.isEmpty {
                // Through the text view, so ⌘Z brings the text back.
                // The pastes stay, so an undone chip still expands.
                if let view, !view.string.isEmpty { view.insertText("", replacementRange: NSRange(location: 0, length: (view.string as NSString).length)) }
                state.draft = ComposerDraft(pastes: state.pastes)
                return true
            }
            return field.onEscape()
        }

        public func textDidBeginEditing(_ notification: Notification) { field.onFocus(true) }
        public func textDidEndEditing(_ notification: Notification) {
            state.dismissMenu()
            field.onFocus(false)
        }

        /// A history entry replaces the text, caret at the end.
        private func show(_ text: String) {
            state.text = text
            apply(field, force: false)
        }

        private func onFirstLine(_ view: NSTextView) -> Bool {
            let caret = view.selectedRange().location
            return !(view.string as NSString).substring(to: caret).contains("\n")
        }

        private func onLastLine(_ view: NSTextView) -> Bool {
            let caret = NSMaxRange(view.selectedRange())
            return !(view.string as NSString).substring(from: caret).contains("\n")
        }

        // MARK: Menu, paste, drop

        func accept() {
            guard let view, let (range, insert) = state.acceptMenu(), NSMaxRange(range) <= (view.string as NSString).length else { return }
            view.insertText(insert, replacementRange: range)
        }

        /// ⌘V. True when handled here; false lets the text view paste plain text.
        func paste(_ pb: NSPasteboard) -> Bool {
            switch ComposerPasteboard.read(pb) {
            case .files(let urls): take(urls); return true
            case .images(let urls): state.attach(urls); return true
            case .text(let text) where ComposerText.shouldCollapse(text):
                view?.insertText(state.collapse(text), replacementRange: view?.selectedRange() ?? NSRange())
                return true
            case .text, .nothing: return false
            }
        }

        /// A drop: true when used.
        func drop(_ pb: NSPasteboard) -> Bool {
            switch ComposerPasteboard.read(pb) {
            case .files(let urls): take(urls); return true
            case .images(let urls): state.attach(urls); return true
            case .text, .nothing: return false
            }
        }

        /// Files: pictures attach, everything else is `@path` at the caret.
        private func take(_ urls: [URL]) {
            let mentions = state.take(urls)
            guard !mentions.isEmpty, let view else { return }
            let range = view.selectedRange()
            let before = range.location > 0 ? (view.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) : " "
            let lead = before.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? " " : ""
            view.insertText(lead + mentions + " ", replacementRange: range)
            view.window?.makeFirstResponder(view)
        }
    }
}

/// The NSTextView: paste and drop go to the coordinator first, a paste chip deletes whole, the
/// edit keys work in a non-activating panel too, and the placeholder draws when empty.
public final class ComposerTextView: NSTextView {
    weak var coordinator: ComposerField.Coordinator?
    var placeholder = ""
    /// The typed text's attributes in the placeholder colour, so the hint sits where text will.
    var placeholderAttributes: [NSAttributedString.Key: Any] = [:]

    override public func paste(_ sender: Any?) {
        if coordinator?.paste(.general) == true { return }
        pasteAsPlainText(sender)
    }

    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if coordinator?.drop(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }

    override public func deleteBackward(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0, let chip = ComposerText.chip(endingAt: range.location, in: string) {
            insertText("", replacementRange: chip)
            return
        }
        super.deleteBackward(sender)
    }

    /// ⌘V, ⌘C, ⌘X, ⌘A, ⌘Z and ⇧⌘Z: the Panel is non-activating, so the menu bar's Edit menu may
    /// not be the one that sees them. ⌘⇧↩ sends to a new session where the host offers it.
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (flags, event.charactersIgnoringModifiers) {
        case (.command, "v"): paste(nil)
        case (.command, "c"): copy(nil)
        case (.command, "x"): cut(nil)
        case (.command, "a"): selectAll(nil)
        case (.command, "z"): undoManager?.undo()
        case ([.command, .shift], "z"), ([.command, .shift], "Z"): undoManager?.redo()
        case ([.command, .shift], "\r") where coordinator?.field.onSubmitToNewSession != nil:
            coordinator?.state.dismissMenu()
            coordinator?.field.onSubmitToNewSession?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        var attrs = placeholderAttributes
        let style = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        attrs[.paragraphStyle] = style
        let origin = textContainerOrigin
        NSAttributedString(string: placeholder, attributes: attrs)
            .draw(with: NSRect(x: origin.x, y: origin.y, width: bounds.width - origin.x, height: max(style.minimumLineHeight, 1)),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override public func didChangeText() {
        super.didChangeText()
        if string.count <= 1 { needsDisplay = true } // the placeholder comes and goes
    }
}
