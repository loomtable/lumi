import AppKit
import BuddyCore
import Foundation
import SwiftUI
import Testing
@testable import BuddyOverlay

/// Every outline of a surface (hairline, listening rim, speaking glow) sits on the surface's own
/// frame, and that frame is where the model put it (owner, Oct 29: the ember rim sat off to the
/// side of the dictation pill and ran past the answer card). The real overlay root is laid out in
/// a window that is never ordered on screen.
@MainActor
@Suite(.serialized)
struct SurfaceOutlineTests {
    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    final class Frames {
        var surface: CGRect?
        var outline: CGRect?
    }

    func model(_ surface: OverlayModel.Surface, target: PillTarget = .none) -> OverlayModel {
        let m = OverlayModel()
        m.screenFrame = Self.screen
        m.displayFrames = [1: Self.screen]
        m.pillBounds = Self.screen
        m.pillTarget = target
        m.surface = surface
        m.placeStatusPill()
        return m
    }

    /// Lays out the overlay root and waits until the surface's frames and the model agree.
    func layOut(_ m: OverlayModel, until settled: (Frames) -> Bool) async -> Frames {
        let frames = Frames()
        let root = OverlayRootView(model: m, displayID: 1, onEvent: { _ in }, onClose: {}, onToggleFullScreen: {},
                                   onSubmit: { _ in }, onCapsuleTap: {})
            .environment(\.surfaceProbe) { part, frame in
                switch part {
                case .surface: frames.surface = frame
                case .outline: frames.outline = frame
                }
            }
        let window = NSWindow(contentRect: Self.screen, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if settled(frames) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        window.contentView = nil
        return frames
    }

    static let pills: [(String, OverlayModel.Surface, PillTarget)] = [
        ("listening", .listening(hint: "tap ⌥ to send"), .new),
        ("dictating", .listening(hint: "Dictating 0:04 · tap fn to stop"), .none),
        ("thinking", .thinking(Lane(mode: .quick, model: .haiku), status: "Searching the web for New Delhi weather"), .new),
    ]

    @Test(arguments: [0, 1, 2])
    func thePillsOutlineIsThePill(_ index: Int) async throws {
        let (name, surface, target) = Self.pills[index]
        let m = model(surface, target: target)
        m.speaking = surface.isListening ? false : true  // thinking: Quick's first sentence glows the pill
        let f = await layOut(m) { f in f.surface.map { m.local(m.pillFrame) == $0 } ?? false }
        let pill = try #require(f.surface, "\(name): no surface laid out")
        #expect(f.outline == pill, "\(name): outline \(String(describing: f.outline)) vs pill \(pill)")
        #expect(pill == m.local(m.pillFrame), "\(name): pill \(pill) vs model \(m.pillFrame)")
        #expect(pill.width > 100 && pill.height >= 36, "\(name): measured \(pill)")
        #expect(abs(pill.midX - Self.screen.midX) <= 1, "\(name): centred at the top")
    }

    @Test func theDictationPillCarriesNoSession() async throws {
        let dictating = model(.listening(hint: "Dictating 0:04 · tap fn to stop"))
        let session = model(.listening(hint: "Dictating 0:04 · tap fn to stop"), target: .new)
        let a = try #require(await layOut(dictating) { $0.surface != nil && $0.outline != nil }.surface)
        let b = try #require(await layOut(session) { $0.surface != nil && $0.outline != nil }.surface)
        #expect(a.width < b.width - 60, "no orb or 'New session' lead: \(a.width) vs \(b.width)")
    }

    static let cards: [(Placer.Style, PlacementEdge, CGSize, CGFloat?)] = [
        (.card, .below, CGSize(width: 330, height: 180), 40),
        (.card, .above, CGSize(width: 330, height: 420), 200),
        (.card, .trailing, CGSize(width: 330, height: 300), 60),
        (.chip, .below, CGSize(width: 260, height: 64), nil),
        (.centered, .centered, CGSize(width: 540, height: 600), nil),
    ]

    @Test(arguments: [0, 1, 2, 3, 4])
    func theCardsOutlineIsTheCard(_ index: Int) async throws {
        let (style, edge, size, tail) = Self.cards[index]
        let placement = Placement(frame: CGRect(origin: CGPoint(x: 300, y: 160), size: size), edge: edge,
                                  tailOffset: tail, avoidsAnchor: true)
        let answer = Answer(block: BuddyBlock(say: "New Delhi is 27°C now.", shape: style == .chip ? .chip : .card),
                            lane: Lane(mode: .quick, model: .haiku), conversation: .ember, turn: 3, replyHint: "r")
        let m = model(.answer(answer, placement, style))
        m.speaking = true
        let outer = m.local(OverlayModel.outerFrame(placement, style: style))
        let f = await layOut(m) { $0.surface == outer && $0.outline == outer }
        let card = try #require(f.surface, "\(style) \(size): no surface laid out")
        #expect(card == outer, "\(style) \(size): card \(card) vs placed \(outer)")
        #expect(f.outline == card, "\(style) \(size): outline \(String(describing: f.outline)) vs card \(card)")
    }

    // MARK: A glow never outlives its card

    func answer(_ say: String) -> Answer {
        Answer(block: BuddyBlock(say: say, shape: .card), lane: Lane(mode: .quick, model: .haiku),
               conversation: .ember, turn: 1, replyHint: "r")
    }

    /// Ember pixels (rim and bloom; Reduce Transparency, so the surface draws offscreen) outside
    /// `keep`, in panel points.
    static func emberOutside(_ keep: CGRect, in host: NSView) -> Int {
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let image = rep.cgImage else { return -1 }
        let (w, h) = (image.width, image.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let scale = CGFloat(w) / host.bounds.width
        var n = 0
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let i = (y * w + x) * 4
                let (r, g, b, a) = (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3]))
                // Ember (premultiplied): clearly red-orange, not grey, not the dark surface.
                guard a > 40, r > 90, r - g > 35, r - b > 60 else { continue }
                let pt = CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale)  // row 0 is the top
                if !keep.contains(pt) { n += 1 }
            }
        }
        return n
    }

    /// Polls until no ember is left outside `keep` and returns what's left. The old card leaves with
    /// the pop (0.56 s; about 1 s offscreen, scans included); a rim that outlived it would stay, so
    /// 5 s only absorbs a busy main actor.
    static func emberLeft(outside keep: CGRect, in host: NSView) async -> Int {
        let deadline = Date().addingTimeInterval(5)
        var n = emberOutside(keep, in: host)
        while n != 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            n = emberOutside(keep, in: host)
        }
        return n
    }

    /// Shows card A speaking, then `change`s the surface with the pop animation and waits it out:
    /// no ember may remain outside what's left (`keep`). Also checks A's glow was drawn at all.
    func glowLeaves(change: (OverlayModel) -> Void, keep: (OverlayModel) -> CGRect) async {
        let m = model(.none)
        let a = Placement(frame: CGRect(x: 300, y: 160, width: 330, height: 420), edge: .below, tailOffset: 200, avoidsAnchor: true)
        m.surface = .answer(answer("New Delhi is 27°C now."), a, .card)
        m.speaking = true
        m.speech.value = 1
        let root = OverlayRootView(model: m, displayID: 1, onEvent: { _ in }, onClose: {}, onToggleFullScreen: {},
                                   onSubmit: { _ in }, onCapsuleTap: {})
            .environment(\.colorScheme, .dark)
            .environment(\._accessibilityReduceTransparency, true)
        let window = NSWindow(contentRect: Self.screen, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: Self.screen.size)
        window.contentView = host
        defer { window.contentView = nil }
        try? await Task.sleep(for: .milliseconds(100))
        let outerA = m.local(OverlayModel.outerFrame(a, style: .card))
        #expect(Self.emberOutside(.zero, in: host) > 0, "card A's glow is drawn")
        #expect(Self.emberOutside(outerA.insetBy(dx: -12, dy: -12), in: host) == 0, "A's glow sits on A")

        withAnimation(Motion.pop) { change(m) }
        #expect(await Self.emberLeft(outside: keep(m), in: host) == 0, "no rim or glow outside what's left")
    }

    @Test func closingACardRemovesItsGlow() async {
        await glowLeaves(change: { $0.surface = .none; $0.speaking = false }, keep: { _ in .zero })
    }

    @Test func replacingACardLeavesOnlyTheNewCardsGlow() async {
        let b = Placement(frame: CGRect(x: 700, y: 400, width: 330, height: 160), edge: .below, tailOffset: 40, avoidsAnchor: true)
        await glowLeaves(change: { m in
            m.answerID += 1
            m.surface = .answer(answer("Tomorrow: 29°C."), b, .card)
        }, keep: { m in m.local(OverlayModel.outerFrame(b, style: .card)).insetBy(dx: -12, dy: -12) })
    }

    @Test func aCardThatShrinksTakesItsGlowWithIt() async {
        let small = Placement(frame: CGRect(x: 300, y: 160, width: 330, height: 160), edge: .below, tailOffset: 120, avoidsAnchor: true)
        await glowLeaves(change: { m in
            if case .answer(let a, _, let style) = m.surface { m.surface = .answer(a, small, style) }
        }, keep: { m in m.local(OverlayModel.outerFrame(small, style: .card)).insetBy(dx: -12, dy: -12) })
    }
}
