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

        public init(restoreDelay: Duration = .milliseconds(250), readTimeout: Duration = .seconds(1)) {
            self.restoreDelay = restoreDelay
            self.readTimeout = readTimeout
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
    private var inFlight = false

    /// `isBlocked` takes a bundle ID (the shell passes BuddyContext's Blocklist). `wait` must not
    /// return early on cancellation; the default doesn't.
    public init(
        target: any TextTargetAccess = AXTextTarget(),
        pasteboard: any PasteboardStore = SystemPasteboard(),
        paster: any PasteShortcut = CGEventPaster(),
        isBlocked: @escaping @Sendable (String?) -> Bool,
        options: Options = Options(),
        wait: @escaping @Sendable (Duration) async -> Void = TextInserter.uncancellableWait
    ) {
        self.target = target
        self.pasteboard = pasteboard
        self.paster = paster
        self.isBlocked = isBlocked
        self.options = options
        self.wait = wait
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
    public func insert(_ text: String, into pid: Int32? = nil) async -> InsertResult {
        guard !inFlight else { return .busy }
        inFlight = true
        defer { inFlight = false }

        var text = text
        while text.last?.isNewline == true { text.removeLast() }
        guard !text.isEmpty else { return .refusedEmptyText }

        // AX calls block for up to the messaging timeout, so they run off the main actor.
        let access = target
        guard let field = await Task.detached(operation: { access.focusedTarget(in: pid) }).value else { return .noFocusedField }
        if let refusal = refusal(for: field, text: text) { return refusal }

        if field.canSetSelectedText {
            let written = text
            switch await Task.detached(operation: { access.setSelectedText(written, target: field) }).value {
            case .verified: return .insertedViaAccessibility
            case .unverified: return .insertedViaAccessibilityUnverified
            case .notApplied: break
            }
        }
        return await paste(text, into: field)
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

    private func paste(_ text: String, into field: InsertTarget) async -> InsertResult {
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
        await wait(options.restoreDelay)
        var waited = options.restoreDelay
        while !ours.wasRead(), waited < options.readTimeout {
            await wait(.milliseconds(20))
            waited += .milliseconds(20)
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
