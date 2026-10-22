import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// Actions a user can bind to a global chord in Settings › Keys. None has a chord by default:
/// the buddy key is the default way in, and ⌘N / ⌘Y are local to the focused card.
public enum ChordAction: String, CaseIterable, Sendable {
    /// An alternative to the buddy key: summon and start listening.
    // Explicit raw values: they are part of the stored names, so a case rename must not change them.
    case summon = "summon"
    case newConversation = "newConversation"
    case openConversations = "openConversations"

    /// Stored as `KeyboardShortcuts_buddy_<action>` in UserDefaults. KeyboardShortcuts forbids
    /// dots in names; don't rename, or saved chords are lost.
    ///
    /// Record chords with `ChordRecorder` (or apply `.shortcutValidation(ChordValidator.validate)`
    /// to a `KeyboardShortcuts.Recorder`); a plain Recorder skips ChordValidator.
    public var name: KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("buddy_\(rawValue)")
    }
}

/// Only lets through chords that no app or macOS commonly uses and that never type.
/// An allowlist: letters, digits, punctuation and F1–F12 need ⌃⌥, ⌃⌥⌘, ⌃⌥⇧ or ⌃⌥⌘⇧ (not ⌥⇧⌘:
/// apps bind it, e.g. Paste and Match Style, Xcode's Clean Build Folder, Log Out);
/// F13–F20 are free with any modifiers; navigation keys are never allowed.
public enum ChordValidator {
    /// For the Recorder's validation. Also refuses chords macOS reports as taken.
    @MainActor
    public static func validate(_ shortcut: KeyboardShortcuts.Shortcut) -> KeyboardShortcuts.ValidationResult {
        validate(shortcut, takenBySystem: shortcut.isTakenBySystem)
    }

    static func validate(_ shortcut: KeyboardShortcuts.Shortcut, takenBySystem: Bool) -> KeyboardShortcuts.ValidationResult {
        if takenBySystem {
            return .disallow(reason: "macOS already uses this shortcut.")
        }
        return validate(keyCode: shortcut.carbonKeyCode, modifiers: shortcut.modifiers)
    }

    /// Shown under the recorder.
    public static let hint = "Use ⌃⌥ or ⌃⌥⌘ with a key, or F13–F19. ⌃⌥ is also VoiceOver's modifier: if you use VoiceOver, prefer ⌃⌥⌘."

    static let freeFunctionKeys: Set<Int> = [
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// Arrows, Space, Tab, Return, Delete, Esc and paging keys: Mission Control, Spaces, window
    /// managers, tab switching and text navigation all live here.
    static let navigationKeys: Set<Int> = [
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Space, kVK_Tab, kVK_Return,
        kVK_ANSI_KeypadEnter, kVK_Delete, kVK_ForwardDelete, kVK_Escape, kVK_Home, kVK_End,
        kVK_PageUp, kVK_PageDown,
    ]

    /// Modifier sets that apps and the system rarely bind and that never type a character.
    static let allowedModifierSets: [NSEvent.ModifierFlags] = [
        [.control, .option], [.control, .option, .command], [.control, .option, .shift],
        [.control, .option, .command, .shift],
    ]

    static func validate(keyCode: Int, modifiers raw: NSEvent.ModifierFlags) -> KeyboardShortcuts.ValidationResult {
        let m = raw.intersection([.command, .option, .control, .shift])
        if freeFunctionKeys.contains(keyCode) { return .allow }
        if navigationKeys.contains(keyCode) {
            return .disallow(reason: "Arrow, space, tab, return, delete and escape chords are used by macOS and apps.")
        }
        if allowedModifierSets.contains(m) { return .allow }
        if m.isEmpty || m == [.shift] || m == [.option] || m == [.option, .shift] {
            return .disallow(reason: "This combination types a character. Use ⌃⌥ or ⌃⌥⌘ with the key.")
        }
        if m == [.command] {
            return .disallow(reason: "⌘ with a key is used by apps (⌘N, ⌘Y, ⌘C…). Use ⌃⌥⌘ with the key.")
        }
        return .disallow(reason: "Apps commonly use this combination. Use ⌃⌥ or ⌃⌥⌘ with the key.")
    }
}

/// A Settings › Keys recorder that always runs ChordValidator.
public struct ChordRecorder: View {
    let title: String
    let action: ChordAction

    public init(_ title: String, for action: ChordAction) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            KeyboardShortcuts.Recorder(title, name: action.name)
                .shortcutValidation { ChordValidator.validate($0) }
                // Refuse system shortcuts outright: the default "Use Anyway" warning would be
                // followed by our own refusal.
                .keyboardShortcutsConflictPolicy(.init(systemShortcut: .block))
            Text(ChordValidator.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Delivers the user's chords as actions. Uses KeyboardShortcuts' global hotkeys, which need no
/// permission; only actions with a recorded chord are active.
@MainActor
public final class ChordMonitor {
    public let events: AsyncStream<ChordAction>
    private let continuation: AsyncStream<ChordAction>.Continuation
    private var listeners: [Task<Void, Never>] = []

    public init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    /// Dropping the monitor without `stop()` still unregisters the hotkeys and ends `events`.
    isolated deinit {
        listeners.forEach { $0.cancel() }
        continuation.finish()
    }

    public func start() {
        guard listeners.isEmpty else { return }
        let continuation = continuation
        listeners = ChordAction.allCases.map { action in
            Task { @MainActor in
                for await _ in KeyboardShortcuts.events(.keyUp, for: action.name) {
                    continuation.yield(action)
                }
            }
        }
    }

    /// Ends the listeners, which also unregisters the hotkeys.
    public func stop() {
        listeners.forEach { $0.cancel() }
        listeners = []
    }

    /// The recorded chord, or nil.
    public static func chord(for action: ChordAction) -> KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: action.name)
    }

    /// Sets or clears a chord, refusing ones `ChordValidator` disallows.
    @discardableResult
    public static func setChord(_ shortcut: KeyboardShortcuts.Shortcut?, for action: ChordAction) -> KeyboardShortcuts.ValidationResult {
        if let shortcut, case .disallow(let reason) = ChordValidator.validate(shortcut) {
            return .disallow(reason: reason)
        }
        KeyboardShortcuts.setShortcut(shortcut, for: action.name)
        return .allow
    }
}
