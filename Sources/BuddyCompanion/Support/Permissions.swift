import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

/// The macOS privacy grants Lumi needs.
public enum PermissionKind: String, CaseIterable, Sendable, Identifiable {
    case microphone, inputMonitoring, accessibility, screenRecording

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    /// Why Lumi asks, in one line.
    public var purpose: String {
        switch self {
        case .microphone: "To hear your question while you hold or tap the Lumi key."
        case .inputMonitoring: "To notice the Lumi key. Lumi never records what you type."
        case .accessibility: "To read the selection, handle Esc while a card is open, and insert text."
        case .screenRecording: "To see what's on screen when you ask, and place answers next to it."
        }
    }

    /// The System Settings page for this grant.
    public var settingsURL: URL {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        // macOS 26's Privacy & Security extension.
        return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)")!
    }

    /// macOS only reports these as granted to a process started after the grant.
    public var needsRelaunchAfterGrant: Bool {
        self == .inputMonitoring || self == .screenRecording
    }
}

public enum PermissionState: Sendable, Equatable {
    case granted
    /// Asked and refused, or turned off in System Settings: only System Settings can change it.
    case denied
    /// Never asked: `request` shows the system prompt.
    case notDetermined
}

/// Real: `SystemPermissions`. Fake: `FakePermissions`.
@MainActor
public protocol PermissionChecking: AnyObject {
    /// Never prompts.
    func state(_ kind: PermissionKind) -> PermissionState
    /// Shows the system prompt if macOS still allows it; returns the state afterwards.
    func request(_ kind: PermissionKind) async -> PermissionState
    func openSettings(_ kind: PermissionKind)
}

public final class SystemPermissions: PermissionChecking {
    /// Stateless, so one instance serves everyone (and is the environment default).
    public static let shared = SystemPermissions()

    public init() {}

    public func state(_ kind: PermissionKind) -> PermissionState {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        // These preflights can't tell "never asked" from "refused", so a missing grant reads as
        // not determined and the Fix button both requests and opens System Settings.
        case .inputMonitoring: CGPreflightListenEventAccess() ? .granted : .notDetermined
        case .accessibility: AXIsProcessTrusted() ? .granted : .notDetermined
        case .screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        }
    }

    public func request(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .accessibility:
            // The prompt option key's value; the C global itself isn't concurrency-safe to read.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
        return state(kind)
    }

    public func openSettings(_ kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}

/// For tests and previews.
public final class FakePermissions: PermissionChecking {
    public var states: [PermissionKind: PermissionState]
    /// What `request` turns each permission into.
    public var afterRequest: [PermissionKind: PermissionState]
    public private(set) var requested: [PermissionKind] = []
    public private(set) var opened: [PermissionKind] = []

    public init(_ states: [PermissionKind: PermissionState] = [:], afterRequest: [PermissionKind: PermissionState] = [:]) {
        self.states = states
        self.afterRequest = afterRequest
    }

    public func state(_ kind: PermissionKind) -> PermissionState { states[kind] ?? .notDetermined }

    public func request(_ kind: PermissionKind) async -> PermissionState {
        requested.append(kind)
        if let next = afterRequest[kind] { states[kind] = next }
        return state(kind)
    }

    public func openSettings(_ kind: PermissionKind) { opened.append(kind) }
}
