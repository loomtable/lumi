import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import BuddyApp
@testable import BuddyBridge
@testable import BuddyContext
import BuddyCompanion
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

/// End-to-end flows through the coordinator, start to finish, asserting only what the user sees
/// and hears, in order: the safety net for any later simplification of the coordinator. Each
/// line of a timeline is one overlay call ("card: …") or voice call ("🔊 …"); level meters,
/// backdrops and hints are left out.
@MainActor
struct ScenarioTests {
    let voice = FakeVoice()
    let bridge = FakeBridge()
    let overlay = FakeOverlay()
    let inserter = FakeInserter()

    init() {
        let overlay = overlay
        voice.setOverlayCount { await MainActor.run { overlay.calls.count } }
    }

    func make(
        context: any ContextPort = FakeContext.packet(), settings: BuddyCoordinator.Settings = .init(),
        bridge: (any BridgePort)? = nil, research: (any ResearchPort)? = nil,
        interruptions: (any SystemInterruptionSource)? = nil, conversations: (any ConversationPort)? = nil
    ) -> BuddyCoordinator {
        var settings = settings
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: context, turns: bridge ?? self.bridge,
            overlay: overlay, inserter: inserter, pointer: FixedPointer(), interruptions: interruptions,
            research: research, conversations: conversations, trust: { FolderTrust(trustedPaths: []) })
        c.start()
        return c
    }

    // MARK: Gestures

    /// Tap to start, tap to send; waits for the answer.
    func tapToTalk(_ c: BuddyCoordinator) async {
        await send(c)
        await settle { c.phase != .thinking }
    }

    /// The same taps, without waiting (a turn that stays in flight).
    func send(_ c: BuddyCoordinator) async {
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
    }

    /// Waits up to 2 s for `done`, then lets pending work run; with no condition, only the latter.
    func settle(_ done: (() -> Bool)? = nil) async {
        if let done {
            let deadline = ContinuousClock.now + waitCeiling
            while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        }
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: What the user sees and hears

    var timeline: [String] {
        let marks = voice.marks
        var out: [String] = []
        var next = 0
        for (i, call) in overlay.calls.enumerated() {
            while next < marks.count, marks[next].overlayIndex <= i {
                out.append(Self.heard(marks[next].call))
                next += 1
            }
            if let seen = Self.seen(call) { out.append(seen) }
        }
        out += marks[next...].map { Self.heard($0.call) }
        return out
    }

    static func heard(_ call: FakeVoice.Call) -> String {
        switch call {
        case .start: "🎤 on"
        case .finish: "🎤 off"
        case .discard: "🎤 discard"
        case .sendHeld: "🎤 send held"
        case .interrupt: "🎤 interrupted"
        case .speak(let text): "🔊 \(text)"
        case .stopSpeaking: "🔇"
        case .play(let sound): "♪ \(sound)"
        }
    }

    static func seen(_ call: FakeOverlay.Call) -> String? {
        switch call {
        case .listening(_, let hint): "listening: \(hint)"
        case .textBox: "text box"
        case .capsule(let jobs): "capsule: " + jobs.map { "\($0.topic) \($0.status)" }.joined(separator: ", ")
        case .rings(let rings): "rings: \(rings.count)"
        case .toast(let text): "toast: \(text)"
        case .thinking(let lane, let status): "thinking \(lane.mode)" + (status.map { ": \($0)" } ?? "")
        case .status(let status): "status: \(status ?? "-")"
        case .headline(let text): "headline: \(text)"
        case .answer(let a, _, _):
            "\(a.block.shape == .chip ? "chip" : "card"): \(a.block.say)"
                + (a.mainAction.map { " [\($0)]" } ?? "")
                + (a.block.actions.isEmpty ? "" : " " + a.block.actions.map { "(\($0.label))" }.joined(separator: " "))
        case .chipText(let text): "chip text: \(text)"
        case .resetPositions: "reset positions"
        case .copyAnswer: "copied"
        case .speaking(let on): on ? "speaking" : "not speaking"
        case .dismiss(let reason): "dismissed (\(reason))"
        case .focus: "focused"
        case .escape: "esc"
        // Level meters, backdrops and hints; also any call added later, until a scenario needs it.
        default: nil
        }
    }

    static func done(_ block: BuddyBlock?, lane: Mode = .quick) -> CascadeEvent {
        BuddyCoordinatorTests.done(block, lane: lane)
    }

    // MARK: Scenarios

    @Test func voiceQuestionQuickAnswerSpokenWithACard() async {
        bridge.setScript([.turn(lane: .quick, .sayFirstSentence("The totals row is off.")),
                          Self.done(BuddyBlock(say: "The totals row is off. It sums the wrong column.", shape: .card))])
        let c = make()
        await tapToTalk(c)
        await settle { voice.calls.contains(.speak("It sums the wrong column.")) }
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "headline: The totals row is off.",
            "🔊 The totals row is off.",
            "speaking",
            "card: The totals row is off. It sums the wrong column.",
            "🔊 It sums the wrong column.",
            "speaking",
        ], "\(timeline)")
    }

    @Test func typedQuestion() async {
        bridge.setScript([
            .turn(lane: .quick, .sayFirstSentence("Yes, that's valid JSON.")),
            Self.done(BuddyBlock(say: "Yes, that's valid JSON.", shape: .chip)),
        ])
        let c = make()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.doubleTap))
        overlay.send(.submitted(text: "is this valid json", source: .textBox))
        await settle { c.phase == .showing }
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "text box",
            "🎤 discard",
            "thinking quick",
            "status: Looking at Safari",
            "headline: Yes, that's valid JSON.", // streamed into the pill, silently
            "chip: Yes, that's valid JSON.",
        ], "\(timeline)")
    }

    @Test func aFollowUpInTheSameConversation() async {
        bridge.setScript([Self.done(BuddyBlock(say: "It's a VLOOKUP.", shape: .card))])
        let c = make()
        await tapToTalk(c)
        await settle { c.phase == .showing }
        bridge.setScript([Self.done(BuddyBlock(say: "Use XLOOKUP instead.", shape: .card))])
        overlay.send(.submitted(text: "what's better", source: .reply))
        await settle { bridge.asked.count == 2 && c.phase == .showing }
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "card: It's a VLOOKUP.",
            "🔊 It's a VLOOKUP.",
            "speaking",
            "not speaking",
            "thinking quick",
            "🔇",
            "card: Use XLOOKUP instead.",
        ], "\(timeline)")
        // The same conversation, one turn on.
        #expect(bridge.asked.map { $0.packet.conversation?.turn } == [1, 2])
        #expect(Set(bridge.asked.map { $0.packet.conversation?.id }).count == 1)
    }

    @Test func aHandOffToDeepSpeaksItsLineThenDeepAnswers() async {
        bridge.setScript([
            .handingOff(say: "Let me check the repo."),
            .turn(lane: .deep, .status("Reading Sources/App.swift")),
            Self.done(BuddyBlock(say: "The crash is a force unwrap in App.swift.", shape: .card), lane: .deep),
        ])
        let c = make()
        await tapToTalk(c)
        await settle { voice.calls.contains(.speak("The crash is a force unwrap in App.swift.")) }
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "thinking deep: Let me check the repo.", // the pill shows what the voice says
            "🔊 Let me check the repo.",
            "speaking",
            "status: Reading Sources/App.swift",
            "card: The crash is a force unwrap in App.swift.",
            "🔊 The crash is a force unwrap in App.swift.",
            "speaking",
        ], "\(timeline)")
    }

    @Test func researchStartsACapsuleThatFinishes() async {
        let runner = FakeResearchRunner()
        let controller = ResearchController(runner: runner, overlay: overlay, model: { .opus }, color: { _ in .sage },
                                            linger: .seconds(60), sleep: { try? await Task.sleep(for: $0) }, openFile: { _ in })
        bridge.setScript([.researchRequested(say: "On it. I'll let you know when it's done."),
                          Self.done(BuddyBlock(say: "On it. I'll let you know when it's done.", shape: .chip, handoff: .research))])
        let c = make(research: controller)
        voice.setTranscript("research quantitative tightening")
        await tapToTalk(c)
        await settle { runner.calls.count == 1 }
        guard var running = controller.jobs.first else { Issue.record("no job"); return }
        running.state = .running
        runner.send(running)
        await settle { overlay.calls.contains { if case .capsule(let j) = $0 { j.first?.status == .running(.planning) } else { false } } }
        var done = running
        done.state = .done
        runner.send(done)
        await settle { overlay.calls.contains { if case .capsule(let j) = $0 { j.first?.status == .done } else { false } } }
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "🔊 On it. I'll let you know when it's done.",
            "speaking",
            "capsule: quantitative tightening queued",
            "dismissed (requested)",
            "toast: Running in the background",
            "capsule: quantitative tightening running(BuddyOverlay.CapsuleState.Phase.planning)",
            "capsule: quantitative tightening done",
            "🔊 Your research on quantitative tightening is ready.",
            "speaking",
        ], "\(timeline)")
    }

    /// A long dictation: the pill says it's transcribing, then the answer comes as usual.
    @Test func aSlowTranscriptSaysTranscribingThenAnswers() async {
        bridge.setScript([Self.done(BuddyBlock(say: "It's the date filter.", shape: .chip))])
        let c = make()
        voice.holdFinish.withLock { $0 = true }
        let sending = Task { await self.send(c) }
        await settle { self.voice.calls.contains(.finish) }
        voice.eventSink.yield(.transcribing(long: false))
        await settle { self.overlay.calls.contains(.status("Transcribing…")) }
        voice.holdFinish.withLock { $0 = false }
        _ = await sending.value
        await settle { c.phase == .showing }
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Transcribing…",
            "status: -",
            "status: Looking at Safari",
            "chip: It's the date filter.",
            "🔊 It's the date filter.",
            "speaking",
        ], "\(timeline)")
    }

    @Test func escMidThinkingThenAskAgain() async {
        let manual = ManualBridge()
        let c = make(bridge: manual)
        await send(c)
        await settle { manual.streamCount == 1 }
        await c.escapePressed()
        await settle()
        await send(c)
        await settle { manual.streamCount == 2 }
        manual.send(Self.done(BuddyBlock(say: "Second answer.", shape: .chip)), to: 1)
        manual.finish(1)
        await settle { c.phase == .showing }
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "dismissed (escape)",
            "not speaking",
            "🔇",
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "chip: Second answer.",
            "🔊 Second answer.",
            "speaking",
        ], "\(timeline)")
        #expect(manual.cancelled.count == 1, "Esc cancels the turn in flight")
    }

    @Test func shiftKeyStartsANewConversation() async {
        bridge.setScript([Self.done(BuddyBlock(say: "First topic answer.", shape: .chip))])
        // The app's own conversation store, in memory.
        let manager = ConversationManager(index: try! ConversationIndex(url: nil), sessionFiles: FakeSessionFiles(),
                                          screenshotDirectory: FileManager.default.temporaryDirectory,
                                          clock: ManualConversationClock())
        let c = make(conversations: LiveConversations(manager: manager, reader: nil))
        await tapToTalk(c)
        await settle { c.phase == .showing }
        let first = bridge.asked.first?.packet.conversation?.id
        bridge.setScript([Self.done(BuddyBlock(say: "New topic answer.", shape: .chip))])
        voice.setTranscript("something else entirely")
        await c.handle(.gesture(.pressBegan(fresh: true)))
        await c.handle(.gesture(.tap))
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await settle { bridge.asked.count == 2 && c.phase == .showing }
        let second = bridge.asked.last?.packet.conversation?.id
        await settle()
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "chip: First topic answer.",
            "🔊 First topic answer.",
            "speaking",
            "not speaking",
            "listening: new session · tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "toast: New session",
            "chip: New topic answer.",
            "🔊 New topic answer.",
            "speaking",
        ], "\(timeline)")
        #expect(first != nil && second != nil && first != second, "⇧ + key started a new conversation")
        #expect(bridge.asked.count == 2)
    }

    @Test func theMainButtonReplacesTheSelection() async {
        bridge.setScript([Self.done(BuddyBlock(say: "Here's a shorter version.", shape: .card, insert: "Thanks, see you Friday."))])
        let c = make(context: FakeContext.packet(editable: .init(field: true, selection: true)))
        await tapToTalk(c)
        await settle { c.phase == .showing }
        overlay.send(.mainAction(.replace))
        await settle { !inserter.inserted.isEmpty && c.phase == .idle }
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "card: Here's a shorter version. [replace]",
            "🔊 Here's a shorter version.",
            "speaking",
            "not speaking",
            "dismissed (requested)",
            "🔇",
        ], "\(timeline)")
        #expect(inserter.inserted == ["Thanks, see you Friday."], "the insert text, never the spoken line")
        #expect(inserter.pids == [4242], "into the app the user summoned in")
    }

    static func failure(code: String? = nil, status: Int? = nil) -> CascadeEvent {
        var r = StreamEvent.TurnResult(subtype: "success", isError: true, sessionID: "s", text: "",
                                       terminalReason: "api_error", apiErrorStatus: status, durationMS: nil,
                                       ttftMS: nil, costUSD: nil, permissionDenials: 0)
        r.errorCode = code
        return .turn(lane: .quick, .failed(.turnFailed(r)))
    }

    @Test func eachFailureLineAndItsFix() async {
        var settings = BuddyCoordinator.Settings()
        settings.quick.model = .opus
        let c = make(settings: settings)
        var opened: [String] = [], repairs = 0, switched: [String] = []
        c.onOpenSettingsPane = { opened.append($0.rawValue) }
        c.onRepairPlugin = { repairs += 1 }
        c.onUseModel = { model, mode in switched.append("\(mode) \(model.rawValue)") }
        let plugin = StreamEvent.InitInfo(sessionID: "s", model: "m", cwd: "/", permissionMode: "auto", version: nil,
                                          pluginErrors: [.init(plugin: "buddy", type: "load", message: "x", path: nil)],
                                          plugins: [], mcpServers: [])
        for script in [[Self.failure(code: "authentication_failed"), Self.done(nil)],
                       [.turn(lane: .quick, .initialized(plugin)), Self.failure(code: "new_thing"), Self.done(nil)],
                       [Self.failure(status: 529), Self.done(nil)],
                       [Self.failure(code: "new_thing"), Self.done(nil)]] {
            bridge.setScript(script)
            await tapToTalk(c)
            await settle { c.phase == .showing }
            bridge.setScript([Self.done(BuddyBlock(say: "Works now.", shape: .chip))])
            overlay.send(.action(index: 0))
            await settle()
            await c.escapePressed()
            await settle()
        }
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "chip: Claude Code isn't signed in. (Fix)",
            "🔊 Claude Code isn't signed in.", // a spoken question's failure is said too
            "speaking",
            "not speaking", // pressing the fix stops it
            "🔇",
            "dismissed (requested)",
            "not speaking",
            "esc",
            "🔇",
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "chip: The Lumi plugin didn't load. (Repair plugin)",
            "🔊 The Lumi plugin didn't load.",
            "speaking",
            "not speaking",
            "🔇",
            "dismissed (requested)",
            "not speaking",
            "esc",
            "🔇",
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "chip: The API is busy right now. Try again in a moment. (Use Sonnet 5.5)",
            "🔊 The API is busy right now. Try again in a moment.",
            "speaking",
            "not speaking",
            "🔇",
            "thinking quick: Switching to Sonnet 5.5…",
            "toast: Quick now uses Sonnet 5.5 · change in Settings › Models",
            "thinking quick",
            "chip: Works now.",
            "🔊 Works now.", // the same spoken question, so its answer is read out too
            "speaking",
            "not speaking",
            "esc",
            "dismissed (escape)",
            "🔇",
            "not speaking",
            "🔇",
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "chip: Claude Code couldn't finish that. (Try again)",
            "🔊 Claude Code couldn't finish that.",
            "speaking",
            "not speaking",
            "🔇",
            "thinking quick",
            "chip: Works now.",
            "🔊 Works now.",
            "speaking",
            "not speaking",
            "esc",
            "dismissed (escape)",
            "🔇",
            "not speaking",
            "🔇",
        ], "\(timeline)")
        #expect(opened == ["claudeCode"] && repairs == 1 && switched == ["quick claude-sonnet-5-5"])
    }

    @Test func aBlockedAppIsNeverLookedAt() async {
        let c = make(context: FakeContext(result: .blocked(app: "1Password")))
        await tapToTalk(c)
        await settle { c.phase == .showing }
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "chip: I don't look at 1Password.",
        ], "\(timeline)")
        #expect(bridge.asked.isEmpty, "a blocked app's screen is never sent")
    }

    @Test func noScreenRecordingPermission() async {
        var context = FakeContext.packet()
        context.shot = nil
        context.unavailable = .notGranted
        bridge.setScript([Self.done(BuddyBlock(say: "I can't see your screen, but here's what I know.", shape: .chip))])
        let c = make(context: context)
        await tapToTalk(c)
        await settle { c.phase == .showing }
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "chip: I can't see your screen, but here's what I know.",
            "🔊 I can't see your screen, but here's what I know.",
            "speaking",
        ], "\(timeline)")
        #expect(bridge.asked.first?.packet.screenshotUnavailable == .notGranted)
        #expect(bridge.asked.first?.screenshot == nil)
    }

    @Test func lockDuringAnAnswer() async {
        let system = FakeSystemInterruptions()
        bridge.setScript([.turn(lane: .quick, .sayFirstSentence("It's a long answer.")),
                          Self.done(BuddyBlock(say: "It's a long answer. With more to say.", shape: .card))])
        let c = make(interruptions: system)
        await tapToTalk(c)
        await settle { c.phase == .showing }
        system.send(.screenLocked)
        await settle()
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "headline: It's a long answer.",
            "🔊 It's a long answer.",
            "speaking",
            "card: It's a long answer. With more to say.",
            "🔊 With more to say.",
            "speaking",
            "not speaking",
            "🔇",
        ], "\(timeline)")
    }

    @Test func ringsOffAndInsertOff() async {
        var settings = BuddyCoordinator.Settings()
        settings.rings = false
        settings.insert = false
        let locator = FakeLocator(rects: ["Total": CGRect(x: 1, y: 2, width: 30, height: 10)])
        bridge.setScript([Self.done(BuddyBlock(say: "The total is wrong.", shape: .card,
                                               points: [.init(quote: "Total", label: "1")], insert: "=SUM(B2:B9)"))])
        var s2 = settings; s2.sounds = false
        let c = BuddyCoordinator(settings: s2, voice: voice, context: FakeContext.packet(editable: .init(field: true, selection: false)),
                                 turns: bridge, overlay: overlay, inserter: inserter, pointer: FixedPointer(),
                                 locator: locator, trust: { FolderTrust(trustedPaths: []) })
        c.start()
        await tapToTalk(c)
        await settle { c.phase == .showing }
        #expect(timeline == [
            "not speaking",
            "listening: tap ⌥ to send",
            "🔇",
            "🎤 on",
            "thinking quick",
            "🎤 off",
            "status: Looking at Safari",
            "card: The total is wrong. [copy]",
            "🔊 The total is wrong.",
            "speaking",
        ], "\(timeline)")
        #expect(locator.calls.isEmpty, "no rings, and no AX or OCR work to place them")
        #expect(bridge.asked.first?.packet.features == ContextPacket.Features(rings: false, insert: false))
    }
}

