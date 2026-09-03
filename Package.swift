// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Clapboard",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Clapboard", targets: ["ClapboardApp"]),
        .library(name: "ClapboardCore", targets: ["ClapboardCore"])
    ],
    targets: [
        .executableTarget(
            name: "ClapboardApp",
            dependencies: ["ClapboardCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Core stays in Swift 5 language mode on purpose: the real-time audio
        // path (RT/) is built from raw pointers and atomics that strict
        // concurrency checking cannot reason about, and nothing in Core may be
        // main-actor isolated by default.
        .target(
            name: "ClapboardCore",
            exclude: ["Sync/README.md"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClapboardCoreTests",
            dependencies: ["ClapboardCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
