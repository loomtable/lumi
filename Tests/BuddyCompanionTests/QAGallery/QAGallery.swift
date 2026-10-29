import AppKit
import BuddyCore
import BuddyVoice
import Foundation
import SwiftUI
import Testing
@testable import BuddyCompanion
@testable import BuddyOverlay

// The v2 screen gallery (qa-ui): renders every v2 screen with fake data into offscreen windows
// and writes PNGs plus a VoiceOver dump per screen. Nothing is shown on screen and nothing asks
// for a permission: the windows sit far off every display, permission and Keychain reads are
// faked, and the settings store uses its own defaults suite.
//
// Runs only when LUMI_QA_SHOTS names an output folder:
//   LUMI_QA_SHOTS=~/Developer/lumi/worktrees/_qa-shots swift test --filter QAGallery

nonisolated enum Gallery {
    static let out: URL? = ProcessInfo.processInfo.environment["LUMI_QA_SHOTS"].map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    }
    static var enabled: Bool { out != nil }
}

/// One rendering condition.
nonisolated struct Look: Sendable, CustomStringConvertible {
    var dark = false
    var reduceTransparency = false
    var increaseContrast = false
    var reduceMotion = false
    var theme: Theme = .system

    static let light = Look()
    static let dark = Look(dark: true)
    /// Liquid Glass doesn't draw offscreen, so floating surfaces are reviewed with Reduce
    /// Transparency (the opaque surface); the plain looks are kept for the Studio's own chrome.
    static let lightRT = Look(dark: false, reduceTransparency: true)
    static let darkRT = Look(dark: true, reduceTransparency: true)
    static let floating: [Look] = [.lightRT, .darkRT]
    static let all: [Look] = [
        .lightRT, .darkRT,
        Look(dark: false, reduceTransparency: true, increaseContrast: true),
        Look(dark: true, reduceTransparency: true, increaseContrast: true),
        Look(dark: true, reduceTransparency: true, reduceMotion: true),
    ]

    var description: String {
        var s = dark ? "dark" : "light"
        if reduceTransparency { s += "-rt" }
        if increaseContrast { s += "-ic" }
        if reduceMotion { s += "-rm" }
        if theme != .system { s = "\(theme.rawValue)-\(s)" }
        return s
    }
}

@MainActor
enum Shot {
    /// Renders `view` at `size` in an offscreen borderless window and writes `<name>.<look>.png`
    /// and `<name>.<look>.ax.txt`. `prepare` runs after the first layout (press buttons, scroll).
    @discardableResult
    static func take<V: View>(_ name: String, _ look: Look, size: CGSize, backdrop: Backdrop = .none,
                              settle: Duration = .milliseconds(450),
                              prepare: ((NSView) async -> Void)? = nil,
                              @ViewBuilder _ content: () -> V) async -> NSView? {
        guard let out = Gallery.out else { return nil }
        let root = content()
            .frame(width: size.width, height: size.height)
            .background { backdrop.view(dark: look.dark).frame(width: size.width, height: size.height, alignment: .topLeading).clipped() }
        .environment(\.colorScheme, look.dark ? .dark : .light)
        .environment(\.lumiTheme, look.theme)
        .environment(\._accessibilityReduceTransparency, look.reduceTransparency)
        .environment(\._colorSchemeContrast, look.increaseContrast ? .increased : .standard)
        .environment(\._accessibilityReduceMotion, look.reduceMotion)
        .environment(\.permissions, GalleryPermissions.shared)
        .environment(\.elevenLabsAccount, GalleryElevenLabs())

        let window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: look.dark ? .darkAqua : .aqua)
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.backgroundColor = look.dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.95, alpha: 1)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrame(CGRect(x: -30_000, y: -30_000, width: size.width, height: size.height), display: false)
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }

        try? await Task.sleep(for: settle)
        host.layoutSubtreeIfNeeded()
        if let prepare {
            await prepare(host)
            try? await Task.sleep(for: settle)
            host.layoutSubtreeIfNeeded()
        }
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return host }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let base = out.appendingPathComponent("\(name).\(look)")
        try? rep.representation(using: .png, properties: [:])?.write(to: base.appendingPathExtension("png"))
        let ax = AX.dump(host)
        try? ax.joined(separator: "\n").write(to: base.appendingPathExtension("ax.txt"), atomically: true, encoding: .utf8)
        return host
    }
}

/// What sits behind a floating surface: the user's own work, light or dark, busy enough that
/// low-contrast glass shows.
enum Backdrop {
    case none, desktop, bright

    @ViewBuilder func view(dark: Bool) -> some View {
        switch self {
        case .none:
            Color(nsColor: dark ? NSColor(srgbRed: 0.067, green: 0.075, blue: 0.09, alpha: 1)
                                : NSColor(srgbRed: 0.965, green: 0.957, blue: 0.94, alpha: 1))
        case .desktop:
            ZStack {
                LinearGradient(colors: dark ? [Color(white: 0.10), Color(red: 0.12, green: 0.14, blue: 0.2)]
                                            : [Color(white: 0.92), Color(red: 0.78, green: 0.84, blue: 0.92)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<40, id: \.self) { i in
                        Text("Q3 budget · row \(i) · March invoices 42,180 · April 39,920 · variance +5.6%")
                            .font(.system(size: 12))
                            .foregroundStyle(dark ? Color(white: 0.75) : Color(white: 0.25))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        case .bright:
            Color.white
        }
    }
}

// MARK: - VoiceOver dump

@MainActor
enum AX {
    /// Every accessibility element under `view`: role, label, title, value. Buttons with no label
    /// are flagged "UNLABELLED".
    static func dump(_ view: NSView) -> [String] {
        var out: [String] = []
        walk(view, depth: 0, into: &out)
        return out
    }

    private static func walk(_ element: Any, depth: Int, into out: inout [String]) {
        guard depth < 60, let e = element as AnyObject? else { return }
        let role = (e.accessibilityRole?() as NSAccessibility.Role?)?.rawValue ?? "-"
        let label = (e.accessibilityLabel?() as String?) ?? ""
        let title = (e.accessibilityTitle?() as String?) ?? ""
        let rawValue: Any?? = e.accessibilityValue?()
        let value = rawValue.flatMap { $0 }.map { "\($0)" } ?? ""
        let help = (e.accessibilityHelp?() as String?) ?? ""
        let interactive = role == "AXButton" || role == "AXCheckBox" || role == "AXPopUpButton" || role == "AXMenuButton"
            || role == "AXTextField" || role == "AXRadioButton"
        let named = !(label.isEmpty && title.isEmpty && value.isEmpty && help.isEmpty)
        var line = String(repeating: "  ", count: depth) + role
        if !label.isEmpty { line += " label=\"\(label)\"" }
        if !title.isEmpty { line += " title=\"\(title)\"" }
        if !value.isEmpty, value.count < 200 { line += " value=\"\(value)\"" }
        if !help.isEmpty { line += " help=\"\(help)\"" }
        if interactive, !named { line += "   <<UNLABELLED>>" }
        if !(e is NSHostingView<AnyView>) { out.append(line) }
        for child in (e.accessibilityChildren?() as [Any]?) ?? [] {
            walk(child, depth: depth + 1, into: &out)
        }
    }

    /// Finds the first element whose label or title contains `text` and presses it.
    @discardableResult
    static func press(_ text: String, in view: NSView) -> Bool {
        find(text, in: view, depth: 0).map { ($0.accessibilityPerformPress?() as Bool?) ?? false } ?? false
    }

    private static func find(_ text: String, in element: Any, depth: Int) -> AnyObject? {
        guard depth < 60, let e = element as AnyObject? else { return nil }
        let label = ((e.accessibilityLabel?() as String?) ?? "") + " " + ((e.accessibilityTitle?() as String?) ?? "")
        let role = (e.accessibilityRole?() as NSAccessibility.Role?)?.rawValue ?? ""
        if label.contains(text), role == "AXButton" || role == "AXRadioButton" || role == "AXCell" || role == "AXRow" { return e }
        for child in (e.accessibilityChildren?() as [Any]?) ?? [] {
            if let hit = find(text, in: child, depth: depth + 1) { return hit }
        }
        return nil
    }
}

// MARK: - Fakes (no system reads, no Keychain)

final class GalleryPermissions: PermissionChecking {
    static let shared = GalleryPermissions()
    var states: [PermissionKind: PermissionState] = [:]
    func state(_ kind: PermissionKind) -> PermissionState { states[kind] ?? .granted }
    func request(_ kind: PermissionKind) async -> PermissionState { state(kind) }
    func openSettings(_ kind: PermissionKind) {}
}

struct GalleryElevenLabs: ElevenLabsAccounting {
    var hasKey: Bool { false }
    func saveKey(_ key: String) throws {}
    func deleteKey() throws {}
    func validate() async -> ElevenLabsCheck { .ok }
    func validate(key: String) async -> ElevenLabsCheck { .ok }
    func voices() async throws -> [ElevenLabsVoice] { [] }
}
