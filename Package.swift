// swift-tools-version: 6.2

import PackageDescription

/// Settings shared by every target: Swift 6 language mode (the tools-version default),
/// complete strict concurrency, and the approachable-concurrency upcoming features.
let strict: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .treatAllWarnings(as: .error),
]

/// UI targets default to the main actor.
let ui: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Lumi",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Lumi", targets: ["Lumi"]),
    ],
    dependencies: [
        // Approved outside package; pinned exactly.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0"),
        // On-device speech-to-text, VAD and TTS. Pinned.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        // Shared value types and protocols. No dependencies, no UI.
        .target(name: "BuddyCore", swiftSettings: strict),

        // Engine
        .target(
            name: "BuddyKeys",
            dependencies: ["BuddyCore", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")],
            swiftSettings: strict),
        .target(name: "BuddyContext", dependencies: ["BuddyCore"], swiftSettings: strict),
        .target(name: "BuddyAct", dependencies: ["BuddyCore"], swiftSettings: strict),
        .target(name: "BuddyConversations", dependencies: ["BuddyCore"], swiftSettings: strict),
        // Trace log: timings and event kinds only
        .target(name: "BuddyTrace", dependencies: ["BuddyCore"], swiftSettings: strict),

        // Companion app: Settings and onboarding
        .target(
            name: "BuddyCompanion",
            dependencies: ["BuddyCore", "BuddyKeys", "BuddyContext", "BuddyConversations", "BuddyVoice", "BuddyBridge", "BuddyOverlay"],
            swiftSettings: ui),

        // Voice
        .target(
            name: "BuddyVoice",
            dependencies: ["BuddyCore", .product(name: "FluidAudio", package: "FluidAudio")],
            exclude: ["README.md"],
            swiftSettings: strict
        ),

        // Overlay UI
        .target(name: "BuddyOverlay", dependencies: ["BuddyCore"], swiftSettings: ui),

        // Claude Code bridge
        .target(name: "BuddyBridge", dependencies: ["BuddyCore"], swiftSettings: strict),

        // App shell and integration. BuddyApp holds the testable coordinator;
        // the executable only wires live implementations.
        .target(
            name: "BuddyApp",
            dependencies: [
                "BuddyCore", "BuddyKeys", "BuddyContext", "BuddyAct",
                "BuddyVoice", "BuddyOverlay", "BuddyBridge", "BuddyCompanion", "BuddyConversations", "BuddyTrace",
            ],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "Lumi",
            dependencies: ["BuddyApp", "BuddyCompanion", "BuddyContext", "BuddyConversations", "BuddyTrace", "BuddyVoice"],
            swiftSettings: ui
        ),

        .testTarget(name: "BuddyAppTests", dependencies: ["BuddyApp"], swiftSettings: strict),
        .testTarget(name: "BuddyCoreTests", dependencies: ["BuddyCore"], swiftSettings: strict),
        .testTarget(name: "BuddyKeysTests", dependencies: ["BuddyKeys"], swiftSettings: strict),
        .testTarget(name: "BuddyContextTests", dependencies: ["BuddyContext"], swiftSettings: strict),
        .testTarget(name: "BuddyActTests", dependencies: ["BuddyAct"], swiftSettings: strict),
        .testTarget(name: "BuddyConversationsTests", dependencies: ["BuddyConversations"], swiftSettings: strict),
        .testTarget(name: "BuddyTraceTests", dependencies: ["BuddyTrace"], swiftSettings: strict),
        .testTarget(name: "BuddyCompanionTests", dependencies: ["BuddyCompanion"], swiftSettings: ui),
        .testTarget(
            name: "BuddyVoiceTests",
            dependencies: ["BuddyVoice", .product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: strict
        ),
        .testTarget(name: "BuddyOverlayTests", dependencies: ["BuddyOverlay"], swiftSettings: ui),
        .testTarget(name: "BuddyBridgeTests", dependencies: ["BuddyBridge"], exclude: ["Fixtures"], swiftSettings: strict),
    ]
)
