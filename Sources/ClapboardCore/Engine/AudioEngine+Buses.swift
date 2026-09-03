import Foundation

/// Bus routing, solo/mute and plug-in delay compensation across the whole
/// tree — `docs/ROUTING.md`. `AudioEngine.swift` keeps the lane API and the
/// thin shims (`setOutputDevice`, `masterGainDB`, `masterEffects`,
/// `masterMeter`) that let the pre-bus UI and headless flows keep working
/// unchanged; everything here is new surface for buses themselves and for
/// routing lanes between them.
extension AudioEngine {
    /// Why a bus-routing edit was refused. Every case here is something the
    /// caller could have checked first — `docs/ROUTING.md` says routing is
    /// validated — so these are reported, never thrown past a UI action that
    /// already offered only legal choices.
    public enum BusRoutingActionError: Error, LocalizedError, Equatable {
        case unknownBus
        case wouldCreateCycle
        case cannotRemoveLastBus
        case cannotRemoveMasterBus

        public var errorDescription: String? {
            switch self {
            case .unknownBus:
                return "That bus is gone."
            case .wouldCreateCycle:
                return "That would route a bus back into itself."
            case .cannotRemoveLastBus:
                return "Every mixer has at least one bus."
            case .cannotRemoveMasterBus:
                return "The Master bus can't be removed — masterGainDB/masterMeter/setOutputDevice point at it."
            }
        }
    }

    // MARK: - Buses

    /// Adds a new root bus — no parent, no output device, i.e. a mute group
    /// nobody is listening to yet. Callers wire it up with
    /// `setBusDestination`/`setBusOutput`.
    @discardableResult
    public func addBus(name: String) -> BusConfig {
        let bus = BusConfig(name: name)
        buses.append(bus)
        host.runtime(forBus: bus.id)
        applyTopologyChange()
        pushEffectiveDelays()
        return bus
    }

    /// Refuses to remove the last bus or the Master bus (`setOutputDevice`,
    /// `masterGainDB`, `masterEffects` and `masterMeter` all point at it, and
    /// none of them has anywhere else to go). Every lane and every child bus
    /// that pointed at the removed bus is re-routed to the bus it was
    /// sending to, or to the first remaining bus.
    @discardableResult
    public func removeBus(id: UUID) -> Result<Void, BusRoutingActionError> {
        guard id != masterBusID else { return .failure(.cannotRemoveMasterBus) }
        guard buses.count > 1 else { return .failure(.cannotRemoveLastBus) }
        guard let index = buses.firstIndex(where: { $0.id == id }) else { return .failure(.unknownBus) }

        let removed = buses[index]
        let fallback = removed.destinationBus ?? buses.first(where: { $0.id != id })?.id ?? masterBusID
        for childIndex in buses.indices where buses[childIndex].destinationBus == id {
            buses[childIndex].destinationBus = fallback
        }
        for laneID in lanes.indices where lanes[laneID].destinationBus == id {
            lanes[laneID].destinationBus = fallback
        }
        buses.remove(at: index)
        // The bus's plug-ins go the same way its runtime does — and the same
        // way `removeLane` sends a lane's: detached now, freed only once the
        // render thread has provably left the snapshot that named them.
        for effect in removed.effects { host.discardEffect(id: effect.id) }
        host.discardBusRuntime(for: id)
        applyTopologyChange()
        pushEffectiveDelays()
        drainRetiredEffects()
        return .success(())
    }

    public func renameBus(_ id: UUID, _ name: String) {
        mutateBus(id) { $0.name = name }
    }

    public func setBusGainDB(_ id: UUID, _ db: Float) {
        mutateBus(id) { $0.gainDB = db }
        host.setBusGain(id, linear: Decibels.linear(db))
    }

    public func setBusMuted(_ id: UUID, _ muted: Bool) {
        mutateBus(id) { $0.muted = muted }
        refreshEffectiveEnable()
    }

    /// Scoped to the sibling set — the buses sharing this bus's parent, or
    /// every root bus when it has none. See `SoloLogic`.
    public func setBusSolo(_ id: UUID, _ solo: Bool) {
        mutateBus(id) { $0.solo = solo }
        refreshEffectiveEnable()
    }

    /// `nil` makes `id` a root. Rejected outright when it would close a loop;
    /// nothing is mutated in that case.
    @discardableResult
    public func setBusDestination(id: UUID, parent: UUID?) -> Result<Void, BusRoutingActionError> {
        guard buses.contains(where: { $0.id == id }) else { return .failure(.unknownBus) }
        if let parent, !buses.contains(where: { $0.id == parent }) { return .failure(.unknownBus) }
        guard !RoutingGraph.wouldCreateCycle(busID: id, newParent: parent, buses: buses) else {
            return .failure(.wouldCreateCycle)
        }
        mutateBus(id) { $0.destinationBus = parent }
        applyTopologyChange()
        pushEffectiveDelays()
        return .success(())
    }

    /// `deviceUID == nil` detaches the bus's output entirely (it still feeds
    /// its parent, if it has one). A lane already sitting on `deviceUID` is
    /// dropped — a lane's device may never also be a live output device.
    public func setBusOutput(id: UUID, deviceUID: String?, channelOffset: Int = 0) {
        guard buses.contains(where: { $0.id == id }) else { return }
        mutateBus(id) {
            $0.outputDeviceUID = deviceUID
            $0.outputChannelOffset = max(0, channelOffset)
        }
        dropLanesConflictingWithOutputs()
        applyTopologyChange()
        pushEffectiveDelays()
    }

    public func bus(id: UUID) -> BusConfig? {
        buses.first { $0.id == id }
    }

    public func busMeter(id: UUID) -> MeterReading { host.busMeter(id) }

    /// Samples of latency this bus's own chain adds — the bus-level analogue
    /// of `laneChainLatency(_:)`. A bus with no chain is simply `0`.
    public func busChainLatency(_ busID: UUID) -> Int {
        chainLatency(bus(id: busID)?.effects ?? [])
    }

    /// End-to-end latency at one output device, in samples — every bus
    /// writing to it, plus every input feeding those buses, aligned. `0` for
    /// a device nothing currently writes to.
    public func outputLatencySamples(forDevice uid: String) -> Int {
        latencyPlan.outputLatency[uid] ?? 0
    }

    // MARK: - Read-only queries for the console UI

    /// Which strips are actually audible right now:
    /// `!muted && (nothing in its scope is soloed || it is soloed)`, for every
    /// lane and every bus.
    ///
    /// This is the same computation `refreshEffectiveEnable()` pushes into the
    /// render thread's atomics, and it exists because the console has to *look*
    /// like what you hear: a lane silenced because a sibling is soloed is drawn
    /// dimmed while its own `S` stays off. The alternative — re-running
    /// `SoloLogic` in the view — is not open to it, since scope comes from
    /// `graph`, which is internal to this module. Nothing here mutates; a
    /// caller that wants the render thread updated still goes through
    /// `setLaneMuted`/`setBusSolo`/….
    public var effectiveEnable: (lanes: [UUID: Bool], buses: [UUID: Bool]) {
        SoloLogic.effectiveEnabled(lanes: lanes, buses: buses, graph: graph)
    }

    /// Buses in console order: children before the bus they feed, so signal
    /// runs left to right across the strips and `Master` sits at the far end.
    ///
    /// This is `RoutingGraph.order` — the same order the render thread
    /// processes buses in — resolved to configs. Any bus the current graph
    /// does not know about (only reachable when `routingError` is set and the
    /// last good graph is being kept) is appended rather than dropped, because
    /// a strip vanishing from the console is a worse failure than a strip in
    /// the wrong place.
    public var consoleBusOrder: [BusConfig] {
        var seen = Set<UUID>()
        var ordered: [BusConfig] = []
        ordered.reserveCapacity(buses.count)
        for id in graph.order {
            guard seen.insert(id).inserted, let bus = bus(id: id) else { continue }
            ordered.append(bus)
        }
        for bus in buses where !seen.contains(bus.id) { ordered.append(bus) }
        return ordered
    }

    /// Is this the bus the `masterGainDB` / `masterMeter` / `masterEffects` /
    /// `setOutputDevice` shims point at? The console asks because `removeBus`
    /// will refuse it, and because the strip is drawn with an accent. Its
    /// effect chain is not special: every bus carries an editable one.
    public func isMasterBus(_ id: UUID) -> Bool { id == masterBusID }

    /// The loop that routing `id` into `parent` would close, named strip by
    /// strip in the order it is walked and closed (`["A", "B", "A"]`), or `nil`
    /// when the edit is legal.
    ///
    /// `setBusDestination` only reports *that* an edit would loop;
    /// `RoutingError.cycle` is what actually names the path, and it is only
    /// raised by building a graph. This builds a throw-away one from a
    /// candidate copy of `buses` — nothing is mutated and the live graph is
    /// untouched — so the console can say which loop it refused.
    public func cyclePath(ifBus id: UUID, wereRoutedTo parent: UUID?) -> [String]? {
        var candidate = buses
        guard let index = candidate.firstIndex(where: { $0.id == id }) else { return nil }
        candidate[index].destinationBus = parent
        do {
            // Lanes are deliberately left out: they cannot take part in a bus
            // loop, and an unrouted one would throw a different error.
            _ = try RoutingGraph.build(lanes: [], buses: candidate)
            return nil
        } catch let RoutingError.cycle(path) {
            return path
        } catch {
            return nil
        }
    }

    /// UID prefix of the loopback devices Clapboard's own HAL driver
    /// publishes: `com.astroqore.Clapboard.bus.<n>`, named `Clapboard Bus n`.
    public static let virtualBusDeviceUIDPrefix = "com.astroqore.Clapboard.bus."

    /// Output devices in the order a bus strip's picker lists them: Clapboard's
    /// own virtual devices first when the driver is installed, everything else
    /// after, each group keeping the registry's order (`docs/ROUTING.md`
    /// § Virtual devices). Nothing in routing depends on this — `setBusOutput`
    /// treats a `Clapboard Bus n` UID like any other — it is purely which one
    /// the user's eye lands on first.
    public static func busOutputDeviceOrder(_ devices: [AudioDeviceInfo]) -> [AudioDeviceInfo] {
        let isVirtualBus = { (device: AudioDeviceInfo) in
            device.uid.hasPrefix(virtualBusDeviceUIDPrefix)
        }
        return devices.filter(isVirtualBus) + devices.filter { !isVirtualBus($0) }
    }

    // MARK: - Lane routing

    /// The bus this lane sums into. Rejected — silently, nothing mutated —
    /// when `busID` is not one of `buses`.
    @discardableResult
    public func setLaneDestination(_ id: UUID, bus busID: UUID) -> Bool {
        guard lanes.contains(where: { $0.id == id }), buses.contains(where: { $0.id == busID }) else {
            return false
        }
        mutate(id) { $0.destinationBus = busID }
        applyTopologyChange()
        pushEffectiveDelays()
        return true
    }

    public func setLaneMuted(_ id: UUID, _ muted: Bool) {
        setLaneEnabled(id, !muted)
    }

    /// Scoped to the lane's destination bus: soloing one lane silences the
    /// other lanes feeding the same bus, nothing upstream or downstream.
    public func setLaneSolo(_ id: UUID, _ solo: Bool) {
        mutate(id) { $0.solo = solo }
        refreshEffectiveEnable()
    }

    // MARK: - Mute all / unmute all / toggle

    /// Mutes every lane, remembering which were live so `unmuteAllLanes()`
    /// puts back exactly those. Never touches buses (`docs/ROUTING.md`).
    public func muteAllLanes() {
        applyMuteOutcome(MuteToggleLogic.muteAll(lanes: lanes, remembered: mutedLanesRemembered))
    }

    /// Turns on every lane, deliberately ignoring the remembered set — the
    /// escape hatch for when the mixer's state is no longer trusted.
    public func unmuteAllLanes() {
        applyMuteOutcome(MuteToggleLogic.unmuteAll(lanes: lanes))
    }

    /// One call for both directions: mutes while any lane is live, otherwise
    /// restores what was live before.
    public func toggleAllLanes() {
        applyMuteOutcome(MuteToggleLogic.toggleAll(lanes: lanes, remembered: mutedLanesRemembered))
    }

    private func applyMuteOutcome(_ outcome: MuteToggleLogic.Outcome) {
        mutedLanesRemembered = outcome.remembered
        for (id, enabled) in outcome.changes(from: lanes) {
            mutate(id) { $0.enabled = enabled }
        }
        refreshEffectiveEnable()
    }
}
