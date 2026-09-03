import ClapboardCore
import Foundation
import Testing

/// `docs/ROUTING.md`: solo is scoped per bus for lanes and per sibling set for
/// buses, and effective enable is `!muted && (no solo in scope || solo)`.
@Suite("Solo logic")
struct SoloLogicTests {
    private typealias Strip = SoloLogic.Strip<String>

    // MARK: - Generic truth table, one scope

    @Test("With nothing soloed, only mute matters")
    func noSoloInScope() {
        let strips = [
            Strip(id: UUID(), muted: false, solo: false, scope: "bus"),
            Strip(id: UUID(), muted: true, solo: false, scope: "bus")
        ]
        let result = SoloLogic.effectiveEnabled(strips)
        #expect(result[strips[0].id] == true)
        #expect(result[strips[1].id] == false)
    }

    @Test("Soloing one strip silences the rest of its scope, even if unmuted")
    func soloSilencesScope() {
        let a = Strip(id: UUID(), muted: false, solo: true, scope: "bus")
        let b = Strip(id: UUID(), muted: false, solo: false, scope: "bus")
        let c = Strip(id: UUID(), muted: false, solo: false, scope: "bus")
        let result = SoloLogic.effectiveEnabled([a, b, c])
        #expect(result[a.id] == true)
        #expect(result[b.id] == false)
        #expect(result[c.id] == false)
    }

    @Test("A soloed strip that is also muted stays silent — mute wins over solo")
    func muteWinsOverSolo() {
        let a = Strip(id: UUID(), muted: true, solo: true, scope: "bus")
        let b = Strip(id: UUID(), muted: false, solo: false, scope: "bus")
        let result = SoloLogic.effectiveEnabled([a, b])
        #expect(result[a.id] == false)
        #expect(result[b.id] == false) // still silenced: a solo exists in scope
    }

    @Test("Multiple strips in the same scope can be soloed together")
    func multipleSoloInSameScope() {
        let a = Strip(id: UUID(), muted: false, solo: true, scope: "bus")
        let b = Strip(id: UUID(), muted: false, solo: true, scope: "bus")
        let c = Strip(id: UUID(), muted: false, solo: false, scope: "bus")
        let result = SoloLogic.effectiveEnabled([a, b, c])
        #expect(result[a.id] == true)
        #expect(result[b.id] == true)
        #expect(result[c.id] == false)
    }

    @Test("Solo in one scope never touches another scope")
    func soloScopedIndependently() {
        let a = Strip(id: UUID(), muted: false, solo: true, scope: "bus1")
        let b = Strip(id: UUID(), muted: false, solo: false, scope: "bus1")
        let c = Strip(id: UUID(), muted: false, solo: false, scope: "bus2")
        let result = SoloLogic.effectiveEnabled([a, b, c])
        #expect(result[a.id] == true)
        #expect(result[b.id] == false)
        #expect(result[c.id] == true) // untouched: different scope, no solo there
    }

    // MARK: - Engine shape: lanes scoped by bus, buses scoped by parent

    @Test("Soloing a lane silences only the other lanes feeding the same bus")
    func laneSoloScopedToBus() throws {
        let master = BusConfig(name: "Master", outputDeviceUID: "out")
        let vocals = BusConfig(name: "Vocals", destinationBus: master.id)
        var laneA = LaneConfig(deviceUID: "a", deviceChannels: [0], name: "A", destinationBus: vocals.id)
        laneA.solo = true
        let laneB = LaneConfig(deviceUID: "b", deviceChannels: [0], name: "B", destinationBus: vocals.id)
        let laneC = LaneConfig(deviceUID: "c", deviceChannels: [0], name: "C", destinationBus: master.id)

        let graph = try RoutingGraph.build(lanes: [laneA, laneB, laneC], buses: [master, vocals])
        let result = SoloLogic.effectiveEnabled(lanes: [laneA, laneB, laneC], buses: [master, vocals], graph: graph)

        #expect(result.lanes[laneA.id] == true)
        #expect(result.lanes[laneB.id] == false) // same bus as the soloed lane
        #expect(result.lanes[laneC.id] == true) // different bus, untouched
        // Soloing a lane must not silence the buses.
        #expect(result.buses[master.id] == true)
        #expect(result.buses[vocals.id] == true)
    }

    @Test("Soloing a bus silences its siblings, not its own lanes or its parent")
    func busSoloScopedToSiblings() throws {
        let master = BusConfig(name: "Master", outputDeviceUID: "out")
        var vocals = BusConfig(name: "Vocals", destinationBus: master.id)
        vocals.solo = true
        let music = BusConfig(name: "Music", destinationBus: master.id)
        let lane = LaneConfig(deviceUID: "a", deviceChannels: [0], name: "A", destinationBus: vocals.id)

        let graph = try RoutingGraph.build(lanes: [lane], buses: [master, vocals, music])
        let result = SoloLogic.effectiveEnabled(lanes: [lane], buses: [master, vocals, music], graph: graph)

        #expect(result.buses[vocals.id] == true)
        #expect(result.buses[music.id] == false) // sibling of the soloed bus
        #expect(result.buses[master.id] == true) // parent, untouched
        #expect(result.lanes[lane.id] == true) // downstream of the soloed bus, untouched
    }

    @Test("Root buses with no parent share one scope")
    func rootBusesShareScope() throws {
        var rootA = BusConfig(name: "A", outputDeviceUID: "out1")
        rootA.solo = true
        let rootB = BusConfig(name: "B", outputDeviceUID: "out2")
        let graph = try RoutingGraph.build(lanes: [], buses: [rootA, rootB])
        let result = SoloLogic.effectiveEnabled(lanes: [], buses: [rootA, rootB], graph: graph)
        #expect(result.buses[rootA.id] == true)
        #expect(result.buses[rootB.id] == false)
    }
}
