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
        // Standalone fixture host (no Apple Music Adapter)
        .executable(name: "FixtureHost", targets: ["FixtureHost"]),
        // Shared domain library (models + protocols)
        .library(name: "Domain", targets: ["Domain"]),
        // Infrastructure
        .library(name: "Infrastructure", targets: ["Infrastructure"]),
        // PlatformRuntime (generic registry, session scopes, engine router)
        .library(name: "PlatformRuntime", targets: ["PlatformRuntime"]),
        // Application services
        .library(name: "Application", targets: ["Application"]),
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

        // ─── PlatformRuntime ──────────────────────────────────────────
        .target(
            name: "PlatformRuntime",
            dependencies: ["Domain", "Infrastructure"],
            path: "Sources/PlatformRuntime",
            swiftSettings: sharedSwiftSettings
        ),

        // ─── Application ──────────────────────────────────────────────
        .target(
            name: "Application",
            dependencies: ["Domain", "Playback", "PlatformRuntime", "Infrastructure"],
            path: "Sources/Application",
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
            dependencies: ["Domain", "Playback", "Application", "PlatformRuntime", "Lyrics", "DesignSystem", "Infrastructure"],
            path: "Sources/UI",
            swiftSettings: sharedSwiftSettings
        ),

        // ─── Apple Music Integration UI (isolated from generic UI) ─────
        .target(
            name: "AppleMusicIntegrationUI",
            dependencies: ["Domain", "DesignSystem", "Providers", "Infrastructure"],
            path: "Sources/AppleMusicIntegrationUI",
            swiftSettings: sharedSwiftSettings
        ),

        // ─── Executable ───────────────────────────────────────────────
        .executableTarget(
            name: "App",
            dependencies: ["Domain", "Playback", "PlatformRuntime", "Application", "Lyrics", "Providers", "DesignSystem", "UI", "AppleMusicIntegrationUI", "Infrastructure"],
            path: "Sources/App",
            swiftSettings: sharedSwiftSettings
        ),

        // ─── Standalone Fixture Host (No Apple Music Adapter) ──────────
        .executableTarget(
            name: "FixtureHost",
            dependencies: ["Domain", "Playback", "PlatformRuntime", "Application", "Lyrics", "DesignSystem", "UI", "Infrastructure"],
            path: "Sources/FixtureHost",
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
            dependencies: ["Domain", "Providers", "PlatformRuntime", "Application", "Playback", "Infrastructure"],
            path: "Tests/Unit",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem", "UI", "Domain", "Playback", "Providers"],
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
