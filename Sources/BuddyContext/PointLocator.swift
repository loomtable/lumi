import ApplicationServices
import BuddyCore
import CoreGraphics
import Foundation
import Synchronization
import Vision

/// Where an answer's `points` quote is on screen (one-shot rings).
public struct LocatedPoint: Sendable, Equatable {
    public enum Source: String, Sendable { case accessibility, ocr }

    public var quote: String
    /// Global points, top-left origin (the overlay's space).
    public var rect: CGRect
    public var source: Source

    public init(quote: String, rect: CGRect, source: Source) {
        self.quote = quote
        self.rect = rect
        self.source = source
    }
}

/// Real: `ScreenPointLocator`. Fake: return fixed points in tests.
public protocol PointLocator: Sendable {
    /// Finds each quote in the app `pid`'s focused window, by AX text first, then by OCR of
    /// `screenshot` (the summon capture) cropped to that window. Quotes that can't be found are
    /// left out (rings are skipped); the rest keep the input order. An unknown or blocked
    /// app gives nothing: no text is read and nothing is ringed.
    func locate(_ quotes: [String], pid: Int32?, screenshot: Screenshot?, blocklist: Blocklist) async -> [LocatedPoint]
}

/// What the locator reads from the system; replaced in tests.
struct LocatorSystem: Sendable {
    var bundleID: @Sendable (Int32) -> String?
    /// The frame of the window the user is looking at, for cropping OCR.
    var windowFrame: @Sendable (Int32) -> CGRect?
    /// AX text search; fills the partial result as it goes.
    var findText: @Sendable ([String], Int32, AXTextSearch.Limits, AXTextSearch.Partial) -> Void

    static let live = LocatorSystem(
        bundleID: { RunningApps.bundleID(of: $0) },
        windowFrame: { AXTextSearch.window(of: $0).flatMap(AX.frame) },
        findText: { AXTextSearch.find($0, pid: $1, limits: $2, into: $3) })
}

/// OCR is slow on dense text, so the shell calls `prepare` as soon as the summon screenshot
/// exists: accurate OCR of the window runs while the user is still speaking, and `locate` then
/// only matches text. `OCRBenchmarkTests` on dense 13 pt text at 2× (Apple M5, macOS 26.6, p50 of
/// 5): accurate OCR of an 800×500 pt window takes ~1.0 s, of the whole 1470×956 pt display
/// ~2.7 s; fast OCR (40–160 ms) recognises no lines at all, so it isn't used. `locate` waits at
/// most `ocrWait` for OCR, prepared or not; past it, rings are skipped.
public actor ScreenPointLocator: PointLocator {
    /// AX walk limits, so a huge web page can't stall the answer.
    public let maxElements = 4_000
    public let maxDepth = 40
    public let axBudget: Duration = .milliseconds(150)
    /// The longest `locate` waits for OCR text.
    public let ocrWait: Duration

    struct Prepared {
        let file: URL
        let pid: Int32
        let task: Task<OCRText?, Never>
    }

    private var prepared: Prepared?
    private let system: LocatorSystem

    public init() {
        self.init(system: .live, ocrWait: .milliseconds(700))
    }

    init(system: LocatorSystem, ocrWait: Duration = .milliseconds(700)) {
        // AX calls to a hung app must give up after 0.25 s, not the 1.5 s default.
        AX.setProcessTimeout()
        self.system = system
        self.ocrWait = ocrWait
    }

    /// For tests: the OCR started by the last `prepare`, until `locate` consumes it.
    var preparedTask: Task<OCRText?, Never>? { prepared?.task }

    /// Starts accurate OCR of `screenshot`, cropped to `pid`'s focused window. Cancels any
    /// earlier preparation. Does nothing for an unknown or blocked app, or a window that isn't
    /// on the captured display.
    public func prepare(_ screenshot: Screenshot, pid: Int32?, blocklist: Blocklist = Blocklist()) {
        prepared?.task.cancel()
        prepared = nil
        guard let pid, let id = system.bundleID(pid), !blocklist.isBlocked(bundleID: id) else { return }
        let system = self.system
        prepared = Prepared(file: screenshot.file, pid: pid, task: Task {
            // AX can wait the messaging timeout per call; never on this actor, never unbounded.
            guard let found = await Deadline.run(within: .milliseconds(400), { system.windowFrame(pid) }),
                  let window = found.value
            else { return nil }
            return await OCRText.recognize(screenshot, within: window, level: .accurate)
        })
    }

    public func locate(
        _ quotes: [String], pid: Int32?, screenshot: Screenshot?, blocklist: Blocklist = Blocklist()
    ) async -> [LocatedPoint] {
        // A preparation is used once, by the next locate.
        let prep = prepared
        prepared = nil
        let wanted = quotes.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Never read, OCR or ring a blocked app, or one whose identity is unknown.
        guard !wanted.isEmpty, let pid, let id = system.bundleID(pid), !blocklist.isBlocked(bundleID: id) else {
            prep?.task.cancel()
            return []
        }
        let partial = AXTextSearch.Partial()
        let limits = AXTextSearch.Limits(elements: maxElements, depth: maxDepth, budget: axBudget)
        let system = self.system
        // The walk stops itself at axBudget; if one AX call hangs past the deadline, what it
        // found so far is still used.
        _ = await Deadline.run(within: axBudget + .milliseconds(100)) { system.findText(wanted, pid, limits, partial) }
        var found = partial.points.withLock { $0 }
        let axWindow = partial.window.withLock { $0 }
        let missing = wanted.filter { found[$0] == nil }
        if !missing.isEmpty, let screenshot {
            var text: OCRText?
            if let prep, prep.file == screenshot.file, prep.pid == pid {
                text = await Deadline.value(of: prep.task, within: ocrWait) ?? nil
                // Nobody waits for it any more: if it hasn't started, it never will (OCRQueue).
                if text == nil { prep.task.cancel() }
            } else {
                prep?.task.cancel()
                if let axWindow {
                    let task = Task { await OCRText.recognize(screenshot, within: axWindow, level: .accurate) }
                    text = await Deadline.value(of: task, within: ocrWait) ?? nil
                    if text == nil { task.cancel() }
                }
            }
            if let text {
                // Only inside the window the user is looking at, never another app's text.
                for point in text.find(missing, within: axWindow ?? text.window) where found[point.quote] == nil {
                    found[point.quote] = point
                }
            }
        } else {
            prep?.task.cancel()
        }
        return wanted.compactMap { found[$0] }
    }
}

// MARK: - AX

enum AXTextSearch {
    struct Limits: Sendable {
        let elements: Int
        let depth: Int
        let budget: Duration
    }

    static let textRoles: Set<String> = [
        kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, "AXHeading", "AXLink", kAXButtonRole, kAXCellRole,
    ]
    /// Prose: a quote found here beats one in a button, link, cell or field.
    static let proseRoles: Set<String> = [kAXStaticTextRole, kAXTextAreaRole, "AXHeading"]

    /// Shared with the caller so results survive a walk that runs past its deadline.
    final class Partial: Sendable {
        let points = Mutex<[String: LocatedPoint]>([:])
        let window = Mutex<CGRect?>(nil)
    }

    /// Text longer than this is skipped (a whole document in one element): matching it can take
    /// hundreds of ms, and OCR covers what is visible anyway.
    static let maxTextUTF16 = 20_000

    /// 0 for the best kind of hit: prose, or a match that is (nearly) the element's whole text.
    static func tier(role: String, coverage: Double) -> Int {
        proseRoles.contains(role) || coverage >= 0.9 ? 0 : 1
    }

    /// Breadth-first through the window. A quote's best-tier hit wins, the first among equals;
    /// the walk ends early once every quote has a best-tier hit.
    static func find(_ quotes: [String], pid: Int32, limits: Limits, into out: Partial) {
        guard let window = window(of: pid) else { return }
        let windowFrame = AX.frame(window)
        out.window.withLock { $0 = windowFrame }
        let matchers = quotes.compactMap(TextMatch.Matcher.init)
        var tiers: [String: Int] = [:]
        let start = ContinuousClock.now
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var head = 0
        while head < queue.count, head < limits.elements, ContinuousClock.now - start < limits.budget,
              tiers.values.count(where: { $0 == 0 }) < matchers.count {
            let (el, depth) = queue[head]
            head += 1
            if let role = AX.string(el, kAXRoleAttribute), textRoles.contains(role), !AX.isSecure(el, role: role),
               let element = ElementText(el) {
                for m in matchers where (tiers[m.quote] ?? 2) > 0 {
                    guard let hit = element.hit(for: m), visible(hit.rect, in: windowFrame) else { continue }
                    let t = tier(role: role, coverage: hit.coverage)
                    guard t < (tiers[m.quote] ?? 2) else { continue }
                    tiers[m.quote] = t
                    out.points.withLock { $0[m.quote] = LocatedPoint(quote: m.quote, rect: hit.rect, source: .accessibility) }
                }
            }
            if depth < limits.depth, let children = AX.value(el, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
    }

    /// AX also reports text scrolled out of view; only a rect inside the window can be ringed.
    static func visible(_ rect: CGRect, in window: CGRect?) -> Bool {
        guard let window else { return true }
        return rect.intersects(window.insetBy(dx: -2, dy: -2))
    }

    /// One element's text and frame, read once.
    struct ElementText {
        let element: AXUIElement
        let text: String
        /// True when `text` is kAXValue, the only text AXBoundsForRange addresses.
        let isValue: Bool
        let frame: CGRect?

        init?(_ el: AXUIElement) {
            let value = AX.string(el, kAXValueAttribute)
            guard let text = value ?? AX.string(el, kAXTitleAttribute) ?? AX.string(el, kAXDescriptionAttribute),
                  text.utf16.count <= AXTextSearch.maxTextUTF16 else { return nil }
            element = el
            self.text = text
            isValue = value != nil
            frame = AX.frame(el)
        }

        /// The exact range's bounds when the element supports it, else the element's own frame
        /// when the quote is most of its text (a label, a short run). `coverage` is the share of
        /// the element's text the quote covers.
        func hit(for matcher: TextMatch.Matcher) -> (rect: CGRect, coverage: Double)? {
            guard let range = matcher.range(in: text) else { return nil }
            let coverage = Double(text.distance(from: range.lowerBound, to: range.upperBound)) / Double(max(text.count, 1))
            if isValue, let r = AX.boundsForRange(element, TextMatch.utf16Range(range, in: text)),
               BoundsCheck.rejectionReason(r, elementFrame: frame) == nil {
                return (r, coverage)
            }
            guard let frame, frame.width > 0, frame.height > 0, coverage >= 0.6 else { return nil }
            return (frame, coverage)
        }
    }

    /// The window the user is looking at: focused, else main, else the first standard window
    /// (an app can report no focused window, e.g. right after a click elsewhere).
    static func window(of pid: Int32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        if let w = AX.element(app, kAXFocusedWindowAttribute) ?? AX.element(app, kAXMainWindowAttribute) { return w }
        let windows = AX.value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { AX.string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole } ?? windows.first
    }
}

// MARK: - OCR

/// Runs Vision text recognition one request at a time and never cancels one in flight.
///
/// Cancelling a Swift `RecognizeTextRequest` mid-`perform` crashes the process inside Vision's
/// TextRecognition (SIGSEGV in objc_retain, after "RecognizeTextRequest was cancelled"):
/// `OCRCancelStressTests` reproduced it in 3 of 3 runs. Summon, Esc and a new summon cancel OCR
/// all the time, so the perform runs in a detached task that the caller's cancellation never
/// reaches; a cancelled caller gets nil at once and the perform finishes on its own. A request
/// whose caller gave up before its turn never starts, so abandoned work can't pile up.
///
/// Trade-off: a new summon's OCR can wait for an abandoned one still running (at most ~1 s of
/// dense accurate OCR); a perform that never returns stops holding the queue after `stuckLimit`.
final class OCRQueue: Sendable {
    typealias Perform = @Sendable (CGImage, RecognizeTextRequest.RecognitionLevel) async -> [RecognizedTextObservation]?

    static let shared = OCRQueue()

    /// How long a job waits for the one before it; past this the previous perform is presumed hung.
    /// Generous, so a slow Mac's long OCR isn't taken for a hang.
    let stuckLimit: Duration
    private let perform: Perform
    /// The last job queued; the next one starts after it.
    private let last = Mutex<Task<Void, Never>?>(nil)

    init(stuckLimit: Duration = .seconds(15), perform: @escaping Perform = OCRQueue.vision) {
        self.stuckLimit = stuckLimit
        self.perform = perform
    }

    static let vision: Perform = { image, level in
        var request = RecognizeTextRequest()
        request.recognitionLevel = level
        return try? await request.perform(on: image, orientation: nil)
    }

    /// Set when the caller is cancelled. A class, not an `Atomic` captured directly (Swift 6.4
    /// rejects capturing a noncopyable value in a closure).
    private final class GaveUp: Sendable {
        private let flag = Mutex(false)
        var isSet: Bool { flag.withLock { $0 } }
        func set() { flag.withLock { $0 = true } }
    }

    func recognize(_ image: CGImage, level: RecognizeTextRequest.RecognitionLevel) async -> [RecognizedTextObservation]? {
        guard !Task.isCancelled else { return nil }
        let gaveUp = GaveUp()
        let (perform, stuckLimit) = (perform, stuckLimit)
        let job = last.withLock { last -> Task<[RecognizedTextObservation]?, Never> in
            let previous = last
            let job = Task.detached(priority: .userInitiated) { () -> [RecognizedTextObservation]? in
                if let previous { _ = await Deadline.value(of: previous, within: stuckLimit) }
                guard !gaveUp.isSet else { return nil }
                return await perform(image, level)
            }
            last = Task.detached { _ = await job.value }
            return job
        }
        // The job is never cancelled (awaiting an unstructured task doesn't pass cancellation on);
        // a cancelled caller stops waiting at once instead.
        let once = Deadline.Once<[RecognizedTextObservation]?>()
        let observations = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.set(continuation)
                if gaveUp.isSet { once.resume(nil) } // cancelled before the continuation existed
                Task.detached { once.resume(await job.value) }
            }
        } onCancel: {
            gaveUp.set()
            once.resume(nil)
        }
        return gaveUp.isSet ? nil : observations
    }
}

/// Recognised lines of one window's crop of a capture, with what's needed to map a match back to
/// global points.
struct OCRText: Sendable {
    let lines: [RecognizedText]
    /// Each line's box, normalised to the crop with a lower-left origin.
    let lineBoxes: [CGRect]
    /// The window (global points) the crop was cut to.
    let window: CGRect
    let cropPx: CGRect
    let cropSize: CGSize
    let displayFrame: CGRect
    /// Full-image pixels per point.
    let sx: Double
    let sy: Double

    /// Nil when the window isn't on the captured display: OCR of anything else would ring
    /// another app's text.
    static func recognize(
        _ shot: Screenshot, within window: CGRect, level: RecognizeTextRequest.RecognitionLevel
    ) async -> OCRText? {
        guard !Task.isCancelled, let cropPx = shot.fullPixels(ofGlobal: window)?.integral, let image = shot.full.cropping(to: cropPx) else {
            return nil
        }
        guard let observations = await OCRQueue.shared.recognize(image, level: level), !Task.isCancelled else { return nil }
        let pairs = observations.compactMap { o in o.topCandidates(1).first.map { ($0, o.boundingBox.cgRect) } }
        return OCRText(
            lines: pairs.map(\.0), lineBoxes: pairs.map(\.1), window: window, cropPx: cropPx,
            cropSize: CGSize(width: image.width, height: image.height), displayFrame: shot.displayFrame,
            sx: Double(shot.full.width) / max(shot.displayFrame.width, 1),
            sy: Double(shot.full.height) / max(shot.displayFrame.height, 1))
    }

    func global(_ box: NormalizedRect) -> CGRect {
        let r = box.toImageCoordinates(cropSize, origin: .upperLeft)
        return CGRect(
            x: displayFrame.minX + (cropPx.minX + r.minX) / sx, y: displayFrame.minY + (cropPx.minY + r.minY) / sy,
            width: r.width / sx, height: r.height / sy)
    }

    /// A run of consecutive lines read as one text, so a quote can wrap across them.
    struct Passage {
        struct Segment {
            let line: Int
            /// Character offsets in `text`.
            let start: Int
            let count: Int
        }

        let text: String
        let segments: [Segment]
    }

    /// Lines in Vision's reading order; each line joins the one before when it sits directly
    /// below it (a wrap), dropping a hyphen that ends the earlier line.
    var passages: [Passage] {
        var out: [Passage] = []
        var chars: [Character] = []
        var segments: [Passage.Segment] = []
        func close() {
            guard !segments.isEmpty else { return }
            let text = String(chars)
            if text.count == chars.count {
                out.append(Passage(text: text, segments: segments))
            } else {
                // Characters merged at a join (a combining mark): match those lines one by one.
                for s in segments {
                    out.append(Passage(text: lines[s.line].string, segments: [.init(line: s.line, start: 0, count: lines[s.line].string.count)]))
                }
            }
            chars = []
            segments = []
        }
        for (i, line) in lines.enumerated() {
            if i > 0, Self.wraps(from: lineBoxes[i - 1], to: lineBoxes[i]), let last = segments.last {
                if let end = chars.last, TextMatch.dashes.contains(end), chars.count >= 2, chars[chars.count - 2].isLetter {
                    chars.removeLast()
                    segments[segments.count - 1] = .init(line: last.line, start: last.start, count: last.count - 1)
                } else {
                    chars.append(" ")
                }
            } else {
                close()
            }
            let lineChars = Array(line.string)
            segments.append(.init(line: i, start: chars.count, count: lineChars.count))
            chars.append(contentsOf: lineChars)
        }
        close()
        return out
    }

    /// `b` is the next line of the same paragraph as `a`: just below it and overlapping it
    /// horizontally (boxes normalised, lower-left origin).
    static func wraps(from a: CGRect, to b: CGRect) -> Bool {
        let gap = a.minY - b.maxY
        let height = max(a.height, b.height)
        return gap > -0.5 * height && gap < height && min(a.maxX, b.maxX) > max(a.minX, b.minX)
    }

    /// Each quote, else its opening words (the rest is off screen or cut), inside `window`. A
    /// match spanning lines rings the union of its pieces.
    func find(_ quotes: [String], within window: CGRect) -> [LocatedPoint] {
        let passages = passages
        return quotes.compactMap { quote in
            let probes = [TextMatch.Matcher(quote), TextMatch.prefix(of: quote, words: 6).flatMap(TextMatch.Matcher.init)]
                .compactMap { $0 }
            for probe in probes {
                for passage in passages {
                    guard let range = probe.range(in: passage.text) else { continue }
                    let lower = passage.text.distance(from: passage.text.startIndex, to: range.lowerBound)
                    let upper = lower + passage.text.distance(from: range.lowerBound, to: range.upperBound)
                    if let rect = rect(lower..<upper, in: passage), AXTextSearch.visible(rect, in: window) {
                        return LocatedPoint(quote: quote, rect: rect, source: .ocr)
                    }
                }
            }
            return nil
        }
    }

    func rect(_ range: Range<Int>, in passage: Passage) -> CGRect? {
        var union: CGRect?
        for s in passage.segments {
            let lo = max(range.lowerBound, s.start) - s.start
            let hi = min(range.upperBound, s.start + s.count) - s.start
            guard hi > lo else { continue }
            let string = lines[s.line].string
            let a = string.index(string.startIndex, offsetBy: lo), b = string.index(a, offsetBy: hi - lo)
            guard let box = lines[s.line].boundingBox(for: a..<b) else { continue }
            let r = global(box.boundingBox)
            union = union.map { $0.union(r) } ?? r
        }
        return union
    }
}
