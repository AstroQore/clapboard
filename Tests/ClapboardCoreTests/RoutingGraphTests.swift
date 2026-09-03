import ClapboardCore
import Foundation
import Testing

/// `docs/ROUTING.md`: routing is a DAG, cycles are rejected with the path
/// named, and buses process children before parents.
@Suite("Routing graph")
struct RoutingGraphTests {
    private func lane(_ name: String, to bus: UUID) -> LaneConfig {
        LaneConfig(deviceUID: "dev-\(name)", deviceChannels: [0], name: name, destinationBus: bus)
    }

    private func bus(_ name: String, id: UUID = UUID(), parent: UUID? = nil, output: String? = nil) -> BusConfig {
        BusConfig(id: id, name: name, destinationBus: parent, outputDeviceUID: output)
    }

    // MARK: - Building

    @Test("Builds a simple two-bus tree with lanes on each")
    func buildsSimpleTree() throws {
        let master = bus("Master", output: "out")
        let vocals = bus("Vocals", parent: master.id)
        let laneA = lane("A", to: vocals.id)
        let laneB = lane("B", to: master.id)

        let graph = try RoutingGraph.build(lanes: [laneA, laneB], buses: [master, vocals])
        #expect(graph.busCount == 2)
        // Vocals (child) must come before Master (parent).
        let vocalsIndex = try #require(graph.index[vocals.id])
        let masterIndex = try #require(graph.index[master.id])
        #expect(vocalsIndex < masterIndex)
        #expect(graph.laneInputs[vocals.id] == [laneA.id])
        #expect(graph.laneInputs[master.id] == [laneB.id])
        #expect(graph.busInputs[master.id] == [vocals.id])
        #expect(graph.outputDeviceUIDs == ["out"])
    }

    @Test("Rejects an empty bus list")
    func rejectsNoBuses() {
        #expect(throws: RoutingError.noBuses) {
            try RoutingGraph.build(lanes: [], buses: [])
        }
    }

    @Test("Rejects a lane pointed at an unknown bus")
    func rejectsUnknownLaneDestination() {
        let master = bus("Master")
        let strayID = UUID()
        let stray = lane("Stray", to: strayID)
        #expect(throws: RoutingError.self) {
            try RoutingGraph.build(lanes: [stray], buses: [master])
        }
        do {
            _ = try RoutingGraph.build(lanes: [stray], buses: [master])
        } catch RoutingError.unknownDestination(let strip, let busID) {
            #expect(strip == "Stray")
            #expect(busID == strayID)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("Rejects a lane with no destination at all")
    func rejectsUnroutedLane() {
        let master = bus("Master")
        let orphan = LaneConfig(deviceUID: "dev", deviceChannels: [0], name: "Orphan")
        #expect(throws: RoutingError.self) {
            try RoutingGraph.build(lanes: [orphan], buses: [master])
        }
    }

    @Test("Rejects a bus pointed at an unknown parent")
    func rejectsUnknownBusDestination() {
        let strayParent = UUID()
        let bus1 = bus("A", parent: strayParent)
        #expect(throws: RoutingError.self) {
            try RoutingGraph.build(lanes: [], buses: [bus1])
        }
    }

    // MARK: - Cycles

    @Test("Rejects a direct two-bus cycle and names the path")
    func rejectsTwoBusCycle() {
        let aID = UUID()
        let bID = UUID()
        let busA = bus("A", id: aID, parent: bID)
        let busB = bus("B", id: bID, parent: aID)
        do {
            _ = try RoutingGraph.build(lanes: [], buses: [busA, busB])
            Issue.record("expected a cycle error")
        } catch RoutingError.cycle(let path) {
            // The cycle is closed and contains both names.
            #expect(path.contains("A"))
            #expect(path.contains("B"))
            #expect(path.first == path.last)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("Rejects a self-referencing bus")
    func rejectsSelfCycle() {
        let id = UUID()
        let busA = bus("A", id: id, parent: id)
        #expect(throws: RoutingError.self) {
            try RoutingGraph.build(lanes: [], buses: [busA])
        }
    }

    @Test("Rejects a longer cycle through three buses")
    func rejectsThreeBusCycle() {
        let aID = UUID(), bID = UUID(), cID = UUID()
        let busA = bus("A", id: aID, parent: bID)
        let busB = bus("B", id: bID, parent: cID)
        let busC = bus("C", id: cID, parent: aID)
        // One healthy bus outside the cycle must not hide it.
        let healthy = bus("Healthy")
        do {
            _ = try RoutingGraph.build(lanes: [], buses: [busA, busB, busC, healthy])
            Issue.record("expected a cycle error")
        } catch RoutingError.cycle(let path) {
            #expect(path.count == 4) // A -> B -> C -> A closed
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("wouldCreateCycle predicts an edit before it is made")
    func wouldCreateCyclePredicts() {
        let aID = UUID(), bID = UUID(), cID = UUID()
        let busA = bus("A", id: aID)
        let busB = bus("B", id: bID, parent: aID)
        let busC = bus("C", id: cID, parent: bID)
        let buses = [busA, busB, busC]

        // Pointing A (the root) at C (its own grandchild) would close a loop.
        #expect(RoutingGraph.wouldCreateCycle(busID: aID, newParent: cID, buses: buses))
        // Pointing A at itself is always a cycle.
        #expect(RoutingGraph.wouldCreateCycle(busID: aID, newParent: aID, buses: buses))
        // Pointing C at A is fine — C already descends from A, this just
        // shortens the chain.
        #expect(!RoutingGraph.wouldCreateCycle(busID: cID, newParent: aID, buses: buses))
        // Clearing a destination never creates a cycle.
        #expect(!RoutingGraph.wouldCreateCycle(busID: bID, newParent: nil, buses: buses))
    }

    // MARK: - Topological order

    @Test("Topological order puts every child before its parent, four-deep chain")
    func topologicalOrderDeepChain() throws {
        let ids = (0..<8).map { _ in UUID() }
        var buses: [BusConfig] = []
        for i in 0..<8 {
            let parent = i == 7 ? nil : ids[i + 1]
            buses.append(bus("bus\(i)", id: ids[i], parent: parent))
        }
        let graph = try RoutingGraph.build(lanes: [], buses: buses)
        #expect(graph.order.count == 8)
        for i in 0..<7 {
            let childIndex = try #require(graph.index[ids[i]])
            let parentIndex = try #require(graph.index[ids[i + 1]])
            #expect(childIndex < parentIndex)
        }
    }

    @Test("Topological order handles a branching tree, children before parents")
    func topologicalOrderBranching() throws {
        let root = UUID()
        let left = UUID()
        let right = UUID()
        let leftLeaf = UUID()
        let buses = [
            bus("root", id: root),
            bus("left", id: left, parent: root),
            bus("right", id: right, parent: root),
            bus("leftLeaf", id: leftLeaf, parent: left)
        ]
        let graph = try RoutingGraph.build(lanes: [], buses: buses)
        let iRoot = try #require(graph.index[root])
        let iLeft = try #require(graph.index[left])
        let iRight = try #require(graph.index[right])
        let iLeaf = try #require(graph.index[leftLeaf])
        #expect(iLeft < iRoot)
        #expect(iRight < iRoot)
        #expect(iLeaf < iLeft)
    }

    // MARK: - Siblings

    @Test("Siblings are the buses sharing a parent, or every root when there is none")
    func siblingSets() throws {
        let root = UUID()
        let left = UUID()
        let right = UUID()
        let buses = [
            bus("root", id: root),
            bus("left", id: left, parent: root),
            bus("right", id: right, parent: root)
        ]
        let graph = try RoutingGraph.build(lanes: [], buses: buses)
        #expect(Set(graph.siblings(of: left)) == Set([left, right]))
        #expect(Set(graph.siblings(of: root)) == Set([root]))
    }

    @Test("outputDeviceUIDs deduplicates and preserves first-seen order")
    func outputDeviceDedup() throws {
        let a = bus("A", output: "dev1")
        let b = bus("B", output: "dev2")
        let c = bus("C", output: "dev1")
        let graph = try RoutingGraph.build(lanes: [], buses: [a, b, c])
        #expect(graph.outputDeviceUIDs == ["dev1", "dev2"])
        #expect(graph.outputSends.count == 3)
    }
}
