import AppKit
import AVFoundation
import ClapboardCore
import Foundation

/// Headless Auto Sync run, the sibling of `--engine-test`.
///
/// It drives the real `SyncSession` against real devices: arm the capture,
/// wait for a clap, run `ClapAligner`, print the verdict per lane, and with
/// `--apply` write the delays and re-measure the residual.
///
/// **A human has to clap.** There is no way to inject a transient into the
/// capture path from here: the engine records what the aggregate's *input*
/// sub-devices receive, and the only thing this process can play is the mix
/// itself, which goes to the *output* device. So a run with no clap is
/// expected to report "not detected" on every lane — which is a real test of
/// the rejection path, just not of the measurement.
///
///     Clapboard --sync-test --output "Loopback" \
///         --lane "Wireless Mic Rx#1" --lane "Wireless Mic Rx#2" \
///         --lane "MacBook Pro Microphone" --takes 1 --apply
enum SyncSmokeTest {
    @MainActor
    static func run(arguments: [String]) -> Never {
        var outputQuery: String?
        var laneQueries: [String] = []
        var takes = 1
        var listen = 4.0
        var window = 0.25
        var relaxed = false
        var apply = false
        var ignoreTCC = false
        var timeout = 30.0

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func next() -> String? {
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }
            switch argument {
            case "--sync-test":
                // Optional numeric argument: the overall timeout in seconds.
                if index + 1 < arguments.count, let value = Double(arguments[index + 1]) {
                    timeout = value
                    index += 1
                }
            case "--output": outputQuery = next()
            case "--lane": if let value = next() { laneQueries.append(value) }
            case "--takes": takes = Int(next() ?? "1") ?? 1
            case "--listen": listen = Double(next() ?? "4") ?? 4
            case "--window": window = Double(next() ?? "0.25") ?? 0.25
            case "--relaxed": relaxed = true
            case "--apply": apply = true
            case "--ignore-tcc": ignoreTCC = true
            default: break
            }
            index += 1
        }

        let registry = AudioDeviceRegistry()
        registry.start()
        let engine = AudioEngine()
        engine.attach(registry: registry)

        func resolve(_ query: String) -> AudioDeviceInfo? {
            registry.devices.first { $0.uid == query }
                ?? registry.devices.first { $0.name == query }
                ?? registry.devices.first { $0.name.localizedCaseInsensitiveContains(query) }
        }

        guard let outputQuery, let output = resolve(outputQuery), output.hasOutput else {
            fail("--output must name a device with output channels")
        }
        engine.setOutputDevice(uid: output.uid)
        say("output   \(output.name) [\(output.transport.label)]")

        for query in laneQueries {
            // Same "Device#2" / "Device#1,2" channel syntax as --engine-test.
            let parts = query.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let channels: [Int] = parts.count > 1
                ? parts[1].split(separator: ",").compactMap { Int($0).map { $0 - 1 } }
                : [0]
            guard let device = resolve(name), device.hasInput else {
                fail("--lane \(name) did not resolve to an input device")
            }
            guard let highest = channels.max(), highest < device.inputChannels, channels.min()! >= 0 else {
                fail("--lane \(query) asks for a channel \(device.name) does not have (\(device.inputChannels))")
            }
            let label = channels.map { String($0 + 1) }.joined(separator: "/")
            engine.addLane(deviceUID: device.uid, deviceChannels: channels, name: "\(device.name) \(label)")
            say("lane     \(device.name) ch\(label) [\(device.transport.label)\(device.transport.isVirtual ? ", virtual" : "")]")
        }
        guard engine.lanes.count >= 2 else {
            fail("Auto Sync needs at least two --lane arguments; lanes are measured against each other")
        }

        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        say("mic TCC  \(describe(authorization))")
        if authorization == .notDetermined && !ignoreTCC {
            engine.requestAuthorization()
            waitUntil(timeout: 20) { AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined }
            say("mic TCC  \(describe(AVCaptureDevice.authorizationStatus(for: .audio))) after prompt")
        }
        if ignoreTCC {
            engine.allowsUnauthorizedCapture = true
            say("mic TCC  bypassed — the capture will be zeros unless TCC is granted")
        }

        engine.start()
        guard engine.runState.isRunning else {
            fail("engine did not start: \(engine.lastError ?? engine.runState.label)")
        }
        say("aggregate \(engine.aggregateSummary ?? "-")")
        _ = waitUntil(timeout: 5) { engine.callbackHealthy }
        say("callbacks \(engine.callbackHealthy ? "healthy" : "NOT RUNNING") after \(engine.callbackCount) blocks")

        let session = SyncSession(engine: engine, registry: registry)
        session.takeCount = takes
        session.listenSeconds = listen
        session.maxLagSeconds = window
        session.relaxed = relaxed
        // The point of the headless run is to exercise every lane, including
        // the virtual ones the sheet leaves out by default.
        for lane in session.laneOptions { session.setIncluded(lane.id, true) }
        say(String(
            format: "options  takes=%d listen=%.0f s window=±%.0f ms minPeakRatio=%.1f "
                + "minDominance=%.0f dB lanes=%d",
            takes, session.boundedListenSeconds, window * 1000,
            session.syncOptions.minPeakRatio, session.syncOptions.minDominanceDB,
            session.selectedLanes.count
        ))
        say("")
        say(">>> CLAP ONCE, HARD, when the line below says LISTENING. <<<")
        say("    Nothing in this process can make the sound for you; with no clap")
        say("    every lane is expected to come back \"no dominant transient\" and")
        say("    the take is expected to run the full listen window.")
        say("")

        let overloadsBefore = engine.overloadCount
        let started = Date()
        session.start()

        var lastLine = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let line = describe(
                session.phase, progress: session.captureProgress,
                remaining: session.listenSecondsRemaining
            )
            if line != lastLine {
                lastLine = line
                say(String(format: "t=%5.1f  %@", Date().timeIntervalSince(started), line))
            }
            if case .results = session.phase { break }
            if case .failed = session.phase { break }
        }

        if case .failed(let message) = session.phase {
            say("FAILED   \(message)")
            teardown(engine: engine, exitCode: 1)
        }
        guard let result = session.lastResult else {
            say("FAILED   the session never produced a result within \(Int(timeout)) s")
            teardown(engine: engine, exitCode: 1)
        }

        say("")
        say(String(
            format: "take     %.2f s over %d lanes at %.0f Hz, %@ (%@)",
            session.takeDuration, session.lastTakeRecordings.count, engine.sampleRate,
            session.takeEndedEarly ? "ended early" as NSString : "ran the full listen window" as NSString,
            session.takeEndReason as NSString
        ))
        say("levels   peak and median are 1 ms RMS windows; dominance is the gap between them")
        for lane in result.lanes {
            guard let levels = lane.levels else {
                say(String(format: "  %-26@ not analysed", short(lane.label) as NSString))
                continue
            }
            say(String(
                format: "  %-26@ peak=%7.2f  median=%7.2f  floor=%7.2f dBFS  dominance=%5.1f dB  onset=%@  multi=%@",
                short(lane.label) as NSString,
                levels.peakDBFS, levels.medianDBFS, levels.noiseFloorDBFS, levels.dominanceDB,
                (lane.onsetSample.map { String(format: "%.3f s", Double($0) / result.sampleRate) }
                    ?? "none") as NSString,
                (levels.multipleTransients ? "yes" : "no") as NSString
            ))
        }

        say("")
        if !result.pairs.isEmpty {
            say("pairs")
            for pair in result.pairs.sorted(by: { $0.offsetSamples < $1.offsetSamples }) {
                let a = result[pair.a]?.label ?? "?"
                let b = result[pair.b]?.label ?? "?"
                say(String(
                    format: "  %-24@ vs %-24@ %+8.2f sp  w=%5.2f  %@",
                    a as NSString, b as NSString,
                    pair.offsetSamples, pair.weight, pair.estimator as NSString
                ))
            }
            for pair in result.droppedPairs {
                let a = result[pair.a]?.label ?? "?"
                let b = result[pair.b]?.label ?? "?"
                say("  dropped as inconsistent: \(a) vs \(b) (\(pair.estimator))")
            }
        }
        if let residual = result.fitResidualSamples {
            var line = String(format: "fit      residual %.3f samples", residual)
            if let triangles = result.triangleResidualSamples {
                line += String(format: ", triangles %.3f samples", triangles)
            } else {
                line += ", no triangle to cross-check"
            }
            say(line)
        }
        say("result   "
            + "aligned=\(result.alignedLanes.count)/\(result.lanes.count)")
        if let failure = result.failureSummary { say("FAILURE  \(failure)") }
        for lane in result.lanes {
            switch lane.status {
            case .aligned(let offset, let confidence, let ratio, let inverted):
                say(String(
                    format: "  %-26@ offset=%+8.3f ms  delay=%7.3f ms (%d sp)  ratio=%5.2f  conf=%3.0f%%%@%@",
                    short(lane.label) as NSString,
                    offset / result.sampleRate * 1000,
                    lane.suggestedDelayMs ?? 0, lane.suggestedDelaySamples ?? 0,
                    ratio, confidence * 100,
                    inverted ? "  POLARITY-INVERTED" : "",
                    lane.clipped ? "  CLIPPED" : ""
                ))
            case .notDetected(let reason):
                say(String(
                    format: "  %-26@ not detected: %@%@",
                    short(lane.label) as NSString, reason as NSString,
                    lane.clipped ? "  CLIPPED" : ""
                ))
            }
        }
        if let advice = session.message { say("advice   \(advice)") }
        say("overloads during capture: \(engine.overloadCount - overloadsBefore)")

        if apply {
            let assignments = session.apply()
            say("")
            say("applied  \(assignments.count) lane\(assignments.count == 1 ? "" : "s"); stale flag now \(engine.delaysMayBeStale)")
            for lane in engine.lanes {
                say(String(format: "  %-26@ delay=%d sp (%.3f ms)",
                           short(lane.name) as NSString, lane.delaySamples, lane.delayMilliseconds()))
            }
            Task { await session.verify() }
            _ = waitUntil(timeout: 20) {
                if case .done = session.phase { return !session.verifications.isEmpty }
                return false
            }
            say("verify   \(session.verifications.count) lane\(session.verifications.count == 1 ? "" : "s") re-measured")
            for verification in session.verifications {
                say(String(
                    format: "  %-26@ residual=%@",
                    short(verification.label) as NSString,
                    verification.residualSamples.map {
                        String(format: "%+.3f samples (%+.4f ms)%@",
                               $0, verification.residualMilliseconds ?? 0,
                               abs($0) <= 1 ? "  OK" : "  OVER ONE SAMPLE")
                    } ?? "not re-measurable"
                ))
            }
        }

        teardown(engine: engine, exitCode: 0)
    }

    // MARK: - Helpers

    @MainActor
    private static func teardown(engine: AudioEngine, exitCode: Int32) -> Never {
        engine.shutdown()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let leftovers = ((try? AudioDeviceInfo.enumerateAll()) ?? [])
            .filter { $0.uid.hasPrefix("com.astroqore.Clapboard.aggregate.") || $0.name == "Clapboard Mix" }
        say("leftover aggregates after shutdown: \(leftovers.count)")
        exit(leftovers.isEmpty ? exitCode : 2)
    }

    private static func describe(
        _ phase: SyncSession.Phase, progress: Double, remaining: Double
    ) -> String {
        switch phase {
        case .idle: return "idle"
        case .armed: return "ARMED — recording room tone, get ready"
        case .listening(let take, let total):
            return String(
                format: "LISTENING (take %d/%d) %.0f%% — clap now, %.0f s left",
                take, total, progress * 100, max(0, remaining.rounded(.up))
            )
        case .analysing: return "analysing"
        case .results: return "results"
        case .verifying: return "verifying"
        case .done: return "done"
        case .failed(let message): return "failed: \(message)"
        }
    }

    @MainActor
    @discardableResult
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private static func decibels(_ amplitude: Double) -> Double {
        amplitude > 1e-9 ? 20 * log10(amplitude) : -999
    }

    private static func say(_ message: String) {
        print(message)
        fflush(stdout)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("sync-test: \(message)\n".utf8))
        exit(1)
    }

    private static func short(_ name: String) -> String {
        String(name.prefix(26))
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "DENIED — the HAL will deliver zeros, not an error"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }
}
