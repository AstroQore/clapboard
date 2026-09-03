import Foundation
import Testing

/// The in-app updater is configured by three files that no test can reach at
/// runtime — `Resources/Info.plist` is read from the built bundle, `Package.swift`
/// pins the framework, and `Scripts/build_app.sh` embeds and signs it — and a
/// mistake in any of them only shows up on a user's Mac, after a release has
/// been published, as an update that cannot be verified or an app that will not
/// launch. So they are checked here, as text, against the repository.
@Suite("Sparkle update pipeline contract")
struct UpdateFeedContractTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ClapboardCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root

    private static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    private static func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appending(path: "Resources/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        return try #require(plist as? [String: Any])
    }

    @Test func feedURLPointsAtTheMachineManagedUpdatesBranch() throws {
        let plist = try Self.infoPlist()
        #expect(
            plist["SUFeedURL"] as? String
                == "https://raw.githubusercontent.com/AstroQore/clapboard/updates/appcast.xml"
        )
    }

    /// Sparkle reads these before it will fetch anything; a missing key is a
    /// silent fallback to Sparkle's own default, not an error.
    @Test func updateBehaviourIsDeclaredExplicitly() throws {
        let plist = try Self.infoPlist()
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(plist["SUScheduledCheckInterval"] as? Int == 86400)
        // Clapboard is a live audio mixer: an update must never install itself
        // out from under a running session.
        #expect(plist["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(plist["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(plist["SUEnableSystemProfiling"] as? Bool == false)
        #expect(plist["SUShowReleaseNotes"] as? Bool == true)
        // Verify the EdDSA signature before unpacking, not after.
        #expect(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
    }

    /// Either the placeholder this repository ships, or a real 32-byte ed25519
    /// public key. Anything else — an empty string, a truncated paste — would
    /// leave Sparkle unable to verify a download it had already fetched.
    @Test func publicKeyIsEitherTheMarkedPlaceholderOrAWholeKey() throws {
        let plist = try Self.infoPlist()
        let key = try #require(plist["SUPublicEDKey"] as? String)
        if key == "REPLACE_ME_WITH_SPARKLE_PUBLIC_ED_KEY" { return }
        let decoded = try #require(
            Data(base64Encoded: key),
            "SUPublicEDKey must be base64"
        )
        #expect(decoded.count == 32)
    }

    /// `Package.resolved` is git-ignored, so the pin in `Package.swift` is the
    /// only thing making two builds of one commit carry the same Sparkle.
    @Test func sparkleIsPinnedToAnExactVersion() throws {
        let manifest = try Self.text("Package.swift")
        #expect(manifest.contains(#"url: "https://github.com/sparkle-project/Sparkle", exact: "#))
        #expect(!manifest.contains("sparkle-project/Sparkle\", from:"))
        // Without the rpath the executable cannot find the framework the build
        // script puts in Contents/Frameworks, and the app dies at launch.
        #expect(manifest.contains("@loader_path/../Frameworks"))
    }

    /// codesign seals whatever it finds, so anything signed *after* the app
    /// bundle invalidates the app's own signature.
    @Test func buildScriptSignsSparkleBeforeTheAppBundle() throws {
        let script = try Self.text("Scripts/build_app.sh")
        let helpers = [
            "XPCServices/Installer.xpc",
            "XPCServices/Downloader.xpc",
            "$SPARKLE_VERSION_DIR/Autoupdate",
            "$SPARKLE_VERSION_DIR/Updater.app"
        ]
        let appSigning = try #require(
            script.range(of: "--entitlements \"$ENTITLEMENTS\" \"$APP_DIR\""),
            "the app bundle signing step moved"
        )
        for helper in helpers {
            let signing = try #require(
                script.range(of: helper),
                "\(helper) is no longer signed"
            )
            #expect(
                signing.upperBound < appSigning.lowerBound,
                "\(helper) must be signed before the app bundle"
            )
        }
    }

    /// Downloader.xpc is the sandboxed half of Sparkle and the only component
    /// that touches the network. Re-signing it without preserving its
    /// entitlements drops the sandbox along with them.
    @Test func downloaderKeepsItsOwnEntitlements() throws {
        let script = try Self.text("Scripts/build_app.sh")
        let preserve = try #require(script.range(of: "--preserve-metadata=entitlements"))
        let downloader = try #require(script.range(of: "XPCServices/Downloader.xpc"))
        #expect(preserve.upperBound < downloader.lowerBound)
    }

    /// Sparkle is MIT-licensed and redistributed inside the bundle, so its
    /// notice has to travel with the binary.
    @Test func sparkleLicenseShipsWithTheApp() throws {
        let license = try Self.text("Resources/ThirdPartyLicenses/Sparkle.txt")
        #expect(license.contains("Andy Matuschak"))
        #expect(license.contains("Permission is hereby granted"))
        let script = try Self.text("Scripts/build_app.sh")
        #expect(script.contains("Resources/ThirdPartyLicenses"))
        #expect(try Self.text("THIRD_PARTY_NOTICES.md").contains("Sparkle"))
    }
}
