import AppKit
import BuddyApp
import BuddyCore

/// The menu bar item's image: brand's MG mark, a small glass orb with a face. Happy eyes when idle, open eyes while listening, breathing while thinking or researching
/// (StatusItemController animates the button's layer), a flat-eyed outline while paused. A small badge marks a
/// required permission that's missing or waits for a reopen.
/// Brand's MG mark at 18 pt (spec from brand, Oct 17; AppKit coordinates, y up): an ember glass orb
/// with a glow and a face. Not a template image, so it keeps its colour on either menu bar.
enum MenuBarDot {
    static func accessibilityText(activity: MenuBarActivity, paused: Bool, attention: Bool = false) -> String {
        let name = BuddyCore.appName
        let state = if paused { "\(name), paused" } else {
            switch activity {
            case .idle: name
            case .listening: "\(name), listening"
            case .busy: "\(name), working"
            }
        }
        return attention ? "\(state), needs a permission" : state
    }

    static let light = NSColor(srgbRed: 0xD9 / 255, green: 0x62 / 255, blue: 0x2F / 255, alpha: 1)
    static let dark = NSColor(srgbRed: 0xFF / 255, green: 0x8A / 255, blue: 0x5B / 255, alpha: 1)
    static let inkLight = NSColor(srgbRed: 0x3A / 255, green: 0x16 / 255, blue: 0x08 / 255, alpha: 1)
    static let inkDark = NSColor(srgbRed: 0x24 / 255, green: 0x13 / 255, blue: 0x0B / 255, alpha: 1)

    static func image(activity: MenuBarActivity, paused: Bool, dark isDark: Bool, badge: Bool = false) -> NSImage {
        let ember = isDark ? dark : light
        let ink = isDark ? inkDark : inkLight
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard NSGraphicsContext.current != nil else { return false }
            drawMark(paused: paused, listening: activity == .listening, ember: ember, ink: ink)
            if badge {
                // A 1 pt gap around the badge, cut out of the mark.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 12, y: 12, width: 7, height: 7)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawMark(paused: Bool, listening: Bool, ember: NSColor, ink: NSColor) {
        if paused {
            let orb = NSBezierPath(ovalIn: NSRect(x: 2.75, y: 2.75, width: 12.5, height: 12.5))
            ember.withAlphaComponent(0.25).setFill()
            orb.fill()
            ember.setStroke()
            orb.lineWidth = 1.5
            orb.stroke()
            ink.setStroke()
            for x in [5.07, 10.39] {
                let eye = NSBezierPath()
                eye.move(to: NSPoint(x: x, y: 8.44))
                eye.line(to: NSPoint(x: x + 2.54, y: 8.44))
                stroke(eye)
            }
            return
        }
        ember.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 18, height: 18)).fill()
        let orb = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
        ember.setFill()
        orb.fill()
        NSGraphicsContext.saveGraphicsState()
        orb.addClip()
        let highlight = NSPoint(x: 7.32, y: 11.8)
        NSGradient(starting: .white.withAlphaComponent(0.55), ending: .white.withAlphaComponent(0))?
            .draw(fromCenter: highlight, radius: 0, toCenter: highlight, radius: 7, options: [])
        NSGraphicsContext.restoreGraphicsState()
        if listening {
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5.39, y: 8.0, width: 1.9, height: 2.7)).fill()
            NSBezierPath(ovalIn: NSRect(x: 10.71, y: 8.0, width: 1.9, height: 2.7)).fill()
        } else {
            ink.setStroke()
            for shift in [0.0, 5.32] {
                let eye = NSBezierPath()
                eye.move(to: NSPoint(x: 4.975 + shift, y: 8.44))
                eye.curve(to: NSPoint(x: 7.705 + shift, y: 8.44),
                          controlPoint1: NSPoint(x: 5.885 + shift, y: 10.38), controlPoint2: NSPoint(x: 6.795 + shift, y: 10.38))
                stroke(eye)
            }
        }
    }

    private static func stroke(_ path: NSBezierPath) {
        path.lineWidth = 1.12
        path.lineCapStyle = .round
        path.stroke()
    }
}
