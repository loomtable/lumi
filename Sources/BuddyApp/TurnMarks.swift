import BuddyCore
import BuddyTrace

/// A session turn's latency marks (QA U48): its first stream event, its first spoken line and its
/// answer appearing. The Glance marks the last two itself (`present`, `markSpoken`); a turn read in a
/// page (Panel or Studio) gets all three here, from the coordinator and from `PageFlow` alike.
struct TurnMarks {
    struct Mark: Equatable {
        var event: TraceEvent
        var outcome: TraceOutcome?
    }

    private var first = false
    private var spoken = false

    /// What `event` completes. `inPage`: the page renders the turn. `speaks`: the page speaks its
    /// answer ("Speak answers").
    mutating func marks(for event: SessionEvent, inPage: Bool, speaks: Bool) -> [Mark] {
        var out: [Mark] = []
        if !first {
            first = true
            out.append(Mark(event: .quickFirstEvent))
        }
        guard inPage else { return out }
        switch event {
        case .sayFirstSentence, .say:
            if speaks, !spoken {
                spoken = true
                out.append(Mark(event: .firstSpokenWord))
            }
        case .turnEnded(let end):
            // A typed answer with no spoken line: the page speaks its first sentence now.
            if speaks, !spoken, !end.isError {
                spoken = true
                out.append(Mark(event: .firstSpokenWord))
            }
            out.append(Mark(event: .answerShown, outcome: end.isError ? .failed : .ok))
        default:
            break
        }
        return out
    }
}
