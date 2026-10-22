import BuddyCore
import Foundation

// The bridge's ConversationState (BuddyCore) in and out of the index. lastQuickAnswer is not
// stored: it only matters for "Go deeper" within a session.

extension TurnUpdate {
    /// From the state in the bridge's `.done` result.
    public init(_ state: ConversationState) {
        self.init(
            quickSessionID: state.quickSessionID, deepSessionID: state.deepSessionID, lastLane: state.lastLane,
            deepFolder: state.deepFolder?.path)
    }
}

extension PreparedConversation {
    /// What to hand `Cascade.ask(_, state:)`: the stored sessions, lane and folder, or an empty
    /// state for a conversation not saved yet.
    public var bridgeState: ConversationState {
        var state = ConversationState(id: id)
        if let record {
            state.quickSessionID = record.quickSessionID
            state.deepSessionID = record.deepSessionID
            state.lastLane = record.lastLane
            state.deepFolder = record.projectFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        return state
    }
}
