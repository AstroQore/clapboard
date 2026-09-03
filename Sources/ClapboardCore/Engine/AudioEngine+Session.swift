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
    /// Effects the file asked for. They are still loading when `restore`
    /// returns — instantiating a plug-in is `async` and slow — so wait on
    /// `AudioEngine.restoringEffects` before judging the result.
    public var pendingEffects: Int = 0

    public var summary: String {
        var parts = ["restored \(restoredLanes) lane\(restoredLanes == 1 ? "" : "s")"]
        if !skippedLanes.isEmpty { parts.append("skipped \(skippedLanes.count)") }
        if restarted { parts.append("engine restarted") }
        if pendingEffects > 0 { parts.append("loading \(pendingEffects) effect(s)") }
        if fromNewerFormat { parts.append("file is from a newer Clapboard") }
        return parts.joined(separator: ", ")
    }
}

extension AudioEngine {
    /// The part of the engine's state that belongs in the session file.
    ///
    /// Meters, run state, overload counts and the aggregate device are all
    /// derived or per-run and deliberately absent.
    public var sessionSnapshot: SessionDocument {
        var laneBags: [String: [String: Data]] = [:]
        for lane in lanes {
            guard let chain = laneEffects[lane.id], !chain.isEmpty else { continue }
            guard let data = try? EffectChainCodec.encode(savedChain(chain)) else { continue }
            laneBags[lane.id.uuidString] = [EffectChainCodec.extrasKey: data]
        }
        var masterBag: [String: Data] = [:]
        if !masterEffects.isEmpty,
           let data = try? EffectChainCodec.encode(savedChain(masterEffects)) {
            masterBag[EffectChainCodec.extrasKey] = data
        }
        return SessionDocument(
            lanes: lanes,
            outputDeviceUID: outputDeviceUID,
            masterGainDB: masterGainDB,
            laneExtras: laneBags,
            masterExtras: masterBag
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
        setOutputDevice(uid: session.outputDeviceUID)
        masterGainDB = AudioEngine.clampedGainDB(session.masterGainDB)

        var usedIDs = Set<UUID>()
        for lane in session.lanes {
            // A lane on the output device would feed the mix back into itself;
            // `setOutputDevice` drops such lanes, and a hand-edited file must
            // not be able to sneak one past it.
            guard lane.deviceUID != session.outputDeviceUID else {
                report.skippedLanes.append("\(lane.name): its device is the output device")
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

        // Chains are attached after the lanes, keyed by the lane ids that
        // just came back — which is exactly why `LaneConfig.id` is persisted.
        var wanted: [(laneID: UUID?, chain: [EffectConfig])] = []
        for lane in lanes {
            let chain = EffectChainCodec.decode(
                session.laneExtras[lane.id.uuidString]?[EffectChainCodec.extrasKey])
            if !chain.isEmpty { wanted.append((lane.id, chain)) }
        }
        let master = EffectChainCodec.decode(session.masterExtras[EffectChainCodec.extrasKey])
        if !master.isEmpty { wanted.append((nil, master)) }
        report.pendingEffects = wanted.reduce(0) { $0 + $1.chain.count }

        if wasRunning {
            start()
            report.restarted = true
        }

        if !wanted.isEmpty {
            restoringEffects = true
            effectRestoreTask = Task { @MainActor [weak self] in
                await self?.loadRestoredChains(wanted)
            }
        }
        return report
    }

    /// Waits for a restore's plug-ins to finish loading. For scripts and
    /// tests; the UI just watches `restoringEffects`.
    public func waitForEffectRestore() async {
        await effectRestoreTask?.value
    }

    /// Loads each saved chain in order, one plug-in at a time.
    ///
    /// Sequential on purpose: instantiating several AUv2 bundles at once means
    /// several plug-ins touching AppKit from the same actor, and the order of
    /// a chain is part of its sound, so there is nothing to gain from racing.
    private func loadRestoredChains(_ wanted: [(laneID: UUID?, chain: [EffectConfig])]) async {
        defer { restoringEffects = false }
        for entry in wanted {
            for config in entry.chain {
                if Task.isCancelled { return }
                // The lane can be removed while an earlier plug-in loads.
                if let laneID = entry.laneID, lane(id: laneID) == nil { break }
                await restoreOne(config, intoLane: entry.laneID)
            }
        }
    }

    private func restoreOne(_ config: EffectConfig, intoLane laneID: UUID?) async {
        guard let info = AUCatalog.find(id: config.componentID) else {
            var placeholder = config
            placeholder.unavailableReason = AUAvailability.missingComponent(config.componentID)
            insertPlaceholder(placeholder, intoLane: laneID)
            return
        }
        let channels: Int
        if let laneID {
            guard let lane = lane(id: laneID) else { return }
            channels = max(1, min(2, lane.deviceChannels.count))
        } else {
            channels = 2
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
            insert(instance, config: restored, intoLane: laneID, at: nil)
        } catch {
            var placeholder = config
            placeholder.displayName = info.displayName
            placeholder.unavailableReason = String(describing: error)
            insertPlaceholder(placeholder, intoLane: laneID)
        }
    }

    /// Drops every chain, tearing the plug-ins down once the render thread has
    /// left them. Only `restore` uses it: opening a session replaces the mixer.
    private func clearAllEffects() {
        for chain in laneEffects.values {
            for config in chain { host.discardEffect(id: config.id) }
        }
        for config in masterEffects { host.discardEffect(id: config.id) }
        laneEffects.removeAll()
        masterEffects.removeAll()
        pdcSamples.removeAll()
        pdcWarning = nil
        republishGraph()
        drainRetiredEffects()
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
            delaySamples: min(max(0, lane.delaySamples), RTLimits.maxDelaySamples)
        )
    }

    private static func clampedGainDB(_ db: Float) -> Float {
        guard db.isFinite else { return 0 }
        return min(max(db, -120), 24)
    }
}
