import AppKit
import Synchronization
import Testing
@testable import BuddyAct

private let field = InsertTarget(pid: 4242, bundleID: "com.apple.TextEdit", isSecure: false, canSetSelectedText: true)
private let noAX = InsertTarget(pid: 4242, bundleID: "com.google.Chrome", isSecure: false, canSetSelectedText: false)

/// A private pasteboard per test, so the user's clipboard is never touched.
@MainActor
private func privatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("LumiTests.\(UUID().uuidString)"))
}

/// A paster that reads the pasteboard's text, like the target app handling ⌘V.
@MainActor
private func readingPaster(_ pb: NSPasteboard, seen: ((String?) -> Void)? = nil) -> FakePaster {
    FakePaster(onPaste: { seen?(pb.string(forType: .string)) ?? { _ = pb.string(forType: .string) }() })
}

@MainActor
private func inserter(
    _ target: FakeTextTarget, pasteboard: NSPasteboard, paster: FakePaster? = nil,
    blocked: Set<String> = []
) -> (TextInserter, SystemPasteboard) {
    let store = SystemPasteboard(pasteboard)
    let inserter = TextInserter(
        target: target, pasteboard: store, paster: paster ?? readingPaster(pasteboard),
        isBlocked: { blocked.contains($0 ?? "") }, wait: { _ in })
    return (inserter, store)
}

@Suite("TextInserter")
@MainActor
struct TextInserterTests {
    @Test("AX first: verified and unverified writes don't paste")
    func axFirst() async {
        for (ax, expected) in [(AXWriteResult.verified, InsertResult.insertedViaAccessibility),
                               (.unverified, .insertedViaAccessibilityUnverified)] {
            let target = FakeTextTarget([field], axResult: ax)
            let paster = FakePaster()
            let pb = privatePasteboard()
            defer { pb.releaseGlobally() }
            let (ins, _) = inserter(target, pasteboard: pb, paster: paster)
            #expect(await ins.insert("hello") == expected)
            #expect(target.axWrites == ["hello"])
            #expect(paster.pastes.isEmpty)
        }
    }

    @Test("AX not applied, or not settable: falls back to paste into the target pid and restores")
    func pasteFallback() async {
        for t in [FakeTextTarget([field], axResult: .notApplied), FakeTextTarget([noAX])] {
            let pb = privatePasteboard()
            defer { pb.releaseGlobally() }
            pb.clearContents()
            pb.setString("user's clipboard", forType: .string)
            let paster = readingPaster(pb)
            let (ins, _) = inserter(t, pasteboard: pb, paster: paster)
            #expect(await ins.insert("draft") == .pasted(clipboardRestored: true))
            #expect(paster.pastes == [4242])
            #expect(pb.string(forType: .string) == "user's clipboard")
        }
    }

    @Test("asks the summoned app for its field, not the system-wide focus (our card may be key)")
    func targetsTheSummonedApp() async {
        let t = FakeTextTarget([noAX])
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let (ins, _) = inserter(t, pasteboard: pb, paster: readingPaster(pb))
        _ = await ins.insert("draft", into: 4242)
        #expect(t.askedPIDs == [4242, 4242]) // the request and the re-check before pasting
    }

    @Test("the pasted text is what the app sees on the pasteboard, marked transient")
    func transientWrite() async {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        var seen: (String?, Bool) = (nil, false)
        let paster = FakePaster(onPaste: {
            seen = (pb.string(forType: .string), (pb.types ?? []).contains(PasteboardMarkers.transient))
        })
        let (ins, _) = inserter(FakeTextTarget([noAX]), pasteboard: pb, paster: paster)
        _ = await ins.insert("draft")
        #expect(seen.0 == "draft")
        #expect(seen.1)
    }

    @Test("refusals: secure field, blocked app, empty text, no focus — nothing written or pasted")
    func refusals() async {
        let secure = InsertTarget(pid: 1, bundleID: "x", isSecure: true, canSetSelectedText: true)
        let cases: [(FakeTextTarget, String, Set<String>, InsertResult)] = [
            (FakeTextTarget([secure]), "pw", [], .refusedSecureField),
            (FakeTextTarget([field]), "pw", ["com.apple.TextEdit"], .refusedBlockedApp),
            (FakeTextTarget([field]), "", [], .refusedEmptyText),
            (FakeTextTarget([nil]), "x", [], .noFocusedField),
        ]
        for (target, text, blocked, expected) in cases {
            let pb = privatePasteboard()
            defer { pb.releaseGlobally() }
            pb.clearContents()
            pb.setString("keep", forType: .string)
            let paster = FakePaster()
            let (ins, _) = inserter(target, pasteboard: pb, paster: paster, blocked: blocked)
            #expect(await ins.insert(text) == expected)
            #expect(target.axWrites.isEmpty)
            #expect(paster.pastes.isEmpty)
            #expect(pb.string(forType: .string) == "keep")
        }
    }

    @Test("focus moved to another app before the paste: nothing pasted, clipboard untouched")
    func focusChanged() async {
        let other = InsertTarget(pid: 9, bundleID: "com.tinyspeck.slackmacgap", isSecure: false, canSetSelectedText: false)
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("keep", forType: .string)
        let paster = FakePaster()
        let (ins, store) = inserter(FakeTextTarget([noAX, other]), pasteboard: pb, paster: paster)
        let before = store.changeCount
        #expect(await ins.insert("draft") == .focusChanged)
        #expect(paster.pastes.isEmpty)
        #expect(store.changeCount == before)
    }

    @Test("field turned secure before the paste: refused")
    func becameSecure() async {
        let secure = InsertTarget(pid: 4242, bundleID: "x", isSecure: true, canSetSelectedText: false)
        let paster = FakePaster()
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let (ins, _) = inserter(FakeTextTarget([noAX, secure]), pasteboard: pb, paster: paster)
        #expect(await ins.insert("draft") == .refusedSecureField)
        #expect(paster.pastes.isEmpty)
    }

    @Test("the user copies during the paste: their new clipboard is kept, not overwritten")
    func userCopiedMeanwhile() async {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("old", forType: .string)
        let paster = FakePaster(onPaste: {
            _ = pb.string(forType: .string)
            pb.clearContents()
            pb.setString("user copied this", forType: .string)
        })
        let (ins, _) = inserter(FakeTextTarget([noAX]), pasteboard: pb, paster: paster)
        #expect(await ins.insert("draft") == .pasted(clipboardRestored: false))
        #expect(pb.string(forType: .string) == "user copied this")
    }

    @Test("⌘V could not be posted: clipboard restored immediately")
    func pasteFailed() async {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("keep", forType: .string)
        let (ins, _) = inserter(FakeTextTarget([noAX]), pasteboard: pb, paster: FakePaster(succeeds: false))
        #expect(await ins.insert("draft") == .pasteFailed)
        #expect(pb.string(forType: .string) == "keep")
    }

    @Test("restore waits the configured delay (within 300 ms) once the app has read the text")
    func restoreDelay() async {
        let waited = Mutex<[Duration]>([])
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let ins = TextInserter(
            target: FakeTextTarget([noAX]), pasteboard: SystemPasteboard(pb), paster: readingPaster(pb),
            isBlocked: { _ in false }, wait: { d in waited.withLock { $0.append(d) } })
        #expect(await ins.insert("x") == .pasted(clipboardRestored: true))
        #expect(waited.withLock { $0 } == [.milliseconds(250)])
        #expect(TextInserter.Options().restoreDelay <= .milliseconds(300))
    }

    @Test("nobody reads the draft within the timeout: draft left, old clipboard not restored")
    func unconfirmed() async {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("secret-ish old clipboard", forType: .string)
        let (ins, _) = inserter(FakeTextTarget([noAX]), pasteboard: pb, paster: FakePaster())
        #expect(await ins.insert("draft") == .pasteUnconfirmed)
        #expect(pb.string(forType: .string) == "draft")
    }

    @Test("a second insert while one is pasting is refused, so the clipboard can't be lost")
    func overlapping() async {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("user's clipboard", forType: .string)
        let gate = AsyncGate()
        let store = SystemPasteboard(pb)
        let ins = TextInserter(
            target: FakeTextTarget([noAX]), pasteboard: store, paster: readingPaster(pb),
            isBlocked: { _ in false }, wait: { _ in await gate.wait() })
        async let first = ins.insert("one")
        while !(await gate.isWaiting) { await Task.yield() }
        // Started while the first is inside its wait. Without the guard it would snapshot the
        // first draft and later "restore" it, losing the user's clipboard; it must not hang here.
        async let second = ins.insert("two")
        for _ in 0..<10 { await Task.yield() }
        await gate.open()
        let results = await (first, second)
        #expect(results.1 == .busy)
        #expect(results.0 == .pasted(clipboardRestored: true))
        #expect(pb.string(forType: .string) == "user's clipboard")
    }

    @Test("concealed clipboard (password manager copy) is cleared, not restored")
    func concealed() async {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("hunter2", forType: .string)
        item.setData(Data(), forType: PasteboardMarkers.concealed)
        pb.writeObjects([item])
        let (ins, _) = inserter(FakeTextTarget([noAX]), pasteboard: pb)
        #expect(await ins.insert("draft") == .pasted(clipboardRestored: true))
        #expect(pb.string(forType: .string) == nil)
    }

    @Test("trailing newlines are dropped; multi-line text into a terminal is refused")
    func newlines() async {
        let target = FakeTextTarget([field], axResult: .verified)
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let (ins, _) = inserter(target, pasteboard: pb)
        _ = await ins.insert("hello\n\n")
        #expect(target.axWrites == ["hello"])
        #expect(await ins.insert("\n") == .refusedEmptyText)

        let term = InsertTarget(pid: 7, bundleID: "com.googlecode.iterm2", isSecure: false, canSetSelectedText: true)
        let t2 = FakeTextTarget([term])
        let (ins2, _) = inserter(t2, pasteboard: pb)
        #expect(await ins2.insert("ls\nrm -rf x") == .refusedMultilineInTerminal)
        #expect(t2.axWrites.isEmpty)
        #expect(await ins2.insert("git status\n") == .insertedViaAccessibility)  // trailing newline dropped
        #expect(t2.axWrites == ["git status"])
    }

    @Test("Lumi's own field is refused")
    func ownApp() async {
        let mine = InsertTarget(pid: getpid(), bundleID: "com.loomtable.lumi", isSecure: false, canSetSelectedText: true)
        let target = FakeTextTarget([mine])
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let (ins, _) = inserter(target, pasteboard: pb)
        #expect(await ins.insert("x") == .refusedOwnApp)
        #expect(target.axWrites.isEmpty)
    }

    @Test("another field in the same app before the paste counts as a focus change")
    func otherFieldSameApp() async {
        var omnibox = noAX
        omnibox.element = 99
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let paster = FakePaster()
        let (ins, _) = inserter(FakeTextTarget([noAX, omnibox]), pasteboard: pb, paster: paster)
        #expect(await ins.insert("draft") == .focusChanged)
        #expect(paster.pastes.isEmpty)
    }
}

/// Lets a test hold the inserter inside its wait.
actor AsyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    var isWaiting: Bool { !waiters.isEmpty }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@Suite("Pasteboard restore")
@MainActor
struct PasteboardRestoreTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    static let rtf = Data("{\\rtf1 hi}".utf8)
    static let custom = NSPasteboard.PasteboardType("com.example.private-type")

    @Test("snapshot and restore keep every item and every type byte-for-byte, incl. non-text")
    func roundTrip() {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let a = NSPasteboardItem()
        a.setString("plain", forType: .string)
        a.setData(Self.rtf, forType: .rtf)
        a.setData(Self.png, forType: .png)
        let b = NSPasteboardItem()
        b.setData(Data([0, 255, 7]), forType: Self.custom)
        b.setString("file:///tmp/x.txt", forType: .fileURL)
        pb.writeObjects([a, b])

        let store = SystemPasteboard(pb)
        let saved = store.snapshot()
        let write = store.writeTransient("temporary")
        #expect(!write.wasRead())
        #expect(pb.string(forType: .string) == "temporary")
        #expect(write.wasRead())
        store.restore(saved)

        let items = pb.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items[0].string(forType: .string) == "plain")
        #expect(items[0].data(forType: .rtf) == Self.rtf)
        #expect(items[0].data(forType: .png) == Self.png)
        #expect(items[1].data(forType: Self.custom) == Data([0, 255, 7]))
        #expect(items[1].string(forType: .fileURL) == "file:///tmp/x.txt")
        // Same content, plus the auto-generated marker so clipboard history skips the restore.
        #expect(!(pb.types ?? []).contains(PasteboardMarkers.transient))
        #expect((pb.types ?? []).contains(PasteboardMarkers.autoGenerated))
        var restored = store.snapshot()
        restored.items[0].entries.removeAll { $0.type == PasteboardMarkers.autoGenerated.rawValue }
        #expect(restored == saved)
    }

    @Test("an empty clipboard is restored as empty")
    func empty() {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let store = SystemPasteboard(pb)
        let saved = store.snapshot()
        _ = store.writeTransient("temporary")
        store.restore(saved)
        #expect((pb.pasteboardItems ?? []).isEmpty)
    }
}

@Suite("AX write verification")
struct AXVerifyTests {
    @Test("caret after the text, or the text left selected, is verified")
    func verified() {
        #expect(AXTextTarget.verify(before: CFRange(location: 5, length: 0), after: CFRange(location: 10, length: 0), insertedUTF16: 5) == .verified)
        #expect(AXTextTarget.verify(before: CFRange(location: 5, length: 3), after: CFRange(location: 10, length: 0), insertedUTF16: 5) == .verified)
        #expect(AXTextTarget.verify(before: CFRange(location: 5, length: 0), after: CFRange(location: 5, length: 5), insertedUTF16: 5) == .verified)
    }

    @Test("no change is notApplied; anything else is unverified, never pasted over")
    func notApplied() {
        #expect(AXTextTarget.verify(before: CFRange(location: 5, length: 2), after: CFRange(location: 5, length: 2), insertedUTF16: 4) == .notApplied)
        #expect(AXTextTarget.verify(before: CFRange(location: 5, length: 0), after: CFRange(location: 0, length: 0), insertedUTF16: 4) == .unverified)
        // "teh" → "the": unchanged range is ambiguous, so no paste.
        #expect(AXTextTarget.verify(before: CFRange(location: 5, length: 3), after: CFRange(location: 5, length: 3), insertedUTF16: 3) == .unverified)
    }
}
