import ClapboardCore
import Foundation

/// Command-line modes used by scripts and acceptance checks. They run on the
/// main thread with a plain `RunLoop`, without `NSApplication`.
enum HeadlessCommand {
    static let flags: Set<String> = [
        "--list-devices",
        "--engine-test",
        "--effects-list",
        "--sync-test",
        "--restore-session",
        "--session-dump",
        "--session-autosave-test",
        "--hotkeys-selftest",
        "--routing-selftest",
        "--list-taps"
    ]

    static func matches(_ arguments: [String]) -> Bool {
        !flags.isDisjoint(with: arguments)
    }

    @MainActor
    static func run(_ arguments: [String]) -> Never {
        if arguments.contains("--list-devices") {
            printDevicesAndExit()
        }
        if arguments.contains("--list-taps") {
            printTapsAndExit()
        }
        if arguments.contains("--effects-list") {
            printEffectsAndExit()
        }
        if arguments.contains("--engine-test") {
            EngineSmokeTest.run(arguments: arguments)
        }
        if arguments.contains("--routing-selftest") {
            EngineSmokeTest.runRoutingSelfTest(arguments: arguments)
        }
        if arguments.contains("--sync-test") {
            SyncSmokeTest.run(arguments: arguments)
        }
        if arguments.contains("--hotkeys-selftest") {
            HotkeySelfTest.run(arguments: arguments)
        }
        if arguments.contains("--restore-session")
            || arguments.contains("--session-dump")
            || arguments.contains("--session-autosave-test") {
            SessionSmokeTest.run(arguments: arguments)
        }
        FileHandle.standardError.write(Data("unknown headless flag\n".utf8))
        exit(64)
    }

    /// Dumps every installed Audio Unit effect, with the reason Clapboard
    /// cannot host it where that applies. On an Apple Silicon Mac that reason
    /// is nearly always the same one: an AUv2 bundle with no arm64 slice.
    private static func printEffectsAndExit() -> Never {
        let effects = AUCatalog.effects()
        var unavailable = 0
        for effect in effects {
            let kind = effect.isAUv3 ? "AUv3" : "AUv2"
            let arch: String
            if effect.isAUv3 {
                arch = "-"
            } else if let url = effect.bundleURL,
                      let types = Bundle(url: url)?.executableURL.flatMap(MachOArchitecture.cpuTypes(inFileAt:)) {
                arch = types.map(name(cpuType:)).joined(separator: "+")
            } else {
                arch = "?"
            }
            let reason = AUAvailability.reason(for: effect)
            if reason != nil { unavailable += 1 }
            print("\(effect.id)\t\(kind)\t\(arch)\t\(effect.manufacturerName)\t\(effect.name)"
                + "\t\(effect.versionString)" + (reason.map { "\tUNAVAILABLE: \($0)" } ?? ""))
        }
        print("\(effects.count) effects, \(unavailable) unavailable")
        exit(0)
    }

    private static func name(cpuType: UInt32) -> String {
        switch cpuType {
        case MachOArchitecture.arm64: return "arm64"
        case MachOArchitecture.x86_64: return "x86_64"
        default: return String(format: "0x%08x", cpuType)
        }
    }

    /// Dumps everything a process-tap lane could be pointed at: whether macOS
    /// lets this build tap at all, and every client process the HAL reports as
    /// producing (or capable of producing) audio.
    ///
    /// The permission line comes first on purpose. Checking it means creating
    /// and destroying a real tap (`ProcessTapPermission`), which is also the
    /// only way to *ask* for the permission, so running `--list-taps` once is
    /// how a script gets the prompt out of the way.
    private static func printTapsAndExit() -> Never {
        let authorization = ProcessTapPermission.probe()
        print("system-audio-capture\t\(authorization.label)")
        print("system\t-\t-\tSystem audio (everything except Clapboard)")
        let processes = ProcessTapCatalog.outputProducingProcesses()
        for process in processes {
            var flags: [String] = []
            if process.isRunningOutput { flags.append("playing") }
            else if process.isRunning { flags.append("audio-io") }
            if process.bundleID == nil { flags.append("no-bundle-id: cannot be saved in a session") }
            print("\(process.bundleID ?? "-")\tpid=\(process.pid)\tobj=\(process.objectID)\t\(process.name)"
                + (flags.isEmpty ? "" : "\t[\(flags.joined(separator: " "))]"))
        }
        print("\(processes.count) tappable process(es)")
        print("leftover taps: \(ProcessTapFactory.leakedTapUIDs().count)")
        exit(authorization.isAuthorized ? 0 : 3)
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
