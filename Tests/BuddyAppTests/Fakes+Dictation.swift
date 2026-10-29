import BuddyAct
import BuddyApp
import BuddyCore
import BuddyTrace
import Synchronization

/// Records dictation inserts; `result` decides how each one goes.
@MainActor
final class FakeDictationInserter: DictationInserting {
    var result: InsertResult = .pasted(clipboardRestored: true)
    private(set) var inserts: [(text: String, pid: Int32?)] = []
    private(set) var copies: [String] = []

    func insert(_ text: String, into pid: Int32?) async -> InsertResult {
        inserts.append((text, pid))
        return result
    }

    func copy(_ text: String) { copies.append(text) }
}

/// Records trace events.
final class FakeTracer: TracePort {
    private let log = Mutex<[(TraceEvent, TraceOutcome?)]>([])
    var events: [(TraceEvent, TraceOutcome?)] { log.withLock { $0 } }

    private let why = Mutex<[TraceReason]>([])
    var reasons: [TraceReason] { why.withLock { $0 } }

    func record(_ event: TraceEvent, duration: Duration?, lane: Mode?, outcome: TraceOutcome?, count: Int?) {
        log.withLock { $0.append((event, outcome)) }
    }

    func record(_ event: TraceEvent, duration: Duration?, outcome: TraceOutcome?, reason: TraceReason) {
        log.withLock { $0.append((event, outcome)) }
        why.withLock { $0.append(reason) }
    }
}

/// A Studio composer for dictation tests.
@MainActor
final class FakeDictationComposer: DictationComposer {
    var composerIsKey = false
    private(set) var inserted: [String] = []
    func insertIntoComposer(_ text: String) { inserted.append(text) }
}

/// Lumi's own focused field, for dictation tests (U64).
@MainActor
final class FakeOwnField: OwnTextInserting {
    let result: OwnInsert
    private(set) var inserted: [String] = []
    private(set) var captures = 0
    init(_ result: OwnInsert) { self.result = result }
    func capture() -> OwnFieldTarget? {
        captures += 1
        return nil
    }
    func insert(_ text: String, into target: OwnFieldTarget?) -> OwnInsert {
        inserted.append(text)
        return result
    }
}
