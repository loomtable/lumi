import AppKit
import BuddyCore
import Foundation
@testable import BuddyCompanion
@testable import BuddyOverlay

/// Fake sessions and pages for the gallery, built from the same events the engine sends.
@MainActor
enum GalleryData {
    static let now = Date()
    static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    static let numbers = ContextStrip(appName: "Numbers", bundleID: "com.apple.iWork.Numbers", title: "Q3 budget",
                                      detail: "B4:F19", readScreen: true)
    static let longTitle = "Reconcile the March vendor invoices against purchase orders and flag every mismatch over 5%"

    static let budgetOld = """
        ## March
        Rent: 12,000
        Payroll: 41,800
        Contractors: 6,200
        Software: 2,950
        """
    static let budgetNew = """
        ## March
        Rent: 12,000
        Payroll: 41,800
        Contractors: 9,400
        Software: 2,950
        One-off: Studio deposit 8,000
        Note: March is high because of the deposit.
        """

    static let answerMarkdown = """
        March is high because of **three one-off invoices**, not a run-rate change:

        1. The studio deposit (8,000), paid once.
        2. A contractor overlap in week 2 (3,200).
        3. Annual software renewals that landed early.

        ```swift
        let runRate = months.filter { !$0.isOneOff }.map(\\.total).average()
        ```

        Without them March sits at 41,950, in line with February.
        """

    // MARK: Pages

    static func page(_ id: String = "s_q3", title: String = "Q3 burn model", symbol: String? = "chart.line.downtrend.xyaxis")
        -> ConversationPage {
        ConversationPage(session: SessionID(rawValue: id), title: title, subtitle: "From Numbers", symbol: symbol)
    }

    static func steps(_ p: inout ConversationPage, from t0: Date, finish: Bool = true) {
        let reads = ["invoices-march.pdf", "invoices-feb.pdf", "po-ledger.csv", "vendors.md"]
        for (i, f) in reads.enumerated() {
            p.apply(.step(TrailStep(id: "r\(i)", kind: .read, verb: "Reading", object: f)), at: t0.addingTimeInterval(1 + Double(i)))
            if finish { p.apply(.stepFinished(id: "r\(i)", isError: false, preview: nil), at: t0.addingTimeInterval(1.5 + Double(i))) }
        }
        p.apply(.step(TrailStep(id: "g1", kind: .search, verb: "Searching for", object: "\"deposit\"")), at: t0.addingTimeInterval(6))
        if finish { p.apply(.stepFinished(id: "g1", isError: false, preview: nil), at: t0.addingTimeInterval(7)) }
        p.apply(.step(TrailStep(id: "b1", kind: .bash, verb: "Running", object: "Sum March by vendor",
                                detail: .command(description: "Sum March by vendor", command: "python3 sum.py --month 3 invoices/*.csv"))),
                at: t0.addingTimeInterval(9))
        if finish {
            p.apply(.stepFinished(id: "b1", isError: false, preview: "Acme 12,000\nNorthwind 9,400\nStudio Co 8,000\nTotal 49,950"),
                    at: t0.addingTimeInterval(12))
        }
        p.apply(.step(TrailStep(id: "e1", kind: .edit, verb: "Editing", object: "budget-notes.md",
                                detail: .diff(path: "budget-notes.md", old: budgetOld, new: budgetNew))),
                at: t0.addingTimeInterval(14))
        if finish { p.apply(.stepFinished(id: "e1", isError: false, preview: nil), at: t0.addingTimeInterval(15)) }
        p.apply(.step(TrailStep(id: "m1", kind: .mcp(server: "slack"), verb: "Checking", object: "Slack")), at: t0.addingTimeInterval(16))
        if finish { p.apply(.stepFinished(id: "m1", isError: false, preview: nil), at: t0.addingTimeInterval(18)) }
    }

    /// A first turn still running: context strip, question, live Trail, a streaming answer, a steer.
    static func running() -> ConversationPage {
        var p = page()
        let t0 = ago(41)
        p.send("Why is March so high?", kind: .typed, context: numbers, at: t0)
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0.addingTimeInterval(0.2))
        steps(&p, from: t0, finish: true)
        p.apply(.step(TrailStep(id: "r9", kind: .read, verb: "Reading", object: "march-contracts.pdf")), at: t0.addingTimeInterval(30))
        p.apply(.text("March is high because of **three one-off invoices**, not a run-rate", subagent: nil), at: t0.addingTimeInterval(35))
        p.send("Only count vendor invoices, not payroll", kind: .typed, context: nil, at: t0.addingTimeInterval(36))
        p.tick(at: now)
        return p
    }

    static func done(longTitle: Bool = false) -> ConversationPage {
        var p = page(title: longTitle ? Self.longTitle : "Q3 burn model")
        let t0 = ago(300)
        p.send("Why is March so high?", kind: .typed, context: numbers, at: t0)
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0)
        steps(&p, from: t0)
        p.apply(.turnEnded(TurnEnd(kind: .typed, markdown: answerMarkdown)), at: t0.addingTimeInterval(41))
        return p
    }

    static func approval(tier: ApprovalTier = .reversible, command: Bool = false, asker: String? = nil) -> ConversationPage {
        var p = page()
        let t0 = ago(70)
        p.send("Add a note to the budget about March", kind: .typed, context: numbers, at: t0)
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0)
        p.apply(.step(TrailStep(id: "r0", kind: .read, verb: "Reading", object: "budget-notes.md")), at: t0.addingTimeInterval(2))
        p.apply(.stepFinished(id: "r0", isError: false, preview: nil), at: t0.addingTimeInterval(3))
        let ask = command
            ? PermissionAsk(id: "p1", title: "Run `npm publish`", toolName: "Bash", detail: .command("npm publish --access public"),
                            tier: tier, asker: asker)
            : PermissionAsk(id: "p1", title: "Edit budget-notes.md", toolName: "Edit",
                            detail: .diff(path: "budget-notes.md", old: budgetOld, new: budgetNew), tier: tier, asker: asker)
        p.apply(.permissionRequested(ask), at: t0.addingTimeInterval(8))
        return p
    }

    static func question(multi: Bool = false) -> ConversationPage {
        var p = page(title: "Investor update draft", symbol: "square.and.pencil")
        let t0 = ago(20)
        p.send("Draft the investor update", kind: .typed, context: nil, at: t0)
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0)
        let item = QuestionAsk.Item(
            question: "Which numbers should lead the update?", header: "Lead with",
            options: [QuestionAsk.Option(label: "Revenue and burn", description: "The two numbers investors asked about last month."),
                      QuestionAsk.Option(label: "Runway", description: "Months left at the current burn."),
                      QuestionAsk.Option(label: "Hiring plan")],
            multiSelect: multi)
        p.apply(.questionAsked(QuestionAsk(id: "q1", items: [item])), at: t0.addingTimeInterval(4))
        return p
    }

    /// Two questions in one ask (Something else steps through both).
    static func questionTwo() -> ConversationPage {
        var p = page(title: "Investor update draft", symbol: "square.and.pencil")
        let t0 = ago(20)
        p.send("Draft the investor update", kind: .typed, context: nil, at: t0)
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0)
        let a = QuestionAsk.Item(question: "Which numbers should lead the update?", header: "Lead with",
                                 options: [.init(label: "Revenue and burn"), .init(label: "Runway")])
        let b = QuestionAsk.Item(question: "How long should it be?", header: "Length",
                                 options: [.init(label: "Five lines"), .init(label: "One page")])
        p.apply(.questionAsked(QuestionAsk(id: "q2", items: [a, b])), at: t0.addingTimeInterval(4))
        return p
    }

    static func plan() -> ConversationPage {
        var p = page(title: "Q3 variance", symbol: "tablecells")
        let t0 = ago(95)
        p.send("Rebuild the Q3 variance table and draft the note for finance", kind: .typed, context: numbers, at: t0)
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0)
        p.apply(.step(TrailStep(id: "t1", kind: .plan, verb: "Planning", detail: .todos([
            .init(content: "Pull March invoices and POs", state: .completed),
            .init(content: "Rebuild the variance table", state: .inProgress),
            .init(content: "Draft the note for finance", state: .pending),
        ]))), at: t0.addingTimeInterval(3))
        p.apply(.step(TrailStep(id: "r1", kind: .read, verb: "Reading", object: "po-ledger.csv")), at: t0.addingTimeInterval(50))
        p.tick(at: now)
        return p
    }

    static func teammates(needsYou: Bool = true) -> ConversationPage {
        var p = page(title: "Q3 variance", symbol: "tablecells")
        let t0 = ago(130)
        p.send("Split this three ways", kind: .typed, context: numbers, at: t0)
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0)
        for (i, (name, brief)) in [("Researcher", "Pull March invoices and POs"), ("Analyst", "Rebuild the variance table"),
                                   ("Writer", "Draft the note for finance")].enumerated() {
            p.apply(.step(TrailStep(id: "a\(i)", kind: .agent, verb: "Briefing", object: name)), at: t0.addingTimeInterval(2))
            p.apply(.task(.started(taskID: "task\(i)", toolUseID: "a\(i)", name: name, description: brief, kind: .agent)),
                    at: t0.addingTimeInterval(3))
        }
        p.apply(.step(TrailStep(id: "x1", kind: .read, verb: "Reading", object: "invoices-march.pdf", subagent: "a0")), at: t0.addingTimeInterval(5))
        p.apply(.task(.progress(taskID: "task0", lastTool: "Read", line: "Reading 4 sources")), at: t0.addingTimeInterval(6))
        p.apply(.task(.progress(taskID: "task1", lastTool: "Bash", line: "Running the variance script")), at: t0.addingTimeInterval(6))
        p.apply(.text("Pulled 14 invoices and 11 POs. Three invoices have no PO.", subagent: "a0"), at: t0.addingTimeInterval(60))
        if needsYou {
            p.apply(.permissionRequested(PermissionAsk(id: "p9", title: "Edit variance.csv", toolName: "Edit",
                                                       detail: .diff(path: "variance.csv", old: "a,b\n1,2", new: "a,b\n1,3"),
                                                       tier: .reversible, asker: "Analyst")), at: t0.addingTimeInterval(100))
        }
        p.apply(.task(.ended(taskID: "task2", status: .completed, summary: "Drafted a 4-line note for finance.")), at: t0.addingTimeInterval(110))
        p.tick(at: now)
        return p
    }

    static func stopped() -> ConversationPage {
        var p = page()
        let t0 = ago(60)
        p.send("Why is March so high?", kind: .typed, context: numbers, at: t0)
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0)
        steps(&p, from: t0)
        p.apply(.text("March is high because of three one-off", subagent: nil), at: t0.addingTimeInterval(20))
        p.stop(at: t0.addingTimeInterval(22))
        return p
    }

    static func failed() -> ConversationPage {
        var p = page()
        let t0 = ago(60)
        p.send("Why is March so high?", kind: .typed, context: numbers, at: t0)
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0)
        steps(&p, from: t0)
        p.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "", isError: true,
                                   error: SessionFailure(reason: .api("overloaded"), lastStep: "checking Slack", retryable: true))),
                at: t0.addingTimeInterval(25))
        return p
    }

    static func interrupted() -> ConversationPage {
        var p = page()
        let t0 = ago(60)
        p.send("Why is March so high?", kind: .typed, context: numbers, at: t0)
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0)
        steps(&p, from: t0)
        p.apply(.processEnded(status: 9, midTurn: true), at: t0.addingTimeInterval(25))
        return p
    }

    static func retrying() -> ConversationPage {
        var p = page()
        let t0 = ago(30)
        p.send("Why is March so high?", kind: .typed, context: numbers, at: t0)
        p.apply(.turnStarted(userUUID: "u1", kind: .typed), at: t0)
        p.apply(.retrying(attempt: 2, delayMS: 12_000, reason: "overloaded"), at: now.addingTimeInterval(-1))
        return p
    }

    /// A page opened from history: what Studio and the Panel load when a session is reopened.
    static func history() -> ConversationPage {
        var p = page()
        p.load(history: [historyTurn], at: ago(3600))
        return p
    }

    /// A typed turn as TranscriptReader returns it: `block.say` is the first line, `markdown` the answer.
    static let historyTurn = TranscriptTurn(
        id: "h1", question: "Why is March so high?",
        block: BuddyBlock(say: "March is high because of **three one-off invoices**, not a run-rate change:", shape: .rich),
        mode: .deep, model: ModelID(rawValue: "claude-opus-5-5"), kind: .typed, markdown: answerMarkdown, teammates: ["Researcher"])

    static func model(_ page: ConversationPage, app: String? = "Numbers", draft: String = "", listening: Bool = false,
                      withScreen: Bool = true, attachments: [PageAttachment] = [], lane: String? = nil)
        -> ConversationPageModel {
        let m = ConversationPageModel(page: page, withScreen: withScreen, screenAppName: app)
        m.draft = draft
        m.listening = listening
        m.attachments = attachments
        m.openLane = lane
        m.clock = { now }
        return m
    }

    // MARK: Sessions (switcher, Studio)

    static let safari = SessionOrigin(key: ContextKey(bundleID: "com.apple.Safari", target: "lisbon"), appName: "Safari",
                                      windowTitle: "Lisbon hotels")
    static let xcode = SessionOrigin(key: ContextKey(bundleID: "com.apple.dt.Xcode"), appName: "Xcode", windowTitle: "AuthKit")
    static let numbersOrigin = SessionOrigin(key: ContextKey(bundleID: "com.apple.iWork.Numbers"), appName: "Numbers",
                                             windowTitle: "Q3 budget")
    static let mail = SessionOrigin(key: ContextKey(bundleID: "com.apple.mail"), appName: "Mail", windowTitle: "Investor update")

    static func s(_ id: String, _ title: String, symbol: String?, color: ConversationColor = .ember, origin: SessionOrigin? = nil,
                  status: SessionStatus = .idle, mates: [TeammateSnapshot] = [], pinned: Bool = false, used: TimeInterval = 60,
                  live: String? = nil, say: String? = nil) -> SessionSnapshot {
        SessionSnapshot(id: SessionID(rawValue: id), title: title, symbol: symbol, color: color, origin: origin, harness: .open,
                        status: status, teammates: mates, pinned: pinned, lastUsed: ago(used), liveLine: live, turns: 3,
                        ranFor: 41, lastSay: say)
    }

    static let mates = [
        TeammateSnapshot(id: "task0", toolUseID: "a0", name: "Researcher", state: .working, liveLine: "Reading 4 sources"),
        TeammateSnapshot(id: "task1", toolUseID: "a1", name: "Analyst", state: .needsYou, liveLine: "Edit variance.csv"),
        TeammateSnapshot(id: "task2", toolUseID: "a2", name: "Writer", state: .done),
    ]

    static let editAsk = PermissionAsk(id: "p1", title: "Edit budget-notes.md", toolName: "Edit",
                                       detail: .plain("budget-notes.md"), tier: .reversible)

    /// One session per tile state, in strip order (03 §4.5).
    static var strip: [SessionSnapshot] {
        [
            s("s1", "Q3 burn model", symbol: "chart.line.downtrend.xyaxis", origin: numbersOrigin,
              status: .thinking(since: ago(200), progress: StepProgress(done: 3, total: 5)), live: "Reading po-ledger.csv · 6 steps · 3:20"),
            s("s2", "Fix login bug", symbol: "hammer", color: .mist, origin: xcode,
              status: .needsYou(NeedsYou(kind: .permission(editAsk), since: ago(60)))),
            s("s3", "Trip to Lisbon", symbol: "airplane", color: .sage, origin: safari, status: .thinking(since: ago(180), progress: nil),
              mates: Array(mates.prefix(2)), live: "Comparing 4 hotels"),
            s("s4", "Investor update draft", symbol: "square.and.pencil", color: .amber, origin: mail,
              status: .done(at: ago(120), unread: true), say: "The draft is in Mail. I kept it to five lines and led with runway."),
            s("s5", "Lecture 7 notes", symbol: "book.closed", status: .idle, used: 40 * 60, say: "Seven key terms, with a one-line gloss each."),
            s("s6", "Onboarding flow review", symbol: "paintpalette", color: .mist, status: .failed(SessionFailure(reason: .crashed, lastStep: "reading Figma", retryable: true))),
            s("s7", "Renewals at risk", symbol: nil, color: .sage, status: .idle, used: 3 * 3600),
            s("s8", "Competitor pricing scan", symbol: "magnifyingglass", color: .amber, status: .interrupted(at: ago(600)), used: 7 * 3600),
        ]
    }

    static var studioSessions: [SessionSnapshot] {
        var all = strip
        all.append(s("s9", longTitle, symbol: "doc.text", origin: mail, status: .idle, pinned: true, used: 26 * 3600))
        all.append(s("s10", "Weekly standup notes", symbol: "person.3", status: .idle, used: 4 * 86_400))
        all.append(s("s11", "Grant application", symbol: "doc.text", status: .idle, used: 20 * 86_400))
        return all
    }
}
