import Foundation

/// Audio Unit chains: one per lane, one on the master bus.
///
/// A lane's chain sits after the delay line and before the fader; the master
/// chain sits after the sum and before the master fader. Editing either while
/// the engine runs is a graph snapshot swap, the same click-free mechanism
/// adding a lane uses, and the plug-ins themselves outlive it — they are owned
/// by `RTEngineHost` and only torn down once the render thread has provably
/// left every snapshot that could reach them.
extension AudioEngine {
    public enum EffectError: Error, LocalizedError, Equatable {
        case unknownLane
        case chainFull(Int)
        case unknownEffect

        public var errorDescription: String? {
            switch self {
            case .unknownLane:
                return "That lane is gone."
            case .chainFull(let limit):
                return "A chain holds at most \(limit) effects."
            case .unknownEffect:
                return "That effect is no longer in the mixer."
            }
        }
    }

    /// Every plug-in runs at the engine's fixed rate, not at whatever the
    /// aggregate currently reports: a chain survives stop/start and aggregate
    /// rebuilds, and re-negotiating a plug-in's format would drop its state.
    /// The engine refuses to run at anything but 48 kHz anyway.
    public static var effectSampleRate: Double { 48_000 }

    // MARK: - Reading a chain

    /// `nil` means the master bus, the same convention `addEffect` uses.
    public func effects(forLane laneID: UUID?) -> [EffectConfig] {
        guard let laneID else { return masterEffects }
        return laneEffects[laneID] ?? []
    }

    public func effectConfig(id: UUID) -> EffectConfig? {
        if let index = masterEffects.firstIndex(where: { $0.id == id }) { return masterEffects[index] }
        for chain in laneEffects.values {
            if let found = chain.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// The lane an effect belongs to, or `nil` for the master chain. The outer
    /// optional distinguishes "not found" from "on the master".
    public func laneOwning(effect id: UUID) -> UUID?? {
        if masterEffects.contains(where: { $0.id == id }) { return .some(nil) }
        for (laneID, chain) in laneEffects where chain.contains(where: { $0.id == id }) {
            return .some(laneID)
        }
        return nil
    }

    public func effectInstance(id: UUID) -> AUEffectInstance? {
        host.effectInstance(id: id)
    }

    /// The plug-in's own reported latency, whether or not it is bypassed.
    public func effectLatencySamples(id: UUID) -> Int {
        host.effectInstance(id: id)?.latencySamples ?? 0
    }

    // MARK: - Editing

    /// Loads a plug-in and appends it to a chain. `laneID == nil` is the
    /// master bus.
    ///
    /// Instantiation is `async` because `AUAudioUnit.instantiate` is, and it
    /// is not quick: a large plug-in takes hundreds of milliseconds. The lane
    /// can disappear while it loads, which is why the lane is checked twice.
    @discardableResult
    public func addEffect(_ info: AUComponentInfo, toLane laneID: UUID?) async throws -> EffectConfig {
        let channels: Int
        if let laneID {
            guard let lane = lane(id: laneID) else { throw EffectError.unknownLane }
            channels = max(1, min(2, lane.deviceChannels.count))
        } else {
            channels = 2
        }
        guard effects(forLane: laneID).count < RTLimits.maxEffectsPerChain else {
            throw EffectError.chainFull(RTLimits.maxEffectsPerChain)
        }

        let instance = try await AUEffectInstance.instantiate(
            info,
            channels: channels,
            sampleRate: AudioEngine.effectSampleRate,
            maximumFrames: RTLimits.maxFramesPerBlock
        )
        guard laneID == nil || lane(id: laneID!) != nil else {
            instance.teardown()
            throw EffectError.unknownLane
        }

        let config = EffectConfig(componentID: info.id, displayName: info.displayName)
        insert(instance, config: config, intoLane: laneID, at: nil)
        return config
    }

    /// Registers an already-instantiated plug-in and republishes. Shared by
    /// `addEffect` and session restore, which needs to keep the saved id.
    func insert(
        _ instance: AUEffectInstance,
        config: EffectConfig,
        intoLane laneID: UUID?,
        at index: Int?
    ) {
        host.registerEffect(id: config.id, instance: instance, channels: instance.laneChannels)
        host.setEffectBypass(id: config.id, config.bypass)
        // A plug-in may change its latency at any time — a linear-phase EQ
        // switching mode, a limiter whose look-ahead is a parameter — and
        // every lane's compensation is computed from it.
        instance.onLatencyChange = { [weak self] _ in
            self?.pushEffectiveDelays()
        }
        if let laneID {
            var chain = laneEffects[laneID] ?? []
            chain.insert(config, at: min(max(0, index ?? chain.count), chain.count))
            laneEffects[laneID] = chain
        } else {
            masterEffects.insert(config, at: min(max(0, index ?? masterEffects.count), masterEffects.count))
        }
        republishGraph()
        pushEffectiveDelays()
    }

    /// Adds a placeholder for a plug-in this Mac cannot load. It is shown
    /// greyed, is not published to the render thread, and keeps its saved
    /// state so the next save does not throw the settings away.
    func insertPlaceholder(_ config: EffectConfig, intoLane laneID: UUID?) {
        if let laneID {
            var chain = laneEffects[laneID] ?? []
            chain.append(config)
            laneEffects[laneID] = chain
        } else {
            masterEffects.append(config)
        }
    }

    public func removeEffect(id: UUID) {
        guard let owner = laneOwning(effect: id) else { return }
        if let laneID = owner {
            laneEffects[laneID]?.removeAll { $0.id == id }
            if laneEffects[laneID]?.isEmpty == true { laneEffects[laneID] = nil }
        } else {
            masterEffects.removeAll { $0.id == id }
        }
        host.discardEffect(id: id)
        republishGraph()
        pushEffectiveDelays()
        drainRetiredEffects()
    }

    /// Moves an effect inside its own chain. Order matters — a compressor
    /// before an EQ is a different sound from an EQ before a compressor — but
    /// nothing here can move an effect between chains: a plug-in is
    /// instantiated for its lane's channel count.
    public func moveEffect(id: UUID, to index: Int) {
        guard let owner = laneOwning(effect: id) else { return }
        func reorder(_ chain: inout [EffectConfig]) {
            guard let from = chain.firstIndex(where: { $0.id == id }) else { return }
            let clamped = min(max(0, index), chain.count - 1)
            guard clamped != from else { return }
            let entry = chain.remove(at: from)
            chain.insert(entry, at: clamped)
        }
        if let laneID = owner {
            var chain = laneEffects[laneID] ?? []
            reorder(&chain)
            laneEffects[laneID] = chain
        } else {
            reorder(&masterEffects)
        }
        republishGraph()
    }

    /// Bypass is a host-level pass-through, not `AUAudioUnit.shouldBypassEffect`:
    /// leaving the plug-in rendering would keep its latency, so toggling it
    /// would shift the lane against the others. That does mean bypass changes
    /// the chain's latency, so compensation is recomputed here.
    public func setEffectBypass(id: UUID, _ bypass: Bool) {
        guard let owner = laneOwning(effect: id) else { return }
        if let laneID = owner {
            if let position = laneEffects[laneID]?.firstIndex(where: { $0.id == id }) {
                laneEffects[laneID]?[position].bypass = bypass
            }
        } else if let position = masterEffects.firstIndex(where: { $0.id == id }) {
            masterEffects[position].bypass = bypass
        }
        host.setEffectBypass(id: id, bypass)
        pushEffectiveDelays()
    }

    /// Asks the app to show the plug-in's editor. A no-op headlessly, where
    /// nothing wired `onShowEffectWindow`.
    public func openEffectWindow(id: UUID) {
        guard let instance = host.effectInstance(id: id) else { return }
        onShowEffectWindow?(instance)
    }

    // MARK: - Plug-in delay compensation

    /// Samples of latency a lane's chain adds. A bypassed effect is a
    /// pass-through and contributes nothing — which is why toggling bypass
    /// changes the compensation.
    public func laneChainLatency(_ laneID: UUID) -> Int {
        chainLatency(laneEffects[laneID] ?? [])
    }

    public var masterChainLatency: Int { chainLatency(masterEffects) }

    /// The lane the whole mix has to wait for.
    public var maxLaneChainLatency: Int {
        lanes.reduce(0) { max($0, laneChainLatency($1.id)) }
    }

    private func chainLatency(_ chain: [EffectConfig]) -> Int {
        chain.reduce(0) { total, config in
            guard !config.bypass, config.isAvailable else { return total }
            return total + effectLatencySamples(id: config.id)
        }
    }

    /// What the render thread's delay line is actually set to: the manual (or
    /// Auto Sync measured) delay, plus enough extra to make up the difference
    /// between this lane's chain latency and the slowest lane's.
    public func effectiveDelaySamples(forLane laneID: UUID) -> Int {
        guard let lane = lane(id: laneID) else { return 0 }
        let wanted = lane.delaySamples + max(0, maxLaneChainLatency - laneChainLatency(laneID))
        return min(max(0, wanted), RTLimits.maxDelaySamples)
    }

    /// Latency the mix adds end to end, in samples: the slowest lane's chain —
    /// which every other lane is now delayed to match — plus the master chain,
    /// which is common to all of them and therefore not compensated at all.
    public var outputLatencySamples: Int { maxLaneChainLatency + masterChainLatency }

    public var outputLatencyMilliseconds: Double {
        Double(outputLatencySamples) / AudioEngine.effectSampleRate * 1000
    }

    /// Recomputes every lane's compensated delay and writes it to the render
    /// thread. Cheap — a handful of atomic stores — and called from every edit
    /// that can move a latency: chain edits, bypass, a plug-in reporting a new
    /// latency, lane add/remove, and the manual delay itself.
    public func pushEffectiveDelays() {
        let ceiling = maxLaneChainLatency
        var clampedLanes: [String] = []
        var added: [UUID: Int] = [:]
        for lane in lanes {
            let compensation = max(0, ceiling - laneChainLatency(lane.id))
            let wanted = lane.delaySamples + compensation
            let clamped = min(max(0, wanted), RTLimits.maxDelaySamples)
            if clamped != wanted { clampedLanes.append(lane.name) }
            added[lane.id] = compensation
            host.setLaneDelay(lane.id, samples: clamped)
        }
        pdcSamples = added
        pdcWarning = clampedLanes.isEmpty
            ? nil
            : "Delay compensation exceeds the \(RTLimits.maxDelaySamples / 48) ms delay limit on "
                + "\(clampedLanes.joined(separator: ", ")) — those lanes are no longer aligned. "
                + "Bypass a high-latency plug-in or lower the manual delay."
    }

    // MARK: - Teardown

    /// Tears down the plug-ins whose last snapshot the render thread has left.
    ///
    /// Called from the watchdog and after every chain edit. The window has to
    /// go first: an editor view keeps drawing from the plug-in's render
    /// resources, which `teardown()` releases.
    func drainRetiredEffects() {
        for instance in host.takeRetiredEffects() {
            onCloseEffectWindow?(instance)
            instance.teardown()
        }
    }

    /// Everything, after the IOProc has stopped. Only `shutdown()` may call it.
    func teardownAllEffects() {
        effectRestoreTask?.cancel()
        effectRestoreTask = nil
        restoringEffects = false
        drainRetiredEffects()
        for instance in host.allEffectInstances() {
            onCloseEffectWindow?(instance)
            instance.teardown()
        }
    }
}
