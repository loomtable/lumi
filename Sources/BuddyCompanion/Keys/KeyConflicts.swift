import AppKit
import BuddyKeys
import Foundation

/// What the conflict check looks at ("Setup" step 2).
public nonisolated struct KeyEnvironment: Sendable, Equatable {
    public var installedBundleIDs: Set<String>
    /// `AppleFnUsageType` in com.apple.HIToolbox: 0 is "Do Nothing". Unset means the macOS
    /// default, which is not "Do Nothing".
    public var globeKeyUsage: Int?
    public var stickyKeys: Bool
    /// Siri on (`com.apple.assistant.support` "Assistant Enabled").
    public var siriEnabled: Bool
    /// Dictation on (`com.apple.HIToolbox` `AppleDictationAutoEnable`).
    public var dictationEnabled: Bool

    public init(
        installedBundleIDs: Set<String> = [], globeKeyUsage: Int? = 0, stickyKeys: Bool = false,
        siriEnabled: Bool = false, dictationEnabled: Bool = false
    ) {
        self.installedBundleIDs = installedBundleIDs
        self.globeKeyUsage = globeKeyUsage
        self.stickyKeys = stickyKeys
        self.siriEnabled = siriEnabled
        self.dictationEnabled = dictationEnabled
    }

    /// Apps that bind a modifier the user might pick. IDs read from installed apps' Info.plist or
    /// from Homebrew cask data.
    public static let watchedApps: [String: String] = [
        "com.anthropic.claudefordesktop": "Claude",
        "com.raycast.macos": "Raycast",
        "com.superduper.superwhisper": "Superwhisper",
        "com.openai.chat": "ChatGPT",
        "com.google.GeminiMacOS": "Gemini",
    ]

    /// Reads the real Mac. Never prompts.
    @MainActor
    public static func current() -> KeyEnvironment {
        let installed = Set(watchedApps.keys.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
        let hitoolbox = UserDefaults(suiteName: "com.apple.HIToolbox")
        let assistant = UserDefaults(suiteName: "com.apple.assistant.support")
        return KeyEnvironment(
            installedBundleIDs: installed,
            globeKeyUsage: hitoolbox?.object(forKey: "AppleFnUsageType") as? Int,
            stickyKeys: StickyKeys.isEnabled(),
            siriEnabled: assistant?.bool(forKey: "Assistant Enabled") ?? false,
            dictationEnabled: hitoolbox?.bool(forKey: "AppleDictationAutoEnable") ?? false)
    }
}

public nonisolated struct KeyConflict: Sendable, Equatable, Identifiable {
    public enum Severity: Sendable, Equatable { case warning, info }
    public enum Fix: Sendable, Equatable {
        /// System Settings › Keyboard, for "Press 🌐 key to".
        case openKeyboardSettings
    }

    public var id: String
    public var severity: Severity
    public var message: String
    public var fix: Fix?
}

public nonisolated enum KeyConflicts {
    public static func check(_ key: BuddyKey, in env: KeyEnvironment) -> [KeyConflict] {
        var out: [KeyConflict] = []
        let isOption = key == .rightOption || key == .leftOption
        let isCommand = key == .rightCommand || key == .leftCommand

        if isOption, env.installedBundleIDs.contains("com.anthropic.claudefordesktop") {
            out.append(KeyConflict(
                id: "claude-quick-entry", severity: .warning,
                message: "Claude's Quick Entry also uses double-tap ⌥. Turn it off in Claude's settings, or pick another Lumi key."))
        }
        if isCommand, env.siriEnabled || env.dictationEnabled {
            let which = [env.siriEnabled ? "Siri" : nil, env.dictationEnabled ? "Dictation" : nil].compactMap { $0 }
                .joined(separator: " and ")
            out.append(KeyConflict(
                id: "siri-dictation", severity: .warning,
                message: "\(which) can be set to start when ⌘ is pressed twice. If yours is, change its shortcut in System Settings or pick right ⌥."))
        }
        if isCommand, env.installedBundleIDs.contains("com.google.GeminiMacOS") {
            out.append(KeyConflict(
                id: "gemini", severity: .warning, message: "Gemini uses ⌘ pressed twice. Give one of them another key."))
        }
        if key == .function {
            if env.globeKeyUsage != 0 {
                out.append(KeyConflict(
                    id: "globe-key", severity: .warning,
                    message: "Set Keyboard › \"Press 🌐 key to\" to Do Nothing, or macOS will also act on every press.",
                    fix: .openKeyboardSettings))
            }
            out.append(KeyConflict(
                id: "fn-keyboards", severity: .info,
                message: "Fn works on Apple keyboards. Many other keyboards handle Fn themselves and never send it; if yours does, pick another key."))
        }
        if [.leftOption, .leftCommand, .leftShift, .leftControl].contains(key) {
            out.append(KeyConflict(
                id: "left-modifier", severity: .warning,
                message: "Left-hand modifiers start lots of shortcuts, so stray taps are common. Right ⌥ is the safest choice."))
        }
        if [.leftShift, .rightShift].contains(key) {
            out.append(KeyConflict(
                id: "shift", severity: .warning, message: "⇧ is tapped constantly while typing; expect accidental summons."))
        }
        if isOption {
            let optionSpace = ["com.raycast.macos", "com.openai.chat", "com.superduper.superwhisper"]
                .filter(env.installedBundleIDs.contains).compactMap { KeyEnvironment.watchedApps[$0] }
            if !optionSpace.isEmpty {
                out.append(KeyConflict(
                    id: "option-space", severity: .info,
                    message: "⌥ shortcuts like \(optionSpace.joined(separator: ", "))'s keep working: the Lumi key only reacts to ⌥ pressed alone."))
            }
            out.append(KeyConflict(
                id: "option-typing", severity: .info,
                message: "If your keyboard layout types characters with ⌥, that's still safe: any other key pressed with it cancels the Lumi key."))
        }
        if env.stickyKeys {
            out.append(KeyConflict(
                id: "sticky-keys", severity: .info, message: "Sticky Keys is on, so double-tap is off. Tap and hold still work."))
        }
        return out
    }

    public static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}

extension BuddyKey {
    /// "Right ⌥": the side and the keycap, without the picker's tags like "(recommended)", for
    /// Home's hint and the menu bar's Lumi Key row.
    public var shortName: String {
        switch self {
        case .rightOption, .rightCommand, .rightShift, .rightControl: "Right \(symbol)"
        case .leftOption, .leftCommand, .leftShift, .leftControl: "Left \(symbol)"
        case .function: symbol
        }
    }

    /// The name in the Keys pane's picker.
    public var settingsName: String {
        switch self {
        case .rightOption: "Right ⌥ Option (recommended)"
        case .leftOption: "Left ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .leftCommand: "Left ⌘ Command"
        case .rightShift: "Right ⇧ Shift"
        case .leftShift: "Left ⇧ Shift"
        case .rightControl: "Right ⌃ Control"
        case .leftControl: "Left ⌃ Control"
        case .function: "Fn / 🌐 Globe"
        }
    }
}
