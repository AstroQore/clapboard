import ClapboardCore
import Foundation
import Testing

/// The read-only queries the console UI is built on — `AudioEngine+Buses.swift`
/// § "Read-only queries for the console UI".
///
/// They live on the engine rather than in the view for two reasons: solo scope
/// and bus order both come from `RoutingGraph`, which is internal to
/// `ClapboardCore`, and everything here is exactly the kind of derivation that
/// should be pinned down by a test instead of eyeballed in a strip. Run on a
/// stopped engine (no aggregate device is built), the same convention
/// `AudioEngineBusTests` uses, so they run anywhere.
@Suite("Console queries")
@MainActor
struct ConsoleQueriesTests {
    private func masterID(_ engine: AudioEngine) -> UUID {
        engine.buses.first { engine.isMasterBus($0.id) }!.id
    }

    private func addLane(_ engine: AudioEngine, _ name: String, to busID: UUID) -> UUID {
        let lane = engine.addLane(deviceUID: "dev-\(name)", deviceChannels: [0], name: name)
        #expect(engine.setLaneDestination(lane.id, bus: busID))
        return lane.id
    }

    // MARK: - isMasterBus

    @Test func isMasterBusNamesTheOneBusEveryEngineStartsWith() {
        let engine = AudioEngine()
        let master = engine.buses[0].id
        #expect(engine.isMasterBus(master))
        let other = engine.addBus(name: "Vocals")
        #expect(!engine.isMasterBus(other.id))
        #expect(!engine.isMasterBus(UUID()))
    }

    // MARK: - effectiveEnable

    @Test func effectiveEnableIsTrueForEveryStripWhenNothingIsMutedOrSoloed() {
        let engine = AudioEngine()
        let master = masterID(engine)
        let a = addLane(engine, "A", to: master)
        let b = addLane(engine, "B", to: master)
        let effective = engine.effectiveEnable
        #expect(effective.lanes[a] == true)
        #expect(effective.lanes[b] == true)
        #expect(effective.buses[master] == true)
    }

    @Test func aMutedLaneIsNotAudible() {
        let engine = AudioEngine()
        let a = addLane(engine, "A", to: masterID(engine))
        engine.setLaneMuted(a, true)
        #expect(engine.effectiveEnable.lanes[a] == false)
    }

    /// The case the console exists to show: `B` looks silenced while its own
    /// `S` button stays off, because `A` is soloed on the same bus.
    @Test func soloingOneLaneSilencesItsSiblingsWithoutMutingThem() {
        let engine = AudioEngine()
        let master = masterID(engine)
        let a = addLane(engine, "A", to: master)
        let b = addLane(engine, "B", to: master)
        engine.setLaneSolo(a, true)

        let effective = engine.effectiveEnable
        #expect(effective.lanes[a] == true)
        #expect(effective.lanes[b] == false)
        // The flags themselves are untouched — the strip must not draw `B` as
        // muted, only as inaudible.
        #expect(engine.lane(id: b)?.muted == false)
        #expect(engine.lane(id: b)?.solo == false)
    }

    @Test func laneSoloDoesNotReachLanesOnAnotherBus() {
        let engine = AudioEngine()
        let master = masterID(engine)
        let vocals = engine.addBus(name: "Vocals")
        #expect(engine.setBusDestination(id: vocals.id, parent: master).isSuccess)
        let onMaster = addLane(engine, "OnMaster", to: master)
        let onVocals = addLane(engine, "OnVocals", to: vocals.id)

        engine.setLaneSolo(onVocals, true)
        let effective = engine.effectiveEnable
        #expect(effective.lanes[onVocals] == true)
        #expect(effective.lanes[onMaster] == true)
    }

    @Test func busSoloIsScopedToSiblings() {
        let engine = AudioEngine()
        let master = masterID(engine)
        let vocals = engine.addBus(name: "Vocals")
        let drums = engine.addBus(name: "Drums")
        #expect(engine.setBusDestination(id: vocals.id, parent: master).isSuccess)
        #expect(engine.setBusDestination(id: drums.id, parent: master).isSuccess)

        engine.setBusSolo(vocals.id, true)
        let effective = engine.effectiveEnable
        #expect(effective.buses[vocals.id] == true)
        #expect(effective.buses[drums.id] == false)
        // Never upstream or downstream: the parent keeps playing.
        #expect(effective.buses[master] == true)
    }

    // MARK: - consoleBusOrder

    @Test func consoleBusOrderListsEveryBusExactlyOnce() {
        let engine = AudioEngine()
        _ = engine.addBus(name: "Vocals")
        _ = engine.addBus(name: "Drums")
        let ordered = engine.consoleBusOrder
        #expect(ordered.count == engine.buses.count)
        #expect(Set(ordered.map(\.id)) == Set(engine.buses.map(\.id)))
    }

    /// Children before the bus they feed, so signal runs left to right across
    /// the console and `Master` sits at the far end.
    @Test func consoleBusOrderPutsChildrenBeforeTheirParent() {
        let engine = AudioEngine()
        let master = masterID(engine)
        let vocals = engine.addBus(name: "Vocals")
        let backing = engine.addBus(name: "Backing")
        #expect(engine.setBusDestination(id: vocals.id, parent: master).isSuccess)
        #expect(engine.setBusDestination(id: backing.id, parent: vocals.id).isSuccess)

        let order = engine.consoleBusOrder.map(\.id)
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        #expect(position[backing.id]! < position[vocals.id]!)
        #expect(position[vocals.id]! < position[master]!)
        #expect(order.last == master)
    }

    // MARK: - cyclePath

    @Test func cyclePathIsNilForALegalRoute() {
        let engine = AudioEngine()
        let vocals = engine.addBus(name: "Vocals")
        #expect(engine.cyclePath(ifBus: vocals.id, wereRoutedTo: masterID(engine)) == nil)
        #expect(engine.cyclePath(ifBus: vocals.id, wereRoutedTo: nil) == nil)
    }

    @Test func cyclePathNamesTheLoopAnEditWouldClose() {
        let engine = AudioEngine()
        let master = masterID(engine)
        let vocals = engine.addBus(name: "Vocals")
        #expect(engine.setBusDestination(id: vocals.id, parent: master).isSuccess)

        // Master → Vocals would close Master → Vocals → Master.
        let path = engine.cyclePath(ifBus: master, wereRoutedTo: vocals.id)
        #expect(path == ["Master", "Vocals", "Master"])
        // …and the engine refuses the edit for the same reason.
        #expect(engine.setBusDestination(id: master, parent: vocals.id).error == .wouldCreateCycle)
    }

    @Test func cyclePathCatchesABusPointedAtItself() {
        let engine = AudioEngine()
        let vocals = engine.addBus(name: "Vocals")
        #expect(engine.cyclePath(ifBus: vocals.id, wereRoutedTo: vocals.id) == ["Vocals", "Vocals"])
    }

    @Test func cyclePathLeavesTheLiveGraphAlone() {
        let engine = AudioEngine()
        let master = masterID(engine)
        let vocals = engine.addBus(name: "Vocals")
        #expect(engine.setBusDestination(id: vocals.id, parent: master).isSuccess)
        _ = engine.cyclePath(ifBus: master, wereRoutedTo: vocals.id)
        #expect(engine.bus(id: master)?.destinationBus == nil)
        #expect(engine.bus(id: vocals.id)?.destinationBus == master)
        #expect(engine.routingError == nil)
    }

    @Test func cyclePathIsNilForABusThatIsNotInTheMixer() {
        let engine = AudioEngine()
        #expect(engine.cyclePath(ifBus: UUID(), wereRoutedTo: masterID(engine)) == nil)
    }

    // MARK: - busOutputDeviceOrder

    private func device(uid: String, name: String) -> AudioDeviceInfo {
        AudioDeviceInfo(
            id: 0, uid: uid, name: name, manufacturer: "test", transport: .builtIn,
            inputStreamChannels: [], outputStreamChannels: [2], nominalSampleRate: 48_000,
            sampleRateRanges: [48_000...48_000], isAlive: true, isHidden: false
        )
    }

    @Test func busOutputPickerListsClapboardsOwnDevicesFirst() {
        let devices = [
            device(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers"),
            device(uid: "com.astroqore.Clapboard.bus.2", name: "Clapboard Bus 2"),
            device(uid: "loopback-1", name: "Loopback"),
            device(uid: "com.astroqore.Clapboard.bus.1", name: "Clapboard Bus 1")
        ]
        let ordered = AudioEngine.busOutputDeviceOrder(devices).map(\.name)
        #expect(ordered == [
            "Clapboard Bus 2", "Clapboard Bus 1", "MacBook Pro Speakers", "Loopback"
        ])
    }

    @Test func busOutputPickerKeepsTheRegistryOrderWhenTheDriverIsNotInstalled() {
        let devices = [
            device(uid: "a", name: "A"),
            device(uid: "b", name: "B"),
            device(uid: "c", name: "C")
        ]
        #expect(AudioEngine.busOutputDeviceOrder(devices).map(\.name) == ["A", "B", "C"])
        #expect(AudioEngine.busOutputDeviceOrder([]).isEmpty)
    }

    @Test func theVirtualBusPrefixMatchesTheDriversDeviceUIDs() {
        // `Driver/README.md`: device UID `com.astroqore.Clapboard.bus.<n>`.
        #expect(AudioEngine.virtualBusDeviceUIDPrefix == "com.astroqore.Clapboard.bus.")
        #expect("com.astroqore.Clapboard.bus.4".hasPrefix(AudioEngine.virtualBusDeviceUIDPrefix))
    }
}
