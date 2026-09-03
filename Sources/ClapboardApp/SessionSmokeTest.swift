import AppKit
import AVFoundation
import ClapboardCore
import Foundation

/// Headless half of M5, the sibling of `--engine-test`.
///
///     Clapboard --session-dump                       # print the default session file
///     Clapboard --session-dump --session-path <file>
///     Clapboard --restore-session <file> [--run 5] [--ignore-tcc]
///     Clapboard --session-autosave-test [--session-path <file>]
///
/// `--restore-session` loads a session into a fresh engine, prints what came
/// back — including which lanes point at devices that are not here — and, when
/// at least one lane resolved, runs the engine for a few seconds so the lane
/// statuses are real rather than assumed.
enum SessionSmokeTest {
    @MainActor
    static func run(arguments: [String]) -> Never {
        var restorePath: String?
        var sessionPath: String?
        var dump = false
        var autosave = false
        var runSeconds = 3.0
        var ignoreTCC = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func next() -> String? {
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }
            switch argument {
            case "--restore-session": restorePath = next()
            case "--session-path": sessionPath = next()
            case "--session-dump": dump = true
            case "--session-autosave-test": autosave = true
            case "--run": runSeconds = Double(next() ?? "3") ?? 3
            case "--ignore-tcc": ignoreTCC = true
            default: break
            }
            index += 1
        }

        if autosave {
            autosaveAndExit(path: sessionPath)
        }
        if dump {
            dumpAndExit(path: sessionPath)
        }
        guard let restorePath else {
            fail("--restore-session needs a file")
        }
        restoreAndExit(path: restorePath, runSeconds: runSeconds, ignoreTCC: ignoreTCC)
    }

    /// Shared with `--engine-test --save-session`. `nil` only when macOS
    /// reports no Application Support directory and no path was given.
    static func store(path: String?) -> SessionStore? {
        if let path {
            return SessionStore(fileURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        return try? SessionStore()
    }

    // MARK: - Dump

    @MainActor
    private static func dumpAndExit(path: String?) -> Never {
        guard let store = store(path: path) else {
            fail("macOS reports no Application Support directory; pass --session-path")
        }
        say("file     \(store.fileURL.path)")
        guard store.fileExists else {
            say("state    no session file yet")
            exit(0)
        }
        if let data = try? Data(contentsOf: store.fileURL) {
            say("bytes    \(data.count)")
        }
        do {
            guard let document = try store.load() else {
                say("state    no session file yet")
                exit(0)
            }
            describe(document)
            say((try? String(decoding: document.jsonData(), as: UTF8.self)) ?? "")
            exit(0)
        } catch {
            fail("\(error)")
        }
    }

    // MARK: - Autosave

    /// Drives the real `SessionController` the way the gain slider does — a
    /// burst of edits — and checks that the debounce turns them into one write.
    @MainActor
    private static func autosaveAndExit(path: String?) -> Never {
        guard let store = store(path: path) else {
            fail("macOS reports no Application Support directory; pass --session-path")
        }
        try? FileManager.default.removeItem(at: store.fileURL)
        say("file     \(store.fileURL.path)")

        let engine = AudioEngine()
        let controller = SessionController(store: store)
        controller.attach(engine: engine)
        let lane = engine.addLane(deviceUID: "autosave-test-device", deviceChannels: [0], name: "Fader")
        settle(1.4)
        say("edit 1   saves=\(controller.saveCount) after adding a lane")

        // 20 edits in 400 ms, the shape of one slider drag.
        for step in 0..<20 {
            engine.setLaneGainDB(lane.id, Float(step) * -0.5)
            settle(0.02)
        }
        settle(1.4)
        say("burst    20 gain edits in ~0.4 s -> saves=\(controller.saveCount)")

        settle(1.5)
        say("idle     saves=\(controller.saveCount) after 1.5 s of nothing happening")

        engine.masterGainDB = -12
        settle(1.4)
        say("edit 2   saves=\(controller.saveCount) after one master gain change")

        let onDisk = (try? store.load()) ?? nil
        let gain = onDisk?.lanes.first?.gainDB ?? .nan
        say("on disk  lanes=\(onDisk?.lanes.count ?? -1) laneGain=\(gain) master=\(onDisk?.masterGainDB ?? .nan)")
        say("saved at \(controller.lastSavedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-")")
        say("error    \(controller.lastSaveError ?? "none")")

        // One write per burst, not one per edit, and the last value wins.
        let ok = controller.saveCount == 3 && gain == -9.5 && onDisk?.masterGainDB == -12
        say("result   \(ok ? "ok" : "UNEXPECTED (wanted saves=3, laneGain=-9.5, master=-12)")")
        exit(ok ? 0 : 2)
    }

    @MainActor
    private static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Restore

    @MainActor
    private static func restoreAndExit(path: String, runSeconds: Double, ignoreTCC: Bool) -> Never {
        let store = SessionStore(fileURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        say("file     \(store.fileURL.path)")
        let document: SessionDocument
        do {
            guard let loaded = try store.load() else { fail("no session file at \(store.fileURL.path)") }
            document = loaded
        } catch {
            fail("\(error)")
        }
        describe(document)

        let registry = AudioDeviceRegistry()
        registry.start()
        let engine = AudioEngine()
        engine.attach(registry: registry)
        let report = engine.restore(document)
        say("restore  \(report.summary)")
        for note in report.skippedLanes { say("skipped  \(note)") }

        let present = Set(registry.devices.map(\.uid))
        say("output   \(describeDevice(engine.outputDeviceUID, registry: registry))")
        say(String(format: "master   %.1f dB", engine.masterGainDB))
        for lane in engine.lanes {
            say("lane     \(lane.name) [\(lane.channelLabel)] "
                + String(format: "gain=%.1fdB ", lane.gainDB)
                + "delay=\(lane.delaySamples) (\(String(format: "%.1f", lane.delayMilliseconds())) ms) "
                + "enabled=\(lane.enabled) polarity=\(lane.polarityInverted ? "inverted" : "normal") "
                + "device=\(present.contains(lane.deviceUID) ? "present" : "MISSING") "
                + "uid=\(lane.deviceUID) id=\(lane.id)")
        }

        guard runSeconds > 0 else { exit(0) }
        let resolvable = engine.lanes.contains { present.contains($0.deviceUID) }
        guard resolvable, engine.outputDeviceUID.map({ present.contains($0) }) == true else {
            say("run      skipped — no restored lane or output device is present on this machine")
            exit(0)
        }

        if ignoreTCC {
            engine.allowsUnauthorizedCapture = true
            say("mic TCC  bypassed for diagnostics — lane input will be zeros unless TCC is granted")
        }
        engine.start()
        guard engine.runState.isRunning else {
            fail("engine did not start: \(engine.lastError ?? engine.runState.label)")
        }
        say("started  aggregate \(engine.aggregateSummary ?? "-")")

        let started = Date()
        let deadline = started.addingTimeInterval(runSeconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            let statuses = engine.lanes.map { lane in
                "\(short(lane.name))=\(label(engine.laneStatus[lane.id]))"
            }
            say(String(
                format: "t=%4.1f  %@  cb=%d  overload=%d  %@",
                Date().timeIntervalSince(started), engine.runState.isRunning ? "running" : engine.runState.label,
                engine.callbackCount, engine.overloadCount, statuses.joined(separator: " ")
            ))
        }

        // The session must survive a restore → run round trip unchanged, which
        // is the whole point of keeping missing-device lanes.
        let after = engine.sessionSnapshot
        let sameLanes = after.lanes == document.lanes
        let sameOutput = after.outputDeviceUID == document.outputDeviceUID
        say("stable   lanes=\(sameLanes) output=\(sameOutput) master=\(after.masterGainDB == document.masterGainDB)")

        engine.shutdown()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let leftovers = ((try? AudioDeviceInfo.enumerateAll()) ?? [])
            .filter { $0.uid.hasPrefix("com.astroqore.Clapboard.aggregate.") || $0.name == "Clapboard Mix" }
        say("leftover aggregates after shutdown: \(leftovers.count)")
        exit(leftovers.isEmpty && sameLanes && sameOutput ? 0 : 2)
    }

    // MARK: - Helpers

    private static func describe(_ document: SessionDocument) {
        say("format   \(document.formatVersion)\(document.isFromNewerFormat ? " (NEWER than this build understands)" : "")")
        say("savedAt  \(ISO8601DateFormatter().string(from: document.savedAt))")
        say("lanes    \(document.lanes.count)  output=\(document.outputDeviceUID ?? "-")  "
            + String(format: "master=%.1f dB", document.masterGainDB))
    }

    @MainActor
    private static func describeDevice(_ uid: String?, registry: AudioDeviceRegistry) -> String {
        guard let uid else { return "-" }
        guard let device = registry.device(uid: uid) else { return "MISSING [\(uid)]" }
        return "\(device.name) [\(uid)]"
    }

    private static func label(_ status: AudioEngine.LaneStatus?) -> String {
        switch status {
        case .ok: return "ok"
        case .deviceMissing: return "deviceMissing"
        case .channelOutOfRange: return "channelOutOfRange"
        case .idle: return "idle"
        case nil: return "-"
        }
    }

    private static func say(_ message: String) {
        print(message)
        fflush(stdout)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("session-test: \(message)\n".utf8))
        exit(1)
    }

    private static func short(_ name: String) -> String {
        String(name.prefix(14)).replacingOccurrences(of: " ", with: "_")
    }
}
