import ClapboardCore
import Foundation
import Testing

/// `AudioEngine`'s bus-routing API — `docs/ROUTING.md` — exercised on a
/// stopped engine (no aggregate device is built, same convention
/// `SessionRestoreTests` uses), so these run anywhere.
extension Result where Success == Void, Failure == AudioEngine.BusRoutingActionError {
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var error: Failure? { if case .failure(let error) = self { return error }; return nil }
}

@Suite("AudioEngine buses")
@MainActor
struct AudioEngineBusTests {
    /// The one bus every fresh engine starts with.
    private func masterID(_ engine: AudioEngine) -> UUID {
        engine.buses.first!.id
    }

    // MARK: - Adding and removing

    @Test func addBusCreatesADanglingRootBus() {
        let engine = AudioEngine()
        let bus = engine.addBus(name: "Vocals")
        #expect(engine.buses.count == 2)
        #expect(bus.destinationBus == nil)
        #expect(bus.outputDeviceUID == nil)
        #expect(engine.bus(id: bus.id)?.name == "Vocals")
    }

    @Test func removeBusRefusesTheLastBus() {
        let engine = AudioEngine()
        let result = engine.removeBus(id: masterID(engine))
        #expect(result.error == .cannotRemoveMasterBus || result.error == .cannotRemoveLastBus)
        #expect(engine.buses.count == 1)
    }

    @Test func removeBusRefusesTheMasterBusEvenWithOthersPresent() {
        let engine = AudioEngine()
        let extra = engine.addBus(name: "Extra")
        let result = engine.removeBus(id: masterID(engine))
        #expect(result.error == .cannotRemoveMasterBus)
        #expect(engine.buses.count == 2)
        _ = extra
    }

    @Test func removeBusRejectsAnUnknownID() {
        let engine = AudioEngine()
        _ = engine.addBus(name: "Extra")
        let result = engine.removeBus(id: UUID())
        #expect(result.error == .unknownBus)
    }

    @Test func removingABusReroutesItsLanesAndChildBusesToItsParent() {
        let engine = AudioEngine()
        let master = masterID(engine)
        let vocals = engine.addBus(name: "Vocals")
        _ = engine.setBusDestination(id: vocals.id, parent: master)
        let child = engine.addBus(name: "Child of Vocals")
        _ = engine.setBusDestination(id: child.id, parent: vocals.id)
        let lane = engine.addLane(deviceUID: "mic", deviceChannels: [0], name: "Mic")
        _ = engine.setLaneDestination(lane.id, bus: vocals.id)

        let result = engine.removeBus(id: vocals.id)
        #expect(result.isSuccess)
        #expect(engine.bus(id: child.id)?.destinationBus == master)
        #expect(engine.lane(id: lane.id)?.destinationBus == master)
    }

    @Test func removingARootBusWithNoParentReroutesToTheFirstRemainingBus() {
        let engine = AudioEngine()
        let master = masterID(engine)
        let root = engine.addBus(name: "Root") // destinationBus == nil
        let lane = engine.addLane(deviceUID: "mic", deviceChannels: [0], name: "Mic")
        _ = engine.setLaneDestination(lane.id, bus: root.id)

        let result = engine.removeBus(id: root.id)
        #expect(result.isSuccess)
        #expect(engine.lane(id: lane.id)?.destinationBus == master)
    }

    // MARK: - Bus routing validation

    @Test func setBusDestinationRejectsACycle() {
        let engine = AudioEngine()
        let a = engine.addBus(name: "A")
        let b = engine.addBus(name: "B")
        #expect(engine.setBusDestination(id: b.id, parent: a.id).isSuccess)
        // A -> B already; routing B's parent A back into B would close a loop.
        let result = engine.setBusDestination(id: a.id, parent: b.id)
        #expect(result.error == .wouldCreateCycle)
        // Unchanged: A must still be a root.
        #expect(engine.bus(id: a.id)?.destinationBus == nil)
    }

    @Test func setBusDestinationRejectsAnUnknownParent() {
        let engine = AudioEngine()
        let a = engine.addBus(name: "A")
        let result = engine.setBusDestination(id: a.id, parent: UUID())
        #expect(result.error == .unknownBus)
    }

    @Test func setLaneDestinationMovesALaneBetweenBuses() {
        let engine = AudioEngine()
        let master = masterID(engine)
        let vocals = engine.addBus(name: "Vocals")
        let lane = engine.addLane(deviceUID: "mic", deviceChannels: [0], name: "Mic")
        #expect(engine.lane(id: lane.id)?.destinationBus == master)

        #expect(engine.setLaneDestination(lane.id, bus: vocals.id))
        #expect(engine.lane(id: lane.id)?.destinationBus == vocals.id)

        #expect(!engine.setLaneDestination(lane.id, bus: UUID()))
        #expect(engine.lane(id: lane.id)?.destinationBus == vocals.id, "an unknown bus must not move the lane")
    }

    @Test func newLaneIsAssignedToTheMasterBus() {
        let engine = AudioEngine()
        let lane = engine.addLane(deviceUID: "mic", deviceChannels: [0], name: "Mic")
        #expect(lane.destinationBus == masterID(engine))
        #expect(engine.lane(id: lane.id)?.destinationBus == masterID(engine))
    }

    // MARK: - setBusOutput / setOutputDevice feedback guard

    @Test func settingABusOutputDropsALaneAlreadyOnThatDevice() {
        let engine = AudioEngine()
        let lane = engine.addLane(deviceUID: "shared-device", deviceChannels: [0], name: "Mic")
        #expect(engine.lanes.contains { $0.id == lane.id })

        engine.setOutputDevice(uid: "shared-device")
        #expect(!engine.lanes.contains { $0.id == lane.id }, "a lane can't share a device with an output")
        #expect(engine.outputDeviceUID == "shared-device")
    }

    @Test func setBusOutputOnANonMasterBusDoesNotDisturbTheMasterShim() {
        let engine = AudioEngine()
        engine.setOutputDevice(uid: "out-1")
        let vocals = engine.addBus(name: "Vocals")
        engine.setBusOutput(id: vocals.id, deviceUID: "out-2")
        #expect(engine.outputDeviceUID == "out-1")
        #expect(engine.bus(id: vocals.id)?.outputDeviceUID == "out-2")
    }

    // MARK: - Mute / solo flags

    @Test func setLaneMutedAndSetLaneSoloUpdateTheLanesPublicFlags() {
        let engine = AudioEngine()
        let lane = engine.addLane(deviceUID: "mic", deviceChannels: [0], name: "Mic")
        engine.setLaneMuted(lane.id, true)
        #expect(engine.lane(id: lane.id)?.muted == true)
        #expect(engine.lane(id: lane.id)?.enabled == false)
        engine.setLaneSolo(lane.id, true)
        #expect(engine.lane(id: lane.id)?.solo == true)
    }

    @Test func setBusMutedAndSetBusSoloUpdateTheBussPublicFlags() {
        let engine = AudioEngine()
        let bus = engine.addBus(name: "Vocals")
        engine.setBusMuted(bus.id, true)
        #expect(engine.bus(id: bus.id)?.muted == true)
        engine.setBusSolo(bus.id, true)
        #expect(engine.bus(id: bus.id)?.solo == true)
    }

    /// `unmuteAllLanes()` is the escape hatch: it turns on *every* lane,
    /// deliberately ignoring what `muteAllLanes()` remembered — the
    /// remember-and-restore round trip is `toggleAllLanes()`'s job.
    @Test func unmuteAllTurnsOnEveryLaneRegardlessOfWhatWasRememberd() {
        let engine = AudioEngine()
        let a = engine.addLane(deviceUID: "mic-a", deviceChannels: [0], name: "A")
        let b = engine.addLane(deviceUID: "mic-b", deviceChannels: [0], name: "B")
        engine.setLaneMuted(b.id, true) // B is deliberately muted beforehand

        engine.muteAllLanes()
        #expect(engine.lane(id: a.id)?.muted == true)
        #expect(engine.lane(id: b.id)?.muted == true)

        engine.unmuteAllLanes()
        #expect(engine.lane(id: a.id)?.muted == false)
        #expect(engine.lane(id: b.id)?.muted == false, "unmute-all ignores memory — that's the point of it")
    }

    /// `toggleAllLanes()` is the one-key round trip: mute remembers which
    /// lanes were live, and a second press puts back exactly those, leaving
    /// a lane that was already muted on purpose alone.
    @Test func toggleAllLanesRemembersAndRestoresExactlyWhatWasLive() {
        let engine = AudioEngine()
        let a = engine.addLane(deviceUID: "mic-a", deviceChannels: [0], name: "A")
        let b = engine.addLane(deviceUID: "mic-b", deviceChannels: [0], name: "B")
        engine.setLaneMuted(b.id, true) // B is deliberately muted beforehand

        engine.toggleAllLanes()
        #expect(engine.lane(id: a.id)?.muted == true)
        #expect(engine.lane(id: b.id)?.muted == true)

        engine.toggleAllLanes()
        #expect(engine.lane(id: a.id)?.muted == false, "A was live before the toggle, so it comes back")
        #expect(engine.lane(id: b.id)?.muted == true, "B was already muted on purpose, so it stays muted")
    }

    // MARK: - Plug-in delay compensation across a real bus tree

    @Test func busChainLatencyAndOutputLatencyFlowThroughARealTree() {
        let engine = AudioEngine()
        engine.setOutputDevice(uid: "out")
        let master = masterID(engine)
        let vocals = engine.addBus(name: "Vocals")
        _ = engine.setBusDestination(id: vocals.id, parent: master)

        let lane = engine.addLane(deviceUID: "mic", deviceChannels: [0], name: "Mic")
        _ = engine.setLaneDestination(lane.id, bus: vocals.id)

        // No effects anywhere yet: everything is zero, nothing is clamped.
        #expect(engine.busChainLatency(vocals.id) == 0)
        #expect(engine.busChainLatency(master) == 0)
        #expect(engine.outputLatencySamples(forDevice: "out") == 0)
        #expect(engine.pdcWarning == nil)

        // A delay pushed to the ceiling has nowhere left to compensate into,
        // so the mix reports itself as no longer aligned.
        engine.setLaneDelaySamples(lane.id, RTLimits.maxDelaySamples)
        engine.setLaneDelaySamples(lane.id, 0) // back to legal; warning clears
        #expect(engine.pdcWarning == nil)
    }

    @Test func routingErrorStaysNilAcrossOrdinaryValidatedEdits() {
        let engine = AudioEngine()
        let vocals = engine.addBus(name: "Vocals")
        _ = engine.setBusDestination(id: vocals.id, parent: masterID(engine))
        let lane = engine.addLane(deviceUID: "mic", deviceChannels: [0], name: "Mic")
        _ = engine.setLaneDestination(lane.id, bus: vocals.id)
        _ = engine.removeBus(id: vocals.id)
        #expect(engine.routingError == nil)
    }
}
