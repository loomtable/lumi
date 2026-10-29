import AppKit
import Synchronization
import Testing
@testable import BuddyAct

/// A shareable, lockable list (Mutex itself can't be passed around).
final class DictationTestLog<T: Sendable>: Sendable {
    private let items = Mutex<[T]>([])
    func add(_ item: T) { items.withLock { $0.append(item) } }
    var all: [T] { items.withLock { $0 } }
}

/// `InsertMode.dictation`: paste first (11-REUSE §5).
@Suite("TextInserter dictation")
@MainActor
struct TextInserterDictationTests {
    let axField = InsertTarget(pid: 4242, bundleID: "com.apple.TextEdit", isSecure: false, canSetSelectedText: true)

    func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("LumiTests.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("user's clipboard", forType: .string)
        return pb
    }

    /// Reads the pasteboard like the target app handling ⌘V, recording what it saw.
    func reader(_ pb: NSPasteboard, seen: DictationTestLog<String>) -> FakePaster {
        FakePaster(onPaste: { seen.add(pb.string(forType: .string) ?? "") })
    }

    func inserter(
        _ target: FakeTextTarget, _ pb: NSPasteboard, paster: FakePaster,
        waited: DictationTestLog<Duration> = DictationTestLog(), secure: Bool = false,
        modifiers: @escaping @Sendable () -> Bool = { false }
    ) -> TextInserter {
        TextInserter(
            target: target, pasteboard: SystemPasteboard(pb), paster: paster, isBlocked: { _ in false },
            wait: { d in waited.add(d) }, secureInput: { secure }, modifiersDown: modifiers)
    }

    @Test("pastes even where AX could write, and restores 200 ms after the read")
    func pasteFirst() async {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let seen = DictationTestLog<String>()
        let waited = DictationTestLog<Duration>()
        let target = FakeTextTarget([axField], axResult: .verified)
        let paster = reader(pb, seen: seen)
        let ins = inserter(target, pb, paster: paster, waited: waited)
        #expect(await ins.insert("hello there", into: 4242, mode: .dictation) == .pasted(clipboardRestored: true))
        #expect(target.axWrites.isEmpty)
        #expect(paster.pastes == [4242])
        #expect(seen.all == ["hello there"])
        #expect(waited.all == [.milliseconds(200)])
        #expect(pb.string(forType: .string) == "user's clipboard")
    }

    @Test("the draft mode is unchanged: AX first")
    func draftUnchanged() async {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let target = FakeTextTarget([axField], axResult: .verified)
        let paster = FakePaster()
        #expect(await inserter(target, pb, paster: paster).insert("x") == .insertedViaAccessibility)
        #expect(paster.pastes.isEmpty)
    }

    @Test("a slow app gets up to 3 s to read; nobody reads: unconfirmed, text left on the clipboard")
    func slowReader() async {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let waited = DictationTestLog<Duration>()
        let ins = inserter(FakeTextTarget([axField]), pb, paster: FakePaster(), waited: waited)
        #expect(await ins.insert("lost?", mode: .dictation) == .pasteUnconfirmed)
        let total = waited.all.reduce(Duration.zero, +)
        #expect(total == .seconds(3))
        #expect(pb.string(forType: .string) == "lost?")
    }

    @Test("Secure Event Input on: refused before anything is touched")
    func secureInput() async {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let target = FakeTextTarget([axField])
        let paster = FakePaster()
        #expect(await inserter(target, pb, paster: paster, secure: true).insert("pw", mode: .dictation) == .refusedSecureField)
        #expect(paster.pastes.isEmpty)
        #expect(target.askedPIDs.isEmpty)
        #expect(pb.string(forType: .string) == "user's clipboard")
    }

    @Test("a secure field is still refused")
    func secureField() async {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let secure = InsertTarget(pid: 1, bundleID: "com.apple.Safari", isSecure: true, canSetSelectedText: true)
        #expect(await inserter(FakeTextTarget([secure]), pb, paster: FakePaster()).insert("pw", mode: .dictation) == .refusedSecureField)
    }

    @Test("terminals: lines are joined with spaces instead of refused")
    func terminalJoins() async {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let seen = DictationTestLog<String>()
        let term = InsertTarget(pid: 7, bundleID: "com.apple.Terminal", isSecure: false, canSetSelectedText: true)
        let ins = inserter(FakeTextTarget([term]), pb, paster: reader(pb, seen: seen))
        #expect(await ins.insert("git status\n  and then\n\nlog\n", mode: .dictation) == .pasted(clipboardRestored: true))
        #expect(seen.all == ["git status and then log"])
        // Elsewhere the newlines stay.
        let seen2 = DictationTestLog<String>()
        let ins2 = inserter(FakeTextTarget([axField]), pb, paster: reader(pb, seen: seen2))
        _ = await ins2.insert("one\ntwo", mode: .dictation)
        #expect(seen2.all == ["one\ntwo"])
    }

    @Test("⌘V waits for the modifiers to be let go")
    func waitsForModifiers() async {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let polls = DictationTestLog<Int>()
        let waited = DictationTestLog<Duration>()
        let ins = inserter(FakeTextTarget([axField]), pb, paster: reader(pb, seen: DictationTestLog()), waited: waited,
                           modifiers: { polls.add(1); return polls.all.count <= 3 })
        #expect(await ins.insert("hi", mode: .dictation) == .pasted(clipboardRestored: true))
        #expect(Array(waited.all.prefix(3)) == [.milliseconds(10), .milliseconds(10), .milliseconds(10)])
    }

    @Test("a modifier held past the timeout: nothing pasted, clipboard untouched")
    func modifierStuck() async {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let paster = FakePaster()
        let ins = inserter(FakeTextTarget([axField]), pb, paster: paster, modifiers: { true })
        #expect(await ins.insert("hi", mode: .dictation) == .pasteFailed)
        #expect(paster.pastes.isEmpty)
        #expect(pb.string(forType: .string) == "user's clipboard")
    }

    @Test("oneLine joins and trims")
    func oneLine() {
        #expect(TextInserter.oneLine("a\r\nb \n  c") == "a b c")
        #expect(TextInserter.oneLine("single") == "single")
    }
}
