import CoreGraphics
import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

/// Records what the coordinator asks of Research and lets the test finish a job.
@MainActor final class FakeResearch: ResearchPort {
    var onDone: ((ResearchJob) -> Void)?
    private(set) var activations = 0
    private(set) var started: [ResearchRequest] = []
    private(set) var handled: [OverlayEvent] = []
    /// The jobs `start` returned, in order.
    private(set) var jobs: [ResearchJob] = []

    func activate() { activations += 1 }
    func start(_ request: ResearchRequest) async -> ResearchJob {
        started.append(request)
        let started = job(request.topic, conversation: request.conversationID)
        jobs.append(started)
        return started
    }
    func handle(_ event: OverlayEvent) async -> Bool {
        handled.append(event)
        return true
    }
}

/// Research hand-offs start a background job; the capsule's events reach it.
@MainActor
struct ResearchFlowTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()
    let research = FakeResearch()

    func make(_ bridge: FakeBridge, voiceReplies: BuddyCoordinator.Settings.VoiceReplies = .onlyWhenSpoken,
              sounds: Bool = true, context: FakeContext = FakeContext.packet()) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = sounds
        settings.voiceReplies = voiceReplies
        let coordinator = BuddyCoordinator(
            settings: settings, voice: voice, context: context, turns: bridge,
            overlay: overlay, pointer: FixedPointer(), research: research)
        coordinator.start()
        return coordinator
    }

    func settle(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func ask(_ coordinator: BuddyCoordinator) async {
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.holdBegan))
        await coordinator.handle(.gesture(.holdEnded))
    }

    static let handoff: [CascadeEvent] = [
        .researchRequested(say: "On it. I'll let you know when it's done."),
        BuddyCoordinatorTests.done(
            BuddyBlock(say: "On it. I'll let you know when it's done.", shape: .chip, handoff: .research), lane: .quick),
    ]

    var answers: [String] { overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a.block.say } else { nil } } }

    @Test func startActivatesTheCapsuleOnce() {
        let coordinator = make(FakeBridge())
        #expect(research.activations == 1)
        withExtendedLifetime(coordinator) {}
    }

    @Test func quickHandoffStartsAJobWithTheUsersWords() async {
        voice.setTranscript("research how QT hit mortgage rates")
        let coordinator = make(FakeBridge(script: Self.handoff))
        await ask(coordinator)
        await settle(until: { !research.started.isEmpty && coordinator.phase == .idle })

        let request = research.started.first
        #expect(request?.topic == "how QT hit mortgage rates") // what the capsule and ready line say
        #expect(request?.packet.utterance == "research how QT hit mortgage rates") // the job gets every word
        #expect(request?.packet.app?.name == "Safari")
        #expect(request?.conversationID.isEmpty == false)
        #expect(coordinator.phase == .idle) // the buddy stays free
        #expect(overlay.calls.contains(.toast("Running in the background")))
        #expect(answers.isEmpty)
        #expect(voice.calls.contains(.speak("On it. I'll let you know when it's done.")))
    }

    @Test func routerStartedResearchStartsAJobAndSaysSo() async {
        // "research …" said first goes straight to Research: as the real cascade sends it, no
        // block, no lane and no line.
        let coordinator = make(FakeBridge(script: [
            .researchRequested(say: nil),
            .done(CascadeResult(lane: nil, outcome: nil, state: ConversationState(id: ""))),
        ]))
        await ask(coordinator)
        await settle(until: { research.started.count == 1 })
        #expect(research.started.count == 1)
        #expect(voice.calls.contains(.speak("On it. I'll let you know when it's done.")))
    }

    @Test func aBlocksHandoffAloneNeverStartsResearch() async {
        // Deep (or an action's turn) returning handoff "research": no cascade request, no job.
        let coordinator = make(FakeBridge(script: [
            BuddyCoordinatorTests.done(BuddyBlock(say: "Researching.", shape: .chip, handoff: .research), lane: .deep),
        ]))
        await ask(coordinator)
        await settle(until: { coordinator.phase == .showing })
        #expect(research.started.isEmpty)
        #expect(answers == ["Claude Code finished without an answer I can show."])
    }

    @Test func theJobsPacketCarriesNoScreenshotPath() async {
        var context = FakeContext.packet()
        context.shot?.detail = ScreenshotDetail(data: Data([9]), rect: CGRect(x: 1, y: 2, width: 3, height: 4), width: 6, height: 8)
        let coordinator = make(FakeBridge(script: Self.handoff), context: context)
        await ask(coordinator)
        await settle(until: { !research.started.isEmpty })
        #expect(research.started.first?.packet.screenshot == nil)
        #expect(research.started.first?.packet.screenshotDetail == nil, "no close-up goes with a job")
    }

    @Test func capsuleEventsReachResearch() async {
        let coordinator = make(FakeBridge())
        let id = UUID()
        overlay.send(.stopResearch(id))
        overlay.send(.openReport(id))
        await settle(until: { research.handled.count == 2 })
        #expect(research.handled == [.stopResearch(id), .openReport(id)])
        withExtendedLifetime(coordinator) {}
    }

    @Test func aReportCardsButtonsAndReplyDontActOnTheLastAnswer() async {
        let block = BuddyBlock(say: "Your filter drops it.", shape: .card,
                               actions: [.init(label: "Loosen it", prompt: "Loosen the filter")])
        let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(block)])
        let coordinator = make(bridge)
        await ask(coordinator)
        await settle(until: { coordinator.phase == .showing })

        overlay.send(.openReport(UUID()))
        overlay.send(.action(index: 0))
        overlay.send(.submitted(text: "and in 2024?", source: .reply))
        await settle(until: { research.handled.count == 1 })
        for _ in 0..<100 { await Task.yield() }
        #expect(coordinator.phase == .showing) // the report card is on screen; Esc closes it
        #expect(bridge.asked.count == 1)
    }

    @Test func aReportNeverOpensOverALiveMic() async {
        let coordinator = make(FakeBridge())
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        overlay.send(.openReport(UUID()))
        for _ in 0..<100 { await Task.yield() }
        #expect(research.handled.isEmpty)
        #expect(coordinator.phase == .listening(confirmedTap: false, holding: false))
    }

    @Test func aFinishedJobChimesAndSpeaksItsLine() async {
        let coordinator = make(FakeBridge())
        research.onDone?(job("QT") { $0.say = "Your research on QT is ready: rates rose about half a point." })
        await settle(until: { voice.calls.contains { if case .speak = $0 { true } else { false } } })
        #expect(voice.calls.contains(.play(.researchDone)))
        #expect(voice.calls.contains(.speak("Your research on QT is ready: rates rose about half a point.")))
        withExtendedLifetime(coordinator) {}
    }

    @Test func aJobWithoutALineUsesTheReadyLine() async {
        let coordinator = make(FakeBridge(), voiceReplies: .always)
        research.onDone?(job("QT"))
        await settle(until: { voice.calls.contains(.speak("Your research on QT is ready.")) })
        #expect(voice.calls.contains(.speak("Your research on QT is ready.")))
        withExtendedLifetime(coordinator) {}
    }

    @Test func aTypedRequestsDoneLineIsSilent() async {
        let coordinator = make(FakeBridge(script: Self.handoff))
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.doubleTap))
        overlay.send(.submitted(text: "research QT and mortgages", source: .textBox))
        await settle(until: { research.jobs.count == 1 && coordinator.phase == .idle })

        // "Only when I spoke": a typed request's report is announced by the chime alone.
        guard research.jobs.count >= 1 else { Issue.record("jobs: \(research.jobs.count) of 1"); return }
        research.onDone?(research.jobs[0])
        await settle(until: { voice.calls.contains(.play(.researchDone)) })
        for _ in 0..<100 { await Task.yield() }
        #expect(!voice.calls.contains { if case .speak = $0 { true } else { false } })

        // A spoken request's report is read out.
        await ask(coordinator)
        await settle(until: { research.jobs.count == 2 && coordinator.phase == .idle })
        guard research.jobs.count >= 2 else { Issue.record("jobs: \(research.jobs.count) of 2"); return }
        research.onDone?(research.jobs[1])
        await settle(until: { voice.calls.contains(.speak("Your research on what does this mean? is ready.")) })
        #expect(voice.calls.contains(.speak("Your research on what does this mean? is ready.")))
    }

    @Test func doneWhileAnAnswerIsShowingOnlyChimes() async {
        let coordinator = make(FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .chip))]))
        await ask(coordinator)
        await settle(until: { coordinator.phase == .showing && voice.calls.contains(.speak("Yes.")) })
        let before = voice.calls.count { if case .speak = $0 { true } else { false } }
        research.onDone?(job("QT"))
        await settle(until: { voice.calls.contains(.play(.researchDone)) })
        for _ in 0..<100 { await Task.yield() }
        #expect(voice.calls.count { if case .speak = $0 { true } else { false } } == before)
    }

    @Test func pausedDoesNothing() async {
        let coordinator = make(FakeBridge())
        await coordinator.setPaused(true)
        research.onDone?(job("QT"))
        for _ in 0..<100 { await Task.yield() }
        #expect(!voice.calls.contains(.play(.researchDone)))
        #expect(!voice.calls.contains { if case .speak = $0 { true } else { false } })
    }

    @Test func voiceRepliesOffOnlyChimes() async {
        let coordinator = make(FakeBridge(), voiceReplies: .off)
        research.onDone?(job("QT"))
        await settle(until: { voice.calls.contains(.play(.researchDone)) })
        for _ in 0..<100 { await Task.yield() }
        #expect(!voice.calls.contains { if case .speak = $0 { true } else { false } })
        withExtendedLifetime(coordinator) {}
    }

    @Test func soundsOffSkipsTheChime() async {
        let coordinator = make(FakeBridge(), sounds: false)
        research.onDone?(job("QT"))
        await settle(until: { voice.calls.contains(.speak("Your research on QT is ready.")) })
        #expect(!voice.calls.contains(.play(.researchDone)))
        withExtendedLifetime(coordinator) {}
    }

    @Test(arguments: [
        ("research quantitative tightening", "quantitative tightening"),
        ("Research: the Fed's QT plan.", "the Fed's QT plan"),
        ("research about laptop batteries", "laptop batteries"),
        ("research", "research"), // nothing after the command: keep what was said
        ("what are the best laptops in 2026", "what are the best laptops in 2026"), // a Quick hand-off
        ("researchers say coffee helps", "researchers say coffee helps"),
    ])
    func theTopicDropsTheResearchCommand(question: String, topic: String) {
        #expect(BuddyCoordinator.researchTopic(question) == topic)
    }
}

