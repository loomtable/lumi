import AppKit
import Testing
@testable import BuddyAct

/// U64: a dictation into Lumi's own field (Glance reply, search, rename, Settings, a Studio field)
/// failed with ownApp. The field is taken at the press and gets the words at its selection when
/// the dictation stops, even if an overlay took the keyboard meanwhile. Never a password field.
/// Which window has the keyboard, as the test moves it.
@MainActor private final class KeyWindow {
    var window: NSWindow
    init(_ window: NSWindow) { self.window = window }
}

@MainActor
struct OwnFieldInserterTests {
    private func window(_ view: NSView) -> NSWindow {
        let w = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 300, height: 100), styleMask: [.titled], backing: .buffered,
                         defer: false)
        w.isReleasedWhenClosed = false
        w.contentView?.addSubview(view)
        return w
    }

    @Test func aFocusedTextFieldTakesTheWordsAtItsSelectionOnOneLine() throws {
        let field = NSTextField(string: "meet at ")
        field.frame = CGRect(x: 0, y: 0, width: 200, height: 24)
        let w = window(field)
        defer { w.close() }
        #expect(w.makeFirstResponder(field))
        let editor = try #require(w.firstResponder as? NSTextView, "the field editor has the keyboard")
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        let inserter = OwnFieldInserter(keyResponder: { w.firstResponder }, mainResponder: { nil })
        #expect(inserter.insert("noon\nsharp", into: inserter.capture()) == .inserted)
        #expect(field.stringValue == "meet at noon sharp", "one line in a one-line field")
    }

    @Test func aFocusedTextViewTakesTheWordsAtItsSelection() {
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        view.string = "ab"
        let w = window(view)
        defer { w.close() }
        #expect(w.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: 1, length: 0))
        let inserter = OwnFieldInserter(keyResponder: { w.firstResponder }, mainResponder: { nil })
        #expect(inserter.insert("X\nY", into: inserter.capture()) == .inserted)
        #expect(view.string == "aX\nYb", "a text view keeps the lines")
    }

    /// Live (15:09:53): a Studio field at the press, the pill's overlay holding the keyboard at the
    /// stop. The field taken at the press still gets the words; a field editor that moved on (the
    /// field lost focus) comes back to the same field.
    @Test func theFieldTakenAtThePressGetsTheWordsWhileAnOverlayHoldsTheKeyboard() throws {
        let field = NSTextField(string: "Q3 ")
        field.frame = CGRect(x: 0, y: 0, width: 200, height: 24)
        let studio = window(field)
        defer { studio.close() }
        #expect(studio.makeFirstResponder(field))
        (studio.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 3, length: 0))
        let overlay = NSPanel(contentRect: CGRect(x: -3000, y: -3000, width: 50, height: 50), styleMask: [.nonactivatingPanel],
                              backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        defer { overlay.close() }
        let key = KeyWindow(studio)
        let inserter = OwnFieldInserter(keyResponder: { key.window.firstResponder }, mainResponder: { nil })
        let target = try #require(inserter.capture(), "the press takes the Studio field")
        key.window = overlay   // the pill's overlay holds the keyboard now
        #expect(OwnFieldInserter(keyResponder: { key.window.firstResponder }, mainResponder: { nil }).insert("x", into: nil) == .none,
                "what the old lookup found at the stop: no field")
        #expect(inserter.insert("budget", into: target) == .inserted)
        #expect(field.stringValue == "Q3 budget")

        studio.makeFirstResponder(nil)   // the field editor moved on
        #expect(inserter.insert("review", into: target) == .inserted, "the field is focused again")
        #expect(field.stringValue.hasSuffix("review"))
    }

    /// QA gate 4.5: the Glance reply taken at the press is gone at the stop (the card folded away
    /// for the pill). The words are Lumi's: `.lost`, never `.none` (which pastes into the app behind).
    @Test func aFieldTakenAtThePressThatIsGoneIsLostNotTheAppBehinds() throws {
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        let w = window(view)
        defer { w.close() }
        #expect(w.makeFirstResponder(view))
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let key = KeyWindow(w)
        let inserter = OwnFieldInserter(keyResponder: { key.window.firstResponder }, mainResponder: { nil })
        let target = try #require(inserter.capture())
        view.removeFromSuperview()   // the card folded away
        key.window = other           // the pill holds the keyboard
        #expect(inserter.insert("hello", into: target) == .lost)
        #expect(view.string.isEmpty)
        #expect(inserter.insert("hello", into: nil) == .none, "nothing taken at the press: the app in front")
    }

    @Test func aPasswordFieldOrNothingFocusedTakesNothing() {
        let secure = NSSecureTextField(string: "")
        secure.frame = CGRect(x: 0, y: 0, width: 200, height: 24)
        let w = window(secure)
        defer { w.close() }
        #expect(w.makeFirstResponder(secure))
        let inserter = OwnFieldInserter(keyResponder: { w.firstResponder }, mainResponder: { nil })
        #expect(inserter.insert("hunter2", into: inserter.capture()) == .secure)
        #expect(secure.stringValue.isEmpty)

        let label = NSTextView(frame: .zero)
        label.isEditable = false
        #expect(OwnFieldInserter(keyResponder: { label }, mainResponder: { nil }).insert("x", into: nil) == .none,
                "read-only text isn't a field")
        #expect(OwnFieldInserter(keyResponder: { nil }, mainResponder: { nil }).insert("x", into: nil) == .none)
    }

    @Test func theMainWindowsFieldIsTheFallbackWhenAnOverlayIsKeyAtThePress() {
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        let w = window(view)
        defer { w.close() }
        #expect(w.makeFirstResponder(view))
        let inserter = OwnFieldInserter(keyResponder: { nil }, mainResponder: { w.firstResponder })
        #expect(inserter.insert("hi", into: inserter.capture()) == .inserted)
        #expect(view.string == "hi")
    }
}
