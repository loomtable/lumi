import AppKit
import Testing
@testable import BuddyAct

/// Manual step, on the real Mac (Accessibility granted to the terminal):
/// 1. Open TextEdit, File › New, click into the empty document.
/// 2. In Terminal.app: `BUDDYACT_LIVE=1 Scripts/test.sh --filter LiveInsert`, then click back into
///    the TextEdit document within 5 s.
/// It refuses to type anywhere but TextEdit. It inserts two lines (one via AX, one via paste),
/// and checks that a test value put on the clipboard first is restored. Your clipboard is saved
/// before and put back after.
@Suite("Live insert", .enabled(if: ProcessInfo.processInfo.environment["BUDDYACT_LIVE"] == "1"), .serialized)
@MainActor
struct LiveInsertTests {
    /// AX-only target that reports "not settable", to force the paste path.
    struct PasteOnly: TextTargetAccess {
        let real = AXTextTarget()
        func focusedTarget(in pid: Int32?) -> InsertTarget? {
            real.focusedTarget(in: pid).map { var t = $0; t.canSetSelectedText = false; return t }
        }
        func setSelectedText(_ text: String, target: InsertTarget) -> AXWriteResult { .notApplied }
    }

    func waitForTextEdit() async throws -> InsertTarget {
        print("Click into the TextEdit document now (5 s)…")
        try await Task.sleep(for: .seconds(5))
        let target = try #require(AXTextTarget().focusedTarget(in: nil), "no focused field")
        try #require(target.bundleID == "com.apple.TextEdit", "focus is in \(target.bundleID ?? "?"), not TextEdit; aborting")
        return target
    }

    @Test("AX path into TextEdit")
    func axPath() async throws {
        _ = try await waitForTextEdit()
        let ins = TextInserter(isBlocked: { _ in false })
        let result = await ins.insert("Lumi AX insert ✓\n")
        print("AX path result: \(result)")
        #expect(result == .insertedViaAccessibility || result == .insertedViaAccessibilityUnverified)
    }

    @Test("paste path into TextEdit restores the clipboard, including non-text types")
    func pastePath() async throws {
        let general = NSPasteboard.general
        let store = SystemPasteboard(general)
        let original = store.snapshot()
        defer { store.restore(original) }
        // A known value with an image type, to check the restore.
        general.clearContents()
        let item = NSPasteboardItem()
        item.setString("clipboard before", forType: .string)
        item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        general.writeObjects([item])
        let before = store.snapshot()

        _ = try await waitForTextEdit()
        let ins = TextInserter(target: PasteOnly(), isBlocked: { _ in false })
        let t = ContinuousClock.now
        let result = await ins.insert("Lumi paste insert ✓\n")
        print("paste path result: \(result) in \(t.duration(to: .now))")
        #expect(result == .pasted(clipboardRestored: true))
        #expect(store.snapshot() == before)
        print("Check TextEdit: two lines, each once.")
    }
}
