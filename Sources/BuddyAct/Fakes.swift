import Foundation
import Synchronization

/// A focused field that records writes. `axResult` decides how the AX write goes.
public final class FakeTextTarget: TextTargetAccess {
    private struct State {
        var targets: [InsertTarget?]
        var axResult: AXWriteResult
        var writes: [String] = []
        var reads = 0
        var pids: [Int32?] = []
    }

    private let state: Mutex<State>

    /// `targets` are returned in order by successive `focusedTarget(in:)` calls (the last repeats),
    /// so tests can move focus between the request and the paste.
    public init(_ targets: [InsertTarget?], axResult: AXWriteResult = .verified) {
        state = Mutex(State(targets: targets, axResult: axResult))
    }

    public var axWrites: [String] { state.withLock { $0.writes } }
    /// The app each `focusedTarget(in:)` asked about.
    public var askedPIDs: [Int32?] { state.withLock { $0.pids } }

    public func focusedTarget(in pid: Int32?) -> InsertTarget? {
        state.withLock { s in
            defer { s.reads += 1 }
            s.pids.append(pid)
            return s.targets.isEmpty ? nil : s.targets[min(s.reads, s.targets.count - 1)]
        }
    }

    public func setSelectedText(_ text: String, target: InsertTarget) -> AXWriteResult {
        state.withLock { s in
            s.writes.append(text)
            return s.axResult
        }
    }
}

@MainActor
public final class FakePaster: PasteShortcut {
    public private(set) var pastes: [Int32] = []
    private let succeeds: Bool
    /// Runs when ⌘V is "pressed": e.g. read the pasteboard like the target app, or copy
    /// something else like the user.
    private let onPaste: @MainActor () -> Void

    public init(succeeds: Bool = true, onPaste: @escaping @MainActor () -> Void = {}) {
        self.succeeds = succeeds
        self.onPaste = onPaste
    }

    public func pasteShortcut(to pid: Int32) -> Bool {
        pastes.append(pid)
        onPaste()
        return succeeds
    }
}
