import AppKit
import SwiftUI

/// The tile's state ring, drawn and animated by Core Animation so a strip of spinning comets
/// costs the app no CPU per frame (as `IndeterminateBar`). 50 pt, centred on the glyph well.
struct StateRing: NSViewRepresentable {
    let ring: TileLook.Ring
    let ember: NSColor
    let amber: NSColor
    let rose: NSColor
    let track: NSColor
    let lineWidth: CGFloat
    /// Only while the strip is on screen; a hidden strip runs no animations.
    let animating: Bool
    let reduceMotion: Bool

    /// What the layers were last set up for. A SwiftUI update with the same look keeps the
    /// running loop, so the comet never jumps back to 12 o'clock mid-turn.
    struct Applied: Equatable {
        var ring: TileLook.Ring
        var animating: Bool
        var reduceMotion: Bool
        var colors: [NSColor]
        var lineWidth: CGFloat
    }

    final class RingView: NSView {
        let trackLayer = CAShapeLayer()
        let arcLayer = CAShapeLayer()
        var applied: Applied?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for l in [trackLayer, arcLayer] {
                l.fillColor = nil
                l.lineCap = .round
                layer?.addSublayer(l)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            for l in [trackLayer, arcLayer] {
                l.frame = bounds
                // Starts at 12 o'clock, clockwise on screen.
                let inset = l.lineWidth / 2
                let r = bounds.insetBy(dx: inset, dy: inset)
                l.path = CGPath(ellipseIn: r, transform: nil)
            }
            arcLayer.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        }
    }

    func makeNSView(context: Context) -> RingView { RingView(frame: NSRect(x: 0, y: 0, width: 50, height: 50)) }

    func updateNSView(_ view: RingView, context: Context) {
        let applied = Applied(ring: ring, animating: animating, reduceMotion: reduceMotion,
                              colors: [ember, amber, rose, track], lineWidth: lineWidth)
        guard applied != view.applied else { return }
        view.applied = applied
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        view.trackLayer.lineWidth = lineWidth
        view.arcLayer.lineWidth = lineWidth
        view.trackLayer.strokeColor = track.cgColor
        view.arcLayer.removeAllAnimations()
        view.trackLayer.isHidden = true
        view.arcLayer.opacity = 1
        switch ring {
        case .none:
            view.arcLayer.isHidden = true
        case .comet:
            view.arcLayer.isHidden = false
            view.arcLayer.strokeColor = ember.cgColor
            view.arcLayer.strokeStart = 0
            view.arcLayer.strokeEnd = reduceMotion ? 0.75 : 0.25
            if animating {
                // Reduce Motion: a steady three-quarter arc, no loop.
                if !reduceMotion {
                    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                    spin.fromValue = -Double.pi / 2
                    spin.toValue = -Double.pi / 2 + 2 * Double.pi
                    spin.duration = Motion.spinPeriod
                    spin.repeatCount = .infinity
                    view.arcLayer.add(spin, forKey: "spin")
                }
            }
        case .progress(let f):
            view.trackLayer.isHidden = false
            view.arcLayer.isHidden = false
            view.arcLayer.strokeColor = ember.cgColor
            view.arcLayer.strokeStart = 0
            view.arcLayer.strokeEnd = f
        case .needsYou:
            view.arcLayer.isHidden = false
            view.arcLayer.strokeColor = amber.cgColor
            view.arcLayer.strokeStart = 0
            view.arcLayer.strokeEnd = 1
            if animating, !reduceMotion { view.arcLayer.add(Motion.caBreathe(.breathe), forKey: "breathe") }
        case .failed:
            view.arcLayer.isHidden = false
            view.arcLayer.strokeColor = rose.cgColor
            view.arcLayer.strokeStart = 0
            view.arcLayer.strokeEnd = 1
        }
        view.needsLayout = true
    }

}

/// A small dot with an optional slow opacity loop, run by Core Animation: the trail's live dot.
struct PulseDot: NSViewRepresentable {
    static let defaultSize: CGFloat = 6

    let color: NSColor
    let opacity: Float
    /// Pulses (`loop`) while live; else steady.
    let pulses: Bool
    let glow: Bool
    var size: CGFloat = PulseDot.defaultSize
    var loop: Motion.Loop = .pulse

    final class DotView: NSView {
        let dot = CALayer()
        /// The last look set up, so an unchanged update never restarts the pulse.
        var applied: (color: NSColor, opacity: Float, pulses: Bool, glow: Bool)?
        var size = PulseDot.defaultSize

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(dot)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            let d = size
            dot.frame = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
            dot.cornerRadius = d / 2
        }
    }

    func makeNSView(context: Context) -> DotView {
        let v = DotView(frame: .zero)
        v.size = size
        return v
    }

    func updateNSView(_ view: DotView, context: Context) {
        if let a = view.applied, a.color == color, a.opacity == opacity, a.pulses == pulses, a.glow == glow { return }
        view.applied = (color, opacity, pulses, glow)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.dot.backgroundColor = color.cgColor
        view.dot.opacity = opacity
        view.dot.shadowColor = color.cgColor
        view.dot.shadowRadius = glow ? 4 : 0
        view.dot.shadowOpacity = glow ? 0.9 : 0
        view.dot.shadowOffset = .zero
        view.dot.removeAnimation(forKey: "pulse")
        if pulses { view.dot.add(Motion.caBreathe(loop, from: opacity), forKey: "pulse") }
        CATransaction.commit()
        view.needsLayout = true
    }
}
