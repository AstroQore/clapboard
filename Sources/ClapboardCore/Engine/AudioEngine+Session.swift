import Foundation

/// What `restore` actually did, for the status line and the headless test.
public struct SessionRestoreReport: Sendable, Equatable {
    public var restoredLanes: Int = 0
    /// One human-readable line per lane that was not restored.
    public var skippedLanes: [String] = []
    /// The engine was running and has been started again.
    public var restarted: Bool = false
    /// The file came from a newer Clapboard; anything this build does not
    /// understand was dropped from the lanes but kept in the extras bag.
    public var fromNewerFormat: Bool = false
    /// `true` when the file predated buses (`formatVersion < 2`, or a
    /// version 2 file with no `buses` at all) and a `Master` bus was
    /// synthesized from `outputDeviceUID`/`masterGainDB`/`masterExtras`.
    public var migratedFromFormat1: Bool = false
    /// Effects the file asked for, across every lane and every bus. They are
    /// still loading when `restore` returns — instantiating a plug-in is
    /// `async` and slow — so wait on `AudioEngine.restoringEffects` before
    /// judging the result.
    public var pendingEffects: Int = 0

    public var summary: String {
        var parts = ["restored \(restoredLanes) lane\(restoredLanes == 1 ? "" : "s")"]
        if !skippedLanes.isEmpty { parts.append("skipped \(skippedLanes.count)") }
        if restarted { parts.append("engine restarted") }
        if pendingEffects > 0 { parts.append("loading \(pendingEffects) effect(s)") }
        if migratedFromFormat1 { parts.append("migrated from format 1") }
        if fromNewerFormat { parts.append("file is from a newer Clapboard") }
        return parts.joined(separator: ", ")
    }
}

extension AudioEngine {
    /// The part of the engine's state that belongs in the session file.
    ///
    /// Meters, run state, overload counts and the aggregate device are all
    /// derived or per-run and deliberately absent. `outputDeviceUID`/
    /// `masterGainDB`/`masterExtras` are written empty/default: `buses`
    /// carries that information now, one entry per bus, each with its own
    /// chain inline — they are kept in the document only so a version 1
    /// reader (or this build reading its own file back after a downgrade)
    /// still finds something familiar.
    public var sessionSnapshot: SessionDocument {
        var laneBags: [String: [String: Data]] = [:]
        for lane in lanes {
            guard let chain = laneEffects[lane.id], !chain.isEmpty else { continue }
            guard let data = try? EffectChainCodec.encode(savedChain(chain)) else { continue }
            laneBags[lane.id.uuidString] = [EffectChainCodec.extrasKey: data]
        }
        let savedBuses = buses.map { bus -> BusConfig in
            var bus = bus
            bus.effects = savedChain(bus.effects)
            return bus
        }
        return SessionDocument(
            lanes: lanes,
            buses: savedBuses,
            laneExtras: laneBags
        )
    }

    /// A chain with each live plug-in's current state read out of it.
    ///
    /// A placeholder keeps whatever state it was loaded with: a session opened
    /// on a Mac without the plug-in and saved again must not lose the
    /// settings, which is the whole reason placeholders exist.
    private func savedChain(_ chain: [EffectConfig]) -> [EffectConfig] {
        chain.map { config in
            var copy = config
            copy.unavailableReason = nil
            if let instance = effectInstance(id: config.id) {
                copy.fullState = instance.fullState()
            }
            return copy
        }
    }

    /// Rebuilds the mixer from `session`.
    ///
    /// Restoring is a topology edit, so it is done with the engine stopped. A
    /// running engine is stopped, restored and started again rather than being
    /// refused: "open a session" should behave the same whether or not the mix
    /// is live, and every intermediate state (no lanes, wrong output device)
    /// would otherwise be pushed to the render thread one edit at a time.
    ///
    /// Lanes whose device is not plugged in are kept, exactly as they were
    /// saved. They come back as `LaneStatus.deviceMissing` once the engine
    /// runs, and rebind by themselves when the device reappears.
    @discardableResult
    public func restore(_ session: SessionDocument) -> SessionRestoreReport {
        var report = SessionRestoreReport(fromNewerFormat: session.isFromNewerFormat)
        let wasRunning = runState.isRunning || runState.isBusy
        if wasRunning { stop() }

        effectRestoreTask?.cancel()
        effectRestoreTask = nil
        restoringEffects = false
        clearAllEffects()

        for id in lanes.map(\.id) { removeLane(id: id) }
        // Mute-all's memory is meaningless once the mixer underneath it has
        // been replaced wholesale.
        mutedLanesRemembered = []

        report.migratedFromFormat1 = session.needsBusMigration
        replaceBuses(AudioEngine.migratedBuses(from: session))
        rebuildRoutingGraph()

        let outputUIDs = Set(buses.compactMap(\.outputDeviceUID))
        var usedIDs = Set<UUID>()
        for lane in session.lanes {
            // A lane on any output device would feed the mix back into
            // itself; `setBusOutput` drops such a lane going forward, and a
            // hand-edited file must not be able to sneak one past it either.
            guard !outputUIDs.contains(lane.deviceUID) else {
                report.skippedLanes.append("\(lane.name): its device is an output device")
                continue
            }
            // Duplicated ids in an edited file would make two lanes share one
            // set of runtime parameters.
            let id = usedIDs.insert(lane.id).inserted ? lane.id : UUID()
            if id != lane.id {
                report.skippedLanes.append("\(lane.name): duplicate id, restored under a new one")
            }
            addLane(AudioEngine.sanitized(lane, id: id))
            report.restoredLanes += 1
        }

        // Chains are attached after the lanes and buses, keyed by whichever
        // id just came back — which is exactly why `LaneConfig.id`/
        // `BusConfig.id` are persisted.
        var wantedLaneEffects: [(laneID: UUID, chain: [EffectConfig])] = []
        for lane in lanes {
            let chain = EffectChainCodec.decode(
                session.laneExtras[lane.id.uuidString]?[EffectChainCodec.extrasKey])
            if !chain.isEmpty { wantedLaneEffects.append((lane.id, chain)) }
        }
        // A version 1 file's master chain travels in `masterExtras`, already
        // folded into the synthesized bus's `effects` by `migratedBuses`; a
        // version 2 file already carries it there directly. Either way it is
        // sitting in `buses[_].effects` right now — take it out and load it
        // the same way a lane's chain loads, then clear the field so
        // `republishGraph()` does not see stale, uninstantiated ids.
        var wantedBusEffects: [(busID: UUID, chain: [EffectConfig])] = []
        for index in buses.indices where !buses[index].effects.isEmpty {
            wantedBusEffects.append((buses[index].id, buses[index].effects))
            buses[index].effects = []
        }
        report.pendingEffects = wantedLaneEffects.reduce(0) { $0 + $1.chain.count }
            + wantedBusEffects.reduce(0) { $0 + $1.chain.count }

        if wasRunning {
            start()
            report.restarted = true
        }

        if !wantedLaneEffects.isEmpty || !wantedBusEffects.isEmpty {
            restoringEffects = true
            effectRestoreTask = Task { @MainActor [weak self] in
                await self?.loadRestoredChains(lanes: wantedLaneEffects, buses: wantedBusEffects)
            }
        }
        return report
    }

    /// Waits for a restore's plug-ins to finish loading. For scripts and
    /// tests; the UI just watches `restoringEffects`.
    public func waitForEffectRestore() async {
        await effectRestoreTask?.value
    }

    /// Loads every saved chain in order, one plug-in at a time — lanes first,
    /// then buses, master included.
    ///
    /// Sequential on purpose: instantiating several AUv2 bundles at once means
    /// several plug-ins touching AppKit from the same actor, and the order of
    /// a chain is part of its sound, so there is nothing to gain from racing.
    private func loadRestoredChains(
        lanes wantedLanes: [(laneID: UUID, chain: [EffectConfig])],
        buses wantedBuses: [(busID: UUID, chain: [EffectConfig])]
    ) async {
        defer { restoringEffects = false }
        for entry in wantedLanes {
            for config in entry.chain {
                if Task.isCancelled { return }
                // The lane can be removed while an earlier plug-in loads.
                if lane(id: entry.laneID) == nil { break }
                await restoreOne(config, into: .lane(entry.laneID))
            }
        }
        // Every bus, master or not: a chain on a bus is a live chain, on the
        // same terms a lane's is. A placeholder here now means only what it
        // means on a lane — the component is not installed, or macOS refused
        // to host it — and never "this build has no API for that bus".
        for entry in wantedBuses {
            for config in entry.chain {
                if Task.isCancelled { return }
                guard bus(id: entry.busID) != nil else { break }
                await restoreOne(config, into: .bus(entry.busID))
            }
        }
    }

    private func restoreOne(_ config: EffectConfig, into target: EffectTarget) async {
        guard let info = AUCatalog.find(id: config.componentID) else {
            var placeholder = config
            placeholder.unavailableReason = AUAvailability.missingComponent(config.componentID)
            insertPlaceholder(placeholder, into: target)
            return
        }
        let channels: Int
        switch target {
        case .lane(let laneID):
            guard let lane = lane(id: laneID) else { return }
            channels = max(1, min(2, lane.deviceChannels.count))
        case .bus(let busID):
            guard bus(id: busID) != nil else { return }
            channels = AudioEngine.busEffectChannels
        }
        do {
            let instance = try await AUEffectInstance.instantiate(
                info,
                channels: channels,
                sampleRate: AudioEngine.effectSampleRate,
                maximumFrames: RTLimits.maxFramesPerBlock
            )
            if let state = config.fullState {
                // A state blob that does not apply is not worth losing the
                // plug-in over: the chain comes back at its defaults.
                try? instance.restore(fullState: state)
            }
            var restored = config
            restored.displayName = info.displayName
            insert(instance, config: restored, into: target, at: nil)
        } catch {
            var placeholder = config
            placeholder.displayName = info.displayName
            placeholder.unavailableReason = String(describing: error)
            insertPlaceholder(placeholder, into: target)
        }
    }

    /// Drops every chain, tearing the plug-ins down once the render thread has
    /// left them. Only `restore` uses it: opening a session replaces the mixer.
    private func clearAllEffects() {
        for chain in laneEffects.values {
            for config in chain { host.discardEffect(id: config.id) }
        }
        for bus in buses {
            for config in bus.effects { host.discardEffect(id: config.id) }
        }
        laneEffects.removeAll()
        for index in buses.indices { buses[index].effects = [] }
        pdcSamples.removeAll()
        pdcWarning = nil
        republishGraph()
        drainRetiredEffects()
    }

    /// Replaces `buses` wholesale — discarding every existing bus's runtime
    /// and registered effects, the same "replace, don't merge" rule `restore`
    /// applies to lanes — and points `masterBusID` at whichever bus in the
    /// new set is `Master`, so `masterGainDB`/`masterEffects`/`masterMeter`/
    /// `setOutputDevice` keep working against the bus the file actually
    /// calls Master. `newBuses` is never empty: `migratedBuses(from:)`
    /// guarantees at least one.
    private func replaceBuses(_ newBuses: [BusConfig]) {
        for bus in buses {
            for config in bus.effects { host.discardEffect(id: config.id) }
            host.discardBusRuntime(for: bus.id)
        }
        buses = []
        for bus in newBuses {
            host.runtime(forBus: bus.id)
            buses.append(bus)
        }
        masterBusID = newBuses.first(where: { $0.name == BusConfig.masterName })?.id
            ?? newBuses[0].id
    }

    /// `session.buses` when the file already has one (version 2), or a
    /// freshly synthesized `Master` bus from the version 1 fields
    /// (`outputDeviceUID`, `masterGainDB`, `masterExtras`) — every lane is
    /// routed to it the moment it is restored (`addLane` assigns any lane
    /// without a known `destinationBus` to `masterBusID`), which is exactly
    /// "migrate the implicit master into an explicit bus, route everything
    /// at it" (`docs/ROUTING.md`).
    static func migratedBuses(from session: SessionDocument) -> [BusConfig] {
        guard !session.needsBusMigration else {
            let effects = EffectChainCodec.decode(session.masterExtras[EffectChainCodec.extrasKey])
            return [BusConfig(
                name: BusConfig.masterName,
                gainDB: clampedGainDB(session.masterGainDB),
                effects: effects,
                outputDeviceUID: session.outputDeviceUID
            )]
        }
        return session.buses.map(sanitized(_:))
    }

    /// Values from a file are not values from the UI: clamp them to what the
    /// render thread can actually accept before they reach it.
    private static func sanitized(_ lane: LaneConfig, id: UUID) -> LaneConfig {
        LaneConfig(
            id: id,
            deviceUID: lane.deviceUID,
            deviceChannels: LaneConfig.sanitized(channels: lane.deviceChannels),
            name: lane.name,
            gainDB: clampedGainDB(lane.gainDB),
            enabled: lane.enabled,
            polarityInverted: lane.polarityInverted,
            delaySamples: min(max(0, lane.delaySamples), RTLimits.maxDelaySamples),
            solo: lane.solo,
            destinationBus: lane.destinationBus
        )
    }

    private static func sanitized(_ bus: BusConfig) -> BusConfig {
        var bus = bus
        bus.gainDB = clampedGainDB(bus.gainDB)
        bus.outputChannelOffset = max(0, bus.outputChannelOffset)
        return bus
    }

    private static func clampedGainDB(_ db: Float) -> Float {
        guard db.isFinite else { return 0 }
        return min(max(db, -120), 24)
    }
}
