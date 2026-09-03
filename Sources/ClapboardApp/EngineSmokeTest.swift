import AppKit
import AVFoundation
import ClapboardCore
import Foundation

/// Headless engine run, the sibling of `--list-devices`.
///
/// Everything M1/M2 promises except the SwiftUI chrome can be checked from a
/// script this way: aggregate creation, IOProc cadence, overload count,
/// meters, rebuild recovery, hot lane add/remove, and clean teardown.
///
///     Clapboard --engine-test 120 \
///         --output "监听" --lane "MacBook Pro Microphone" --lane "Audio Hijack Input" \
///         --rebuild-at 20 --hot-lane "Loopback"
///
/// `--save-session` writes the resulting lanes and output device to the session
/// file — `--session-path <file>` for somewhere other than the default — so the
/// M5 round trip can be driven entirely from a script:
///
///     Clapboard --engine-test 5 --output Loopback --lane "…" \
///         --save-session --session-path /tmp/session.json
///     Clapboard --restore-session /tmp/session.json
///
/// M4: `--lane-effect <name-or-id>` inserts an Audio Unit into the lane named
/// by the preceding `--lane`, `--master-effect` into the master chain, and
/// `--bypass-at <sec>` toggles every inserted effect once, so the crossfade
/// and the delay compensation that follows a bypass can be checked from a
/// script:
///
///     Clapboard --engine-test 20 --output Loopback \
///         --lane "MacBook Pro Microphone" --lane-effect AUDelay \
///         --lane "Audio Hijack Input" --master-effect AUPeakLimiter --bypass-at 10
enum EngineSmokeTest {
    @MainActor
    static func run(arguments: [String]) -> Never {
        var seconds = 10.0
        var outputQuery: String?
        var laneQueries: [String] = []
        /// Effects to insert into each lane, parallel to `laneQueries`.
        var laneEffectQueries: [[String]] = []
        var masterEffectQueries: [String] = []
        var bypassAt: Double?
        var hotLaneQuery: String?
        var rebuildAt: Double?
        var ignoreTCC = false
        var saveSession = false
        var sessionPath: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func next() -> String? {
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }
            switch argument {
            case "--engine-test": seconds = Double(next() ?? "10") ?? 10
            case "--output": outputQuery = next()
            case "--lane":
                if let value = next() {
                    laneQueries.append(value)
                    laneEffectQueries.append([])
                }
            // Attaches to the most recent `--lane`, so the flag order on the
            // command line is the chain order in the mixer.
            case "--lane-effect":
                if let value = next(), !laneEffectQueries.isEmpty {
                    laneEffectQueries[laneEffectQueries.count - 1].append(value)
                }
            case "--master-effect": if let value = next() { masterEffectQueries.append(value) }
            case "--bypass-at": bypassAt = Double(next() ?? "")
            case "--hot-lane": hotLaneQuery = next()
            case "--rebuild-at": rebuildAt = Double(next() ?? "")
            case "--ignore-tcc": ignoreTCC = true
            case "--save-session": saveSession = true
            case "--session-path": sessionPath = next()
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
        say("output   \(output.name) [\(output.uid)]")

        var laneIDs: [UUID] = []
        for query in laneQueries {
            // "Device Name#2" takes channel 2, "Device Name#1,2" the stereo
            // pair. A bare name takes channel 1. `#` rather than `:` because
            // device UIDs are full of colons.
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
            let lane = engine.addLane(
                deviceUID: device.uid, deviceChannels: channels, name: "\(device.name) \(label)")
            laneIDs.append(lane.id)
            say("lane     \(device.name) ch\(label) [\(device.uid)]")
        }

        // Effects go in before the engine starts, so the very first block the
        // IOProc renders already has the chains and the compensation in place.
        var effectIDs: [UUID] = []
        for (index, queries) in laneEffectQueries.enumerated() where index < laneIDs.count {
            for query in queries {
                effectIDs.append(insertEffect(query, into: laneIDs[index], engine: engine))
            }
        }
        for query in masterEffectQueries {
            effectIDs.append(insertEffect(query, into: nil, engine: engine))
        }
        if !effectIDs.isEmpty {
            say("latency  " + latencyLine(engine))
        }

        // TCC: without it the HAL hands the IOProc zeros rather than an error,
        // so say plainly which way it went instead of reporting silence as a
        // working capture.
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        say("mic TCC  \(describe(authorization))")
        if authorization == .notDetermined && !ignoreTCC {
            engine.requestAuthorization()
            waitUntil(timeout: 20) { AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined }
            say("mic TCC  \(describe(AVCaptureDevice.authorizationStatus(for: .audio))) after prompt")
        }
        if ignoreTCC {
            engine.allowsUnauthorizedCapture = true
            say("mic TCC  bypassed for diagnostics — lane input will be zeros unless TCC is granted")
        }

        let started = Date()
        engine.start()
        guard engine.runState.isRunning else {
            fail("engine did not start: \(engine.lastError ?? engine.runState.label)")
        }
        say("started  in \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms")
        say("aggregate \(engine.aggregateSummary ?? "-")")

        var didRebuild = rebuildAt == nil
        var didBypass = bypassAt == nil
        var overloadsBeforeBypass = 0
        var didHotAdd = hotLaneQuery == nil
        var hotLaneID: UUID?
        var worstCallbackAge = 0.0
        var lastCallbacks = 0
        let deadline = Date().addingTimeInterval(seconds)

        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            let elapsed = Date().timeIntervalSince(started)
            worstCallbackAge = max(worstCallbackAge, engine.secondsSinceLastCallback)

            let callbacks = engine.callbackCount
            let perSecond = callbacks - lastCallbacks
            lastCallbacks = callbacks

            var meters = engine.lanes.map { lane -> String in
                let reading = engine.meter(laneID: lane.id)
                return String(format: "%@=%.1f", short(lane.name), reading.peakDB)
            }
            meters.append(String(format: "master=%.1f", engine.masterMeter.peakDB))

            say(String(
                format: "t=%5.1f  %@  cb=%d(+%d)  overload=%d  dropped=%d  age=%.3fs  %@",
                elapsed, engine.runState.isRunning ? "running" : engine.runState.label,
                callbacks, perSecond, engine.overloadCount, engine.droppedBlocks,
                engine.secondsSinceLastCallback, meters.joined(separator: " ")
            ))

            if !effectIDs.isEmpty {
                say("         " + latencyLine(engine))
            }

            if let bypassAt, !didBypass, elapsed >= bypassAt {
                didBypass = true
                overloadsBeforeBypass = engine.overloadCount
                for id in effectIDs {
                    let now = !(engine.effectConfig(id: id)?.bypass ?? false)
                    engine.setEffectBypass(id: id, now)
                }
                say("BYPASS   toggled \(effectIDs.count) effect(s); " + latencyLine(engine))
            } else if bypassAt != nil, didBypass, overloadsBeforeBypass >= 0,
                      elapsed >= (bypassAt ?? 0) + 2 {
                say("BYPASS   overloads \(overloadsBeforeBypass) -> \(engine.overloadCount) "
                    + "two seconds after the toggle")
                overloadsBeforeBypass = -1
            }

            if let rebuildAt, !didRebuild, elapsed >= rebuildAt {
                didRebuild = true
                let mark = Date()
                engine.rebuild(reason: "smoke test")
                let recovered = waitUntil(timeout: 5) { engine.runState.isRunning && engine.callbackHealthy }
                say(String(
                    format: "REBUILD  back to running+callbacks in %.0f ms (%@)",
                    Date().timeIntervalSince(mark) * 1000, recovered ? "ok" : "TIMED OUT"
                ))
            }

            if let hotLaneQuery, !didHotAdd, elapsed >= seconds / 2 {
                didHotAdd = true
                if let device = resolve(hotLaneQuery), device.hasInput, device.uid != output.uid {
                    let before = engine.restartCount
                    hotLaneID = engine.addLane(deviceUID: device.uid, deviceChannels: [0], name: device.name).id
                    _ = waitUntil(timeout: 5) { engine.runState.isRunning && engine.callbackHealthy }
                    say("HOT ADD  \(device.name) — aggregate rebuilt: \(engine.restartCount > before), state=\(engine.runState.label)")
                }
            } else if let id = hotLaneID, elapsed >= seconds / 2 + 3 {
                hotLaneID = nil
                let before = engine.restartCount
                engine.removeLane(id: id)
                _ = waitUntil(timeout: 5) { engine.runState.isRunning && engine.callbackHealthy }
                say("HOT DROP removed — aggregate rebuilt: \(engine.restartCount > before), state=\(engine.runState.label)")
            }
        }

        say("summary  callbacks=\(engine.callbackCount) overloads=\(engine.overloadCount) "
            + "dropped=\(engine.droppedBlocks) rebuilds=\(engine.restartCount) "
            + "worstCallbackAge=\(String(format: "%.3f", worstCallbackAge))s "
            + "state=\(engine.runState.label)")

        if let warning = engine.pdcWarning {
            say("PDC WARN \(warning)")
        }

        if saveSession {
            guard let store = SessionSmokeTest.store(path: sessionPath) else {
                fail("macOS reports no Application Support directory; pass --session-path")
            }
            do {
                try store.save(engine.sessionSnapshot)
                say("session  wrote \(engine.lanes.count) lane(s) to \(store.fileURL.path)")
            } catch {
                fail("could not write the session: \(error)")
            }
        }

        engine.shutdown()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // Nothing of ours may survive the teardown.
        let leftovers = ((try? AudioDeviceInfo.enumerateAll()) ?? [])
            .filter { $0.uid.hasPrefix("com.astroqore.Clapboard.aggregate.") || $0.name == "Clapboard Mix" }
        say("leftover aggregates after shutdown: \(leftovers.count)")
        exit(leftovers.isEmpty ? 0 : 2)
    }

    // MARK: - Effects

    /// Resolves a plug-in by `AUComponentInfo.id`, exact name, or a
    /// case-insensitive substring, then inserts it and waits for it to load.
    @MainActor
    private static func insertEffect(_ query: String, into laneID: UUID?, engine: AudioEngine) -> UUID {
        let catalog = AUCatalog.effects()
        guard let info = catalog.first(where: { $0.id == query })
            ?? catalog.first(where: { $0.name == query })
            ?? catalog.first(where: { $0.name.localizedCaseInsensitiveContains(query) })
            ?? catalog.first(where: { $0.displayName.localizedCaseInsensitiveContains(query) })
        else {
            fail("--lane-effect/--master-effect \(query) matched no installed Audio Unit; "
                + "run --effects-list to see what is here")
        }
        if let reason = AUAvailability.reason(for: info) {
            fail("\(info.displayName): \(reason)")
        }
        var outcome: Result<EffectConfig, any Error>?
        Task { @MainActor in
            do {
                outcome = .success(try await engine.addEffect(info, toLane: laneID))
            } catch {
                outcome = .failure(error)
            }
        }
        _ = waitUntil(timeout: 30) { outcome != nil }
        switch outcome {
        case .success(let config):
            let where_ = laneID == nil ? "master" : "lane"
            say("effect   \(where_) += \(info.displayName) "
                + "[\(engine.effectLatencySamples(id: config.id)) sp latency]")
            return config.id
        case .failure(let error):
            fail("could not load \(info.displayName): \(error)")
        case nil:
            fail("\(info.displayName) did not finish loading in 30 s")
        }
    }

    /// Per-lane chain, chain latency, the compensation added on top, and what
    /// the render thread's delay line is actually set to.
    @MainActor
    private static func latencyLine(_ engine: AudioEngine) -> String {
        var parts: [String] = []
        for lane in engine.lanes {
            let chain = engine.effects(forLane: lane.id)
            let names = chain.isEmpty
                ? "-"
                : chain.map { config in
                    let short = config.displayName.split(separator: ":").last.map(String.init)
                        ?? config.displayName
                    return short.trimmingCharacters(in: .whitespaces)
                        + (config.bypass ? "(byp)" : "")
                }.joined(separator: ">")
            parts.append(String(
                format: "%@[%@ chain=%dsp pdc=+%dsp delay=%dsp]",
                short(lane.name), names,
                engine.laneChainLatency(lane.id),
                engine.pdcSamples[lane.id] ?? 0,
                engine.effectiveDelaySamples(forLane: lane.id)))
        }
        if !engine.masterEffects.isEmpty {
            parts.append("master[\(engine.masterEffects.map(\.displayName).joined(separator: ">")) "
                + "chain=\(engine.masterChainLatency)sp]")
        }
        parts.append(String(format: "out=%dsp/%.2fms",
                            engine.outputLatencySamples, engine.outputLatencyMilliseconds))
        return parts.joined(separator: "  ")
    }

    // MARK: - Helpers

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

    private static func say(_ message: String) {
        print(message)
        fflush(stdout)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("engine-test: \(message)\n".utf8))
        exit(1)
    }

    private static func short(_ name: String) -> String {
        String(name.prefix(14)).replacingOccurrences(of: " ", with: "_")
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
