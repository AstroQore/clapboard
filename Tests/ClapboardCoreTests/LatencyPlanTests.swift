import ClapboardCore
import Foundation
import Testing

/// `docs/ROUTING.md`: plug-in delay compensation across the whole tree — every
/// lane and bus feeding a given bus is delayed so they all arrive together,
/// and the resulting total latency from any leaf to a given output is the
/// same number for every path.
@Suite("Latency plan")
struct LatencyPlanTests {
    private func lane(_ name: String, to bus: UUID) -> LaneConfig {
        LaneConfig(deviceUID: "dev-\(name)", deviceChannels: [0], name: name, destinationBus: bus)
    }

    private func bus(_ name: String, id: UUID = UUID(), parent: UUID? = nil, output: String? = nil) -> BusConfig {
        BusConfig(id: id, name: name, destinationBus: parent, outputDeviceUID: output)
    }

    /// Master
    ///   ├─ BusA (chain 10ms-equivalent)
    ///   │    ├─ Lane1 (chain 0)
    ///   │    └─ Lane2 (chain 5)
    ///   └─ BusB (chain 0)
    ///        └─ Lane3 (chain 20)
    private struct Tree {
        let master: BusConfig
        let busA: BusConfig
        let busB: BusConfig
        let lane1: LaneConfig
        let lane2: LaneConfig
        let lane3: LaneConfig
        let graph: RoutingGraph
        let plan: LatencyPlan
    }

    private func buildTree() throws -> Tree {
        let master = bus("Master", output: "out")
        let busA = bus("BusA", parent: master.id)
        let busB = bus("BusB", parent: master.id)
        let lane1 = lane("Lane1", to: busA.id)
        let lane2 = lane("Lane2", to: busA.id)
        let lane3 = lane("Lane3", to: busB.id)

        let graph = try RoutingGraph.build(lanes: [lane1, lane2, lane3], buses: [master, busA, busB])
        let plan = LatencyPlan.compute(
            graph: graph,
            laneChainLatency: [lane1.id: 0, lane2.id: 5, lane3.id: 20],
            busChainLatency: [busA.id: 10, busB.id: 0, master.id: 0]
        )
        return Tree(master: master, busA: busA, busB: busB, lane1: lane1, lane2: lane2, lane3: lane3, graph: graph, plan: plan)
    }

    @Test("Every leaf-to-output path through the tree ends up equal")
    func everyPathEndsUpEqual() throws {
        let t = try buildTree()
        let toMaster = [t.lane1, t.lane2, t.lane3].map {
            t.plan.totalLatency(
                forLane: $0.id, to: t.master.id, graph: t.graph,
                laneChainLatency: [t.lane1.id: 0, t.lane2.id: 5, t.lane3.id: 20]
            )
        }
        let values = toMaster.compactMap { $0 }
        #expect(values.count == 3)
        #expect(Set(values).count == 1, "all three leaf-to-output latencies must be equal, got \(values)")

        // And that shared number must equal the reported output latency.
        let outputLatency = try #require(t.plan.outputLatency["out"])
        #expect(values.first == outputLatency)
    }

    @Test("Lanes on the same bus compensate to the slowest lane's chain")
    func laneCompensationAlignsSiblingLanes() throws {
        let t = try buildTree()
        // Lane2 already has the longer chain (5), so it gets no extra delay;
        // Lane1 (chain 0) is delayed to catch up.
        #expect(t.plan.laneCompensation[t.lane1.id] == 5)
        #expect(t.plan.laneCompensation[t.lane2.id] == 0)
    }

    @Test("A bus with a faster subtree is delayed to match its slower sibling")
    func busCompensationAlignsSiblingBuses() throws {
        let t = try buildTree()
        // subtree(BusA) = inputAlign(5) + chain(10) = 15
        // subtree(BusB) = inputAlign(20) + chain(0) = 20
        // BusA is the faster subtree, so it picks up the difference.
        #expect(t.plan.busCompensation[t.busA.id] == 5)
        #expect(t.plan.busCompensation[t.busB.id] == 0)
    }

    @Test("Root buses on different output devices are not compensated against each other")
    func differentOutputsNotAligned() throws {
        let rootA = bus("A", output: "out1")
        let rootB = bus("B", output: "out2")
        let laneA = lane("LaneA", to: rootA.id)
        let laneB = lane("LaneB", to: rootB.id)
        let graph = try RoutingGraph.build(lanes: [laneA, laneB], buses: [rootA, rootB])
        let plan = LatencyPlan.compute(
            graph: graph,
            laneChainLatency: [laneA.id: 0, laneB.id: 500],
            busChainLatency: [:]
        )
        // Nobody hears both outputs mixed, so neither root should be forced
        // to wait on the other's much slower lane.
        #expect(plan.busCompensation[rootA.id] == 0)
        #expect(plan.busCompensation[rootB.id] == 0)
    }

    @Test("Root buses that share one output device are aligned like siblings")
    func sameOutputAlignedLikeSiblings() throws {
        let rootA = bus("A", output: "out")
        let rootB = bus("B", output: "out")
        let laneA = lane("LaneA", to: rootA.id)
        let laneB = lane("LaneB", to: rootB.id)
        let graph = try RoutingGraph.build(lanes: [laneA, laneB], buses: [rootA, rootB])
        let plan = LatencyPlan.compute(
            graph: graph,
            laneChainLatency: [laneA.id: 0, laneB.id: 100],
            busChainLatency: [:]
        )
        // Same destination device: the faster root (A) must catch up to B.
        #expect(plan.busCompensation[rootA.id] == 100)
        #expect(plan.busCompensation[rootB.id] == 0)
        #expect(plan.outputLatency["out"] == 100)
    }

    @Test("A lane with no destination contributes nothing and gets no compensation")
    func emptyPlanIsHarmless() {
        #expect(LatencyPlan.empty.laneCompensation.isEmpty)
        #expect(LatencyPlan.empty.busCompensation.isEmpty)
        #expect(LatencyPlan.empty.outputLatency.isEmpty)
    }

    @Test("Compensation beyond the delay line capacity is clamped and reported")
    func excessiveCompensationIsClamped() throws {
        let master = bus("Master", output: "out")
        let busA = bus("BusA", parent: master.id)
        let fast = lane("Fast", to: busA.id)
        let slow = lane("Slow", to: busA.id)
        let graph = try RoutingGraph.build(lanes: [fast, slow], buses: [master, busA])

        // The slow lane's chain is far beyond what any delay line can make up.
        let hugeLatency = RTLimits.maxDelaySamples * 4
        let plan = LatencyPlan.compute(
            graph: graph,
            laneChainLatency: [fast.id: 0, slow.id: hugeLatency],
            busChainLatency: [:]
        )
        #expect(plan.laneCompensation[fast.id] == RTLimits.maxDelaySamples)
        #expect(plan.clamped.contains(fast.id))
        // The slow lane itself needs no compensation (it already is the max).
        #expect(plan.laneCompensation[slow.id] == 0)
        #expect(!plan.clamped.contains(slow.id))
    }
}
