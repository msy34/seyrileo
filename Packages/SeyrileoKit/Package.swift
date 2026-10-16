// swift-tools-version: 6.0
import PackageDescription

// Shared, UI-free code for Seyrileo. Kept platform-neutral (iOS + macOS for fast `swift test`)
// so a future tvOS target can reuse domain, provider and playback logic without its UI.
let package = Package(
    name: "SeyrileoKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SeyrileoKit", targets: ["SeyrileoKit"]),
        .library(name: "SeyrileoFixtureServer", targets: ["SeyrileoFixtureServer"]),
    ],
    dependencies: [
        // MIT license; version and license verified 2026-10-15 (see docs/adr/0002). Pinned exactly.
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "SeyrileoKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Loopback-only HTTP server that serves synthetic Xtream-shaped responses and
        // original generated test media. Isolated so it can be excluded from a release later.
        .target(
            name: "SeyrileoFixtureServer",
            resources: [.copy("Media")]
        ),
        .testTarget(
            name: "SeyrileoKitTests",
            dependencies: ["SeyrileoKit", "SeyrileoFixtureServer"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
