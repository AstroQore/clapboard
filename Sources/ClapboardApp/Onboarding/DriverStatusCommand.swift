import ClapboardCore
import Foundation

/// `--driver-status`: what `DriverInstallation` sees on this machine, printed
/// without starting AppKit.
///
/// It exists for support ("paste the output of this") and for acceptance
/// checks, so it prints the raw state name as well as the sentence a user
/// would read, and it never exits non-zero for a *state* — only for a genuine
/// failure to look.
enum DriverStatusCommand {
    @MainActor
    static func run() -> Never {
        let status = DriverInstallation.probe()

        func line(_ key: String, _ value: String) {
            print(key.padding(toLength: 16, withPad: " ", startingAt: 0) + value)
        }

        line("state", status.state.name)
        line("installed", status.state.installedVersion.map(String.init(describing:)) ?? "(none)")
        line("driver path", DriverInstallation.installedDriverURL.path)

        if let bundled = status.bundled {
            let short = bundled.shortVersion.map { " (short \($0))" } ?? ""
            line("bundled", "\(bundled.version)\(short)")
            line("installer", bundled.pkgURL.path)
            line("uninstaller", bundled.uninstallerPkgURL?.path ?? "(none)")
            line("bus count", bundled.busCount.map(String.init) ?? "(unknown)")
        } else {
            line("bundled", "(none)")
            line("installer", "(none — build with Scripts/build_driver_pkg.sh)")
        }

        line("app resources", Bundle.main.resourceURL?.path ?? "(none)")
        line("devices", status.devicesPresent ? "present" : "absent")
        line("bus uids", status.busDeviceUIDs.isEmpty
            ? "(none)"
            : status.busDeviceUIDs.joined(separator: " "))
        line("needs restart", status.needsCoreAudioRestart ? "yes" : "no")
        line("summary", status.summary)

        exit(0)
    }
}
