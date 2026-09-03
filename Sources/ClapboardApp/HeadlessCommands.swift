import ClapboardCore
import Foundation

/// Command-line modes used by scripts and acceptance checks. They run on the
/// main thread with a plain `RunLoop`, without `NSApplication`.
enum HeadlessCommand {
    static let flags: Set<String> = [
        "--list-devices",
        "--engine-test",
        "--sync-test",
        "--restore-session",
        "--session-dump",
        "--session-autosave-test"
    ]

    static func matches(_ arguments: [String]) -> Bool {
        !flags.isDisjoint(with: arguments)
    }

    @MainActor
    static func run(_ arguments: [String]) -> Never {
        if arguments.contains("--list-devices") {
            printDevicesAndExit()
        }
        if arguments.contains("--engine-test") {
            EngineSmokeTest.run(arguments: arguments)
        }
        if arguments.contains("--sync-test") {
            SyncSmokeTest.run(arguments: arguments)
        }
        if arguments.contains("--restore-session")
            || arguments.contains("--session-dump")
            || arguments.contains("--session-autosave-test") {
            SessionSmokeTest.run(arguments: arguments)
        }
        FileHandle.standardError.write(Data("unknown headless flag\n".utf8))
        exit(64)
    }

    /// Dumps every Core Audio device the HAL reports and exits.
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
