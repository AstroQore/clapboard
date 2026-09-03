import Foundation

/// A dotted version string — `CFBundleVersion` ("1.0.0") or
/// `CFBundleShortVersionString` ("1.0") — with a comparison that does not care
/// how many components were written down.
///
/// Equality and ordering run over the *normalized* components (trailing zeros
/// dropped), so `1.0` and `1.0.0` are the same version and `1.0.1` is newer
/// than both. `raw` is kept for display only and is deliberately outside
/// `==`/`hash`, because two spellings of one version must not compare unequal.
public struct DriverVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Exactly what was read from the plist, for showing to a human.
    public let raw: String
    /// Leading integer of each dot-separated component, in order.
    public let components: [Int]

    /// Fails when the string carries no leading numeric component at all —
    /// an empty `CFBundleVersion` is a missing version, not version zero.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            // "1.0b3" → [1, 0]: take the digits a component starts with and
            // stop at the first component that starts with something else.
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            parsed.append(value)
        }
        guard !parsed.isEmpty else { return nil }
        self.raw = trimmed
        self.components = parsed
    }

    /// Trailing zeros carry no information: `1.0.0` and `1` are one version.
    public var normalized: [Int] {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        return trimmed
    }

    public var description: String { raw }

    public static func == (lhs: DriverVersion, rhs: DriverVersion) -> Bool {
        lhs.normalized == rhs.normalized
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(normalized)
    }

    public static func < (lhs: DriverVersion, rhs: DriverVersion) -> Bool {
        let left = lhs.normalized
        let right = rhs.normalized
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b }
        }
        return false
    }
}

/// What the machine holds versus what this build of Clapboard carries.
///
/// "Installed" here means *on disk*, under `/Library/Audio/Plug-Ins/HAL`. It
/// says nothing about whether `coreaudiod` has loaded the plug-in — that is
/// `DriverStatus.devicesPresent`, and the two really can disagree.
public enum DriverInstallationState: Hashable, Sendable {
    /// No driver on disk, and this build can install one.
    case notInstalled
    /// On disk and not older than what this build carries.
    case installed(version: DriverVersion)
    /// On disk, but this build carries a newer package.
    case outdated(installed: DriverVersion, bundled: DriverVersion)
    /// Nothing on disk and no package inside the app bundle — an app built
    /// without `Scripts/build_driver_pkg.sh` having succeeded.
    case installerUnavailable

    public var isInstalled: Bool {
        switch self {
        case .installed, .outdated: return true
        case .notInstalled, .installerUnavailable: return false
        }
    }

    /// The version sitting in `/Library/Audio/Plug-Ins/HAL`, if any.
    public var installedVersion: DriverVersion? {
        switch self {
        case .installed(let version): return version
        case .outdated(let installed, _): return installed
        case .notInstalled, .installerUnavailable: return nil
        }
    }

    /// Machine-readable name used by `--driver-status` and by tests.
    public var name: String {
        switch self {
        case .notInstalled: return "notInstalled"
        case .installed: return "installed"
        case .outdated: return "outdated"
        case .installerUnavailable: return "installerUnavailable"
        }
    }
}

/// The installer package this build of Clapboard carries in its `Resources`
/// directory, described by the manifest `Scripts/build_app.sh` writes beside
/// it. Both the manifest and the package have to be there: a package whose
/// version is unknown cannot be compared against what is installed.
public struct BundledDriverInstaller: Hashable, Sendable {
    public let pkgURL: URL
    /// The payload-free uninstaller package, when it was built too.
    public let uninstallerPkgURL: URL?
    public let version: DriverVersion
    public let shortVersion: String?
    /// `ClapboardDeviceCount` from the driver's `Info.plist` — how many
    /// `Clapboard Bus n` devices installing will publish.
    public let busCount: Int?

    public init(
        pkgURL: URL,
        uninstallerPkgURL: URL?,
        version: DriverVersion,
        shortVersion: String?,
        busCount: Int?
    ) {
        self.pkgURL = pkgURL
        self.uninstallerPkgURL = uninstallerPkgURL
        self.version = version
        self.shortVersion = shortVersion
        self.busCount = busCount
    }
}

/// Everything the setup assistant, the menu bar and `--driver-status` need to
/// say in one sentence: what is on disk, what this build could install, and
/// whether the buses are actually there right now.
public struct DriverStatus: Hashable, Sendable {
    public let state: DriverInstallationState
    /// UIDs of the `Clapboard Bus n` devices the HAL is publishing, in bus
    /// order. Empty means `coreaudiod` is not serving the driver.
    public let busDeviceUIDs: [String]
    public let bundled: BundledDriverInstaller?

    public init(
        state: DriverInstallationState,
        busDeviceUIDs: [String],
        bundled: BundledDriverInstaller?
    ) {
        self.state = state
        self.busDeviceUIDs = busDeviceUIDs
        self.bundled = bundled
    }

    public var devicesPresent: Bool { !busDeviceUIDs.isEmpty }
    public var isInstalled: Bool { state.isInstalled }
    public var canInstall: Bool { bundled != nil }
    public var canUninstall: Bool { bundled?.uninstallerPkgURL != nil && state.isInstalled }

    /// The driver is on disk but the HAL is not publishing its devices —
    /// almost always a `coreaudiod` that has not been restarted since the
    /// install, and the one state a user cannot diagnose on their own.
    public var needsCoreAudioRestart: Bool {
        state.isInstalled && busDeviceUIDs.isEmpty
    }

    /// One line, written for a person rather than for a log.
    public var summary: String {
        switch state {
        case .installerUnavailable:
            return "Virtual devices are not installed, and this build of Clapboard "
                + "carries no installer (build one with Scripts/build_driver_pkg.sh)."
        case .notInstalled:
            let version = bundled.map { " (driver \($0.version))" } ?? ""
            return "Virtual devices are not installed. Clapboard can install "
                + "them for you\(version)."
        case .installed(let version):
            if busDeviceUIDs.isEmpty {
                return "The virtual-device driver \(version) is installed, but Core Audio "
                    + "is not publishing the buses yet — it needs a restart."
            }
            return "\(busDeviceUIDs.count) Clapboard Bus device"
                + (busDeviceUIDs.count == 1 ? "" : "s")
                + " ready (driver \(version))."
        case .outdated(let installed, let bundledVersion):
            return "The installed virtual-device driver is \(installed); this build "
                + "of Clapboard carries \(bundledVersion)."
        }
    }
}

/// Reading and interpreting the state of the Clapboard virtual-audio driver.
///
/// The derivation and the UID parsing are pure functions over injected inputs
/// so they can be tested without a driver, an app bundle or a HAL; the probing
/// helpers on top of them are thin and do nothing but supply those inputs.
public enum DriverInstallation {
    /// Every device the driver publishes has a UID starting with this.
    public static let busUIDPrefix = "com.astroqore.Clapboard.bus."
    public static let driverBundleIdentifier = "com.astroqore.ClapboardDriver"
    /// Where an installed driver lives. `coreaudiod` scans this directory.
    public static let installedDriverURL =
        URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/ClapboardDriver.driver")
    /// Written into `Contents/Resources` by `Scripts/build_app.sh` beside the
    /// package it describes.
    public static let manifestName = "ClapboardDriverInstaller.plist"

    // MARK: - Pure derivation

    /// The whole four-state model, over nothing but two optional versions.
    ///
    /// `bundled == nil` means this build carries no installer. That is only
    /// reported as `installerUnavailable` when there is also nothing on disk;
    /// a driver that is installed is `installed` whether or not this build
    /// could have installed it, because that is what matters to the user.
    public static func state(
        installed: DriverVersion?,
        bundled: DriverVersion?
    ) -> DriverInstallationState {
        switch (installed, bundled) {
        case (nil, nil):
            return .installerUnavailable
        case (nil, _):
            return .notInstalled
        case (.some(let installed), nil):
            return .installed(version: installed)
        case (.some(let installed), .some(let bundled)):
            return bundled > installed
                ? .outdated(installed: installed, bundled: bundled)
                : .installed(version: installed)
        }
    }

    /// The bus number encoded in a driver device UID, or `nil` for a UID that
    /// belongs to something else.
    public static func busIndex(forUID uid: String) -> Int? {
        guard uid.hasPrefix(busUIDPrefix) else { return nil }
        return Int(uid.dropFirst(busUIDPrefix.count))
    }

    /// Picks Clapboard's own bus devices out of a list of Core Audio device
    /// UIDs and returns them in bus order.
    ///
    /// Keying on the UID rather than on the name is deliberate: names are
    /// localizable and duplicable, UIDs are what the session file stores.
    public static func busUIDs(in uids: [String]) -> [String] {
        uids.filter { $0.hasPrefix(busUIDPrefix) }
            .sorted { lhs, rhs in
                switch (busIndex(forUID: lhs), busIndex(forUID: rhs)) {
                case (.some(let a), .some(let b)): return a < b
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return lhs < rhs
                }
            }
    }

    /// Assembles a status from inputs that have already been gathered. Pure.
    public static func status(
        installed: DriverVersion?,
        bundled: BundledDriverInstaller?,
        deviceUIDs: [String]
    ) -> DriverStatus {
        DriverStatus(
            state: state(installed: installed, bundled: bundled?.version),
            busDeviceUIDs: busUIDs(in: deviceUIDs),
            bundled: bundled
        )
    }

    // MARK: - Reading a bundle's Info.plist

    /// Reads `CFBundleVersion` (falling back to `CFBundleShortVersionString`)
    /// out of an `Info.plist`, refusing a plist whose `CFBundleIdentifier` is
    /// not the one expected — a differently-named bundle at that path is not
    /// our driver, and reporting its version would be a lie.
    public static func version(
        inInfoPlistAt url: URL,
        expectedIdentifier: String? = driverBundleIdentifier
    ) -> DriverVersion? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }
        if let expectedIdentifier,
           plist["CFBundleIdentifier"] as? String != expectedIdentifier {
            return nil
        }
        let candidates = [
            plist["CFBundleVersion"] as? String,
            plist["CFBundleShortVersionString"] as? String
        ]
        return candidates.compactMap { $0 }.compactMap(DriverVersion.init).first
    }

    /// The version of the driver currently sitting in `/Library/Audio/Plug-Ins/HAL`.
    public static func installedVersion(
        driverURL: URL = installedDriverURL
    ) -> DriverVersion? {
        version(inInfoPlistAt: driverURL.appendingPathComponent("Contents/Info.plist"))
    }

    // MARK: - Reading the bundled installer

    /// Manifest written next to the package by `Scripts/build_app.sh`. Its
    /// only job is to carry the driver's version across into the app bundle:
    /// a `.pkg` is an archive, and cracking one open at launch to read a
    /// version would be both slow and fragile.
    private struct Manifest: Decodable {
        var pkgName: String
        var uninstallerPkgName: String?
        var driverVersion: String
        var driverShortVersion: String?
        var busCount: Int?
    }

    /// Loads the installer this build carries, or `nil` when the app was built
    /// without one (the driver failed to build, or this is a bare `swift run`
    /// executable with no bundle around it).
    public static func bundledInstaller(
        resourcesURL: URL?,
        fileManager: FileManager = .default
    ) -> BundledDriverInstaller? {
        guard let resourcesURL else { return nil }
        let manifestURL = resourcesURL.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? PropertyListDecoder().decode(Manifest.self, from: data),
              let version = DriverVersion(manifest.driverVersion)
        else { return nil }

        let pkgURL = resourcesURL.appendingPathComponent(manifest.pkgName)
        guard fileManager.fileExists(atPath: pkgURL.path) else { return nil }

        let uninstallerURL = manifest.uninstallerPkgName
            .map { resourcesURL.appendingPathComponent($0) }
            .flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil }

        return BundledDriverInstaller(
            pkgURL: pkgURL,
            uninstallerPkgURL: uninstallerURL,
            version: version,
            shortVersion: manifest.driverShortVersion,
            busCount: manifest.busCount
        )
    }

    // MARK: - Probing this machine

    /// UIDs of every device the HAL is publishing right now. Returns an empty
    /// list rather than throwing: "the HAL would not talk to us" and "there
    /// are no Clapboard buses" lead to the same advice.
    public static func currentDeviceUIDs() -> [String] {
        ((try? AudioDeviceInfo.enumerateAll()) ?? []).map(\.uid)
    }

    /// One call for the app and for `--driver-status`.
    ///
    /// `deviceUIDs` is injectable so a caller that already has a live
    /// `AudioDeviceRegistry` does not re-enumerate the HAL behind its back.
    public static func probe(
        resourcesURL: URL? = Bundle.main.resourceURL,
        driverURL: URL = installedDriverURL,
        deviceUIDs: [String]? = nil
    ) -> DriverStatus {
        status(
            installed: installedVersion(driverURL: driverURL),
            bundled: bundledInstaller(resourcesURL: resourcesURL),
            deviceUIDs: deviceUIDs ?? currentDeviceUIDs()
        )
    }
}
