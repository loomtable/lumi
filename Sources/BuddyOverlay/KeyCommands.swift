import AppKit

/// Keys inside a focused card. These are local: they only reach the overlay
/// while the panel is key, which happens only after the user clicks the card or the shell
/// focuses it. They are never global shortcuts.
nonisolated enum KeyCommand: Equatable {
    case event(OverlayEvent)
    /// Esc leaves full screen, or closes the card (focus returns to the previous app).
    case escape
    /// F toggles full screen; the overlay handles it itself.
    case toggleFullScreen
    /// ⌘C on a focused card with no field being edited: copy the answer.
    case copy

    static let escapeKeyCode: UInt16 = 0x35   // kVK_Escape
    static let returnKeyCode: UInt16 = 0x24   // kVK_Return
    static let enterKeyCode: UInt16 = 0x4C    // kVK_ANSI_KeypadEnter

    /// - Parameters:
    ///   - characters: `charactersIgnoringModifiers`, lowercased by the caller's layout.
    ///   - plainKeysActive: plain keys (F, 1–3) act only when no text field is being edited
    ///     ("while the reply field is empty"): a voice card the user clicked. In a typed
    ///     conversation the reply field has focus, so F and digits type.
    static func map(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                    plainKeysActive: Bool, actionCount: Int, mainAction: MainAction? = nil) -> KeyCommand? {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        let key = characters?.lowercased() ?? ""
        if keyCode == escapeKeyCode, mods.isEmpty { return .escape }
        if mods == .command {
            switch key {
            case "n": return .event(.newConversation)
            case "y": return .event(.openConversations)
            case ",": return .event(.openSettings)
            // A field being edited keeps ⌘C for its own selection.
            case "c": return plainKeysActive ? .copy : nil
            default: break
            }
            if keyCode == returnKeyCode || keyCode == enterKeyCode {
                if let mainAction { return .event(.mainAction(mainAction)) }
                return actionCount > 0 ? .event(.action(index: 0)) : nil
            }
            return nil
        }
        guard mods.isEmpty, plainKeysActive else { return nil }
        if key == "f" { return .toggleFullScreen }
        if let n = Int(key), (1...BuddyBlockLimits.maxActions).contains(n), n <= actionCount {
            return .event(.action(index: n - 1))
        }
        // ↵ sends the reply field, which arrives with typed follow-ups (M3).
        return nil
    }
}

/// Mirrors `BuddyBlock.maxActions` without making this pure type depend on BuddyCore's
/// isolation.
nonisolated enum BuddyBlockLimits {
    static let maxActions = 3
}
