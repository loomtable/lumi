import BuddyAct
import BuddyCompanion
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyTrace
import CoreGraphics
import Testing
@testable import BuddyApp

/// The dictation key's controller (10-ENGINEERING §1.11): types at the cursor, never asks Claude.
@Suite("DictationController")
@MainActor
struct DictationControllerTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()
    let inserter = FakeDictationInserter()
    let tracer = FakeTracer()
    let point = FixedPointer().point

    func make(phase: BuddyCoordinator.Phase = .idle, panel: FakePanel? = nil) -> DictationController {
        let c = DictationController(
            voice: voice, overlay: overlay, inserter: inserter, panel: panel, pointer: FixedPointer(),
            tracer: tracer, coordinatorPhase: { phase }, frontmostPID: { 4242 })
        return c
    }

    @Test("press listens at once with the pill; release types the words into the app in front")
    func pressAndRelease() async {
        let c = make()
        voice.setTranscript("  meet at noon  ")
        await c.handle(.began)
        #expect(voice.calls == [.start])
        #expect(overlay.calls == [.listening(point, hint: "Dictating 0:00 · release to type")])
        #expect(c.isActive)
        await c.handle(.ended)
        #expect(voice.calls == [.start, .finish])
        #expect(overlay.calls.last == .dismiss(.requested))
        #expect(inserter.inserts.map(\.text) == ["meet at noon"])
        #expect(inserter.inserts.map(\.pid) == [4242])
        #expect(tracer.events.map(\.0) == [.dictationInserted])
        #expect(tracer.events.map(\.1) == [.ok])
        #expect(!c.isActive)
    }

    @Test("the pill carries no session: dictation isn't sent to one")
    func pillHasNoSession() async {
        let c = make()
        overlay.setPillTarget(.new)  // left over from the talk key's last press
        await c.handle(.began)
        #expect(overlay.pillTargets == [.new, .none])
        #expect(overlay.calls == [.listening(point, hint: "Dictating 0:00 · release to type")])
    }

    @Test("discarded: the audio is dropped, nothing inserted")
    func releaseBeforeThreshold() async {
        let c = make()
        await c.handle(.began)
        await c.handle(.discarded(.interrupted(.otherKey(8))))
        #expect(voice.calls == [.start, .discard])
        #expect(overlay.calls.last == .dismiss(.requested))
        #expect(inserter.inserts.isEmpty)
        #expect(inserter.copies.isEmpty)
        // The mic did start, so the discard is counted (QA R14).
        #expect(tracer.events.map(\.0) == [.dictationInserted])
        #expect(tracer.events.map(\.1) == [.cancelled])
        // A late `ended` after the discard does nothing.
        await c.handle(.ended)
        #expect(voice.calls == [.start, .discard])
        #expect(!c.isActive)
    }

    @Test("a bare short press says to hold the key, naming it, at most once per 30 s")
    func shortPressHint() async {
        var time = ContinuousClock.now
        let start = time
        let c = DictationController(
            voice: voice, overlay: overlay, inserter: inserter, pointer: FixedPointer(), tracer: tracer,
            coordinatorPhase: { .idle }, frontmostPID: { 1 }, now: { time })
        let fnTap = DictationGesture.discarded(.shortPress(.function, held: 142_000_000))
        await c.handle(.began)
        await c.handle(fnTap)
        #expect(overlay.calls.last == .toast("Hold fn and speak, release to type."))
        #expect(tracer.reasons == [.release])
        time = start + .seconds(10)
        await c.handle(.began)
        await c.handle(fnTap)
        #expect(overlay.calls.last == .dismiss(.requested))  // not again within 30 s
        time = start + .seconds(31)
        await c.handle(.began)
        await c.handle(.discarded(.shortPress(.rightCommand, held: 200_000_000)))
        #expect(overlay.calls.last == .toast("Hold right ⌘ and speak, release to type."))
        #expect(overlay.calls.filter { if case .toast = $0 { true } else { false } }.count == 2)
    }

    @Test("a shortcut, another key or a click discards silently, and the trace says why",
          arguments: [
            (DictationDiscard.interrupted(.otherKey(8)), TraceReason.otherKey(nil)),
            (.interrupted(.otherKey(179)), .otherKey(179)),
            (.interrupted(.otherModifier), .otherModifier),
            (.interrupted(.mouseDown), .click),
            (.interrupted(.scroll), .scroll),
            (.interrupted(.tapInterrupted), .tapInterrupted),
          ])
    func silentDiscards(why: DictationDiscard, reason: TraceReason) async {
        let c = make()
        await c.handle(.began)
        await c.handle(.discarded(why))
        #expect(!overlay.calls.contains { if case .toast = $0 { true } else { false } })
        #expect(tracer.reasons == [reason])
        #expect(tracer.events.map(\.1) == [.cancelled])
    }

    @Test("ignored unless the coordinator is idle or showing: the talk key keeps the mic")
    func busyCoordinator() async {
        let phases: [BuddyCoordinator.Phase] = [.listening(confirmedTap: false, holding: true), .held, .typing]
        for phase in phases {
            let c = make(phase: phase)
            await c.handle(.began)
            await c.handle(.ended)
            await c.handle(.discarded(.shortPress(.function, held: 100_000_000)))
        }
        #expect(voice.calls.isEmpty)
        #expect(overlay.calls.isEmpty)
        #expect(inserter.inserts.isEmpty)
    }

    @Test("a running turn never blocks dictation: it moves behind, and the dictation types (65 C)")
    func overRunningTurn() async {
        let c = make(phase: .thinking)
        var moved = 0
        c.moveTurnBehind = { moved += 1; return true }
        voice.setTranscript("meet at noon")
        await c.handle(.began)
        #expect(moved == 1)
        #expect(overlay.calls == [.listening(point, hint: "Dictating 0:00 · release to type")])
        await c.handle(.ended)
        #expect(inserter.inserts.map(\.text) == ["meet at noon"])
    }

    @Test("while an answer is on its way and it can't move behind (sessions off): a toast says why (V-10)")
    func whileThinking() async {
        let c = make(phase: .thinking)
        c.moveTurnBehind = { false }
        await c.handle(.began)
        await c.handle(.ended)
        #expect(voice.calls.isEmpty)
        #expect(inserter.inserts.isEmpty)
        #expect(overlay.calls == [.toast(DictationController.answeringLine)])
    }

    @Test("over an answer: the pill shows too (a dictation can run for minutes); still types")
    func overAnswer() async {
        let c = make(phase: .showing)
        await c.handle(.began)
        #expect(overlay.calls == [.listening(point, hint: "Dictating 0:00 · release to type")])
        await c.handle(.ended)
        #expect(overlay.calls.contains(.dismiss(.requested)))
        #expect(inserter.inserts.count == 1)
    }

    @Test("Lumi's composer has the keyboard: the words go into it, not through the pasteboard")
    func composer() async {
        let panel = FakePanel()
        panel.composerIsKey = true
        voice.setTranscript("draft this")
        let c = make(panel: panel)
        await c.handle(.began)
        await c.handle(.ended)
        #expect(panel.calls == [.insert("draft this")])
        #expect(inserter.inserts.isEmpty)
    }

    @Test("the Studio composer has the keyboard: the words go into it (Lumi's window can't be pasted into)")
    func studioComposer() async {
        let studio = FakeDictationComposer()
        studio.composerIsKey = true
        voice.setTranscript("plan the week")
        let c = make()
        c.studio = studio
        await c.handle(.began)
        await c.handle(.ended)
        #expect(studio.inserted == ["plan the week"])
        #expect(inserter.inserts.isEmpty)
        #expect(inserter.copies.isEmpty)
        #expect(tracer.events.map(\.1) == [.ok])
    }

    @Test("a Studio composer without the keyboard is skipped: the words go to the app in front")
    func studioComposerNotKey() async {
        let studio = FakeDictationComposer()
        let c = make()
        c.studio = studio
        await c.handle(.began)
        await c.handle(.ended)
        #expect(studio.inserted.isEmpty)
        #expect(inserter.inserts.count == 1)
    }

    @Test("nothing said: nothing typed, a toast says so and the trace counts it (QA U44)")
    func emptyTranscript() async {
        voice.setTranscript("   ")
        let c = make()
        await c.handle(.began)
        await c.handle(.ended)
        #expect(inserter.inserts.isEmpty)
        #expect(inserter.copies.isEmpty)
        #expect(overlay.calls.suffix(2) == [.dismiss(.requested), .toast(DictationController.heardNothingLine)])
        #expect(tracer.events.map(\.0) == [.dictationInserted])
        #expect(tracer.events.map(\.1) == [.skipped])
        #expect(!c.isActive)
    }

    @Test("a dictation that didn't go in traces why, never what was said",
          arguments: [(InsertResult.noFocusedField, TraceReason.noField), (.focusChanged, .focusChanged),
                      (.refusedSecureField, .secureField), (.refusedBlockedApp, .blockedApp), (.refusedOwnApp, .ownApp),
                      (.refusedMultilineInTerminal, .multilineTerminal), (.pasteUnconfirmed, .pasteUnconfirmed),
                      (.pasteFailed, .pasteFailed), (.busy, .busy)])
    func failedInsertTracesItsReason(result: InsertResult, reason: TraceReason) async {
        inserter.result = result
        voice.setTranscript("keep me")
        let c = make()
        await c.handle(.began)
        await c.handle(.ended)
        #expect(tracer.events.map(\.0) == [.dictationInserted])
        #expect(tracer.events.map(\.1) == [.failed])
        #expect(tracer.reasons == [reason])
        #expect(DictationController.failureReason(.pasted(clipboardRestored: true)) == nil)
        #expect(DictationController.failureReason(.insertedViaAccessibility) == nil)
    }

    /// U64: Lumi's own field with the keyboard takes the words in process; a password field
    /// takes nothing (as outside Lumi); with no Lumi field focused, the app in front gets them.
    @Test("dictating into one of Lumi's own fields types there", arguments: [OwnInsert.inserted, .secure, .none, .lost])
    func ownField(own: OwnInsert) async {
        voice.setTranscript("meet at noon")
        let c = make()
        let field = FakeOwnField(own)
        c.ownField = field
        await c.handle(.began)
        await c.handle(.ended)
        #expect(field.inserted == ["meet at noon"])
        #expect(field.captures == 1, "the field is taken at the press")
        switch own {
        case .inserted:
            #expect(inserter.inserts.isEmpty, "nothing pasted from outside")
            #expect(tracer.events.map(\.1) == [.ok])
        case .secure:
            #expect(inserter.inserts.isEmpty && inserter.copies.isEmpty, "a password field gets nothing, not even the clipboard")
            #expect(tracer.reasons == [.secureField])
        case .none:
            #expect(inserter.inserts.map(\.text) == ["meet at noon"], "the app in front gets them")
        case .lost:
            // QA gate 4.5: the Glance reply taken at the press folded away for the pill.
            #expect(inserter.inserts.isEmpty, "never pasted into the app behind")
            #expect(inserter.copies == ["meet at noon"])
            #expect(tracer.reasons == [.focusChanged])
        }
    }

    @Test("couldn't type it: the words go on the clipboard and a toast says so",
          arguments: [InsertResult.noFocusedField, .focusChanged, .pasteFailed, .refusedOwnApp, .busy])
    func fallbackToClipboard(result: InsertResult) async {
        inserter.result = result
        voice.setTranscript("keep me")
        let c = make()
        await c.handle(.began)
        await c.handle(.ended)
        #expect(inserter.copies == ["keep me"])
        #expect(overlay.calls.last == .toast(DictationController.copiedLine))
        #expect(tracer.events.map(\.1) == [.failed])
    }

    @Test("a password field or a blocked app: refused, never copied")
    func refusedNotCopied() async {
        for result in [InsertResult.refusedSecureField, .refusedBlockedApp] {
            inserter.result = result
            let c = make()
            await c.handle(.began)
            await c.handle(.ended)
            #expect(inserter.copies.isEmpty)
            #expect(overlay.calls.last == .toast(result == .refusedSecureField ? DictationController.secureLine
                                                                                 : LiveInserter.problem(for: result)!))
        }
    }

    @Test("the mic can't start: a true line, and the release does nothing")
    func micFails() async {
        voice.setStartError(VoicePortError("Still setting up voice.", stillSettingUp: true))
        let c = make()
        await c.handle(.began)
        #expect(overlay.calls == [.toast("Still setting up voice.")])
        #expect(!c.isActive)
        await c.handle(.ended)
        #expect(voice.calls == [.start])
        #expect(inserter.inserts.isEmpty)
    }
}

/// Tap to toggle, Esc, and Dictation history (owner, Oct 29): every transcript is kept, typed or not.
@Suite("DictationController history and toggle")
@MainActor
struct DictationHistoryFlowTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()
    let inserter = FakeDictationInserter()
    let tracer = FakeTracer()
    let point = FixedPointer().point
    let history = DictationHistory(file: nil)

    final class Calls {
        var saved: [String] = []
        var endGestures = 0
    }

    func make(time: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) -> (DictationController, Calls) {
        let calls = Calls()
        let c = DictationController(
            voice: voice, overlay: overlay, inserter: inserter, pointer: FixedPointer(), tracer: tracer,
            history: history, coordinatorPhase: { .idle }, frontmostPID: { 4242 }, appName: { _ in "Notes" },
            now: time)
        c.dictationKey = { .function }
        c.showSaved = { calls.saved.append($0) }
        c.endGesture = { calls.endGestures += 1 }
        return (c, calls)
    }

    @Test("toggle: began, latched (the pill says how to stop), the stop tap types and keeps it")
    func toggle() async {
        let (c, calls) = make()
        voice.setTranscript("a long thought")
        await c.handle(.began)
        await c.handle(.latched)
        #expect(overlay.calls.last == .hint("Dictating 0:00 · tap fn to stop"))
        #expect(c.isActive)
        await c.handle(.ended)
        #expect(inserter.inserts.map(\.text) == ["a long thought"])
        #expect(history.records.map(\.text) == ["a long thought"])
        #expect(history.records.map(\.status) == [.inserted])
        #expect(history.records.map(\.appName) == ["Notes"])
        #expect(calls.saved.isEmpty)
        #expect(!c.isActive)
    }

    @Test("the pill's clock counts up each refresh")
    func clock() async {
        var time = ContinuousClock.now
        let start = time
        let (c, _) = make(time: { time })
        await c.handle(.began)
        await c.handle(.latched)
        time = start + .seconds(75)
        c.refreshHint()
        #expect(overlay.calls.last == .hint("Dictating 1:15 · tap fn to stop"))
        #expect(DictationController.clock(.seconds(3725)) == "1:02:05")
        #expect(DictationController.clock(.seconds(9)) == "0:09")
        #expect(DictationController.hint(elapsed: .seconds(3490), latched: true, nearLimit: true, key: .function)
            == "Dictating 58:10 · stops at 60:00")
    }

    @Test("couldn't type it: copied, kept as not inserted, and a line with a way to open history",
          arguments: [InsertResult.noFocusedField, .refusedOwnApp])
    func notInserted(result: InsertResult) async {
        inserter.result = result
        voice.setTranscript("keep me")
        let (c, calls) = make()
        await c.handle(.began)
        await c.handle(.ended)
        #expect(inserter.copies == ["keep me"])
        #expect(history.records.map(\.status) == [.notInserted])
        #expect(calls.saved == [DictationController.copiedSavedLine])
    }

    @Test("a password field: never copied, never kept in history, and said so (lead, Oct 29)")
    func secureField() async {
        inserter.result = .refusedSecureField
        voice.setTranscript("not a password")
        let (c, calls) = make()
        await c.handle(.began)
        await c.handle(.ended)
        #expect(inserter.copies.isEmpty)
        #expect(history.records.isEmpty)
        #expect(calls.saved.isEmpty)
        #expect(overlay.calls.last == .toast(DictationController.secureLine))
    }

    @Test("Esc (Lumi's Esc tap): finished, kept, not typed; the key monitor is told")
    func escape() async {
        voice.setTranscript("half a thought")
        let (c, calls) = make()
        await c.handle(.began)
        await c.handle(.latched)
        await c.cancel()
        #expect(voice.calls == [.start, .finish])
        #expect(inserter.inserts.isEmpty)
        #expect(history.records.map(\.text) == ["half a thought"])
        #expect(history.records.map(\.status) == [.notInserted])
        #expect(calls.saved == [DictationController.cancelledLine])
        #expect(calls.endGestures == 1)
        #expect(tracer.reasons == [.escape])
        #expect(!c.isActive)
    }

    @Test("Esc seen by the key monitor, and another key during a hold: kept, not typed")
    func cancelledGestures() async {
        voice.setTranscript("words")
        let (c, calls) = make()
        await c.handle(.began)
        await c.handle(.cancelled(.escape))
        await c.handle(.began)
        await c.handle(.cancelled(.interrupted(.otherKey(8))))
        #expect(inserter.inserts.isEmpty)
        #expect(history.records.count == 2)
        #expect(calls.saved == [DictationController.cancelledLine, DictationController.stoppedLine])
        #expect(calls.endGestures == 0, "the gate already knows")
    }

    @Test("Esc with nothing said: nothing kept, nothing said")
    func escapeSilent() async {
        voice.setTranscript("")
        let (c, calls) = make()
        await c.handle(.began)
        await c.cancel()
        #expect(history.records.isEmpty)
        #expect(calls.saved.isEmpty)
    }

    @Test("the voice stopped the listen itself (the hour limit, sleep): kept and said so, never lost")
    func voiceStopped() async {
        voice.setTranscript("an hour of notes")
        let (c, calls) = make()
        await c.handle(.began)
        await c.handle(.latched)
        await c.voiceStopped(message: nil)
        #expect(history.records.map(\.text) == ["an hour of notes"])
        #expect(calls.saved == [DictationController.stoppedLine])
        #expect(calls.endGestures == 1)
        #expect(inserter.inserts.isEmpty)
        await c.handle(.ended)  // the stop tap that follows does nothing
        #expect(inserter.inserts.isEmpty)
    }

    @Test("near the limit, the pill says when it stops")
    func nearLimit() async {
        let (c, _) = make()
        await c.handle(.began)
        c.voiceNearLimit()
        #expect(overlay.calls.last == .hint("Dictating 0:00 · stops at 60:00"))
    }

    @Test("a dictation listen asks the voice for one (no silence stop)")
    func dictationListen() async {
        let (c, _) = make()
        await c.handle(.began)
        #expect(voice.dictationStarts == 1)
    }
}

/// Through the coordinator: dictation never reaches Claude, and the buddy key waits for it.
@Suite("Dictation via the coordinator")
@MainActor
struct DictationCoordinatorTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()
    let bridge = FakeBridge()
    let inserter = FakeDictationInserter()

    func make() -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), turns: bridge,
            overlay: overlay, pointer: FixedPointer())
        c.start()
        c.dictation = DictationController(
            voice: voice, overlay: overlay, inserter: inserter, pointer: FixedPointer(),
            coordinatorPhase: { [weak c] in c?.phase ?? .idle }, frontmostPID: { 7 })
        return c
    }

    @Test("a dictation makes zero TurnPort calls")
    func neverAsksClaude() async {
        let c = make()
        voice.setTranscript("hello world")
        await c.handle(.dictation(.began))
        await c.handle(.dictation(.ended))
        await c.handle(.dictation(.began))
        await c.handle(.dictation(.discarded(.interrupted(.otherKey(8)))))
        #expect(bridge.asked.isEmpty)
        #expect(bridge.deeper.isEmpty)
        #expect(bridge.cancelled.isEmpty)
        #expect(inserter.inserts.map(\.text) == ["hello world"])
        #expect(c.phase == .idle)
    }

    @Test("the buddy key is ignored while dictating")
    func buddyKeyWaits() async {
        let c = make()
        await c.handle(.dictation(.began))
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        #expect(voice.calls == [.start])
        #expect(c.phase == .idle)
        #expect(bridge.asked.isEmpty)
        await c.handle(.dictation(.ended))
        #expect(inserter.inserts.count == 1)
    }

    @Test("dictation is ignored while the talk key is listening")
    func talkKeyWins() async {
        let c = make()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        let starts = voice.calls.filter { $0 == .start }.count
        await c.handle(.dictation(.began))
        await c.handle(.dictation(.ended))
        #expect(voice.calls.filter { $0 == .start }.count == starts)
        #expect(inserter.inserts.isEmpty)
    }

    @Test("paused: dictation does nothing")
    func paused() async {
        let c = make()
        await c.setPaused(true)
        await c.handle(.dictation(.began))
        #expect(!voice.calls.contains(.start))
    }

    @Test("Esc while dictating cancels the dictation, not the overlay")
    func escapeCancelsDictation() async {
        let c = make()
        voice.setTranscript("draft")
        await c.handle(.dictation(.began))
        await c.escapePressed()
        #expect(inserter.inserts.isEmpty)
        #expect(c.dictation?.isActive == false)
    }

    @Test("the voice's auto-stop during a dictation goes to the dictation")
    func autoStopForwarded() async {
        let c = make()
        let history = DictationHistory(file: nil)
        c.dictation?.history = history
        voice.setTranscript("kept")
        await c.handle(.dictation(.began))
        await c.handle(VoiceEvent.autoStopped(held: true, message: nil))
        #expect(history.records.map(\.text) == ["kept"])
        #expect(c.dictation?.isActive == false)
        #expect(c.phase == .idle)
    }

    @Test("pausing cancels a running dictation and keeps its words")
    func pauseKeeps() async {
        let c = make()
        let history = DictationHistory(file: nil)
        c.dictation?.history = history
        voice.setTranscript("before pause")
        await c.handle(.dictation(.began))
        await c.setPaused(true)
        #expect(history.records.map(\.text) == ["before pause"])
        #expect(c.dictation?.isActive == false)
    }
}
