import Foundation

/// A session's teammates, folded from its task events (02 §D4, 04 §5). The session's read model
/// and its page both run this one reducer, so the sidebar, switcher, Panel and Studio agree. Pure.
///
/// - One entry per task, from `task_started` to `task_notification`, in start order. Nothing
///   removes an entry mid-run.
/// - States only move forward (working ⇄ needs you → done, failed or stopped): a late, repeated or
///   out-of-order event never brings an ended teammate back, and step counts never drop.
/// - The team stays live between the lead's interim answers, until the lead answers after the
///   last teammate ended (the merged answer). The next teammate after that starts a new team.
public struct TeamRoster: Sendable, Equatable {
    public private(set) var members: [TeammateSnapshot] = []
    public private(set) var isLive = false

    public init() {}

    /// The members to show live: all of them while the team works, none once it has settled.
    public var live: [TeammateSnapshot] { isLive ? members : [] }

    /// A teammate still works or waits on the user: the running indicators' share of the team.
    /// A team that has handed back stays live until the lead answers, but nothing runs in it.
    public var isWorking: Bool { live.contains { $0.state.isRunning } }

    /// "2 of 3 done": teammates that ended (done, failed or stopped) of the team. Nil with no team.
    public static func summary(of members: [TeammateSnapshot]) -> String? {
        guard !members.isEmpty else { return nil }
        return "\(members.count { !$0.state.isRunning }) of \(members.count) done"
    }

    public mutating func apply(_ event: SessionEvent, at now: Date) {
        switch event {
        case .task(.started(let taskID, let toolUseID, let name, let description, let kind)):
            guard kind != .bash, !members.contains(where: { $0.id == taskID }) else { return }
            if !isLive { members = [] }
            isLive = true
            let resolved = [name, Self.role(from: description)].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "Teammate \(members.count + 1)"
            members.append(TeammateSnapshot(id: taskID, toolUseID: toolUseID ?? taskID, name: resolved, state: .working,
                                            brief: description.isEmpty ? nil : description, startedAt: now))
        case .task(.progress(let taskID, _, let line, let steps)):
            guard let i = members.firstIndex(where: { $0.id == taskID }), members[i].state.isRunning else { return }
            // The CLI repeats the brief as the line when the teammate hands back: keep its last step.
            if let line, !line.isEmpty, line != members[i].brief { members[i].liveLine = line }
            if let steps { members[i].steps = max(members[i].steps, steps) }
            members[i].lastEventAt = now
        case .step(let step) where step.subagent != nil:
            if let i = members.firstIndex(where: { $0.toolUseID == step.subagent }) { members[i].lastEventAt = now }
        case .text(_, let subagent?):
            if let i = members.firstIndex(where: { $0.toolUseID == subagent }) { members[i].lastEventAt = now }
        case .task(.ended(let taskID, let status, _)):
            guard let i = members.firstIndex(where: { $0.id == taskID }), members[i].state.isRunning else { return }
            members[i].state = switch status {
            case .completed: .done
            case .failed: .failed
            case .stopped: .stopped
            }
            members[i].liveLine = nil
            members[i].endedAt = now
        case .turnStarted(.some, let kind) where kind != .steer:
            // The user moved on: a team that has handed back is over, answer or not.
            settle()
        case .turnEnded:
            // The lead answered after the team: it folds away (04 §5.3).
            settle()
        case .processEnded:
            // Teammates die with the process.
            for i in members.indices where members[i].state.isRunning {
                members[i].state = .stopped
                members[i].liveLine = nil
                members[i].endedAt = now
            }
            isLive = false
        default:
            break
        }
    }

    /// Teammates waiting on a permission (by asker name) need you; the rest go back to working.
    public mutating func waiting(on askers: Set<String>) {
        for i in members.indices {
            if askers.contains(members[i].name) {
                if members[i].state == .working { members[i].state = .needsYou }
            } else if members[i].state == .needsYou {
                members[i].state = .working
            }
        }
    }

    /// A member the store knew before this roster saw it (a page opened mid-run, QA U30). A known
    /// member only moves forward; `live` turns the team on, never off.
    public mutating func adopt(_ mate: TeammateSnapshot, live: Bool) {
        if let i = members.firstIndex(where: { $0.id == mate.id }) {
            guard members[i].state.isRunning else { return }
            let steps = max(members[i].steps, mate.steps)
            members[i] = mate
            members[i].steps = steps
        } else {
            if !isLive, live { members = [] }
            members.append(mate)
        }
        if live { isLive = true }
    }

    /// An edited prompt replaced the turns this team worked in: it goes with them.
    public mutating func clear() {
        members = []
        isLive = false
    }

    /// The team is over once nobody works.
    public mutating func settle() {
        if !members.contains(where: \.state.isRunning) { isLive = false }
    }

    /// "Research the March invoices" → nil; the description is a name only when it's one word.
    static func role(from description: String) -> String? {
        let words = description.split(separator: " ")
        return words.count == 1 ? String(words[0]).capitalized : nil
    }
}
