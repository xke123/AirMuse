// swift-tools-version: 6.2
// AirMuse macOS – Swift Package Manager manifest
// Deployment target: macOS 26  |  Swift 6 strict concurrency

import PackageDescription

let package = Package(
    name: "AirMuse",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        // Main executable
        .executable(name: "AirMuse", targets: ["App"]),
        // Shared domain library (models + protocols)
        .library(name: "Domain", targets: ["Domain"]),
        // Infrastructure
        .library(name: "Infrastructure", targets: ["Infrastructure"]),
        // Providers
        .library(name: "Providers", targets: ["Providers"]),
        // Playback coordination
        .library(name: "Playback", targets: ["Playback"]),
        // Lyrics engine
        .library(name: "Lyrics", targets: ["Lyrics"]),
        // Design System
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        // UI
        .library(name: "UI", targets: ["UI"]),
    ],
    targets: [
        // ─── Domain (models + protocols) ──────────────────────────────
        .target(
            name: "Domain",
            path: "Sources/Domain",
            swiftSettings: sharedSwiftSettings
        ),

        // ─── Infrastructure (SQLite, ImageCache, WebKit) ──────────────
        .target(
            name: "Infrastructure",
            dependencies: ["Domain"],
            path: "Sources/Infrastructure",
            swiftSettings: sharedSwiftSettings
        ),

        // ─── Providers (AppleMusic, Spotify, QQMusic) ─────────────────
        .target(
            name: "Providers",
            dependencies: ["Domain", "Infrastructure"],
            path: "Sources/Providers",
            swiftSettings: sharedSwiftSettings
        ),

        // ─── Playback coordination ────────────────────────────────────
        .target(
            name: "Playback",
            dependencies: ["Domain", "Infrastructure"],
            path: "Sources/Playback",
            swiftSettings: sharedSwiftSettings
        ),

        // ─── Lyrics engine ────────────────────────────────────────────
        .target(
            name: "Lyrics",
            dependencies: ["Domain", "Playback", "Infrastructure"],
            path: "Sources/Lyrics",
            swiftSettings: sharedSwiftSettings
        ),

        // ─── Design System ────────────────────────────────────────────
        .target(
            name: "DesignSystem",
            dependencies: ["Domain"],
            path: "Sources/DesignSystem",
            resources: [
                .copy("Resources")
            ],
            swiftSettings: sharedSwiftSettings
        ),

        // ─── UI ───────────────────────────────────────────────────────
        .target(
            name: "UI",
            dependencies: ["Domain", "Playback", "Lyrics", "DesignSystem", "Providers", "Infrastructure"],
            path: "Sources/UI",
            swiftSettings: sharedSwiftSettings
        ),

        // ─── Executable ───────────────────────────────────────────────
        .executableTarget(
            name: "App",
            dependencies: ["Domain", "Playback", "Lyrics", "Providers", "DesignSystem", "UI", "Infrastructure"],
            path: "Sources/App",
            swiftSettings: sharedSwiftSettings
        ),

        // ─── Tests ────────────────────────────────────────────────────
        .testTarget(
            name: "DomainTests",
            dependencies: ["Domain"],
            path: "Tests/DomainTests",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "PlaybackTests",
            dependencies: ["Playback", "Domain"],
            path: "Tests/PlaybackTests",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "UnitTests",
            dependencies: ["Domain", "Providers", "Infrastructure"],
            path: "Tests/Unit",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem", "UI", "Domain", "Playback"],
            path: "Tests/DesignSystemTests",
            swiftSettings: sharedSwiftSettings
        ),
    ]
)

// Swift 6 strict concurrency settings shared by all targets
private let sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableExperimentalFeature("StrictConcurrency"),
    .unsafeFlags(["-sdk", "/Library/Developer/CommandLineTools/SDKs/MacOSX27.2.sdk"]),
]
