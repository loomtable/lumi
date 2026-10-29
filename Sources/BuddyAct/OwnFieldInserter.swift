import AppKit

/// What dictating into Lumi's own focused field did.
public enum OwnInsert: Equatable, Sendable {
    case inserted
    /// A password field: never typed into.
    case secure
    /// No editable Lumi field had the keyboard: the words go to the app in front.
    case none
    /// A Lumi field was taken at the press but is gone now (the Glance card folded away for the
    /// pill): the words are meant for Lumi, so they never go to the app behind.
    case lost
}

/// The Lumi field that had the keyboard at the dictation key's press: its window, its text view
/// (an `NSTextField`'s field editor, or an `NSTextView`) and, for a text field, the field itself.
@MainActor
public final class OwnFieldTarget {
    public private(set) weak var window: NSWindow?
    public private(set) weak var view: NSTextView?
    /// The text field the field editor was editing: focused again if the editor moved on.
    public private(set) weak var field: NSTextField?

    init(window: NSWindow?, view: NSTextView, field: NSTextField?) {
        self.window = window
        self.view = view
        self.field = field
    }
}

/// Lumi's own windows can't be pasted into from outside (`InsertResult.refusedOwnApp`), so a
/// dictation into one of its fields goes in here, in process (U64): the Glance reply, search,
/// rename, Settings, a composer. The field is taken at the press, before the pill or an overlay
/// takes the keyboard, and gets the words at its selection when the dictation stops.
@MainActor
public protocol OwnTextInserting: AnyObject {
    /// At the press: the Lumi field that has the keyboard now, if any.
    func capture() -> OwnFieldTarget?
    /// At the stop: into `target` (else whatever Lumi field has the keyboard now).
    func insert(_ text: String, into target: OwnFieldTarget?) -> OwnInsert
}

@MainActor
public final class OwnFieldInserter: OwnTextInserting {
    private let keyResponder: @MainActor () -> NSResponder?
    private let mainResponder: @MainActor () -> NSResponder?

    /// `keyResponder`: what has Lumi's keyboard (the key window's first responder, a
    /// non-activating panel's too). `mainResponder`: the main window's, the fallback when an
    /// overlay holds the key status.
    public init(keyResponder: @escaping @MainActor () -> NSResponder? = { NSApp.windows.first(where: \.isKeyWindow)?.firstResponder },
                mainResponder: @escaping @MainActor () -> NSResponder? = { NSApp.mainWindow?.firstResponder }) {
        self.keyResponder = keyResponder
        self.mainResponder = mainResponder
    }

    public func capture() -> OwnFieldTarget? {
        guard let view = Self.editable(keyResponder()) ?? Self.editable(mainResponder()) else { return nil }
        return OwnFieldTarget(window: view.window, view: view, field: view.isFieldEditor ? view.delegate as? NSTextField : nil)
    }

    public func insert(_ text: String, into target: OwnFieldTarget?) -> OwnInsert {
        guard let view = resolve(target) ?? Self.editable(keyResponder()) ?? Self.editable(mainResponder()) else {
            return target == nil ? .none : .lost
        }
        if Self.isSecure(view) { return .secure }
        // A one-line field (a field editor) gets one line, as typing there would.
        let words = view.isFieldEditor ? TextInserter.oneLine(text) : text
        view.insertText(words, replacementRange: view.selectedRange())
        return .inserted
    }

    /// The captured field's text view now: the same one if it still edits there; for a text field
    /// whose editor moved on, the field focused again. Its window takes the keyboard back (an
    /// overlay or the pill may hold it), within Lumi, never activating it.
    private func resolve(_ target: OwnFieldTarget?) -> NSTextView? {
        guard let target, let window = target.window else { return nil }
        if !window.isKeyWindow, window.canBecomeKey { window.makeKey() }
        if let view = target.view, view.window === window, window.firstResponder === view, view.isEditable { return view }
        if let field = target.field, field.window === window, window.makeFirstResponder(field) {
            return Self.editable(window.firstResponder)
        }
        return nil
    }

    private static func editable(_ responder: NSResponder?) -> NSTextView? {
        guard let view = responder as? NSTextView, view.isEditable else { return nil }
        return view
    }

    /// An `NSSecureTextField` edits through a field editor whose delegate is the field.
    static func isSecure(_ view: NSTextView) -> Bool {
        view.isFieldEditor && view.delegate is NSSecureTextField
    }
}
