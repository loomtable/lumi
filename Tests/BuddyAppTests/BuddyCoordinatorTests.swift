import CoreGraphics
import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
@testable import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

@MainActor
struct BuddyCoordinatorTests {
    let voice = FakeVoice()
    let bridge = FakeBridge()
    let overlay = FakeOverlay()
    let inserter = FakeInserter()

    func makeCoordinator(
        context: FakeContext = .packet(),
        settings: BuddyCoordinator.Settings = .init()
    ) -> BuddyCoordinator {
        var settings = settings
        settings.sounds = false
        let coordinator = BuddyCoordinator(
            settings: settings, voice: voice, context: context, bridge: bridge,
            overlay: overlay, inserter: inserter, pointer: FixedPointer())
        coordinator.start()
        return coordinator
    }

    /// Lets pending tasks run without waiting on a condition.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// Waits up to 2 s for `done`, so tests don't depend on scheduling under load.
    func settle(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    static func done(_ block: BuddyBlock?, lane: Mode = .quick, sessionID: String? = nil, id: String = "") -> CascadeEvent {
        let result = StreamEvent.TurnResult(
            subtype: "success", isError: false, sessionID: "s1", text: nil, terminalReason: nil,
            apiErrorStatus: nil, durationMS: nil, ttftMS: nil, costUSD: nil, permissionDenials: 0)
        let outcome = block.map {
            TurnOutcome(
                result: result,
                extraction: .init(block: $0, prose: ""),
                timing: TurnTiming())
        }
        var state = ConversationState(id: id)
        state.lastLane = lane
        state.quickSessionID = sessionID
        return .done(CascadeResult(lane: lane, outcome: outcome, state: state, handoffToFirstText: nil))
    }

    func tapToTalk(_ coordinator: BuddyCoordinator) async {
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        await settle(until: { coordinator.phase != .thinking })
    }

    // MARK: - Gestures

    /// A Deep turn that never ends, so the coordinator stays in `.thinking`.
    func thinkingForever() async -> (BuddyCoordinator, ManualBridge) {
        let manual = ManualBridge()
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let coordinator = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), bridge: manual,
            overlay: overlay, inserter: inserter, pointer: FixedPointer())
        coordinator.start()
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        await settle(until: { manual.streamCount == 1 })
        return (coordinator, manual)
    }

    /// A screenshot that never comes back (a hung ScreenCaptureKit).
    struct HangingShot: ContextPort {
        let inner = FakeContext.packet()
        func capture() async -> SummonContext { await inner.capture() }
        func screenshot(displayID: UInt32?) async -> ShotOutcome {
            try? await Task.sleep(for: .seconds(3600))
            return inner.shot.map(ShotOutcome.shot) ?? .unavailable(.captureFailed)
        }
    }

    @Test func aHungScreenshotSendsWithoutItInsteadOfThinkingForever() async {
        bridge.setScript([Self.done(BuddyBlock(say: "Yes.", shape: .chip))])
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let coordinator = BuddyCoordinator(
            settings: settings, voice: voice, context: HangingShot(), bridge: bridge,
            overlay: overlay, inserter: inserter, pointer: FixedPointer())
        coordinator.screenshotDeadline = .milliseconds(50)
        coordinator.start()
        await tapToTalk(coordinator)
        await settle(until: { coordinator.phase == .showing })
        #expect(coordinator.phase == .showing)
        #expect(bridge.asked.first?.packet.screenshotUnavailable == .captureFailed)
        #expect(bridge.asked.first?.packet.screenshot == nil)
        #expect(bridge.asked.first?.screenshot == nil)
    }

    @Test func anAltGrChordDuringALongTurnCostsNothing() async {
        let (coordinator, manual) = await thinkingForever()
        #expect(coordinator.phase == .thinking)
        let listensBefore = voice.calls.filter { $0 == .start }.count
        await coordinator.handle(.gesture(.pressBegan(fresh: false))) // right ⌥ (AltGr) …
        await coordinator.handle(.gesture(.cancelled(.otherKey(14)))) // … then "e": é
        await settle()
        #expect(coordinator.phase == .thinking)
        #expect(manual.cancelled.isEmpty, "the Deep turn keeps going")
        #expect(voice.calls.filter { $0 == .start }.count == listensBefore, "no mic")
    }

    @Test func aRealTapOrHoldDuringATurnStillInterrupts() async {
        for second in [GestureEvent.tap, .holdBegan] {
            let (coordinator, manual) = await thinkingForever()
            await coordinator.handle(.gesture(.pressBegan(fresh: false)))
            #expect(manual.cancelled.isEmpty, "a press alone waits")
            await coordinator.handle(.gesture(second))
            await settle(until: { !manual.cancelled.isEmpty })
            #expect(manual.cancelled.count == 1)
            if case .listening = coordinator.phase {} else { Issue.record("not listening after \(second)") }
        }
    }

    @Test func tapListensThenSecondTapSends() async {
        bridge.setScript([Self.done(BuddyBlock(say: "It means shrinking the balance sheet.", shape: .chip))])
        let coordinator = makeCoordinator()

        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        #expect(coordinator.phase == .listening(confirmedTap: false, holding: false))
        await coordinator.handle(.gesture(.tap))
        #expect(coordinator.phase == .listening(confirmedTap: true, holding: false))
        #expect(bridge.asked.isEmpty)

        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        await settle(until: { coordinator.phase != .thinking })

        #expect(bridge.asked.count == 1)
        #expect(bridge.asked.first?.packet.utterance == "what does this mean?")
        #expect(coordinator.phase == .showing)
        await settle(until: { voice.calls.contains(.speak("It means shrinking the balance sheet.")) }) // after its card
        #expect(voice.calls.contains(.speak("It means shrinking the balance sheet.")))
    }

    @Test func holdSendsOnRelease() async {
        bridge.setScript([Self.done(BuddyBlock(say: "Done.", shape: .chip))])
        let coordinator = makeCoordinator()
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.holdBegan))
        await coordinator.handle(.gesture(.holdEnded))
        await settle(until: { coordinator.phase != .thinking })
        #expect(bridge.asked.count == 1)
    }

    @Test func holdInterruptedDiscards() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.holdBegan))
        await coordinator.handle(.gesture(.holdDiscarded(.otherKey(14))))
        #expect(voice.calls.contains(.discard))
        #expect(bridge.asked.isEmpty)
        #expect(coordinator.phase == .idle)
    }

    @Test func cancelledBeforeConfirmationDiscardsButNotDuringTapToTalk() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.cancelled(.otherModifier)))
        #expect(coordinator.phase == .idle)

        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        await coordinator.handle(.gesture(.cancelled(.mouseDown)))
        #expect(coordinator.phase == .listening(confirmedTap: true, holding: false))
    }

    @Test func doubleTapDiscardsAudioWithoutSending() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.doubleTap))
        #expect(voice.calls.contains(.discard))
        #expect(bridge.asked.isEmpty)
    }

    @Test func emptyTranscriptIsDiscardedNotSent() async {
        voice.setTranscript("  ")
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        #expect(bridge.asked.isEmpty)
        #expect(coordinator.phase == .idle)
    }

    @Test func pressWhileSpeakingStopsSpeechFirst() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        #expect(voice.calls.prefix(2) == [.stopSpeaking, .start])
    }

    // MARK: - Context

    @Test func blockedAppShowsChipAndNeverAsks() async {
        let coordinator = makeCoordinator(context: FakeContext(result: .blocked(app: "1Password")))
        await tapToTalk(coordinator)
        #expect(bridge.asked.isEmpty)
        let shown = overlay.calls.compactMap { call -> String? in
            if case .answer(let answer, _, _) = call { answer.block.say } else { nil }
        }
        #expect(shown == ["I don't look at 1Password."])
    }

    @Test func aCloseUpGoesAsTheSecondImageAndThePacketSaysWhereItIs() async {
        bridge.setScript([Self.done(BuddyBlock(say: "Ok.", shape: .card))])
        var context = FakeContext.packet()
        context.shot?.detail = ScreenshotDetail(data: Data([9]), rect: CGRect(x: 300, y: 200, width: 256, height: 256),
                                                width: 512, height: 512)
        let coordinator = makeCoordinator(context: context)
        await tapToTalk(coordinator)
        let question = try! #require(bridge.asked.first)
        #expect(question.detail == TurnInput.Image(data: Data([9]), mediaType: "image/jpeg"))
        #expect(question.packet.screenshotDetail == .init(x: 300, y: 200, width: 256, height: 256))
    }

    @Test func packetCarriesScreenshotConversationAndAnchorsOnSelection() async {
        bridge.setScript([Self.done(BuddyBlock(say: "Ok.", shape: .card))])
        let selection = ContextPacket.Selection(
            text: "quantitative tightening",
            bounds: .init(x: 10, y: 20, width: 120, height: 18))
        let coordinator = makeCoordinator(context: .packet(selection: selection))
        await tapToTalk(coordinator)

        let packet = try! #require(bridge.asked.first?.packet)
        #expect(packet.screenshot == "/tmp/shot.jpg")
        #expect(packet.conversation?.turn == 1)
        #expect(bridge.asked.first?.screenshot?.mediaType == "image/jpeg")
        #expect(bridge.asked.first?.detail == nil && packet.screenshotDetail == nil, "no close-up captured")
        let anchors = overlay.calls.compactMap { call -> Anchor? in
            if case .answer(_, let anchor, _) = call { anchor } else { nil }
        }
        #expect(anchors == [.rect(CGRect(x: 10, y: 20, width: 120, height: 18))])
    }

    @Test func followUpContinuesConversationWithPreviousTurn() async {
        bridge.setScript([Self.done(BuddyBlock(say: "First.", shape: .chip))])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        await tapToTalk(coordinator)
        #expect(bridge.asked.count == 2)
        let second = bridge.asked[1].packet.conversation
        #expect(second?.id == bridge.asked[0].packet.conversation?.id)
        #expect(second?.turn == 2)
        #expect(second?.previous.count == 1)
    }

    // MARK: - Streaming and speech

    @Test func earlyFirstSentenceIsNotSpokenTwice() async {
        bridge.setScript([
            .turn(lane: .quick, .sayFirstSentence("Your filter drops last week.")),
            Self.done(BuddyBlock(say: "Your filter drops last week. Want me to loosen it?", shape: .card)),
        ])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        await settle(until: { voice.calls.contains(.speak("Want me to loosen it?")) }) // after its card
        let spoken = voice.calls.compactMap { call -> String? in
            if case .speak(let text) = call { text } else { nil }
        }
        #expect(spoken == ["Your filter drops last week.", "Want me to loosen it?"])
    }

    @Test func handoffShowsDeepLaneAndSpeaksLine() async {
        bridge.setScript([
            .turn(lane: .quick, .status("Reading the table")),
            .handingOff(say: "Let me check the repo."),
            .turn(lane: .deep, .status("Read useFeed.ts")),
            Self.done(BuddyBlock(say: "The filter drops it.", shape: .card), lane: .deep),
        ])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)

        #expect(overlay.calls.contains(.thinking(Lane(mode: .deep, model: .opus), status: "Let me check the repo.")))
        #expect(voice.calls.contains(.speak("Let me check the repo.")))
        let lanes = overlay.calls.compactMap { call -> Mode? in
            if case .answer(let answer, _, _) = call { answer.lane.mode } else { nil }
        }
        #expect(lanes == [.deep])
    }

    @Test func voiceRepliesOffNeverSpeaks() async {
        var settings = BuddyCoordinator.Settings()
        settings.voiceReplies = .off
        bridge.setScript([Self.done(BuddyBlock(say: "Quiet.", shape: .chip))])
        let coordinator = makeCoordinator(settings: settings)
        await tapToTalk(coordinator)
        #expect(!voice.calls.contains { if case .speak = $0 { true } else { false } })
    }

    @Test(arguments: [(BridgeError, String)]([
        (.timedOut, "Claude Code didn't answer in time."),
        (.launchFailed("no claude"), "Claude Code stopped unexpectedly."),
        (.busy, "Still working on the last question."),
    ]))
    func bridgeFailureShowsOneTrueLine(error: BridgeError, message: String) async {
        bridge.setScript([.turn(lane: .quick, .failed(error)), Self.done(nil)])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        let shown = overlay.calls.compactMap { call -> String? in
            if case .answer(let answer, _, _) = call { answer.block.say } else { nil }
        }
        #expect(shown == [message])
    }

    @Test func cancelledTurnShowsNothing() async {
        bridge.setScript([.turn(lane: .quick, .failed(.cancelled)), Self.done(nil)])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        #expect(!overlay.calls.contains { if case .answer = $0 { true } else { false } })
    }

    // MARK: - Esc, actions, go deeper

    @Test func escapeWhileListeningDiscards() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.escapePressed()
        #expect(voice.calls.contains(.discard))
        #expect(coordinator.phase == .idle)
    }

    var lastShownText: String? {
        overlay.calls.last { if case .answer = $0 { true } else { false } }.flatMap {
            if case .answer(let answer, _, _) = $0 { answer.block.say } else { nil }
        }
    }

    @Test func onAnswerShownFiresForAnswersOnly() async {
        var shown = 0
        let coordinator = makeCoordinator()
        coordinator.onAnswerShown = { shown += 1 }

        bridge.setScript([Self.done(BuddyBlock(say: "It's QT.", shape: .chip))])
        await tapToTalk(coordinator)
        #expect(shown == 1)

        // A failed turn shows a true line, not an answer.
        bridge.setScript([.turn(lane: .quick, .failed(.timedOut)), Self.done(nil)])
        await tapToTalk(coordinator)
        #expect(lastShownText == "Claude Code didn't answer in time.")
        #expect(shown == 1)

        // A research handoff isn't an answer yet.
        bridge.setScript([
            .researchRequested(say: "On it."),
            Self.done(BuddyBlock(say: "On it.", shape: .chip, handoff: .research), lane: .quick),
        ])
        await tapToTalk(coordinator)
        #expect(lastShownText == "Research isn't available right now.") // none composed
        #expect(shown == 1)

        // Go deeper's answer is one.
        bridge.setScript([Self.done(BuddyBlock(say: "Deeper.", shape: .card), lane: .deep)])
        await tapToTalk(coordinator)
        overlay.send(.goDeeper)
        await settle(until: { shown == 3 })
        #expect(shown == 3)
    }

    @Test func onAnswerShownSkipsABlockedApp() async {
        var shown = 0
        bridge.setScript([Self.done(BuddyBlock(say: "It's QT.", shape: .chip))])
        let coordinator = makeCoordinator(context: FakeContext(result: .blocked(app: "1Password")))
        coordinator.onAnswerShown = { shown += 1 }
        await tapToTalk(coordinator)
        #expect(lastShownText == "I don't look at 1Password.")
        #expect(shown == 0)
    }

    @Test func actionSendsPromptToDeep() async {
        let block = BuddyBlock(
            say: "Your filter drops it.", shape: .card,
            actions: [.init(label: "Loosen filter in dev", prompt: "Loosen the filter")])
        bridge.setScript([Self.done(block)])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)

        overlay.send(.action(index: 0))
        await settle(until: { bridge.asked.count == 2 && coordinator.phase != .thinking })
        #expect(bridge.asked.count == 2)
        #expect(bridge.asked[1].packet.utterance == "Loosen the filter")
        #expect(bridge.asked[1].routing == .alwaysDeep)
        _ = coordinator
    }

    @Test func onlyAPressedActionIsMarkedApproved() async {
        let block = BuddyBlock(
            say: "I can convert these cells.", shape: .rich,
            actions: [.init(label: "Convert", prompt: "Convert column C to numbers"),
                      .init(label: "Cancel", prompt: "Leave it as is")])
        bridge.setScript([Self.done(block)])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        #expect(bridge.asked.first?.isApprovedAction == false)

        overlay.send(.action(index: 0))
        await settle(until: { bridge.asked.count == 2 && coordinator.phase != .thinking })
        #expect(bridge.asked[1].isApprovedAction)

        // Go deeper reruns the user's own question: no approval carried over.
        overlay.send(.goDeeper)
        await settle(until: { bridge.deeperCount == 1 && coordinator.phase != .thinking })
        #expect(bridge.deeper.first?.isApprovedAction == false)
        #expect(bridge.deeper.first?.packet.utterance == "what does this mean?")
    }

    @Test func aChipsHiddenActionsCantBePressed() async {
        let block = BuddyBlock(
            say: "Column C is text.", shape: .chip,
            actions: [.init(label: "Convert", prompt: "Convert column C"),
                      .init(label: "Delete", prompt: "Delete column C")])
        bridge.setScript([Self.done(block)])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)

        overlay.send(.action(index: 1)) // key 2 on a focused chip, which shows one button
        for _ in 0..<100 { await Task.yield() }
        #expect(bridge.asked.count == 1)

        overlay.send(.action(index: 0))
        await settle(until: { bridge.asked.count == 2 })
        #expect(bridge.asked[1].packet.utterance == "Convert column C")
    }

    @Test func theMainButtonInsertsIntoTheSummonedAppThenCloses() async {
        let block = BuddyBlock(
            say: "Here's a draft.", shape: .card,
            actions: [.init(label: "Warmer", prompt: "Make it warmer")], insert: "Sounds good, thanks!")
        bridge.setScript([Self.done(block)])
        let coordinator = makeCoordinator(context: .packet(editable: .init(field: true, selection: false)))
        await tapToTalk(coordinator)
        #expect(overlay.calls.contains { if case .answer(let a, _, _) = $0 { a.mainAction == .insert } else { false } })

        overlay.send(.mainAction(.insert))
        await settle(until: { overlay.calls.contains(.dismiss(.requested)) })
        #expect(inserter.inserted == ["Sounds good, thanks!"])
        #expect(inserter.pids == [4242]) // the app summoned in, never whatever is key (our card)
        #expect(bridge.asked.count == 1)
        _ = coordinator
    }

    @Test func aFailedInsertKeepsTheCardAndSaysWhy() async {
        bridge.setScript([Self.done(BuddyBlock(say: "Draft.", shape: .card, insert: "text"))])
        inserter.problem = "Click the field you want it in, then try again."
        let coordinator = makeCoordinator(context: .packet(editable: .init(field: true, selection: true)))
        await tapToTalk(coordinator)
        overlay.send(.mainAction(.replace))
        await settle(until: { overlay.calls.contains(.toast("Click the field you want it in, then try again.")) })
        #expect(!overlay.calls.contains(.dismiss(.requested)))
        #expect(overlay.calls.filter { if case .answer = $0 { true } else { false } }.count == 1) // no chip over it
        inserter.problem = nil
        overlay.send(.mainAction(.replace)) // still there to try again
        await settle(until: { inserter.inserted.count == 2 })
        #expect(inserter.inserted == ["text", "text"])
        _ = coordinator
    }

    @Test func aModelActionGoesToDeepBesideTheMainButton() async {
        let block = BuddyBlock(say: "Here's a draft.", shape: .card,
                               actions: [.init(label: "Warmer", prompt: "Make it warmer")], insert: "Draft")
        bridge.setScript([Self.done(block)])
        let coordinator = makeCoordinator(context: .packet(editable: .init(field: true, selection: false)))
        await tapToTalk(coordinator)
        overlay.send(.action(index: 0)) // never an insert any more
        await settle(until: { bridge.asked.count == 2 && coordinator.phase != .thinking })
        #expect(inserter.inserted.isEmpty)
        #expect(bridge.asked.last?.packet.utterance == "Make it warmer")
        _ = coordinator
    }

    @Test func aSecondPressAfterInsertingDoesNothing() async {
        bridge.setScript([Self.done(BuddyBlock(say: "Draft.", shape: .card, insert: "one"))])
        let coordinator = makeCoordinator(context: .packet(editable: .init(field: true, selection: true)))
        await tapToTalk(coordinator)
        overlay.send(.mainAction(.replace))
        await settle(until: { overlay.calls.contains(.dismiss(.requested)) })
        overlay.send(.mainAction(.replace))
        for _ in 0..<100 { await Task.yield() }
        #expect(inserter.inserted == ["one"])
        _ = coordinator
    }

    @Test func theCopyButtonCopiesAndAStaleEventIsIgnored() async {
        bridge.setScript([Self.done(BuddyBlock(say: "Here.", shape: .card, insert: "text"))])
        let coordinator = makeCoordinator() // no editable field in front
        await tapToTalk(coordinator)
        overlay.send(.mainAction(.insert)) // not the shown button
        overlay.send(.mainAction(.copy))
        await settle(until: { overlay.calls.contains(.copyAnswer) })
        #expect(overlay.calls.contains(.copyAnswer))
        #expect(inserter.inserted.isEmpty)
        _ = coordinator
    }

    @Test func aChipsOneButtonIsTheMainOne() async {
        let block = BuddyBlock(say: "Copy this.", shape: .chip,
                               actions: [.init(label: "Explain", prompt: "Explain it")], insert: "abc")
        bridge.setScript([Self.done(block)])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        #expect(overlay.calls.contains { if case .answer(let a, _, _) = $0 { a.mainAction == .copy } else { false } })
        overlay.send(.action(index: 0)) // hidden: the chip shows Copy instead
        for _ in 0..<100 { await Task.yield() }
        #expect(bridge.asked.count == 1)
        _ = coordinator
    }

    @Test(arguments: [
        (ContextPacket.Editable?.some(.init(field: true, selection: true)), ContextPacket.AppKind.browser, "insert", MainAction?.some(.replace)),
        (.init(field: true, selection: false), .other, "insert", .insert),
        (.init(field: true, selection: true), .terminal, "insert", .copy), // never into a shell
        (nil, .document, "insert", .copy),
        (.init(field: true, selection: false), .other, "", .copy), // card HTML only: copy, not insert
        (nil, .other, "none", nil),
        (.init(field: true, selection: false), .other, "blank", nil), // whitespace: nothing to put in
    ])
    func mainButtonChoice(editable: ContextPacket.Editable?, kind: ContextPacket.AppKind, content: String, expected: MainAction?) {
        var packet = ContextPacket(askedAt: Date(), utterance: "")
        packet.app = .init(name: "x", bundle: nil, kind: kind)
        packet.editable = editable
        let block = BuddyBlock(say: "Spoken headline.", shape: .card,
                               cardHTML: content == "" ? "<p>card</p>" : nil,
                               insert: content == "insert" ? "body" : content == "blank" ? " \n" : nil)
        #expect(BuddyCoordinator.mainAction(for: block, packet: packet) == expected)
    }

    @Test func insertOffMeansCopyOnlyAndTheModelIsTold() async {
        bridge.setScript([Self.done(BuddyBlock(say: "Draft.", shape: .card, insert: "text"))])
        var settings = BuddyCoordinator.Settings()
        settings.insert = false
        let coordinator = makeCoordinator(context: .packet(editable: .init(field: true, selection: true)), settings: settings)
        await tapToTalk(coordinator)
        #expect(bridge.asked.first?.packet.features == ContextPacket.Features(rings: true, insert: false))
        #expect(bridge.asked.first?.packet.editable != nil) // kept: the model may still say "select it and Copy"
        #expect(overlay.calls.contains { if case .answer(let a, _, _) = $0 { a.mainAction == .copy } else { false } })
        overlay.send(.mainAction(.replace)) // never shown, never run
        for _ in 0..<100 { await Task.yield() }
        #expect(inserter.inserted.isEmpty)
        _ = coordinator
    }

    @Test func everythingOnLeavesFeaturesOut() async throws {
        bridge.setScript([Self.done(BuddyBlock(say: "Yes.", shape: .chip))])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        let packet = try #require(bridge.asked.first?.packet)
        #expect(packet.features == nil)
        #expect(!String(decoding: try ContextPacket.makeEncoder().encode(packet), as: UTF8.self).contains("features"))
        var off = packet
        off.features = .init(rings: false, insert: true)
        #expect(String(decoding: try ContextPacket.makeEncoder().encode(off), as: UTF8.self)
            .contains(#""features":{"insert":true,"rings":false}"#))
        _ = coordinator
    }

    @Test func approvalCardsHaveNoMainButton() {
        let block = BuddyBlock(say: "Convert?", shape: .rich, insert: "x", needsApproval: true)
        var packet = ContextPacket(askedAt: Date(), utterance: "")
        packet.editable = .init(field: true, selection: false)
        #expect(BuddyCoordinator.mainAction(for: block, packet: packet) == nil)
    }

    @Test func visibleActionsMirrorTheOverlay() {
        let three = (1...3).map { BuddyBlock.Action(label: "\($0)", prompt: "p") }
        #expect(BuddyCoordinator.visibleActions(BuddyBlock(say: "", shape: .card, actions: three), mainAction: .copy) == 2)
        #expect(BuddyCoordinator.visibleActions(BuddyBlock(say: "", shape: .card, actions: three)) == 3)
        #expect(BuddyCoordinator.visibleActions(BuddyBlock(say: "", shape: .chip, actions: three), mainAction: .copy) == 0)
        #expect(BuddyCoordinator.visibleActions(BuddyBlock(say: "", shape: .chip, actions: three)) == 1)
        #expect(BuddyCoordinator.visibleActions(BuddyBlock(say: "", shape: .card, actions: three, needsApproval: true)) == 2)
        #expect(BuddyCoordinator.visibleActions(BuddyBlock(say: "", shape: .chip, actions: three, needsApproval: true)) == 0)
    }

    @Test func goDeeperRerunsInDeepWithoutSpeaking() async {
        bridge.setScript([Self.done(BuddyBlock(say: "Short answer.", shape: .chip))])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        await settle(until: { voice.calls.contains(.speak("Short answer.")) }) // the first answer, after its card
        let spokenBefore = voice.calls.count

        overlay.send(.goDeeper)
        await settle(until: { bridge.deeperCount == 1 && coordinator.phase != .thinking })
        #expect(bridge.deeperCount == 1)
        #expect(!voice.calls.dropFirst(spokenBefore).contains { if case .speak = $0 { true } else { false } })
        _ = coordinator
    }

    @Test func aLongQuickConversationSaysSoOnce() async {
        var long = Self.done(BuddyBlock(say: "Yes.", shape: .chip))
        if case .done(var r) = long { r.outcome?.result.contextTokens = 60_000; long = .done(r) }
        bridge.setScript([long, long])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        await settle(until: { coordinator.phase == .showing })
        await tapToTalk(coordinator)
        await settle(until: { coordinator.phase == .showing })
        let headers = overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a.headerLabel } else { nil } }
        #expect(headers.last?.hasSuffix(" · long") == true)
        #expect(overlay.calls.filter { $0 == .toast("Long conversation · ⇧ + ⌥ starts fresh") }.count == 1)
    }

    @Test func newConversationStartsFreshId() async {
        bridge.setScript([Self.done(BuddyBlock(say: "One.", shape: .chip))])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        overlay.send(.newConversation)
        await settle()
        await tapToTalk(coordinator)
        #expect(bridge.asked[0].packet.conversation?.id != bridge.asked[1].packet.conversation?.id)
        #expect(bridge.asked[1].packet.conversation?.turn == 1)
    }

    // MARK: - Pure helpers

    @Test func remainderAfterSpokenFirstSentence() {
        #expect(BuddyCoordinator.remainder(of: "A b. C d.", after: "A b.") == "C d.")
        #expect(BuddyCoordinator.remainder(of: "A b.", after: "A b.") == "")
        #expect(BuddyCoordinator.remainder(of: "A b.", after: nil) == "A b.")
        #expect(BuddyCoordinator.remainder(of: "Different.", after: "A b.") == "Different.") // never silent
        #expect(BuddyCoordinator.remainder(of: "A  b.\nC d.", after: "A b.") == "C d.") // whitespace-insensitive
    }
}

@MainActor
struct ConversationBookTests {
    final class Clock: @unchecked Sendable {
        // Mutated only from the test's main actor; read synchronously by the book.
        var now = Date(timeIntervalSince1970: 0)
    }

    @Test func idleThirtyMinutesStartsFresh() {
        let clock = Clock()
        var book = ConversationBook(clock: { clock.now })
        let first = book.prepare(project: nil)
        _ = book.recordTurn(conversationID: first.state.id, question: "q", answer: "a")
        clock.now += 29 * 60
        #expect(book.prepare(project: nil).state.id == first.state.id)
        clock.now += 31 * 60
        #expect(book.prepare(project: nil).state.id != first.state.id)
    }

    @Test func differentProjectStartsFreshButEmptyConversationAdoptsIt() {
        var book = ConversationBook(clock: { Date() })
        let first = book.prepare(project: nil)
        #expect(book.prepare(project: "/w/a").state.id == first.state.id) // adopted, no turns yet
        _ = book.recordTurn(conversationID: first.state.id, question: "q", answer: "a")
        #expect(book.prepare(project: "/w/a").state.id == first.state.id)
        #expect(book.prepare(project: nil).state.id == first.state.id) // nothing in front: continue
        #expect(book.prepare(project: "/w/b").state.id != first.state.id)
    }

    @Test func recordTurnIgnoresStaleConversation() {
        var book = ConversationBook(clock: { Date() })
        let old = book.startNew()
        book.startNew()
        #expect(book.recordTurn(conversationID: old.state.id, question: "q", answer: "a") == nil)
        #expect(book.current?.turn == 0)
    }

    @Test func coloursRotate() {
        var book = ConversationBook(clock: { Date() })
        let colours = (0..<5).map { _ in book.startNew().color }
        #expect(colours == [.ember, .mist, .sage, .amber, .ember])
    }

    @Test func keepsLastThreeTurns() {
        var book = ConversationBook(clock: { Date() })
        let id = book.startNew().state.id
        for i in 1...5 { _ = book.recordTurn(conversationID: id, question: "q\(i)", answer: "a\(i)") }
        #expect(book.current?.previous.count == 3)
        #expect(book.current?.previous.first?.hasPrefix("Q: q3") == true)
    }
}

@MainActor
struct ScreenTokenTests {
    static func shot(_ shade: CGFloat) -> CapturedShot {
        let ctx = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: shade, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        let screenshot = Screenshot(file: URL(fileURLWithPath: "/dev/null"), fileData: Data(), fileWidth: 64, fileHeight: 40,
                                    full: ctx.makeImage()!, displayID: 1, scale: 1, displayFrame: CGRect(x: 0, y: 0, width: 64, height: 40))
        return CapturedShot(path: "/tmp/s.jpg", data: Data([1]), mediaType: "image/jpeg", screenshot: screenshot)
    }

    @Test func aSummonMatchesThePreviousScreenOnlyWhenItIsTheSame() async throws {
        let context = SummonContext(result: .noFrontApp)
        let first = await BuddyCoordinator.summon(context, .shot(Self.shot(1)), comparedWith: nil)
        let fingerprint = try #require(first.fingerprint)
        #expect(first.sameAs == nil)
        let same = await BuddyCoordinator.summon(context, .shot(Self.shot(1)), comparedWith: (fingerprint, "t1"))
        #expect(same.sameAs == "t1")
        let changed = await BuddyCoordinator.summon(context, .shot(Self.shot(0.2)), comparedWith: (fingerprint, "t1"))
        #expect(changed.sameAs == nil)
        let failed = await BuddyCoordinator.summon(context, .unavailable(.captureFailed), comparedWith: (fingerprint, "t1"))
        #expect(failed.sameAs == nil && failed.fingerprint == nil && failed.unavailable == .captureFailed)
    }

    @Test func onlyACaretSizedRectIsExempt() {
        var p = ContextPacket(askedAt: Date(), utterance: "")
        p.selection = .init(text: nil, bounds: .init(x: 100, y: 200, width: 1, height: 18))
        #expect(BuddyCoordinator.caret(in: p) == CGRect(x: 100, y: 200, width: 1, height: 18))
        p.selection = .init(text: nil, bounds: .init(x: 100, y: 200, width: 600, height: 18))
        #expect(BuddyCoordinator.caret(in: p) == nil, "a whole-line rect would hide real changes")
        p.selection = .init(text: nil, bounds: .init(x: 100, y: 200, width: 2, height: 400))
        #expect(BuddyCoordinator.caret(in: p) == nil)
        p.selection = .init(text: "refund", bounds: .init(x: 100, y: 200, width: 1, height: 18))
        #expect(BuddyCoordinator.caret(in: p) == nil, "a selection isn't a caret")
    }
}
