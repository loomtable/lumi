import Foundation

/// A teammate's lane as its subagent transcript has it, for a page opened after the teammate
/// started (QA U30): its words, and its tool steps with their real times.
public struct LaneHistory: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        /// A `.step` or `.stepFinished` for the lane, as the live stream would have sent it.
        public var event: SessionEvent
        public var at: Date

        public init(_ event: SessionEvent, at: Date) {
            self.event = event
            self.at = at
        }
    }

    public var texts: [String]
    public var steps: [Step]

    public init(texts: [String] = [], steps: [Step] = []) {
        self.texts = texts
        self.steps = steps
    }
}
