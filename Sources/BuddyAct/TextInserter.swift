import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Dispatch
import Foundation

/// How an insert ended. Every case is a real outcome the shell can report as-is.
public enum InsertResult: Sendable, Equatable {
    /// Set through AX and confirmed by the caret.
    case insertedViaAccessibility
    /// Set through AX; the app gave no way to confirm it.
    case insertedViaAccessibilityUnverified
    /// Pasted with ⌘V and read by an app; the clipboard was put back (or cleared, if it held
    /// concealed data), unless the user copied something new meanwhile.
    case pasted(clipboardRestored: Bool)
    /// ⌘V was sent but no app read the text within the wait. The draft is left on the
    /// clipboard: restoring could let a late paste insert the old clipboard instead.
    case pasteUnconfirmed
    case refusedSecureField
    case refusedBlockedApp
    case refusedOwnApp
    case refusedEmptyText
    /// Multi-line text into a terminal: a newline could run a command.
    case refusedMultilineInTerminal
    case noFocusedField
    /// Focus moved to another field or app before the write; nothing was written.
    case focusChanged
    /// ⌘V could not be sent (no permission, or no key types "v" in this layout).
    case pasteFailed
    /// Another insert is still running.
    case busy
}

/// Who is inserting, which decides the method.
public enum InsertMode: Sendable, Equatable {
    /// Lumi's draft insert: AX first (verified by the caret), paste as the fallback.
    case draft
    /// The dictation key (11-REUSE §5): paste first, because an AX write can report success in
    /// Chrome or Electron and do nothing, and a dictation must never vanish. Refused under Secure
    /// Event Input; lines are joined with spaces in terminals; ⌘V waits until no modifier is
    /// down (a held ⌥ or fn would make it ⌥⌘V); the clipboard comes back 200 ms after the app
    /// reads it, waiting up to 3 s for slow (Electron) apps.
    case dictation
}

/// Puts text into the user's app ("Typing and inserting"): first by setting
/// kAXSelectedTextAttribute on the focused element, else by pasting — save the clipboard, write
/// the text, send ⌘V to the target app only, and restore the clipboard once the app has read it.
///
/// It never sends: no Return or Enter is ever posted, trailing newlines are dropped, and
/// multi-line text is refused in terminals. It never writes into a secure field, a blocked app or
/// Lumi itself. One insert runs at a time.
@MainActor
public final class TextInserter {
    public struct Options: Sendable, Equatable {
        /// Minimum time the clipboard keeps the draft after ⌘V (restored within 300 ms).
        public var restoreDelay: Duration
        /// How long to wait for an app to read the draft before giving up on restoring.
        public var readTimeout: Duration
        /// Dictation: how long to wait for an app to read the text.
        public var dictationReadTimeout: Duration
        /// Dictation: how long the text stays on the clipboard after the app read it.
        public var dictationRestoreAfterRead: Duration
        /// Dictation: how long to wait for the modifiers to be let go before giving up on ⌘V.
        public var modifierReleaseTimeout: Duration

        public init(
            restoreDelay: Duration = .milliseconds(250), readTimeout: Duration = .seconds(1),
            dictationReadTimeout: Duration = .seconds(3), dictationRestoreAfterRead: Duration = .milliseconds(200),
            modifierReleaseTimeout: Duration = .seconds(1)
        ) {
            self.restoreDelay = restoreDelay
            self.readTimeout = readTimeout
            self.dictationReadTimeout = dictationReadTimeout
            self.dictationRestoreAfterRead = dictationRestoreAfterRead
            self.modifierReleaseTimeout = modifierReleaseTimeout
        }
    }

    /// Terminals, where a pasted newline can execute a line (no bracketed paste in bash 3.2/ssh).
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty", "co.zeit.hyper", "org.tabby",
    ]

    let target: any TextTargetAccess
    let pasteboard: any PasteboardStore
    let paster: any PasteShortcut
    let isBlocked: @Sendable (String?) -> Bool
    let options: Options
    let wait: @Sendable (Duration) async -> Void
    let secureInput: @Sendable () -> Bool
    let modifiersDown: @Sendable () -> Bool
    private var inFlight = false

    /// `isBlocked` takes a bundle ID (the shell passes BuddyContext's Blocklist). `wait` must not
    /// return early on cancellation; the default doesn't.
    public init(
        target: any TextTargetAccess = AXTextTarget(),
        pasteboard: any PasteboardStore = SystemPasteboard(),
        paster: any PasteShortcut = CGEventPaster(),
        isBlocked: @escaping @Sendable (String?) -> Bool,
        options: Options = Options(),
        wait: @escaping @Sendable (Duration) async -> Void = TextInserter.uncancellableWait,
        secureInput: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() },
        modifiersDown: @escaping @Sendable () -> Bool = TextInserter.physicalModifiersDown
    ) {
        self.target = target
        self.pasteboard = pasteboard
        self.paster = paster
        self.isBlocked = isBlocked
        self.options = options
        self.wait = wait
        self.secureInput = secureInput
        self.modifiersDown = modifiersDown
    }

    /// Whether ⇧, ⌃, ⌥, ⌘ or fn is physically down right now.
    @Sendable public nonisolated static func physicalModifiersDown() -> Bool {
        let flags = CGEventSource.flagsState(.hidSystemState)
        return !flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).isEmpty
    }

    /// Sleeps the full duration even if the task is cancelled, so a cancelled insert can't
    /// restore the clipboard before the app has pasted.
    @Sendable public nonisolated static func uncancellableWait(_ d: Duration) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(d.components.seconds)
                + Double(d.components.attoseconds) / 1e18) { c.resume() }
        }
    }

    /// Into `pid`'s focused field (the app the user summoned in), or the system-wide focus if nil.
    public func insert(_ text: String, into pid: Int32? = nil, mode: InsertMode = .draft) async -> InsertResult {
        guard !inFlight else { return .busy }
        inFlight = true
        defer { inFlight = false }

        var text = text
        while text.last?.isNewline == true { text.removeLast() }
        guard !text.isEmpty else { return .refusedEmptyText }
        // A password prompt somewhere has the keyboard: its field may not say it is secure.
        if mode == .dictation, secureInput() { return .refusedSecureField }

        // AX calls block for up to the messaging timeout, so they run off the main actor.
        let access = target
        guard let field = await Task.detached(operation: { access.focusedTarget(in: pid) }).value else { return .noFocusedField }
        if mode == .dictation, Self.terminalBundleIDs.contains(field.bundleID ?? "") {
            text = Self.oneLine(text)
        }
        if let refusal = refusal(for: field, text: text) { return refusal }

        if mode == .draft, field.canSetSelectedText {
            let written = text
            switch await Task.detached(operation: { access.setSelectedText(written, target: field) }).value {
            case .verified: return .insertedViaAccessibility
            case .unverified: return .insertedViaAccessibilityUnverified
            case .notApplied: break
            }
        }
        return await paste(text, into: field, mode: mode)
    }

    /// Dictated lines joined with spaces, so a terminal never gets a newline that runs a command.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func refusal(for field: InsertTarget, text: String) -> InsertResult? {
        if field.pid == getpid() { return .refusedOwnApp }
        if field.isSecure { return .refusedSecureField }
        if isBlocked(field.bundleID) { return .refusedBlockedApp }
        if text.contains(where: \.isNewline), Self.terminalBundleIDs.contains(field.bundleID ?? "") {
            return .refusedMultilineInTerminal
        }
        return nil
    }

    private func paste(_ text: String, into field: InsertTarget, mode: InsertMode) async -> InsertResult {
        if mode == .dictation {
            var waited: Duration = .zero
            while modifiersDown() {
                guard waited < options.modifierReleaseTimeout else { return .pasteFailed }
                await wait(.milliseconds(10))
                waited += .milliseconds(10)
            }
        }
        // Re-check right before touching the clipboard: same field, still allowed.
        let access = target
        let pid = field.pid
        guard let now = await Task.detached(operation: { access.focusedTarget(in: pid) }).value,
              now.isSameField(as: field) else { return .focusChanged }
        if let refusal = refusal(for: now, text: text) { return refusal }

        let saved = pasteboard.snapshot()
        let ours = pasteboard.writeTransient(text)
        guard paster.pasteShortcut(to: field.pid) else {
            pasteboard.restore(saved)
            return .pasteFailed
        }
        switch mode {
        case .draft:
            await wait(options.restoreDelay)
            var waited = options.restoreDelay
            while !ours.wasRead(), waited < options.readTimeout {
                await wait(.milliseconds(20))
                waited += .milliseconds(20)
            }
        case .dictation:
            var waited: Duration = .zero
            while !ours.wasRead(), waited < options.dictationReadTimeout {
                await wait(.milliseconds(20))
                waited += .milliseconds(20)
            }
            if ours.wasRead() { await wait(options.dictationRestoreAfterRead) }
        }
        // The user copied something new meanwhile: keep theirs.
        guard pasteboard.changeCount == ours.changeCount else { return .pasted(clipboardRestored: false) }
        guard ours.wasRead() else { return .pasteUnconfirmed }
        // Concealed data (a password manager's copy) is not put back: its owner's timed clear
        // would no longer fire, and the secret would stay on the clipboard.
        pasteboard.restore(saved.isConcealed ? .empty : saved)
        return .pasted(clipboardRestored: true)
    }
}
