import AppKit
import ClapboardCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--list-devices") {
            Self.printDevicesAndExit()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
