import Foundation

/// Audio Unit chains: one per lane and one per bus, master included.
///
/// A lane's chain sits after the delay line and before the fader; a bus's
/// chain sits after the sum (and after the bus's own PDC delay line) and
/// before the bus fader. Editing either while the engine runs is a graph
/// snapshot swap, the same click-free mechanism adding a lane uses, and the
/// plug-ins themselves outlive it — they are owned by `RTEngineHost` and only
/// torn down once the render thread has provably left every snapshot that
/// could reach them.
///
/// Every entry point takes an `EffectTarget`. The older `toLane laneID: UUID?`
/// spelling, where `nil` meant the master bus and no other bus could be named,
/// survives as a shim below.
extension AudioEngine {
    public enum EffectError: Error, LocalizedError, Equatable {
        case unknownLane
        case unknownBus
        case chainFull(Int)
        case unknownEffect

        public var errorDescription: String? {
            switch self {
            case .unknownLane:
                return "That lane is gone."
            case .unknownBus:
                return "That bus is gone."
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

    /// A bus is a stereo sum, so its plug-ins are always instantiated with two
    /// channels — unlike a lane's, which follow the lane's own channel count.
    static var busEffectChannels: Int { 2 }

    // MARK: - Reading a chain

    /// The chain on one strip, in order.
    public func effects(for target: EffectTarget) -> [EffectConfig] {
        switch target {
        case .lane(let laneID): return laneEffects[laneID] ?? []
        case .bus(let busID): return bus(id: busID)?.effects ?? []
        }
    }

    /// The strip the master shims (`masterEffects`, `masterGainDB`,
    /// `setOutputDevice`) point at, as an `EffectTarget` — what a UI written
    /// against "the master chain" passes to `addEffect(_:to:)`.
    public var masterEffectTarget: EffectTarget { .bus(masterBusID) }

    public func effectConfig(id: UUID) -> EffectConfig? {
        for chain in laneEffects.values {
            if let found = chain.first(where: { $0.id == id }) { return found }
        }
        for bus in buses {
            if let found = bus.effects.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// Which strip an effect is on, or `nil` when nothing in the mixer has it.
    public func target(ofEffect id: UUID) -> EffectTarget? {
        for (laneID, chain) in laneEffects where chain.contains(where: { $0.id == id }) {
            return .lane(laneID)
        }
        for bus in buses where bus.effects.contains(where: { $0.id == id }) {
            return .bus(bus.id)
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

    /// Loads a plug-in and appends it to a strip's chain.
    ///
    /// Instantiation is `async` because `AUAudioUnit.instantiate` is, and it
    /// is not quick: a large plug-in takes hundreds of milliseconds. The strip
    /// can disappear while it loads, which is why it is checked twice.
    @discardableResult
    public func addEffect(_ info: AUComponentInfo, to target: EffectTarget) async throws -> EffectConfig {
        let channels: Int
        switch target {
        case .lane(let laneID):
            guard let lane = lane(id: laneID) else { throw EffectError.unknownLane }
            channels = max(1, min(2, lane.deviceChannels.count))
        case .bus(let busID):
            guard bus(id: busID) != nil else { throw EffectError.unknownBus }
            channels = AudioEngine.busEffectChannels
        }
        guard effects(for: target).count < RTLimits.maxEffectsPerChain else {
            throw EffectError.chainFull(RTLimits.maxEffectsPerChain)
        }

        let instance = try await AUEffectInstance.instantiate(
            info,
            channels: channels,
            sampleRate: AudioEngine.effectSampleRate,
            maximumFrames: RTLimits.maxFramesPerBlock
        )
        guard stripExists(target) else {
            instance.teardown()
            throw target.isLane ? EffectError.unknownLane : EffectError.unknownBus
        }

        let config = EffectConfig(componentID: info.id, displayName: info.displayName)
        insert(instance, config: config, into: target, at: nil)
        return config
    }

    /// Is the lane or bus this target names still in the mixer?
    func stripExists(_ target: EffectTarget) -> Bool {
        switch target {
        case .lane(let laneID): return lane(id: laneID) != nil
        case .bus(let busID): return bus(id: busID) != nil
        }
    }

    /// Registers an already-instantiated plug-in and republishes. Shared by
    /// `addEffect` and session restore, which needs to keep the saved id.
    func insert(
        _ instance: AUEffectInstance,
        config: EffectConfig,
        into target: EffectTarget,
        at index: Int?
    ) {
        host.registerEffect(id: config.id, instance: instance, channels: instance.laneChannels)
        host.setEffectBypass(id: config.id, config.bypass)
        // A plug-in may change its latency at any time — a linear-phase EQ
        // switching mode, a limiter whose look-ahead is a parameter — and
        // every strip's compensation is computed from it.
        instance.onLatencyChange = { [weak self] _ in
            self?.pushEffectiveDelays()
        }
        editChain(on: target) { chain in
            chain.insert(config, at: min(max(0, index ?? chain.count), chain.count))
        }
        republishGraph()
        pushEffectiveDelays()
    }

    /// Adds a placeholder for a plug-in this Mac cannot load. It is shown
    /// greyed, is not published to the render thread, and keeps its saved
    /// state so the next save does not throw the settings away.
    func insertPlaceholder(_ config: EffectConfig, into target: EffectTarget) {
        editChain(on: target) { $0.append(config) }
    }

    /// The one place a chain is mutated in place, so lanes (which keep theirs
    /// in `laneEffects`) and buses (which carry theirs inline on `BusConfig`)
    /// cannot drift apart. A lane with an empty chain drops its dictionary
    /// entry, the way it always has.
    private func editChain(on target: EffectTarget, _ body: (inout [EffectConfig]) -> Void) {
        switch target {
        case .lane(let laneID):
            var chain = laneEffects[laneID] ?? []
            body(&chain)
            laneEffects[laneID] = chain.isEmpty ? nil : chain
        case .bus(let busID):
            mutateBus(busID) { body(&$0.effects) }
        }
    }

    public func removeEffect(id: UUID) {
        guard let target = target(ofEffect: id) else { return }
        editChain(on: target) { $0.removeAll { $0.id == id } }
        host.discardEffect(id: id)
        republishGraph()
        pushEffectiveDelays()
        drainRetiredEffects()
    }

    /// Moves an effect inside its own chain. Order matters — a compressor
    /// before an EQ is a different sound from an EQ before a compressor — but
    /// nothing here can move an effect between chains: a plug-in is
    /// instantiated for its strip's channel count.
    public func moveEffect(id: UUID, to index: Int) {
        guard let target = target(ofEffect: id) else { return }
        editChain(on: target) { chain in
            guard let from = chain.firstIndex(where: { $0.id == id }) else { return }
            let clamped = min(max(0, index), chain.count - 1)
            guard clamped != from else { return }
            let entry = chain.remove(at: from)
            chain.insert(entry, at: clamped)
        }
        republishGraph()
    }

    /// Bypass is a host-level pass-through, not `AUAudioUnit.shouldBypassEffect`:
    /// leaving the plug-in rendering would keep its latency, so toggling it
    /// would shift the strip against the others. That does mean bypass changes
    /// the chain's latency, so compensation is recomputed here.
    public func setEffectBypass(id: UUID, _ bypass: Bool) {
        guard let target = target(ofEffect: id) else { return }
        editChain(on: target) { chain in
            guard let position = chain.firstIndex(where: { $0.id == id }) else { return }
            chain[position].bypass = bypass
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

    // MARK: - Pre-`EffectTarget` spelling

    // These are the entry points that existed while only lanes and the master
    // bus could carry an editable chain, with `nil` standing in for the master.
    // They are thin forwards onto the `EffectTarget` API — kept, not removed,
    // so the row-based mixer and the headless smoke tests need no edit. New
    // code should name its target.
    //
    // Deliberately not marked `@available(*, deprecated:)`: `ClapboardApp`'s
    // `--engine-test`/`--restore-session` still call them, and a build full of
    // deprecation warnings hides the ones that matter.

    /// `nil` means the master bus. Prefer `effects(for:)`.
    public func effects(forLane laneID: UUID?) -> [EffectConfig] {
        effects(for: laneID.map(EffectTarget.lane) ?? masterEffectTarget)
    }

    /// `nil` means the master bus. Prefer `addEffect(_:to:)`.
    @discardableResult
    public func addEffect(_ info: AUComponentInfo, toLane laneID: UUID?) async throws -> EffectConfig {
        try await addEffect(info, to: laneID.map(EffectTarget.lane) ?? masterEffectTarget)
    }

    /// The lane an effect belongs to, or `nil` for the master chain. The outer
    /// optional distinguishes "not found" from "on the master".
    ///
    /// Cannot describe a chain on any other bus — it returns `nil` (i.e. "not
    /// found") for one, which is the whole reason `target(ofEffect:)` replaced
    /// it. Prefer that.
    public func laneOwning(effect id: UUID) -> UUID?? {
        switch target(ofEffect: id) {
        case .lane(let laneID): return .some(.some(laneID))
        case .bus(let busID) where busID == masterBusID: return .some(nil)
        default: return nil
        }
    }

    // MARK: - Plug-in delay compensation

    /// Samples of latency a lane's chain adds. A bypassed effect is a
    /// pass-through and contributes nothing — which is why toggling bypass
    /// changes the compensation.
    public func laneChainLatency(_ laneID: UUID) -> Int {
        chainLatency(laneEffects[laneID] ?? [])
    }

    /// Shim onto `busChainLatency(masterBusID)`, kept because it reads nicer
    /// at call sites that only ever dealt with the one bus.
    public var masterChainLatency: Int { busChainLatency(masterBusID) }

    /// The lane the whole mix has to wait for, regardless of which bus it
    /// feeds. Superseded by `LatencyPlan.inputAlignment` for the actual
    /// per-bus compensation `pushEffectiveDelays()` pushes, but still a
    /// useful single-number diagnostic.
    public var maxLaneChainLatency: Int {
        lanes.reduce(0) { max($0, laneChainLatency($1.id)) }
    }

    func chainLatency(_ chain: [EffectConfig]) -> Int {
        chain.reduce(0) { total, config in
            guard !config.bypass, config.isAvailable else { return total }
            return total + effectLatencySamples(id: config.id)
        }
    }

    /// What the render thread's delay line is actually set to: the manual (or
    /// Auto Sync measured) delay, plus whatever `LatencyPlan` computed for
    /// this lane across the whole bus tree.
    public func effectiveDelaySamples(forLane laneID: UUID) -> Int {
        guard let lane = lane(id: laneID) else { return 0 }
        let wanted = lane.delaySamples + (latencyPlan.laneCompensation[laneID] ?? 0)
        return min(max(0, wanted), RTLimits.maxDelaySamples)
    }

    /// Legacy single-bus diagnostic: the slowest lane's chain plus the master
    /// chain, as if every lane fed the master bus directly. Still exactly
    /// right when that is true (the common case); for a multi-bus mix use
    /// `outputLatencySamples(forDevice:)`, which is what `latencyPlan`
    /// actually drives.
    public var outputLatencySamples: Int { maxLaneChainLatency + masterChainLatency }

    public var outputLatencyMilliseconds: Double {
        Double(outputLatencySamples) / AudioEngine.effectSampleRate * 1000
    }

    /// Recomputes plug-in delay compensation across the whole routing tree —
    /// every lane against the others feeding its bus, every bus against its
    /// siblings — and writes the result to the render thread. Cheap: a
    /// `LatencyPlan.compute` pass plus a handful of atomic stores. Called from
    /// every edit that can move a latency: chain edits, bypass, a plug-in
    /// reporting a new latency, lane/bus add/remove/re-route, and the manual
    /// delay itself.
    public func pushEffectiveDelays() {
        let laneLatencies = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, laneChainLatency($0.id)) })
        let busLatencies = Dictionary(uniqueKeysWithValues: buses.map { ($0.id, busChainLatency($0.id)) })
        let plan = LatencyPlan.compute(graph: graph, laneChainLatency: laneLatencies, busChainLatency: busLatencies)
        latencyPlan = plan

        // `plan.clamped` only catches compensation the plan itself had to
        // clip; a lane's own manual/measured delay can push the *combined*
        // value over the ceiling even when its compensation alone was fine,
        // so that combine has to be checked here too.
        var clampedIDs = plan.clamped
        var added: [UUID: Int] = [:]
        for lane in lanes {
            let compensation = plan.laneCompensation[lane.id] ?? 0
            added[lane.id] = compensation
            let wanted = lane.delaySamples + compensation
            let clamped = min(max(0, wanted), RTLimits.maxDelaySamples)
            if clamped != wanted { clampedIDs.insert(lane.id) }
            host.setLaneDelay(lane.id, samples: clamped)
        }
        pdcSamples = added

        for bus in buses {
            host.setBusDelay(bus.id, samples: plan.busCompensation[bus.id] ?? 0)
        }

        if clampedIDs.isEmpty {
            pdcWarning = nil
        } else {
            let names = clampedIDs.compactMap { id in
                lane(id: id)?.name ?? bus(id: id)?.name
            }
            pdcWarning = "Delay compensation exceeds the \(RTLimits.maxDelaySamples / 48) ms delay limit on "
                + "\(names.joined(separator: ", ")) — those strips are no longer aligned. "
                + "Bypass a high-latency plug-in or lower the manual delay."
        }
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
