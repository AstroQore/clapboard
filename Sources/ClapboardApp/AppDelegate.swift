import AppKit
import ClapboardCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the scene once the engine exists, so termination and sleep can
    /// reach it. `AudioEngine` itself stays free of AppKit.
    var engine: AudioEngine? {
        didSet { installWorkspaceObservers() }
    }

    private var observersInstalled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--list-devices") {
            Self.printDevicesAndExit()
        }
        if CommandLine.arguments.contains("--engine-test") {
            EngineSmokeTest.run(arguments: Array(CommandLine.arguments.dropFirst()))
        }
        if CommandLine.arguments.contains("--sync-test") {
            SyncSmokeTest.run(arguments: Array(CommandLine.arguments.dropFirst()))
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Last chance to destroy the private aggregate device. Leaving one behind
    /// would keep every sub-device open.
    func applicationWillTerminate(_ notification: Notification) {
        engine?.shutdown()
    }

    /// Devices are torn down across sleep and come back with different object
    /// ids, so the engine stops on the way down and rebuilds on the way up.
    private func installWorkspaceObservers() {
        guard !observersInstalled, engine != nil else { return }
        observersInstalled = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine?.handleWillSleep() }
        }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine?.handleDidWake() }
        }
    }

    /// Headless dump used by scripts and by the M0 acceptance check.
    private static func printDevicesAndExit() -> Never {
        do {
            let devices = try AudioDeviceInfo.enumerateAll()
            let defaultIn = AudioDeviceInfo.defaultDeviceID(input: true)
            let defaultOut = AudioDeviceInfo.defaultDeviceID(input: false)
            for device in devices {
                var flags: [String] = []
                if device.id == defaultIn { flags.append("default-in") }
                if device.id == defaultOut { flags.append("default-out") }
                if device.isHidden { flags.append("hidden") }
                if !device.isAlive { flags.append("dead") }
                let rates = device.fixedSampleRates.map { String(Int($0)) }.joined(separator: ",")
                print(
                    "\(device.name)\t\(device.transport.label)\tin=\(device.inputStreamChannels)\tout=\(device.outputStreamChannels)" +
                    "\trate=\(Int(device.nominalSampleRate))\trates=[\(rates)]\tuid=\(device.uid)" +
                    (flags.isEmpty ? "" : "\t[\(flags.joined(separator: " "))]")
                )
            }
            print("\(devices.count) devices")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
