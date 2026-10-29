import BuddyCore
import Testing
@testable import BuddyOverlay

/// QA U16 and U17: status is never colour alone, and VoiceOver names what a mark stands for.
struct StatusWordsTests {
    private func mate(_ name: String, _ state: TeammateSnapshot.State, _ line: String? = nil) -> TeammateSnapshot {
        TeammateSnapshot(id: name, toolUseID: "tu-" + name, name: name, state: state, liveLine: line)
    }

    @Test func aPeekRowAlwaysHasAWord() {
        #expect(TeammateRow.line(mate("Scout", .needsYou, "Reading 4 sources")) == "Needs your OK")
        #expect(TeammateRow.line(mate("Scout", .working, "Reading 4 sources")) == "Reading 4 sources")
        #expect(TeammateRow.line(mate("Scout", .working)) == "Working")
        #expect(TeammateRow.line(mate("Scout", .failed, "Reading")) == "Didn't finish")
    }

    @Test func theDiscSaysTitleStateAndEveryBead() {
        #expect(SessionDisc.spoken(title: "Fix login", working: true, needsYou: false, teammates: []) == "Fix login, working")
        #expect(SessionDisc.spoken(title: nil, working: false, needsYou: false, teammates: []) == "Session")
        #expect(SessionDisc.spoken(title: "Q3", working: true, needsYou: true,
                                   teammates: [mate("Writer", .working), mate("Scout", .done), mate("Critic", .needsYou)])
            == "Q3, needs you, with Writer working, Scout done and Critic needs you")
    }

    @Test func theRecommendedChipSaysSoOnce() {
        #expect(QuestionCard.needsRecommendedWord("Q3 sheet"))
        #expect(!QuestionCard.needsRecommendedWord("Q3 sheet (Recommended)"))
    }
}
