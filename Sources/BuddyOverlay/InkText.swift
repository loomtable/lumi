import SwiftUI

/// Marks which word a run of text belongs to, for the ink-in renderer.
nonisolated struct InkWord: TextAttribute {
    let index: Int
}

/// Draws each word from blur to sharp (Text inking in: one word every 34 ms, each
/// over 550 ms from blur 5 and +0.06 em tracking), with a blinking ember caret after the
/// newest word while words stream. Layout is computed once: tracking is drawn as per-glyph
/// offsets that close as the word sharpens, so measurement and wrapping never change.
nonisolated struct InkRenderer: TextRenderer {
    var elapsed: Double
    var caret: Color

    static let wordInterval = 0.034
    static let wordDuration = 0.55
    static let tracking = 0.06       // em, at the start of a word
    static let caretBlink = 0.5      // s per phase
    static let caretWidth: CGFloat = 2

    var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    static func progress(word index: Int, elapsed: Double) -> Double {
        min(max((elapsed - Double(index) * wordInterval) / wordDuration, 0), 1)
    }

    /// Horizontal offset of glyph `k` in a word at progress `p`, for a font size `em`.
    static func trackingOffset(glyph k: Int, progress p: Double, em: CGFloat) -> CGFloat {
        CGFloat(Double(k) * tracking * (1 - p)) * em
    }

    /// The caret shows while words stream and blinks: on for half a second, off for half.
    static func caretOn(elapsed: Double) -> Bool { Int(elapsed / caretBlink) % 2 == 0 }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var newest: (index: Int, rect: CGRect)?
        for line in layout {
            for run in line {
                let index = run[InkWord.self]?.index ?? 0
                let p = Self.progress(word: index, elapsed: elapsed)
                guard p > 0 else { continue }
                var word = context
                word.opacity = p
                let bounds = run.typographicBounds
                if p < 1 {
                    word.addFilter(.blur(radius: 5 * (1 - p)))
                    let em = (bounds.ascent + bounds.descent) / 1.2
                    for k in run.indices {
                        var glyph = word
                        glyph.translateBy(x: Self.trackingOffset(glyph: k - run.startIndex, progress: p, em: em), y: 0)
                        glyph.draw(run[k])
                    }
                    let spread = Self.trackingOffset(glyph: max(run.count - 1, 0), progress: p, em: em)
                    if index > (newest?.index ?? -1) {
                        newest = (index, bounds.rect.offsetBy(dx: spread, dy: 0))
                    }
                } else {
                    word.draw(run)
                }
            }
        }
        if let newest, Self.caretOn(elapsed: elapsed) {
            let r = newest.rect
            context.fill(Path(CGRect(x: r.maxX + 1, y: r.minY, width: Self.caretWidth, height: r.height)), with: .color(caret))
        }
    }
}

/// A headline that inks in word by word, once, starting when its row arrives.
struct InkText: View {
    let text: String
    let enabled: Bool
    var caret: Color = .orange
    /// When the headline's row arrives (140 ms + 55 ms × index).
    var delay: Double = 0
    @State private var start: Date?
    /// Set once the last word is sharp; then plain text is drawn and no timeline runs.
    @State private var done = false

    private var words: [Substring] { text.split(separator: " ", omittingEmptySubsequences: false) }

    /// Whether a timeline and renderer run at all; otherwise plain Text is drawn.
    static func animates(enabled: Bool, done: Bool) -> Bool { enabled && !done }

    /// How long the whole headline takes to ink in.
    static func duration(wordCount: Int) -> Double {
        Double(max(wordCount - 1, 0)) * InkRenderer.wordInterval + InkRenderer.wordDuration
    }

    var body: some View {
        if Self.animates(enabled: enabled, done: done) {
            let inked = self.inked
            let delay = self.delay
            let caret = self.caret
            TimelineView(.animation) { context in
                let elapsed = start.map { context.date.timeIntervalSince($0) - delay } ?? 0
                inked.textRenderer(InkRenderer(elapsed: elapsed, caret: caret))
            }
            .onAppear { if start == nil { start = .now } }
            .task(id: text) {
                // Body doesn't re-run while the timeline ticks, so a timer ends it.
                try? await Task.sleep(for: .seconds(delay + Self.duration(wordCount: words.count) + 0.05))
                done = true
            }
        } else {
            Text(text)
        }
    }

    private var inked: Text {
        var out = Text("")
        for (i, word) in words.enumerated() {
            let next = Text(String(word) + (i < words.count - 1 ? " " : "")).customAttribute(InkWord(index: i))
            out = Text("\(out)\(next)")
        }
        return out
    }
}

/// Six plain level bars, when the dot field is turned off (Settings › Appearance).
struct LevelBars: View {
    let level: LevelBox
    let t: Tokens
    static let count = 6

    static func height(bar: Int, level: Double) -> Double {
        // Middle bars move most, as in the dot field.
        let centre = Double(count - 1) / 2
        let weight = 1 - abs(Double(bar) - centre) / (centre + 1)
        return 0.2 + 0.8 * min(max(level * (0.6 + 0.6 * weight), 0), 1)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let v = level.value
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<Self.count, id: \.self) { i in
                    Capsule()
                        .fill(t.emberMark.color)
                        .frame(width: 3, height: 16 * Self.height(bar: i, level: v))
                }
            }
            .frame(width: 28, height: 16)
        }
        .accessibilityHidden(true)
    }
}
