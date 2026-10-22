import Foundation
import Testing
@testable import BuddyCore

@Test func transcriptTurnRoundTripsWithItsCard() throws {
    let turn = TranscriptTurn(id: "m-1", question: "Why is the list empty?",
                              block: BuddyBlock(say: "The fetch runs late.", shape: .rich, cardHTML: "<p>Detail</p>",
                                                actions: [BuddyBlock.Action(label: "Fix", prompt: "fix it")], needsApproval: true),
                              mode: .deep, model: .opus)
    let decoded = try JSONDecoder().decode(TranscriptTurn.self, from: JSONEncoder().encode(turn))
    #expect(decoded == turn)
}

@Test func transcriptTurnsGetDistinctIDsByDefault() {
    let block = BuddyBlock(say: "s", shape: .card)
    #expect(TranscriptTurn(question: "q", block: block, mode: .quick, model: .haiku).id
        != TranscriptTurn(question: "q", block: block, mode: .quick, model: .haiku).id)
}
