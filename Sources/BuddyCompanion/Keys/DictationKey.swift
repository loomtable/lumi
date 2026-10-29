import BuddyKeys

/// What the user picked for the dictation key in Settings › General.
public nonisolated enum DictationKeyChoice: Sendable, Equatable, Hashable {
    /// fn when the 🌐 key does nothing, else right ⌘ (owner decision, Oct 28).
    case auto
    case off
    case key(BuddyKey)
}

/// The key in effect and the line Settings shows for it.
public nonisolated struct DictationKeyResolution: Sendable, Equatable {
    /// nil: no dictation key.
    public var key: BuddyKey?
    /// Which key and why, or why none.
    public var reason: String
}

/// Resolves the dictation key where preferences are read (10-ENGINEERING §1.11).
///
/// Dictation starts on a single tap or a hold, and its start and stop taps are seconds apart, so
/// shortcuts fired by pressing a key twice quickly (Claude's Quick Entry, Siri, macOS Dictation,
/// Gemini) don't clash with it. What does clash: the buddy key itself and a 🌐 key with a macOS
/// action (it fires on release). Other apps that use the same key aren't detected: the user picks
/// another key.
public nonisolated enum DictationKeyResolver {
    public static func resolve(_ choice: DictationKeyChoice, buddyKey: BuddyKey, in env: KeyEnvironment) -> DictationKeyResolution {
        switch choice {
        case .off:
            return DictationKeyResolution(key: nil, reason: "Dictation key off.")
        case .key(let key):
            if key == buddyKey {
                return DictationKeyResolution(key: nil, reason: "Off: \(name(key)) is already your Lumi key.")
            }
            if let clash = blockingConflicts(for: key, in: env).first {
                return DictationKeyResolution(key: nil, reason: "Off. \(clash.message)")
            }
            return DictationKeyResolution(key: key, reason: "Dictation key: \(name(key)).")
        case .auto:
            guard let why = whyNotFn(buddyKey: buddyKey, in: env) else {
                return DictationKeyResolution(
                    key: .function, reason: "Auto: fn, because the 🌐 key is set to Do Nothing. If another app also uses fn, pick another key here.")
            }
            if buddyKey == .rightCommand {
                return DictationKeyResolution(
                    key: nil, reason: "No dictation key: right ⌘ is your Lumi key and \(why). Pick a key here.")
            }
            return DictationKeyResolution(key: .rightCommand, reason: "Auto: right ⌘, because \(why).")
        }
    }

    /// The conflicts that rule a key out. Warnings about quick double presses and stray taps
    /// don't: a stray tap starts a dictation that Esc or another tap ends, with nothing typed
    /// unless words were said.
    public static func blockingConflicts(for key: BuddyKey, in env: KeyEnvironment) -> [KeyConflict] {
        KeyConflicts.check(key, in: env).filter { $0.severity == .warning && !holdSafe.contains($0.id) }
    }

    /// `KeyConflicts` ids that only concern taps or double presses.
    static let holdSafe: Set<String> = ["claude-quick-entry", "siri-dictation", "gemini", "left-modifier", "shift"]

    /// Why Auto can't use fn, or nil if it can.
    private static func whyNotFn(buddyKey: BuddyKey, in env: KeyEnvironment) -> String? {
        if buddyKey == .function { return "fn is your Lumi key" }
        if env.globeKeyUsage != 0 { return "the 🌐 key has a macOS action (set it to Do Nothing to use fn)" }
        return nil
    }

    /// "right ⌘", "left ⌥", "fn".
    public static func name(_ key: BuddyKey) -> String {
        switch key {
        case .rightOption: "right ⌥"
        case .leftOption: "left ⌥"
        case .rightCommand: "right ⌘"
        case .leftCommand: "left ⌘"
        case .rightShift: "right ⇧"
        case .leftShift: "left ⇧"
        case .rightControl: "right ⌃"
        case .leftControl: "left ⌃"
        case .function: "fn"
        }
    }
}

/// `KeyEnvironment.current()` costs LaunchServices lookups and two UserDefaults suites on the main
/// actor, and settings re-map on every keystroke in a field (QA R15). The engine reads it through
/// this cache instead, at most once per `maxAge`. The Keys page still reads it fresh when shown.
@MainActor
public final class KeyEnvironmentCache {
    public static let shared = KeyEnvironmentCache()

    private let maxAge: Duration
    private let read: @MainActor () -> KeyEnvironment
    private let now: @MainActor () -> ContinuousClock.Instant
    private var cached: (value: KeyEnvironment, at: ContinuousClock.Instant)?

    public init(
        maxAge: Duration = .seconds(30),
        read: @escaping @MainActor () -> KeyEnvironment = { KeyEnvironment.current() },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.maxAge = maxAge
        self.read = read
        self.now = now
    }

    public func current() -> KeyEnvironment {
        let time = now()
        if let cached, time - cached.at < maxAge { return cached.value }
        let value = read()
        cached = (value, time)
        return value
    }

    /// The next `current()` reads the Mac again.
    public func invalidate() { cached = nil }
}
