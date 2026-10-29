import Foundation
import Testing
@testable import BuddyOverlay

// theme (round 3, 30-QA.md "Round 3 theme"; themes, 67-THEMES.md): every colour comes from the
// tokens, and every token resolves in every theme, light and dark, with the display options.

struct ThemeTokenTests {
    nonisolated static let variants: [Tokens.Variant] = Theme.allCases.flatMap { theme in
        [false, true].flatMap { dark in
            [false, true].flatMap { rt in
                [false, true].map { ic in Tokens.Variant(dark: dark, theme: theme, reduceTransparency: rt, increaseContrast: ic) }
            }
        }
    }

    /// Every `TokenColor` the tokens hold, by name.
    static func colors(_ t: Tokens) -> [(name: String, color: TokenColor)] {
        Mirror(reflecting: t).children.compactMap { child in
            (child.value as? TokenColor).map { (child.label ?? "?", $0) }
        }
    }

    @Test(arguments: variants)
    func everyColourTokenResolves(_ v: Tokens.Variant) {
        let all = Self.colors(Tokens(v))
        #expect(all.count >= 16)
        for (name, c) in all {
            for part in [c.red, c.green, c.blue, c.alpha] {
                #expect((0...1).contains(part), "\(name) out of range in \(v)")
            }
        }
    }

    /// Light and dark are different palettes: the text, surfaces and outlines all change.
    @Test func lightAndDarkDiffer() {
        let light = Dictionary(uniqueKeysWithValues: Self.colors(Tokens(.init(dark: false))).map { ($0.name, $0.color) })
        let dark = Dictionary(uniqueKeysWithValues: Self.colors(Tokens(.init(dark: true))).map { ($0.name, $0.color) })
        #expect(Set(light.keys) == Set(dark.keys))
        for name in ["well", "opaqueSurface", "text", "secondaryText", "emberText", "hairline", "sage", "amber", "rose"] {
            #expect(light[name] != dark[name], "\(name) is the same in light and dark")
        }
    }

    /// Light and the futures fix the look whatever the Mac's; System and Liquid Glass follow it.
    @Test(arguments: Theme.allCases)
    func eachThemeHasItsLook(_ theme: Theme) {
        for macDark in [false, true] {
            let dark = Tokens(.init(dark: macDark, theme: theme)).variant.dark
            switch theme {
            case .system, .glass: #expect(dark == macDark)
            case .light: #expect(!dark)
            case .dark, .neonNoir, .synthwave: #expect(dark)
            }
        }
        #expect(theme.alwaysDark.forcedDark != false, "the notch capsule's theme is never light")
    }

    /// Ember stays the brand accent in System, Light, Dark and Liquid Glass; the futures have their own.
    @Test func emberIsTheAccentOutsideTheFutures() {
        for dark in [false, true] {
            let lantern = Tokens(.init(dark: dark)).emberMark
            for theme in [Theme.light, .dark, .glass] where (theme.forcedDark ?? dark) == dark {
                #expect(Tokens(.init(dark: dark, theme: theme)).emberMark == lantern, "\(theme)")
            }
            for theme in [Theme.neonNoir, .synthwave] {
                #expect(Tokens(.init(dark: dark, theme: theme)).emberMark != Tokens(.init(dark: true)).emberMark)
            }
        }
        #expect(Set(Theme.allCases.map { Tokens(.init(dark: true, theme: $0)).wash.alpha > 0 }) == [false, true])
    }

    /// Reduce Transparency and Increase Contrast make every surface solid, Liquid Glass included.
    @Test(arguments: Theme.allCases)
    func accessibilityMakesSurfacesSolid(_ theme: Theme) {
        for dark in [false, true] {
            for v in [Tokens.Variant(dark: dark, theme: theme, reduceTransparency: true),
                      .init(dark: dark, theme: theme, increaseContrast: true)] {
                let t = Tokens(v)
                #expect(t.well.alpha == 1 && t.windowBackground.alpha == 1 && t.panel.alpha == 1, "\(v)")
            }
            #expect(!Tokens(.init(dark: dark, theme: theme, reduceTransparency: true)).usesGlass)
        }
    }

    /// Button labels on their fills, over the surfaces buttons sit on (WCAG AA, 4.5:1).
    @Test(arguments: variants)
    func buttonLabelsRead(_ v: Tokens.Variant) {
        let t = Tokens(v)
        typealias C = QAUIContrastTests
        for (sName, surface) in [("well", C.opaque(t.well)), ("tile", t.opaqueSurface)] {
            // The neutral capsule: the label on its faint fill over the surface.
            let pill = SwitcherSurface.over(t.text.opacity(0.07), surface)
            #expect(C.ratio(t.text, on: pill) >= 4.5, "pill label on \(sName), \(v)")
            #expect(C.ratio(t.rose, on: pill) >= 4.5, "destructive label on \(sName), \(v)")
            #expect(C.ratio(t.secondaryText, on: pill) >= 4.5, "quiet label on \(sName), \(v)")
            #expect(C.ratio(t.emberText, on: surface) >= 4.5, "link on \(sName), \(v)")
        }
        #expect(C.ratio(t.onEmber, on: t.emberMark) >= 4.5, "primary label, \(v)")
    }
}

/// No colour literals outside the token files: views name a token, so light and dark, Reduce
/// Transparency and Increase Contrast all follow.
struct NoHardCodedColourTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    /// Where literals belong: the tokens, and brand art drawn to the brand spec.
    static let allowed: Set<String> = [
        "BuddyOverlay/Tokens.swift",
        "Lumi/MenuBarIcon.swift",          // the menu bar mark (brand spec, AppKit drawing)
        "BuddyCompanion/Studio/LumiOrb.swift", // the orb's specular highlight (brand art)
    ]

    static let patterns = [
        #"Color\((red|white|hue|\.sRGB)[:,]"#,
        #"NSColor\((srgbRed|red|white|calibratedRed|calibratedWhite|deviceRed|deviceWhite|displayP3Red):"#,
        #"(Color|NSColor)\.(white|black|gray|red|green|blue|orange|yellow|pink|purple|brown|accentColor)\b"#,
        #"NSColor\.system(Red|Orange|Green|Blue|Yellow|Pink|Purple|Gray)\b"#,
        #"\.(white|black)\.opacity\("#,
        #"(foregroundStyle|foregroundColor|tint|fill|background)\(\.(white|black|gray|red|green|blue|orange|yellow|pink|purple)\)"#,
    ]

    @Test func noColourLiteralsOutsideTheTokens() throws {
        let regexes = try Self.patterns.map { try NSRegularExpression(pattern: $0) }
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        var hits: [String] = []
        for file in files {
            let relative = String(file.path.dropFirst(Self.sources.path.count + 1))
            guard !Self.allowed.contains(relative) else { continue }
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let range = NSRange(line.startIndex..., in: line)
                if regexes.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                    hits.append("\(relative):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(hits.isEmpty, "Colour literals outside the tokens:\n\(hits.joined(separator: "\n"))")
    }
}

/// The app's accent (App/Assets.xcassets, Info.plist NSAccentColorName) is `emberDeep`: the system
/// draws selected sidebar rows in it with white text, so it must hold 4.5:1 against white.
struct AccentColorAssetTests {
    static let colorset = NoHardCodedColourTests.sources.deletingLastPathComponent()
        .appendingPathComponent("App/Assets.xcassets/AccentColor.colorset/Contents.json")

    @Test func theAccentIsEmberDeepAndReadsUnderWhiteText() throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.colorset)) as? [String: Any]
        let colors = json?["colors"] as? [[String: Any]] ?? []
        #expect(colors.count == 1, "one accent for both appearances")
        let parts = (colors.first?["color"] as? [String: Any])?["components"] as? [String: String] ?? [:]
        func channel(_ key: String) -> Double { Double(UInt8(parts[key]?.dropFirst(2) ?? "", radix: 16) ?? 0) / 255 }
        let accent = TokenColor(channel("red"), channel("green"), channel("blue"))
        for dark in [false, true] {
            #expect(accent == Tokens(.init(dark: dark)).emberDeep, "asset \(accent)")
        }
        #expect(QAUIContrastTests.ratio(TokenColor(1, 1, 1), on: accent) >= 4.5)
    }
}
