import ClapboardCore
import Foundation
import Testing

@Suite("DriverVersion")
struct DriverVersionTests {
    @Test func parsesDottedComponents() throws {
        let version = try #require(DriverVersion("1.2.3"))
        #expect(version.components == [1, 2, 3])
        #expect(version.raw == "1.2.3")
        #expect(version.description == "1.2.3")
    }

    @Test func trimsWhitespaceAndStopsAtNonNumericComponents() throws {
        #expect(try #require(DriverVersion("  2.0 ")).components == [2, 0])
        // "1.0b3" is a beta of 1.0, not 1.0.3.
        #expect(try #require(DriverVersion("1.0b3")).components == [1, 0])
        #expect(try #require(DriverVersion("3.1.rc2")).components == [3, 1])
    }

    @Test func rejectsStringsWithNoLeadingNumber() {
        // An empty CFBundleVersion is a missing version, not version zero.
        #expect(DriverVersion("") == nil)
        #expect(DriverVersion("   ") == nil)
        #expect(DriverVersion("beta") == nil)
        #expect(DriverVersion("v1.0") == nil)
    }

    @Test func trailingZerosDoNotChangeTheVersion() throws {
        let short = try #require(DriverVersion("1.0"))
        let long = try #require(DriverVersion("1.0.0"))
        #expect(short == long)
        #expect(!(short < long))
        #expect(!(long < short))
        #expect(short.hashValue == long.hashValue)
    }

    @Test func ordersByComponent() throws {
        let v100 = try #require(DriverVersion("1.0.0"))
        let v101 = try #require(DriverVersion("1.0.1"))
        let v110 = try #require(DriverVersion("1.1"))
        let v200 = try #require(DriverVersion("2.0"))
        let v1010 = try #require(DriverVersion("1.0.10"))
        #expect(v100 < v101)
        #expect(v101 < v110)
        #expect(v110 < v200)
        // Not a string comparison: 10 > 2.
        #expect(try #require(DriverVersion("1.0.2")) < v1010)
        #expect([v200, v100, v110, v101].sorted() == [v100, v101, v110, v200])
    }
}

@Suite("DriverInstallation state")
struct DriverInstallationStateTests {
    private func version(_ string: String) throws -> DriverVersion {
        try #require(DriverVersion(string))
    }

    @Test func nothingInstalledAndNoInstallerIsUnavailable() {
        #expect(DriverInstallation.state(installed: nil, bundled: nil) == .installerUnavailable)
        #expect(DriverInstallation.state(installed: nil, bundled: nil).name == "installerUnavailable")
        #expect(!DriverInstallation.state(installed: nil, bundled: nil).isInstalled)
    }

    @Test func nothingInstalledWithAnInstallerIsNotInstalled() throws {
        let state = DriverInstallation.state(installed: nil, bundled: try version("1.0.0"))
        #expect(state == .notInstalled)
        #expect(state.installedVersion == nil)
        #expect(!state.isInstalled)
    }

    @Test func sameVersionIsInstalled() throws {
        let state = DriverInstallation.state(
            installed: try version("1.0.0"), bundled: try version("1.0")
        )
        #expect(state == .installed(version: try version("1.0.0")))
        #expect(state.isInstalled)
        #expect(state.installedVersion == (try version("1.0")))
    }

    @Test func aNewerBundledPackageMakesTheInstalledDriverOutdated() throws {
        let state = DriverInstallation.state(
            installed: try version("1.0.0"), bundled: try version("1.2")
        )
        #expect(state == .outdated(installed: try version("1.0"), bundled: try version("1.2")))
        #expect(state.isInstalled)
        #expect(state.installedVersion == (try version("1.0.0")))
        #expect(state.name == "outdated")
    }

    @Test func anOlderBundledPackageIsNotAnUpdate() throws {
        // Downgrades are not offered: a newer driver on disk than the app
        // carries is a perfectly good driver.
        let state = DriverInstallation.state(
            installed: try version("2.0"), bundled: try version("1.0")
        )
        #expect(state == .installed(version: try version("2.0")))
    }

    @Test func anInstalledDriverBeatsAMissingInstaller() throws {
        // installerUnavailable is about what this build could install, and
        // that only matters when there is nothing installed.
        let state = DriverInstallation.state(installed: try version("1.0"), bundled: nil)
        #expect(state == .installed(version: try version("1.0")))
    }
}

@Suite("DriverInstallation device UIDs")
struct DriverInstallationDeviceTests {
    private let prefix = DriverInstallation.busUIDPrefix

    @Test func picksOutClapboardBusesAndIgnoresEverythingElse() {
        let uids = [
            "BuiltInSpeakerDevice",
            "\(prefix)2",
            "com.rogueamoeba.Loopback:ABC",
            "\(prefix)1",
            "com.astroqore.Clapboard.aggregate"
        ]
        #expect(DriverInstallation.busUIDs(in: uids) == ["\(prefix)1", "\(prefix)2"])
    }

    @Test func ordersByBusNumberNotByString() {
        let uids = ["\(prefix)10", "\(prefix)2", "\(prefix)1"]
        #expect(DriverInstallation.busUIDs(in: uids) == ["\(prefix)1", "\(prefix)2", "\(prefix)10"])
    }

    @Test func unparseableSuffixesSortLast() {
        let uids = ["\(prefix)zzz", "\(prefix)3"]
        #expect(DriverInstallation.busUIDs(in: uids) == ["\(prefix)3", "\(prefix)zzz"])
    }

    @Test func busIndexDecodesTheSuffix() {
        #expect(DriverInstallation.busIndex(forUID: "\(prefix)4") == 4)
        #expect(DriverInstallation.busIndex(forUID: "\(prefix)") == nil)
        #expect(DriverInstallation.busIndex(forUID: "BuiltInSpeakerDevice") == nil)
    }

    @Test func noBusesMeansNoDevices() {
        #expect(DriverInstallation.busUIDs(in: []).isEmpty)
        #expect(DriverInstallation.busUIDs(in: ["BuiltInMicrophoneDevice"]).isEmpty)
    }
}

@Suite("DriverStatus")
struct DriverStatusTests {
    private let prefix = DriverInstallation.busUIDPrefix

    private func version(_ string: String) throws -> DriverVersion {
        try #require(DriverVersion(string))
    }

    private func installer(_ versionString: String, uninstaller: Bool = true) throws
        -> BundledDriverInstaller {
        BundledDriverInstaller(
            pkgURL: URL(fileURLWithPath: "/tmp/ClapboardDriver.pkg"),
            uninstallerPkgURL: uninstaller
                ? URL(fileURLWithPath: "/tmp/ClapboardDriverUninstaller.pkg") : nil,
            version: try version(versionString),
            shortVersion: nil,
            busCount: 4
        )
    }

    @Test func aDriverOnDiskWithNoDevicesNeedsCoreAudioRestarted() throws {
        // The one state a user cannot diagnose: the plug-in is installed but
        // coreaudiod has not loaded it, so nothing in the device list explains
        // where Clapboard Bus 1 went.
        let status = DriverInstallation.status(
            installed: try version("1.0.0"),
            bundled: try installer("1.0.0"),
            deviceUIDs: ["BuiltInSpeakerDevice"]
        )
        #expect(status.isInstalled)
        #expect(!status.devicesPresent)
        #expect(status.needsCoreAudioRestart)
        #expect(status.summary.contains("needs a restart"))
    }

    @Test func devicesPresentIsTheHappyPath() throws {
        let status = DriverInstallation.status(
            installed: try version("1.0.0"),
            bundled: try installer("1.0.0"),
            deviceUIDs: ["\(prefix)1", "\(prefix)2", "BuiltInSpeakerDevice"]
        )
        #expect(status.devicesPresent)
        #expect(!status.needsCoreAudioRestart)
        #expect(status.busDeviceUIDs.count == 2)
        #expect(status.canUninstall)
        #expect(status.canInstall)
    }

    @Test func devicesCanBePresentWithNothingReadableOnDisk() throws {
        // /Library is readable by everyone, but a driver installed by some
        // other means still shows up as devices. Presence is reported on its
        // own evidence, never inferred from the install state.
        let status = DriverInstallation.status(
            installed: nil,
            bundled: try installer("1.0.0"),
            deviceUIDs: ["\(prefix)1"]
        )
        #expect(status.state == .notInstalled)
        #expect(status.devicesPresent)
        #expect(!status.needsCoreAudioRestart)
    }

    @Test func anAppWithNoInstallerSaysSo() {
        let status = DriverInstallation.status(installed: nil, bundled: nil, deviceUIDs: [])
        #expect(status.state == .installerUnavailable)
        #expect(!status.canInstall)
        #expect(!status.canUninstall)
        #expect(status.summary.contains("Scripts/build_driver_pkg.sh"))
    }

    @Test func withoutAnUninstallerPackageUninstallIsNotOffered() throws {
        let status = DriverInstallation.status(
            installed: try version("1.0.0"),
            bundled: try installer("1.0.0", uninstaller: false),
            deviceUIDs: ["\(prefix)1"]
        )
        #expect(status.canInstall)
        #expect(!status.canUninstall)
    }

    @Test func outdatedSummaryNamesBothVersions() throws {
        let status = DriverInstallation.status(
            installed: try version("1.0.0"),
            bundled: try installer("1.4.0"),
            deviceUIDs: ["\(prefix)1"]
        )
        #expect(status.summary.contains("1.0.0"))
        #expect(status.summary.contains("1.4.0"))
    }

    @Test func notInstalledSummaryNamesTheBundledVersion() throws {
        let status = DriverInstallation.status(
            installed: nil, bundled: try installer("1.0.0"), deviceUIDs: []
        )
        #expect(status.summary.contains("1.0.0"))
    }
}

@Suite("DriverInstallation bundle reading")
struct DriverInstallationBundleTests {
    private func makeDirectory() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClapboardDriverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func writeInfoPlist(
        at url: URL, identifier: String?, version: String?, shortVersion: String?
    ) throws {
        var plist: [String: Any] = [:]
        if let identifier { plist["CFBundleIdentifier"] = identifier }
        if let version { plist["CFBundleVersion"] = version }
        if let shortVersion { plist["CFBundleShortVersionString"] = shortVersion }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: url)
    }

    @Test func readsCFBundleVersion() throws {
        let base = try makeDirectory()
        let plist = base.appendingPathComponent("Info.plist")
        try writeInfoPlist(
            at: plist,
            identifier: DriverInstallation.driverBundleIdentifier,
            version: "1.2.3",
            shortVersion: "1.2"
        )
        #expect(DriverInstallation.version(inInfoPlistAt: plist) == DriverVersion("1.2.3"))
    }

    @Test func fallsBackToTheShortVersionString() throws {
        let base = try makeDirectory()
        let plist = base.appendingPathComponent("Info.plist")
        try writeInfoPlist(
            at: plist,
            identifier: DriverInstallation.driverBundleIdentifier,
            version: nil,
            shortVersion: "2.5"
        )
        #expect(DriverInstallation.version(inInfoPlistAt: plist) == DriverVersion("2.5"))
    }

    @Test func refusesABundleThatIsNotOurDriver() throws {
        // Something else living at /Library/Audio/Plug-Ins/HAL/ClapboardDriver.driver
        // is not a Clapboard driver, and reporting its version would be a lie.
        let base = try makeDirectory()
        let plist = base.appendingPathComponent("Info.plist")
        try writeInfoPlist(
            at: plist, identifier: "com.example.Other", version: "9.9", shortVersion: nil
        )
        #expect(DriverInstallation.version(inInfoPlistAt: plist) == nil)
    }

    @Test func missingOrUnreadablePlistIsNotInstalled() throws {
        let base = try makeDirectory()
        #expect(DriverInstallation.version(
            inInfoPlistAt: base.appendingPathComponent("Nope.plist")
        ) == nil)
        let junk = base.appendingPathComponent("Info.plist")
        try Data("not a plist".utf8).write(to: junk)
        #expect(DriverInstallation.version(inInfoPlistAt: junk) == nil)
        #expect(DriverInstallation.installedVersion(
            driverURL: base.appendingPathComponent("Missing.driver")
        ) == nil)
    }

    // MARK: - The manifest written by Scripts/build_app.sh

    private func writeManifest(
        in resources: URL,
        pkgName: String = "ClapboardDriver.pkg",
        uninstallerPkgName: String? = "ClapboardDriverUninstaller.pkg",
        driverVersion: String = "1.0.0"
    ) throws {
        var plist: [String: Any] = [
            "pkgName": pkgName,
            "driverVersion": driverVersion,
            "driverShortVersion": "1.0",
            "busCount": 4
        ]
        if let uninstallerPkgName { plist["uninstallerPkgName"] = uninstallerPkgName }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: resources.appendingPathComponent(DriverInstallation.manifestName))
    }

    private func touch(_ url: URL) throws {
        try Data("pkg".utf8).write(to: url)
    }

    @Test func readsTheBundledInstaller() throws {
        let resources = try makeDirectory()
        try writeManifest(in: resources)
        try touch(resources.appendingPathComponent("ClapboardDriver.pkg"))
        try touch(resources.appendingPathComponent("ClapboardDriverUninstaller.pkg"))

        let installer = try #require(DriverInstallation.bundledInstaller(resourcesURL: resources))
        #expect(installer.version == DriverVersion("1.0"))
        #expect(installer.shortVersion == "1.0")
        #expect(installer.busCount == 4)
        #expect(installer.pkgURL.lastPathComponent == "ClapboardDriver.pkg")
        #expect(installer.uninstallerPkgURL?.lastPathComponent == "ClapboardDriverUninstaller.pkg")
    }

    @Test func anUninstallerThatWasNotBuiltIsSimplyAbsent() throws {
        let resources = try makeDirectory()
        try writeManifest(in: resources, uninstallerPkgName: nil)
        try touch(resources.appendingPathComponent("ClapboardDriver.pkg"))
        let installer = try #require(DriverInstallation.bundledInstaller(resourcesURL: resources))
        #expect(installer.uninstallerPkgURL == nil)
    }

    @Test func aManifestNamingAMissingUninstallerDoesNotInventOne() throws {
        let resources = try makeDirectory()
        try writeManifest(in: resources)
        try touch(resources.appendingPathComponent("ClapboardDriver.pkg"))
        let installer = try #require(DriverInstallation.bundledInstaller(resourcesURL: resources))
        #expect(installer.uninstallerPkgURL == nil)
    }

    @Test func aManifestWithNoPackageBesideItIsUnavailable() throws {
        let resources = try makeDirectory()
        try writeManifest(in: resources)
        #expect(DriverInstallation.bundledInstaller(resourcesURL: resources) == nil)
    }

    @Test func noManifestMeansNoInstaller() throws {
        // What `swift run` and a driver-less build_app.sh both produce.
        let resources = try makeDirectory()
        try touch(resources.appendingPathComponent("ClapboardDriver.pkg"))
        #expect(DriverInstallation.bundledInstaller(resourcesURL: resources) == nil)
        #expect(DriverInstallation.bundledInstaller(resourcesURL: nil) == nil)
    }

    @Test func anUnparseableManifestVersionMeansNoInstaller() throws {
        let resources = try makeDirectory()
        try writeManifest(in: resources, driverVersion: "")
        try touch(resources.appendingPathComponent("ClapboardDriver.pkg"))
        #expect(DriverInstallation.bundledInstaller(resourcesURL: resources) == nil)
    }

    @Test func probeOfABareDirectoryReportsInstallerUnavailable() throws {
        let base = try makeDirectory()
        let status = DriverInstallation.probe(
            resourcesURL: base,
            driverURL: base.appendingPathComponent("NotADriver.driver"),
            deviceUIDs: []
        )
        #expect(status.state == .installerUnavailable)
        #expect(!status.devicesPresent)
    }
}

@Suite("SetupCompletion")
struct SetupCompletionTests {
    @Test func neverRunMeansPresent() {
        #expect(SetupCompletion.shouldPresent(completedVersion: nil))
    }

    @Test func anUnreadableRecordMeansPresent() {
        #expect(SetupCompletion.shouldPresent(completedVersion: ""))
        #expect(SetupCompletion.shouldPresent(completedVersion: "nightly"))
    }

    @Test func theSameVersionDoesNotPresentAgain() {
        #expect(!SetupCompletion.shouldPresent(
            completedVersion: "0.2.0", required: "0.2.0"
        ))
        #expect(!SetupCompletion.shouldPresent(
            completedVersion: "0.2", required: "0.2.0"
        ))
    }

    @Test func aLaterVersionDoesNotPresentAgain() {
        #expect(!SetupCompletion.shouldPresent(
            completedVersion: "1.0.0", required: "0.2.0"
        ))
    }

    @Test func aVersionThatAddedAStepPresentsAgain() {
        // The reason the key holds a version rather than a boolean: a release
        // that adds a step can raise `requiredVersion` and reach exactly the
        // people who have not seen it.
        #expect(SetupCompletion.shouldPresent(
            completedVersion: "0.1.0", required: "0.2.0"
        ))
    }

    @Test func theShippingDefaultIsSelfConsistent() {
        #expect(!SetupCompletion.shouldPresent(completedVersion: SetupCompletion.requiredVersion))
        #expect(DriverVersion(SetupCompletion.requiredVersion) != nil)
    }
}
