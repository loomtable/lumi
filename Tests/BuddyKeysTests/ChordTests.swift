import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import Testing
@testable import BuddyKeys

@Suite("ChordValidator")
@MainActor
struct ChordValidatorTests {
    func check(_ key: Int, _ m: NSEvent.ModifierFlags) -> KeyboardShortcuts.ValidationResult {
        ChordValidator.validate(keyCode: key, modifiers: m)
    }

    func allowed(_ key: Int, _ m: NSEvent.ModifierFlags) -> Bool { check(key, m) == .allow }

    @Test("⌘N, ⌘Y and every other bare ⌘ + key are refused", arguments: [
        kVK_ANSI_N, kVK_ANSI_Y, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_1, kVK_ANSI_Comma,
    ])
    func bareCommand(key: Int) {
        #expect(!allowed(key, [.command]))
    }

    @Test("keys that type characters are refused: plain, ⇧, ⌥ and ⌥⇧")
    func typing() {
        #expect(!allowed(kVK_ANSI_A, []))
        #expect(!allowed(kVK_ANSI_A, [.shift]))
        #expect(!allowed(kVK_ANSI_E, [.option]))
        #expect(!allowed(kVK_ANSI_E, [.option, .shift]))
        #expect(!allowed(kVK_Space, []))
    }

    @Test("common ⌘⇧ shortcuts and macOS system chords are refused")
    func taken() {
        for key in [kVK_ANSI_N, kVK_ANSI_T, kVK_ANSI_Z, kVK_ANSI_P, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5] {
            #expect(!allowed(key, [.command, .shift]))
        }
        #expect(!allowed(kVK_Space, [.command]))
        #expect(!allowed(kVK_Space, [.control]))
        #expect(!allowed(kVK_Space, [.control, .command]))
        #expect(!allowed(kVK_Tab, [.command]))
        #expect(!allowed(kVK_Escape, [.command, .option]))
        #expect(!allowed(kVK_ANSI_Q, [.control, .command]))
    }

    @Test("only the allowlisted modifier sets pass", arguments: [
        NSEvent.ModifierFlags([.control, .option]), [.control, .option, .command], [.control, .option, .shift],
        [.control, .option, .command, .shift],
    ])
    func allowedSets(m: NSEvent.ModifierFlags) {
        #expect(allowed(kVK_ANSI_B, m))
        #expect(allowed(kVK_ANSI_7, m))
        #expect(allowed(kVK_F5, m))
    }

    @Test("terminal, devtools and system chords found in review are refused")
    func reviewCases() {
        #expect(!allowed(kVK_ANSI_V, [.option, .command, .shift]))  // Paste and Match Style
        #expect(!allowed(kVK_ANSI_K, [.option, .command, .shift]))  // Xcode Clean Build Folder
        #expect(!allowed(kVK_ANSI_C, [.control]))            // ⌃C in terminals
        #expect(!allowed(kVK_ANSI_A, [.control, .shift]))
        #expect(!allowed(kVK_ANSI_I, [.command, .option]))   // devtools
        #expect(!allowed(kVK_ANSI_J, [.command, .option]))   // Chrome console
        #expect(!allowed(kVK_ANSI_J, [.command, .shift]))
        #expect(!allowed(kVK_ANSI_Grave, [.command, .shift]))
        #expect(!allowed(kVK_F5, [.command]))                // VoiceOver
        #expect(!allowed(kVK_F5, [.control]))
        #expect(!allowed(kVK_F5, []))
        #expect(!allowed(kVK_LeftArrow, [.control]))          // Spaces
        #expect(!allowed(kVK_RightArrow, [.command, .option]))  // tab switching
        #expect(!allowed(kVK_LeftArrow, [.control, .option, .command]))  // window managers
    }

    @Test("F13–F20 are free keys with or without modifiers")
    func freeFunctionKeys() {
        #expect(allowed(kVK_F13, []))
        #expect(allowed(kVK_F19, [.command]))
    }

    @Test("caps lock and other non-modifier flags don't change the verdict")
    func ignoresCapsLock() {
        #expect(!allowed(kVK_ANSI_N, [.command, .capsLock]))
        #expect(allowed(kVK_ANSI_B, [.control, .option, .capsLock]))
        #expect(allowed(kVK_ANSI_B, [.control, .option, .function]))
    }

    @Test("the Shortcut overload agrees with the key code path")
    func shortcutOverload() {
        #expect(ChordValidator.validate(KeyboardShortcuts.Shortcut(.n, modifiers: [.command])) != .allow)
        #expect(ChordValidator.validate(KeyboardShortcuts.Shortcut(.b, modifiers: [.control, .option])) == .allow)
    }
}

@Suite("Chords")
@MainActor
struct ChordTests {
    @Test("no action has a chord by default; names have no dots (KeyboardShortcuts rule)")
    func noDefaults() {
        for action in ChordAction.allCases {
            #expect(action.name.initialShortcut == nil)
            #expect(!action.name.rawValue.contains("."))
        }
    }

    @Test("a shortcut macOS has taken is refused even when the combination is allowlisted")
    func takenBySystem() {
        let shortcut = KeyboardShortcuts.Shortcut(.b, modifiers: [.control, .option])
        #expect(ChordValidator.validate(shortcut, takenBySystem: false) == .allow)
        #expect(ChordValidator.validate(shortcut, takenBySystem: true) != .allow)
    }

    @Test("action raw values are fixed (they are part of the stored chord names)")
    func rawValues() {
        #expect(ChordAction.allCases.map(\.name.rawValue) == ["buddy_summon", "buddy_newConversation", "buddy_openConversations"])
    }

    @Test("dropping a monitor without stop() ends its events stream")
    func dropWithoutStop() async throws {
        var monitor: ChordMonitor? = ChordMonitor()
        monitor?.start()
        let events = try #require(monitor?.events)
        let ended = Flag()
        // Not awaited: if the stream never ends this task just stays suspended; the poll below
        // fails the test instead of hanging it.
        Task { @MainActor in
            for await _ in events {}
            ended.set()
        }
        await Task.yield()
        monitor = nil
        let deadline = ContinuousClock.now + .seconds(2)
        while !ended.isSet, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ended.isSet)
    }

    @Test("setChord refuses a disallowed chord without storing it")
    func setChordRefuses() {
        let before = ChordMonitor.chord(for: .newConversation)
        let result = ChordMonitor.setChord(KeyboardShortcuts.Shortcut(.n, modifiers: [.command]), for: .newConversation)
        #expect(result != .allow)
        #expect(ChordMonitor.chord(for: .newConversation) == before)
    }

    @Test("the monitor starts and stops cleanly with no chords recorded")
    func monitorLifecycle() async {
        let monitor = ChordMonitor()
        monitor.start()
        monitor.start()  // idempotent
        await Task.yield()
        monitor.stop()
    }
}

@MainActor
final class Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}
