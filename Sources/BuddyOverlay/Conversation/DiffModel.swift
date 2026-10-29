import BuddyCore
import Foundation

/// A line-wise diff for the inline diff tile (04 §4.2): built from the Edit's input before it
/// runs, or from the result's `structuredPatch` sides after (the bridge passes both as
/// old/new text). Stdlib `CollectionDifference`, no library.
nonisolated public struct DiffModel: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case context, added, removed }

    public struct Line: Sendable, Equatable {
        public var kind: Kind
        public var text: String
    }

    /// A tile row: a line, or a gap where unchanged lines were left out.
    public enum Row: Sendable, Equatable {
        case line(Line)
        case gap
    }

    public var path: String?
    public var lines: [Line]

    public var added: Int { lines.lazy.filter { $0.kind == .added }.count }
    public var removed: Int { lines.lazy.filter { $0.kind == .removed }.count }
    /// "+12 −3".
    public var counts: String { "+\(added) −\(removed)" }

    public init(path: String?, old: String, new: String) {
        self.path = path
        let a = Self.split(old), b = Self.split(new)
        let diff = b.difference(from: a)
        var removedAt = Set<Int>(), insertedAt = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedAt.insert(offset)
            case .insert(let offset, _, _): insertedAt.insert(offset)
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removedAt.contains(i) {
                out.append(Line(kind: .removed, text: a[i]))
                i += 1
            } else if j < b.count, insertedAt.contains(j) {
                out.append(Line(kind: .added, text: b[j]))
                j += 1
            } else if i < a.count, j < b.count {
                out.append(Line(kind: .context, text: a[i]))
                i += 1
                j += 1
            } else {
                break
            }
        }
        lines = out
    }

    public init?(_ detail: StepDetail?) {
        guard case .diff(let path, let old, let new)? = detail else { return nil }
        self.init(path: path, old: old, new: new)
    }

    static func split(_ s: String) -> [String] {
        s.isEmpty ? [] : s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The tile: the first `changed` changed lines with `context` lines around them; longer
    /// unchanged runs become a gap.
    public func preview(changed limit: Int = 8, context: Int = 3) -> [Row] {
        let changedIdx = lines.indices.filter { lines[$0].kind != .context }
        guard let first = changedIdx.first else { return [] }
        let lastShown = changedIdx.prefix(limit).last ?? first
        var keep = Set<Int>()
        for c in changedIdx.prefix(limit) {
            for k in max(0, c - context)...min(lines.count - 1, c + context) where k <= lastShown || (lines[k].kind == .context && k <= lastShown + context) {
                keep.insert(k)
            }
        }
        var rows: [Row] = []
        var previous: Int?
        for k in keep.sorted() {
            if let p = previous, k > p + 1 { rows.append(.gap) }
            rows.append(.line(lines[k]))
            previous = k
        }
        if let p = previous, p < lines.count - 1, lines[(p + 1)...].contains(where: { $0.kind != .context }) {
            rows.append(.gap)
        }
        return rows
    }
}
