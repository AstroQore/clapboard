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
///
/// Bus routing (`docs/ROUTING.md`): `--bus <name>` adds a bus, parented to
/// Master by default; `--route <lane>=<bus>` moves a lane (matched by its
/// `--lane` query string) onto a bus; `--bus-parent <bus>=<parent>` overrides
/// the default parent (`-`/`none` makes it a root); `--bus-output
/// <bus>=<device>` gives a bus its own output device, in addition to (or
/// instead of) feeding its parent; `--solo <name>`/`--mute <name>` take
/// either a lane or a bus name. Every second's status line grows a per-bus
/// meter column, a per-bus PDC line and a per-output-device latency line:
///
///     Clapboard --engine-test 10 --output Loopback \
///         --lane "MacBook Pro Microphone" --bus Vocals \
///         --route "MacBook Pro Microphone"=Vocals --lane "Audio Hijack Input"
enum EngineSmokeTest {
    @MainActor
    static func run(arguments: [String]) -> Never {
        var seconds = 10.0
        var outputQuery: String?
        var laneQueries: [String] = []
        /// Effects to insert into each lane, parallel to `laneQueries`.
        var laneEffectQueries: [[String]] = []
        var masterEffectQueries: [String] = []
        var busNames: [String] = []
        var routePairs: [String] = []
        var busParentPairs: [String] = []
        var busOutputPairs: [String] = []
        var soloNames: [String] = []
        var muteNames: [String] = []
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
            case "--bus": if let value = next() { busNames.append(value) }
            case "--route": if let value = next() { routePairs.append(value) }
            case "--bus-parent": if let value = next() { busParentPairs.append(value) }
            case "--bus-output": if let value = next() { busOutputPairs.append(value) }
            case "--solo": if let value = next() { soloNames.append(value) }
            case "--mute": if let value = next() { muteNames.append(value) }
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
        var laneIDsByQuery: [String: UUID] = [:]
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
            laneIDsByQuery[query] = lane.id
            say("lane     \(device.name) ch\(label) [\(device.uid)]")
        }

        // Buses and routing go in before the effects and before the engine
        // starts, so the very first block the IOProc renders already has the
        // whole tree — lanes on the right buses, buses on the right parents
        // and output devices — in place.
        var busIDsByName: [String: UUID] = [BusConfig.masterName: engine.buses[0].id]
        for name in busNames {
            let bus = engine.addBus(name: name)
            // `--bus` alone feeds Master by default; `--bus-parent` below can
            // override or clear it.
            _ = engine.setBusDestination(id: bus.id, parent: engine.buses[0].id)
            busIDsByName[name] = bus.id
            say("bus      \(name) [\(bus.id)]")
        }

        func splitPair(_ flag: String, _ value: String) -> (String, String) {
            guard let separator = value.firstIndex(of: "=") else {
                fail("\(flag) \(value) needs the shape name=name")
            }
            return (String(value[value.startIndex..<separator]), String(value[value.index(after: separator)...]))
        }

        func resolveLane(_ key: String) -> UUID? {
            laneIDsByQuery[key] ?? engine.lanes.first(where: { $0.name.hasPrefix(key) })?.id
        }

        func resolveStrip(_ name: String) -> (isLane: Bool, id: UUID)? {
            if let laneID = resolveLane(name) { return (true, laneID) }
            if let busID = busIDsByName[name] { return (false, busID) }
            return nil
        }

        for pair in routePairs {
            let (laneKey, busKey) = splitPair("--route", pair)
            guard let laneID = resolveLane(laneKey) else { fail("--route \(pair): no lane named \(laneKey)") }
            guard let busID = busIDsByName[busKey] else {
                fail("--route \(pair): no bus named \(busKey) (add it first with --bus)")
            }
            guard engine.setLaneDestination(laneID, bus: busID) else {
                fail("--route \(pair): could not route \(laneKey) to \(busKey)")
            }
            say("route    \(laneKey) -> \(busKey)")
        }

        for pair in busParentPairs {
            let (busKey, parentKey) = splitPair("--bus-parent", pair)
            guard let busID = busIDsByName[busKey] else { fail("--bus-parent \(pair): no bus named \(busKey)") }
            let parentID: UUID?
            if parentKey == "-" || parentKey.lowercased() == "none" {
                parentID = nil
            } else if let id = busIDsByName[parentKey] {
                parentID = id
            } else {
                fail("--bus-parent \(pair): no bus named \(parentKey)")
            }
            switch engine.setBusDestination(id: busID, parent: parentID) {
            case .success: say("bus-parent \(busKey) -> \(parentKey)")
            case .failure(let error): fail("--bus-parent \(pair): \(error)")
            }
        }

        for pair in busOutputPairs {
            let (busKey, deviceKey) = splitPair("--bus-output", pair)
            guard let busID = busIDsByName[busKey] else { fail("--bus-output \(pair): no bus named \(busKey)") }
            guard let device = resolve(deviceKey), device.hasOutput else {
                fail("--bus-output \(pair): \(deviceKey) did not resolve to an output device")
            }
            engine.setBusOutput(id: busID, deviceUID: device.uid)
            say("bus-output \(busKey) -> \(device.name) [\(device.uid)]")
        }

        for name in soloNames {
            guard let (isLane, id) = resolveStrip(name) else { fail("--solo \(name): no lane or bus with that name") }
            if isLane { engine.setLaneSolo(id, true) } else { engine.setBusSolo(id, true) }
            say("solo     \(name)")
        }
        for name in muteNames {
            guard let (isLane, id) = resolveStrip(name) else { fail("--mute \(name): no lane or bus with that name") }
            if isLane { engine.setLaneMuted(id, true) } else { engine.setBusMuted(id, true) }
            say("mute     \(name)")
        }

        if let error = engine.routingError {
            fail("routing did not validate: \(error)")
        }

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

            let laneMeters = engine.lanes.map { lane -> String in
                let reading = engine.meter(laneID: lane.id)
                return String(format: "%@=%.1f", short(lane.name), reading.peakDB)
            }
            // Master is just another bus, so this one loop covers it too.
            let busMeters = engine.buses.map { bus -> String in
                String(format: "%@=%.1f", short(bus.name), engine.busMeter(id: bus.id).peakDB)
            }

            say(String(
                format: "t=%5.1f  %@  cb=%d(+%d)  overload=%d  dropped=%d  age=%.3fs  %@",
                elapsed, engine.runState.isRunning ? "running" : engine.runState.label,
                callbacks, perSecond, engine.overloadCount, engine.droppedBlocks,
                engine.secondsSinceLastCallback, (laneMeters + busMeters).joined(separator: " ")
            ))

            if !effectIDs.isEmpty {
                say("         " + latencyLine(engine))
            }
            say("         " + busPDCLine(engine))
            say("         " + outputLatencyLine(engine))

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
        if let error = engine.routingError {
            say("ROUTING WARN \(error)")
        }

        if saveSession {
            guard let store = SessionSmokeTest.store(path: sessionPath) else {
                fail("macOS reports no Application Support directory; pass --session-path")
            }
            do {
                try store.save(engine.sessionSnapshot)
                say("session  wrote \(engine.lanes.count) lane(s), \(engine.buses.count) bus(es) to \(store.fileURL.path)")
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
    static func insertEffect(_ query: String, into laneID: UUID?, engine: AudioEngine) -> UUID {
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
    static func latencyLine(_ engine: AudioEngine) -> String {
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

    /// Every bus's own chain latency and the compensation delay
    /// `pushEffectiveDelays()` gave it, so a sibling pair can be checked by
    /// eye for "same total at the shared parent".
    @MainActor
    static func busPDCLine(_ engine: AudioEngine) -> String {
        "bus pdc: " + engine.buses.map { bus in
            String(format: "%@[chain=%dsp pdc=+%dsp]",
                short(bus.name), engine.busChainLatency(bus.id), engine.latencyPlan.busCompensation[bus.id] ?? 0)
        }.joined(separator: " ")
    }

    /// End-to-end latency at every output device any bus currently writes to.
    @MainActor
    static func outputLatencyLine(_ engine: AudioEngine) -> String {
        let devices = Set(engine.buses.compactMap(\.outputDeviceUID)).sorted()
        guard !devices.isEmpty else { return "out pdc: -" }
        return "out pdc: " + devices.map { uid in
            String(format: "%@=%dsp", short(uid), engine.outputLatencySamples(forDevice: uid))
        }.joined(separator: " ")
    }

    // MARK: - Helpers

    @MainActor
    @discardableResult
    static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    static func say(_ message: String) {
        print(message)
        fflush(stdout)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("engine-test: \(message)\n".utf8))
        exit(1)
    }

    static func short(_ name: String) -> String {
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

/// `--routing-selftest`: exercises the bus tree end to end on real hardware
/// without needing the caller to know this Mac's device names.
///
/// Builds Master (unchanged) with two children, `BusA` and `BusB`, each with
/// its own output device — a "Loopback" device and, in order of preference, a
/// "监听"/"監聽" device or a second "Loopback" device — and routes up to two
/// input devices onto `BusA`. Then checks, in order: the private aggregate
/// really carries both output devices, IOProc callbacks are flowing, every
/// bus's meter reads a sane value, mute/solo flags apply, every lane on
/// `BusA` reaches its output at the same total latency (`docs/ROUTING.md`'s
/// plug-in delay compensation), and nothing is left behind on shutdown.
extension EngineSmokeTest {
    @MainActor
    static func runRoutingSelfTest(arguments: [String]) -> Never {
        let ignoreTCC = arguments.contains("--ignore-tcc")
        let seconds = arguments.firstIndex(of: "--routing-selftest").flatMap { index -> Double? in
            let next = index + 1
            guard next < arguments.count else { return nil }
            return Double(arguments[next])
        } ?? 4.0

        let registry = AudioDeviceRegistry()
        registry.start()
        let devices = registry.devices

        func findOutput(containing needles: [String], excluding: Set<String> = []) -> AudioDeviceInfo? {
            devices.first { device in
                device.hasOutput && !excluding.contains(device.uid)
                    && needles.contains { needle in device.name.localizedCaseInsensitiveContains(needle) }
            }
        }

        guard let deviceA = findOutput(containing: ["Loopback"]) else {
            fail("--routing-selftest needs at least one \"Loopback\" output device on this Mac")
        }
        guard let deviceB = findOutput(containing: ["监听", "監聽"], excluding: [deviceA.uid])
            ?? findOutput(containing: ["Loopback"], excluding: [deviceA.uid])
        else {
            fail("--routing-selftest needs a second output device — a \"监听\"/\"監聽\" device, "
                + "or a second \"Loopback\" device — on this Mac")
        }
        say("devices  A=\(deviceA.name) [\(deviceA.uid)]  B=\(deviceB.name) [\(deviceB.uid)]")

        let excludedUIDs: Set<String> = [deviceA.uid, deviceB.uid]
        let laneDevices = Array(devices.filter { $0.hasInput && !excludedUIDs.contains($0.uid) }.prefix(2))
        if laneDevices.isEmpty {
            say("lanes    none available on this Mac — routing/output plumbing is still checked, "
                + "meters will just read silence")
        }

        let engine = AudioEngine()
        engine.attach(registry: registry)

        let master = engine.buses[0]
        let busA = engine.addBus(name: "BusA")
        let busB = engine.addBus(name: "BusB")
        _ = engine.setBusDestination(id: busA.id, parent: master.id)
        _ = engine.setBusDestination(id: busB.id, parent: master.id)
        engine.setBusOutput(id: busA.id, deviceUID: deviceA.uid)
        engine.setBusOutput(id: busB.id, deviceUID: deviceB.uid)
        say("buses    BusA -> \(deviceA.name), BusB -> \(deviceB.name), both children of Master")

        var laneIDs: [UUID] = []
        for device in laneDevices {
            let lane = engine.addLane(deviceUID: device.uid, deviceChannels: [0], name: device.name)
            _ = engine.setLaneDestination(lane.id, bus: busA.id)
            laneIDs.append(lane.id)
            say("lane     \(device.name) -> BusA")
        }

        // A real, installed effect on the first lane, if this Mac has one
        // this build can host — gives the PDC-equality check below something
        // nonzero to actually compensate for, not just an "all zeros" pass.
        var effectID: UUID?
        if let firstLane = laneIDs.first {
            let catalog = AUCatalog.effects()
            if let info = catalog.first(where: { $0.name.localizedCaseInsensitiveContains("AUDelay") && AUAvailability.reason(for: $0) == nil })
                ?? catalog.first(where: { AUAvailability.reason(for: $0) == nil }) {
                effectID = insertEffect(info.id, into: firstLane, engine: engine)
            }
        }

        if ignoreTCC {
            engine.allowsUnauthorizedCapture = true
            say("mic TCC  bypassed for diagnostics")
        } else if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            engine.requestAuthorization()
            waitUntil(timeout: 20) { AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined }
        }

        engine.start()
        guard engine.runState.isRunning else {
            fail("engine did not start: \(engine.lastError ?? engine.runState.label)")
        }
        say("started  aggregate \(engine.aggregateSummary ?? "-")")

        var pass = true
        func check(_ label: String, _ ok: Bool) {
            say("\(ok ? "PASS" : "FAIL")     \(label)")
            if !ok { pass = false }
        }

        // 1. The private aggregate really has both output devices — the
        // buffer/channel-count each got is right there in the summary
        // (`AggregateDevice.summary`), derived from the actual stream
        // configuration rather than an assumed index.
        let summary = engine.aggregateSummary ?? ""
        check("aggregate carries both output devices",
              summary.contains(deviceA.uid) && summary.contains(deviceB.uid))

        // 2. Callbacks are flowing and routing validated cleanly.
        _ = waitUntil(timeout: 3) { engine.callbackCount > 0 }
        check("IOProc callbacks are flowing", engine.callbackCount > 0)
        check("no routing error", engine.routingError == nil)

        // 3. Every bus's meter reads back a finite, sane value — proof the
        // per-bus accumulator/meter wiring in the render kernel runs for
        // every bus in the graph, not just Master.
        let metersOK = engine.buses.allSatisfy { bus in
            let meter = engine.busMeter(id: bus.id)
            return meter.peak.isFinite && meter.rms.isFinite && meter.peak >= 0 && meter.rms >= 0
        }
        check("every bus meter reads a finite, non-negative value", metersOK)

        // 4. Mute/solo semantics reach the bus's own flags (the render-side
        // truth table — soloing one bus silencing its siblings, never its
        // parent or its own lanes — is `SoloLogicTests`/`RenderKernelBusTests`;
        // this checks the real engine actually applies an edit rather than
        // silently dropping it).
        engine.setBusSolo(busA.id, true)
        check("solo sets the bus's own flag", engine.bus(id: busA.id)?.solo == true)
        engine.setBusSolo(busA.id, false)
        engine.setBusMuted(busB.id, true)
        check("mute sets the bus's own flag", engine.bus(id: busB.id)?.muted == true)
        engine.setBusMuted(busB.id, false)

        // 5. PDC equality: every lane feeding BusA reaches BusA's output at
        // the same total latency — `docs/ROUTING.md`'s per-bus PDC, the same
        // invariant `LatencyPlanTests` checks in isolation, now through the
        // real engine end to end.
        if laneIDs.count >= 2 {
            let totals = laneIDs.map { engine.laneChainLatency($0) + engine.effectiveDelaySamples(forLane: $0) }
            check("every lane on BusA totals the same latency to its output \(totals)", Set(totals).count == 1)
        } else {
            say("SKIP     PDC equality needs 2 lanes on one bus; only \(laneIDs.count) available on this Mac")
        }
        if let effectID {
            check("the inserted effect reports a latency reading",
                  engine.effectLatencySamples(id: effectID) >= 0)
        }

        say("bus meters " + engine.buses.map { "\($0.name)=\(String(format: "%.1f", engine.busMeter(id: $0.id).peakDB))" }.joined(separator: " "))
        say(busPDCLine(engine))
        say(outputLatencyLine(engine))

        // Let a few more real IOProc cycles go by before tearing down.
        _ = waitUntil(timeout: max(0, seconds - 3)) { false }

        engine.shutdown()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let leftovers = ((try? AudioDeviceInfo.enumerateAll()) ?? [])
            .filter { $0.uid.hasPrefix("com.astroqore.Clapboard.aggregate.") || $0.name == "Clapboard Mix" }
        check("no leftover aggregate after shutdown", leftovers.isEmpty)

        say(pass ? "ROUTING SELFTEST PASSED" : "ROUTING SELFTEST FAILED")
        exit(pass ? 0 : 2)
    }
}
