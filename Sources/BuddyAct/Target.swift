import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// The text field the user is in when an insert is requested.
public struct InsertTarget: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String?
    /// A secure text field (passwords): insert always refuses.
    public var isSecure: Bool
    /// The focused element accepts a new kAXSelectedTextAttribute.
    public var canSetSelectedText: Bool
    /// Identifies the focused element (CFHash), to notice a move to another field in the same app.
    public var element: Int

    public init(pid: Int32, bundleID: String?, isSecure: Bool, canSetSelectedText: Bool, element: Int = 0) {
        self.pid = pid
        self.bundleID = bundleID
        self.isSecure = isSecure
        self.canSetSelectedText = canSetSelectedText
        self.element = element
    }

    /// Same app and same field.
    public func isSameField(as other: InsertTarget) -> Bool {
        pid == other.pid && element == other.element
    }
}

public enum AXWriteResult: Sendable, Equatable {
    /// The caret moved as expected: the text is in.
    case verified
    /// The write was refused, or the caret shows nothing changed: safe to paste instead.
    case notApplied
    /// The write was accepted but the caret can't be read. Treated as inserted, because pasting
    /// as well could insert the text twice.
    case unverified
}

/// Reads and writes the focused text element. Real: `AXTextTarget`. Fake: `FakeTextTarget`.
public protocol TextTargetAccess: Sendable {
    /// The focused text element of `pid` (the app the user summoned in), or system-wide when nil.
    /// By app, because our own card may be the key window when the user presses Insert.
    func focusedTarget(in pid: Int32?) -> InsertTarget?
    /// Sets kAXSelectedTextAttribute on the focused element if it is still `target`'s field
    /// (some apps return success and change nothing, hence the check).
    func setSelectedText(_ text: String, target: InsertTarget) -> AXWriteResult
}

/// Sends the paste shortcut. Real: `CGEventPaster`. Fake: `FakePaster`.
@MainActor
public protocol PasteShortcut {
    /// Posts ⌘V to `pid` only, so a focus change can't paste into another app. False if it
    /// could not be sent.
    func pasteShortcut(to pid: Int32) -> Bool
}

public struct AXTextTarget: TextTargetAccess {
    public init() {}

    static func focusedElement(in pid: Int32?) -> AXUIElement? {
        let root = pid.map { AXUIElementCreateApplication($0) } ?? AXUIElementCreateSystemWide()
        // On this element only; the process-wide value is set by ContextBuilder.prepare().
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    static func selectedRange(_ el: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    public func focusedTarget(in pid: Int32?) -> InsertTarget? {
        guard let el = Self.focusedElement(in: pid) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return nil }
        let secure = Self.string(el, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
            || Self.string(el, kAXRoleAttribute) == "AXSecureTextField"
        var settable: DarwinBoolean = false
        let canSet = AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success
            && settable.boolValue
        return InsertTarget(
            pid: pid, bundleID: RunningApp.bundleID(pid), isSecure: secure, canSetSelectedText: canSet,
            element: Int(bitPattern: CFHash(el)))
    }

    public func setSelectedText(_ text: String, target: InsertTarget) -> AXWriteResult {
        guard let el = Self.focusedElement(in: target.pid), let now = focusedTarget(in: target.pid),
              now.isSameField(as: target), !now.isSecure
        else { return .notApplied }
        let before = Self.selectedRange(el)
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return .notApplied }
        guard let before, let after = Self.selectedRange(el) else { return .unverified }
        return Self.verify(before: before, after: after, insertedUTF16: text.utf16.count)
    }

    /// The caret sits after the new text, or the new text is left selected (both seen in apps).
    /// Ranges are in UTF-16 units. When the old selection had the same length as the new text,
    /// "left selected" looks like "nothing happened", so that case is unverified.
    static func verify(before: CFRange, after: CFRange, insertedUTF16 n: Int) -> AXWriteResult {
        if after.length == 0, after.location == before.location + n { return .verified }
        if after.location == before.location, after.length == before.length {
            return before.length == n ? .unverified : .notApplied
        }
        if after.location == before.location, after.length == n, n > 0 { return .verified }
        return .unverified
    }
}

public struct CGEventPaster: PasteShortcut {
    public init() {}

    public func pasteShortcut(to pid: Int32) -> Bool {
        // Apps match ⌘V by the character the layout gives the key under ⌘ (on Dvorak, keycode 9
        // is "." and would send ⌘.), so find the key that types "v".
        guard CGPreflightPostEventAccess(), let key = KeyLayout.keyCode(typing: "v") else { return false }
        // A private source, and explicit flags, so modifiers the user is holding (the buddy
        // key, say) don't turn ⌘V into ⌥⌘V.
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}

@MainActor
enum KeyLayout {
    /// The key that types `character` with ⌘ held in the current layout, or in the ASCII-capable
    /// layout macOS uses for shortcuts when the current one has no Latin letters.
    static func keyCode(typing character: Character) -> CGKeyCode? {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for case let source? in sources {
            if let code = keyCode(typing: character, in: source.takeRetainedValue()) { return code }
        }
        return nil
    }

    static func keyCode(typing character: Character, in source: TISInputSource) -> CGKeyCode? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let target = Array(String(character).utf16)
        return data.withUnsafeBytes { bytes -> CGKeyCode? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF),
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count,
                    &length, &chars)
                if status == noErr, Array(chars.prefix(length)) == target { return CGKeyCode(code) }
            }
            return nil
        }
    }
}
