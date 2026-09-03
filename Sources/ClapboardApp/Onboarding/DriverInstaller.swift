import AppKit
import ClapboardCore
import Observation

/// Drives installing and removing the Clapboard virtual-device driver from
/// inside the app, and keeps a live `DriverStatus` for the UI to read.
///
/// The install itself is deliberately **not** done by Clapboard. The package
/// is handed to `Installer.app` with `NSWorkspace.open`, and macOS asks for
/// the administrator password in its own window, showing its own description
/// of what is about to be written. The alternatives — `do shell script … with
/// administrator privileges`, an embedded `SMJobBless` helper, a password
/// field of our own — all end with an open-source audio app asking for a root
/// password in a dialog that only *looks* like the system's. Saving a click is
/// not worth that; see `docs/PERMISSIONS.md`.
@MainActor
@Observable
final class DriverInstaller {
    /// What the sheet should be saying about an install that is under way.
    enum Phase: Equatable {
        /// Nothing in flight; `status` is the whole story.
        case idle
        /// Installer.app has been opened and the buses have not appeared yet.
        case awaitingInstall
        /// The uninstaller has been opened and the buses are still there.
        case awaitingUninstall
        /// `Clapboard Bus 1` showed up while we were watching.
        case installed
        /// The buses went away while we were watching.
        case uninstalled
        /// Watched for the full window and nothing changed — cancelled at the
        /// password prompt, most likely.
        case timedOut
        case failed(String)
    }

    private(set) var status: DriverStatus
    private(set) var phase: Phase = .idle
    /// True when `install()` stopped a running engine, so the sheet can offer
    /// to start it again afterwards.
    private(set) var didStopEngine = false

    /// Installing restarts `coreaudiod` and the HAL takes a few seconds to
    /// republish; a user reading the Installer's panes takes rather longer.
    private static let watchWindow: TimeInterval = 180
    private static let pollInterval: Duration = .seconds(2)

    private weak var registry: AudioDeviceRegistry?
    private var watchTask: Task<Void, Never>?

    init(registry: AudioDeviceRegistry? = nil) {
        self.registry = registry
        status = DriverInstallation.probe(deviceUIDs: registry?.devices.map(\.uid))
    }

    func attach(registry: AudioDeviceRegistry) {
        self.registry = registry
        refresh()
    }

    /// Re-reads `/Library/Audio/Plug-Ins/HAL` and the current device list.
    /// Cheap enough to call from a view's `onAppear`.
    func refresh() {
        status = DriverInstallation.probe(deviceUIDs: registry?.devices.map(\.uid))
    }

    // MARK: - Installing

    /// Stops the engine, hands the bundled package to Installer.app, and
    /// starts watching for the buses to appear.
    ///
    /// The engine has to go down first: the package's `postinstall` restarts
    /// `coreaudiod`, which tears down every IOProc and aggregate device on the
    /// machine. Stopping cleanly is the difference between a one-second gap
    /// and an engine left pointing at a dead aggregate.
    func install(engine: AudioEngine?) {
        guard let pkgURL = status.bundled?.pkgURL else {
            phase = .failed("This build of Clapboard carries no installer package.")
            return
        }
        stopEngineIfRunning(engine)
        guard NSWorkspace.shared.open(pkgURL) else {
            phase = .failed("Could not open \(pkgURL.lastPathComponent) in Installer.")
            return
        }
        phase = .awaitingInstall
        watch { !$0.busDeviceUIDs.isEmpty }
    }

    /// Same route, with the payload-free uninstaller package.
    func uninstall(engine: AudioEngine?) {
        guard let pkgURL = status.bundled?.uninstallerPkgURL else {
            phase = .failed("This build of Clapboard carries no uninstaller package.")
            return
        }
        stopEngineIfRunning(engine)
        guard NSWorkspace.shared.open(pkgURL) else {
            phase = .failed("Could not open \(pkgURL.lastPathComponent) in Installer.")
            return
        }
        phase = .awaitingUninstall
        watch { $0.busDeviceUIDs.isEmpty && !$0.state.isInstalled }
    }

    /// Dismisses a finished or failed attempt without touching anything.
    func acknowledge() {
        watchTask?.cancel()
        watchTask = nil
        phase = .idle
        refresh()
    }

    private func stopEngineIfRunning(_ engine: AudioEngine?) {
        guard let engine, engine.runState.isRunning || engine.runState.isBusy else {
            didStopEngine = false
            return
        }
        engine.stop()
        didStopEngine = true
    }

    // MARK: - Watching for the devices

    /// Polls rather than relying on `AudioDeviceRegistry.onHardwareChange`.
    ///
    /// Two reasons. The engine already owns that callback and chains onto it,
    /// so a second subscriber would have to mutate shared state; and the event
    /// we are waiting for is a `coreaudiod` restart, which is exactly the
    /// situation where a HAL property listener registered against the old
    /// daemon cannot be trusted to fire. `refresh()` on the registry is a
    /// plain re-enumeration and does not disturb the engine.
    private func watch(until satisfied: @escaping @Sendable (DriverStatus) -> Bool) {
        watchTask?.cancel()
        let deadline = Date().addingTimeInterval(Self.watchWindow)
        let finishedPhase: Phase = phase == .awaitingUninstall ? .uninstalled : .installed
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.registry?.refresh()
                self.refresh()
                if satisfied(self.status) {
                    self.phase = finishedPhase
                    self.watchTask = nil
                    return
                }
                if Date() >= deadline {
                    self.phase = .timedOut
                    self.watchTask = nil
                    return
                }
            }
        }
    }
}
