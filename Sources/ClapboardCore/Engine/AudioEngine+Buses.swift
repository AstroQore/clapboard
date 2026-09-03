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
        host.discardBusRuntime(for: id)
        applyTopologyChange()
        pushEffectiveDelays()
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
    /// of `laneChainLatency(_:)`. A bus this task hasn't given its own effect
    /// chain (every bus but the master, today) is simply `0`.
    public func busChainLatency(_ busID: UUID) -> Int {
        chainLatency(bus(id: busID)?.effects ?? [])
    }

    /// End-to-end latency at one output device, in samples — every bus
    /// writing to it, plus every input feeding those buses, aligned. `0` for
    /// a device nothing currently writes to.
    public func outputLatencySamples(forDevice uid: String) -> Int {
        latencyPlan.outputLatency[uid] ?? 0
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
