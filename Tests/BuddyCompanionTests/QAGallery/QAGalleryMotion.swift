import AppKit
import BuddyCore
import SwiftUI
import Testing
@testable import BuddyCompanion
@testable import BuddyOverlay

/// Motion stills (60-MOTION.md): the states Lumi's light moves through, each frozen at a few
/// points, so a reviewer can check them without running the app. Writes into the gallery
/// folder's `motion/`.
@Suite(.serialized, .enabled(if: Gallery.enabled))
@MainActor
struct QAGalleryMotion {
    static let looks: [Look] = [.lightRT, .darkRT]

    func shot<V: View>(_ name: String, _ look: Look, size: CGSize, @ViewBuilder _ content: () -> V) async {
        await Shot.take("motion/\(name)", look, size: size, backdrop: .desktop) { content() }
    }

    /// The pill in each voice state.
    @Test func pill() async {
        for look in Self.looks {
            for (name, surface, level) in [("listening-quiet", OverlayModel.Surface.listening(hint: "tap ⌥ to send"), 0.0),
                                           ("listening-loud", .listening(hint: "tap ⌥ to send"), 0.9),
                                           ("thinking", .thinking(Lane(mode: .quick, model: .haiku), status: "Reading the sheet"), 0)] {
                let model = OverlayModel()
                model.surface = surface
                model.mic.value = level
                await shot("pill-\(name)", look, size: CGSize(width: 420, height: 90)) {
                    TokensReader { t in
                        PillContent(model: model, t: t)
                            .modifier(SurfaceChrome(t: t, shape: Capsule(),
                                                    rim: surface.isListening ? .listening(model.mic) : nil))
                    }
                }
            }
        }
    }

    /// The speaking glow around a card at three reply levels.
    @Test func speakingGlow() async {
        for look in Self.looks {
            for level in [0.0, 0.5, 1.0] {
                let box = LevelBox()
                box.value = level
                await shot("glow-\(Int(level * 100))", look, size: CGSize(width: 440, height: 260)) {
                    TokensReader { t in
                        RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous).fill(t.well.color)
                            .frame(width: 330, height: 150)
                            .modifier(SurfaceChrome(t: t, shape: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous),
                                                    rim: .speaking(box)))
                    }
                }
            }
        }
    }

    /// Lumi's expressions on Home, mid-blink included.
    @Test func orb() async {
        for look in Self.looks {
            await shot("orb-expressions", look, size: CGSize(width: 640, height: 200)) {
                HStack(spacing: 40) {
                    ForEach(LumiExpression.allCases, id: \.self) { LumiOrb(expression: $0, size: 64) }
                }
            }
        }
    }

    /// The working light, moving and with Reduce Motion.
    @Test func workingLight() async {
        for look in [Look.darkRT, Look(dark: true, reduceTransparency: true, reduceMotion: true)] {
            await shot("working-light", look, size: CGSize(width: 420, height: 60)) {
                TokensReader { t in
                    WorkingLight(color: t.emberMark, reduceMotion: look.reduceMotion).frame(width: 380)
                }
            }
        }
    }
}
