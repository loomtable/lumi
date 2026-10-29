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
        record?.bridgeState ?? ConversationState(id: id)
    }
}

extension ConversationRecord {
    /// The stored sessions, lane and Deep folder for the bridge. Deep's folder is the folder its
    /// newest session ran in, never the conversation's project folder (Quick-only turns set that,
    /// and a Quick project must not pass for Deep's folder). Every Deep session is kept by folder,
    /// and when Deep last answered, so a resumed conversation follows up on Deep as before.
    public var bridgeState: ConversationState {
        var state = ConversationState(id: id)
        state.quickSessionID = quickSessionID
        state.deepSessionID = deepSessionID
        state.lastLane = lastLane
        state.deepFolder = lastDeepFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
        state.deepSessions = deepSessions
        state.lastDeepAnswerAt = lastDeepAnswer
        return state
    }
}
