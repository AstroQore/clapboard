import AudioToolbox
import ClapboardCore
import Foundation
import Testing

/// Effect chains on a bus that is not the master.
///
/// `EffectChainTests` covers lanes and the master bus; everything here is the
/// part that used to be missing — a chain on any other bus is instantiated,
/// audible, compensated, editable and restored on relaunch, on exactly the
/// terms the master's chain has always had.
///
/// Every plug-in used here is one of Apple's own: on an Apple Silicon Mac an
/// AUv2 bundle without an arm64 slice cannot be hosted in process at all, and
/// every third-party effect installed on this machine is x86_64-only.
/// `AUPeakLimiter` reports exactly 96 samples of look-ahead at 48 kHz and
/// `AUDelay` reports none, which makes the pair a sharp probe for PDC.
@Suite("Bus effect chains")
@MainActor
struct BusEffectChainTests {
    private static let sampleRate = 48_000.0

    private func nonZero(_ samples: [Float], above: Float = 1e-6) -> [Int] {
        samples.enumerated().filter { abs($0.element) > above }.map(\.offset)
    }

    // MARK: - Kernel: a chain on one of two sibling buses

    /// Two lanes on two sibling buses, a look-ahead limiter on one of the
    /// *buses*: the plan delays the other bus by the limiter's latency, so the
    /// two impulses still reach the master output on the same frame. Bypassing
    /// the limiter takes its latency away and the pair re-aligns at zero.
    ///
    /// The topology, the plan and the render all come from the shipping types:
    /// `RoutingGraph.build` over real configs, `LatencyPlan.compute` over that
    /// graph, and the numbers it produces written straight into the render
    /// thread — which is what `AudioEngine.pushEffectiveDelays()` does.
    @Test func aBusChainCompensatesItsSiblingSoImpulsesStayOnOneFrame() async throws {
        let limiter = try await AUEffectInstance.instantiate(
            try AUFixtures.info(AUFixtures.peakLimiter),
            channels: 2,
            sampleRate: Self.sampleRate)
        defer { limiter.teardown() }
        #expect(limiter.latencySamples == 96, "AUPeakLimiter's look-ahead at 48 kHz")

        let tree = SiblingTree()
        let effectID = UUID()
        tree.host.registerEffect(id: effectID, instance: limiter, channels: 2)
        tree.publish(busAChainLatency: limiter.latencySamples, busAEffects: [effectID])

        // The plan's own arithmetic, before a single sample is rendered: busA
        // carries the whole chain, so busB is the one that waits.
        #expect(tree.plan.busCompensation[tree.busA.id] == 0)
        #expect(tree.plan.busCompensation[tree.busB.id] == 96)
        #expect(tree.plan.outputLatency["out"] == 96)

        let rendered = tree.renderBlocks(4) { block in
            if block == 0 {
                tree.input[0, 0, 0] = 0.1
                tree.input[1, 0, 0] = 0.1
            }
        }
        #expect(nonZero(rendered.left) == [96], "both impulses have to land on one frame")
        #expect(abs(rendered.left[96] - 0.2) < 1e-4, "0.1 from each bus")
        #expect(abs(rendered.right[96] - 0.2) < 1e-4)

        // Bypass is a host-level pass-through, so the latency goes with it and
        // the compensation the plan hands busB goes to zero.
        tree.host.setEffectBypass(id: effectID, true)
        tree.publish(busAChainLatency: 0, busAEffects: [effectID])
        #expect(tree.plan.busCompensation[tree.busB.id] == 0)
        #expect(tree.plan.outputLatency["out"] == 0)
        _ = tree.renderBlocks(8)

        let again = tree.renderBlocks(4) { block in
            if block == 0 {
                tree.input[0, 0, 0] = 0.1
                tree.input[1, 0, 0] = 0.1
            }
        }
        #expect(nonZero(again.left) == [0], "bypassed, the two buses are aligned at zero again")
        #expect(abs(again.left[0] - 0.2) < 1e-4)

        tree.host.discardEffect(id: effectID)
        tree.host.unpublish()
        for retired in tree.host.takeRetiredEffects() where retired !== limiter { retired.teardown() }
    }

    // MARK: - Engine: editing a chain on a non-master bus

    @Test func anEffectOnANonMasterBusIsLiveAndCompensatesItsSiblings() async throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        engine.setOutputDevice(uid: "out")
        let master = try #require(engine.buses.first)
        let busA = engine.addBus(name: "A")
        let busB = engine.addBus(name: "B")
        #expect(engine.setBusDestination(id: busA.id, parent: master.id).isSuccess)
        #expect(engine.setBusDestination(id: busB.id, parent: master.id).isSuccess)
        let laneA = engine.addLane(deviceUID: "mic-a", deviceChannels: [0], name: "A")
        let laneB = engine.addLane(deviceUID: "mic-b", deviceChannels: [0], name: "B")
        #expect(engine.setLaneDestination(laneA.id, bus: busA.id))
        #expect(engine.setLaneDestination(laneB.id, bus: busB.id))

        let config = try await engine.addEffect(
            try AUFixtures.info(AUFixtures.peakLimiter), to: .bus(busA.id))

        // Live, not a placeholder: there is a real instance behind it.
        let instance = try #require(engine.effectInstance(id: config.id))
        #expect(config.isAvailable)
        #expect(engine.effects(for: .bus(busA.id)).map(\.id) == [config.id])
        #expect(engine.target(ofEffect: config.id) == .bus(busA.id))
        #expect(engine.bus(id: busA.id)?.effects.map(\.id) == [config.id])
        // A bus is a stereo sum, so its plug-ins are instantiated with two
        // channels even though both lanes here are mono.
        #expect(instance.laneChannels == 2)

        #expect(engine.busChainLatency(busA.id) == 96)
        #expect(engine.busChainLatency(busB.id) == 0)
        #expect(engine.latencyPlan.busCompensation[busA.id] == 0)
        #expect(engine.latencyPlan.busCompensation[busB.id] == 96, "the sibling waits for the chain")
        #expect(engine.outputLatencySamples(forDevice: "out") == 96)
        // Lanes on either side of the tree are still aligned with each other:
        // the compensation happened one level up, at the buses.
        #expect(engine.pdcSamples[laneA.id] == 0)
        #expect(engine.pdcSamples[laneB.id] == 0)
        #expect(engine.pdcWarning == nil)

        engine.setEffectBypass(id: config.id, true)
        #expect(engine.effects(for: .bus(busA.id))[0].bypass)
        #expect(engine.busChainLatency(busA.id) == 0)
        #expect(engine.latencyPlan.busCompensation[busB.id] == 0)

        engine.setEffectBypass(id: config.id, false)
        #expect(engine.latencyPlan.busCompensation[busB.id] == 96)

        engine.removeEffect(id: config.id)
        #expect(engine.effects(for: .bus(busA.id)).isEmpty)
        #expect(engine.effectInstance(id: config.id) == nil, "stopped, so it was reclaimed at once")
        #expect(engine.latencyPlan.busCompensation[busB.id] == 0)
    }

    @Test func aBusChainReordersLikeALanesDoes() async throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        let bus = engine.addBus(name: "Drums")

        let first = try await engine.addEffect(try AUFixtures.info(AUFixtures.delay), to: .bus(bus.id))
        let second = try await engine.addEffect(
            try AUFixtures.info(AUFixtures.peakLimiter), to: .bus(bus.id))
        #expect(engine.effects(for: .bus(bus.id)).map(\.id) == [first.id, second.id])

        engine.moveEffect(id: second.id, to: 0)
        #expect(engine.effects(for: .bus(bus.id)).map(\.id) == [second.id, first.id])
        engine.moveEffect(id: second.id, to: 99)
        #expect(engine.effects(for: .bus(bus.id)).map(\.id) == [first.id, second.id])

        // Chain latency is the sum of what is not bypassed, on a bus exactly
        // as on a lane.
        #expect(engine.busChainLatency(bus.id) == 96)
        engine.setEffectBypass(id: second.id, true)
        #expect(engine.busChainLatency(bus.id) == 0)
    }

    /// Removing a bus takes its plug-ins with it, on the same
    /// snapshot-generation terms `removeLane` uses.
    @Test func removingABusTearsDownItsChain() async throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        let bus = engine.addBus(name: "Strings")
        let config = try await engine.addEffect(try AUFixtures.info(AUFixtures.delay), to: .bus(bus.id))
        #expect(engine.effectInstance(id: config.id) != nil)

        #expect(engine.removeBus(id: bus.id).isSuccess)
        #expect(engine.bus(id: bus.id) == nil)
        #expect(engine.target(ofEffect: config.id) == nil)
        // Stopped, so nothing can be inside the kernel: the plug-in was
        // reclaimed and torn down immediately.
        #expect(engine.effectInstance(id: config.id) == nil)
        #expect(engine.effectConfig(id: config.id) == nil)
    }

    @Test func addingToABusThatIsGoneIsRefused() async throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        await #expect(throws: AudioEngine.EffectError.unknownBus) {
            _ = try await engine.addEffect(try AUFixtures.info(AUFixtures.delay), to: .bus(UUID()))
        }
    }

    /// The pre-`EffectTarget` spelling still means what it always meant.
    @Test func theLaneIDShimStillAddressesLanesAndTheMasterBus() async throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        let lane = engine.addLane(deviceUID: "mic-a", deviceChannels: [0], name: "A")
        let onMaster = try await engine.addEffect(try AUFixtures.info(AUFixtures.delay), toLane: nil)
        let onLane = try await engine.addEffect(
            try AUFixtures.info(AUFixtures.peakLimiter), toLane: lane.id)

        #expect(engine.masterEffectTarget == .bus(engine.buses[0].id))
        #expect(engine.effects(forLane: nil).map(\.id) == [onMaster.id])
        #expect(engine.effects(for: engine.masterEffectTarget).map(\.id) == [onMaster.id])
        #expect(engine.masterEffects.map(\.id) == [onMaster.id])
        #expect(engine.effects(forLane: lane.id).map(\.id) == [onLane.id])
        #expect(engine.laneOwning(effect: onMaster.id) == .some(nil))
        #expect(engine.laneOwning(effect: onLane.id) == .some(.some(lane.id)))
    }

    // MARK: - Session round trip

    @Test func aChainOnANonMasterBusComesBackLive() async throws {
        let engine = AudioEngine()
        engine.setOutputDevice(uid: "out")
        let master = try #require(engine.buses.first)
        let bus = engine.addBus(name: "Vocals")
        #expect(engine.setBusDestination(id: bus.id, parent: master.id).isSuccess)
        let config = try await engine.addEffect(try AUFixtures.info(AUFixtures.delay), to: .bus(bus.id))
        engine.setEffectBypass(id: config.id, true)

        // Something to notice on the other side.
        let tree = try #require(engine.effectInstance(id: config.id)?.auAudioUnit.parameterTree)
        let delayTime = try #require(
            tree.parameter(withAddress: AUParameterAddress(kDelayParam_DelayTime)))
        delayTime.value = 0.25

        let document = engine.sessionSnapshot
        let savedBus = try #require(document.buses.first { $0.id == bus.id })
        #expect(savedBus.effects.map(\.id) == [config.id])
        #expect(savedBus.effects[0].bypass)
        #expect(savedBus.effects[0].componentID == "aufx.dely.appl")
        #expect(savedBus.effects[0].fullState != nil, "AUDelay published no state")

        // Through JSON and back, the way the session file travels.
        let round = try SessionDocument.decode(try document.jsonData())
        #expect(round.buses == document.buses)
        engine.shutdown()

        let reopened = AudioEngine()
        defer { reopened.shutdown() }
        let report = reopened.restore(round)
        #expect(report.pendingEffects == 1)
        await reopened.waitForEffectRestore()
        #expect(!reopened.restoringEffects)

        let restoredBus = try #require(reopened.bus(id: bus.id))
        #expect(restoredBus.name == "Vocals")
        let chain = reopened.effects(for: .bus(bus.id))
        #expect(chain.map(\.id) == [config.id], "effect ids have to survive")
        #expect(chain[0].bypass)
        #expect(chain[0].isAvailable, "a live instance, not a placeholder")
        #expect(chain[0].unavailableReason == nil)
        let instance = try #require(reopened.effectInstance(id: config.id))
        #expect(instance.laneChannels == 2)

        let restoredTree = try #require(instance.auAudioUnit.parameterTree)
        let restoredTime = try #require(
            restoredTree.parameter(withAddress: AUParameterAddress(kDelayParam_DelayTime)))
        #expect(abs(restoredTime.value - 0.25) < 1e-4, "fullState did not come back")

        // And it is editable from the far side of the relaunch.
        reopened.setEffectBypass(id: config.id, false)
        #expect(reopened.effects(for: .bus(bus.id))[0].bypass == false)
        reopened.removeEffect(id: config.id)
        #expect(reopened.effects(for: .bus(bus.id)).isEmpty)
    }

    /// A plug-in this Mac does not have still comes back as a placeholder that
    /// keeps its state — the same contract a lane's chain has, and the only
    /// reason a placeholder should exist on a bus any more.
    @Test func aMissingPlugInOnANonMasterBusStaysAPlaceholderThatKeepsItsState() async throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        let ghost = EffectConfig(
            componentID: "aufx.zzzz.zzzz",
            displayName: "Nonexistent: Ghost",
            fullState: Data([1, 2, 3, 4]))
        let master = BusConfig(name: BusConfig.masterName, outputDeviceUID: "out")
        let side = BusConfig(name: "Side", effects: [ghost], destinationBus: master.id)
        let document = SessionDocument(lanes: [], buses: [master, side])

        engine.restore(document)
        await engine.waitForEffectRestore()

        let chain = engine.effects(for: .bus(side.id))
        #expect(chain.count == 1)
        #expect(!chain[0].isAvailable)
        #expect(chain[0].unavailableReason?.contains("aufx.zzzz.zzzz") == true,
                "a placeholder now means the component is missing, not that the bus is unreachable")
        // Not published, so it contributes no latency and nothing to the graph.
        #expect(engine.busChainLatency(side.id) == 0)
        #expect(engine.effectInstance(id: ghost.id) == nil)

        // Saving again keeps the state rather than dropping it, so the chain
        // comes back on a Mac that does have the plug-in.
        let again = engine.sessionSnapshot
        let saved = try #require(again.buses.first { $0.id == side.id })
        #expect(saved.effects.map(\.componentID) == ["aufx.zzzz.zzzz"])
        #expect(saved.effects[0].fullState == Data([1, 2, 3, 4]))
        #expect(saved.effects[0].unavailableReason == nil,
                "a placeholder is a local fact, not a saved one")
    }
}

// MARK: - Render harness

/// Two lanes, each on its own child bus, both feeding a root bus that owns the
/// output device — the smallest tree in which one bus's chain has to be
/// compensated against a sibling.
///
/// Unlike `RenderKernelBusTests.Tree` the delays are not hand-written: the
/// topology is real `LaneConfig`/`BusConfig` values, the graph comes from
/// `RoutingGraph.build`, and every delay written to the render thread comes
/// from `LatencyPlan.compute` over that graph.
@MainActor
private final class SiblingTree {
    let host = RTEngineHost()
    let input: BufferListBox
    let output: BufferListBox
    let frames = 256

    let master = BusConfig(name: "Master", outputDeviceUID: "out")
    let busA: BusConfig
    let busB: BusConfig
    let laneA: LaneConfig
    let laneB: LaneConfig
    let graph: RoutingGraph
    private(set) var plan: LatencyPlan = .empty

    init() {
        busA = BusConfig(name: "A", destinationBus: master.id)
        busB = BusConfig(name: "B", destinationBus: master.id)
        laneA = LaneConfig(deviceUID: "mic-a", deviceChannels: [0], name: "LaneA",
                           destinationBus: busA.id)
        laneB = LaneConfig(deviceUID: "mic-b", deviceChannels: [0], name: "LaneB",
                           destinationBus: busB.id)
        // Two mono input streams, one stereo output stream.
        input = BufferListBox(streams: [1, 1], frames: frames)
        output = BufferListBox(streams: [2], frames: frames)
        graph = try! RoutingGraph.build(lanes: [laneA, laneB], buses: [master, busA, busB])
        host.setMeterDecay(framesPerBlock: frames, sampleRate: 48_000)
        for id in [master.id, busA.id, busB.id] { host.runtime(forBus: id) }
        for id in [laneA.id, laneB.id] { _ = host.runtime(for: id) }
    }

    deinit { host.unpublish() }

    /// Recomputes the plan for the given bus-chain latency and publishes it —
    /// exactly the two steps `AudioEngine.pushEffectiveDelays()` +
    /// `republishGraph()` take.
    func publish(busAChainLatency: Int, busAEffects: [UUID]) {
        plan = LatencyPlan.compute(
            graph: graph,
            laneChainLatency: [laneA.id: 0, laneB.id: 0],
            busChainLatency: [busA.id: busAChainLatency, busB.id: 0, master.id: 0]
        )
        for lane in [laneA, laneB] {
            host.setLaneDelay(lane.id, samples: plan.laneCompensation[lane.id] ?? 0)
        }
        for id in graph.order {
            host.setBusDelay(id, samples: plan.busCompensation[id] ?? 0)
        }
        let laneNodes = [
            RTLaneNode(runtime: host.runtime(for: laneA.id), channelCount: 1,
                       bufferIndex0: 0, channelInBuffer0: 0, channelsInBuffer0: 1),
            RTLaneNode(runtime: host.runtime(for: laneB.id), channelCount: 1,
                       bufferIndex0: 1, channelInBuffer0: 0, channelsInBuffer0: 1)
        ]
        host.publish(
            laneNodes: laneNodes,
            laneBusIDs: [busA.id, busB.id],
            laneEffectIDs: [[], []],
            // `graph.order` is topological — children before the parent — which
            // is what the kernel needs.
            buses: graph.order.map { id in
                RTEngineHost.BusPublishInfo(
                    id: id,
                    parentID: graph.parent[id],
                    outputBufferIndex: id == master.id ? 0 : -1,
                    outputChannelsInBuffer: id == master.id ? 2 : 0,
                    effectIDs: id == busA.id ? busAEffects : []
                )
            }
        )
    }

    func renderBlocks(_ count: Int, beforeEach: (Int) -> Void = { _ in }) -> (left: [Float], right: [Float]) {
        var left: [Float] = []
        var right: [Float] = []
        for block in 0..<count {
            input.clear()
            beforeEach(block)
            render(state: host.state, input: input.pointer, output: output.pointer, frames: frames)
            for frame in 0..<frames {
                left.append(output[0, 0, frame])
                right.append(output[0, 1, frame])
            }
        }
        return (left, right)
    }
}
