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
    dependencies: [
        // Sparkle drives the in-app updater (Clapboard > Check for Updates...)
        // and the EdDSA-signed appcast the release pipeline publishes.
        //
        // Pinned to an exact version on purpose, for two reasons:
        //  1. Update discovery, signature verification and installation are
        //     security-sensitive; the pinned tag is the one that was reviewed.
        //  2. `Package.resolved` is git-ignored here, so a release built from a
        //     clean checkout has nothing else to make two builds of the same
        //     Clapboard commit contain the same Sparkle. Bump it deliberately,
        //     and re-check `Resources/ThirdPartyLicenses/Sparkle.txt` when you
        //     do.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "ClapboardApp",
            dependencies: [
                "ClapboardCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle ships as a framework, and `Scripts/build_app.sh` puts it
            // in `Clapboard.app/Contents/Frameworks`. Without this rpath the
            // executable looks for it beside itself and the app will not launch.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../Frameworks"
                ])
            ]
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
