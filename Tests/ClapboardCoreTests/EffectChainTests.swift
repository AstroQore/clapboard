import AudioToolbox
import ClapboardCore
import Foundation
import Testing

/// M4 part 2: effect chains in the render kernel, plug-in delay compensation,
/// and the session round trip.
///
/// Every plug-in used here is one of Apple's own. That is not a stylistic
/// choice: on an Apple Silicon Mac an AUv2 bundle without an arm64 slice
/// cannot be hosted in process at all, and every third-party effect installed
/// on this machine is x86_64-only.
@Suite("Effect chains")
@MainActor
struct EffectChainTests {
    private static let sampleRate = 48_000.0

    // MARK: - Helpers

    private func limiter(channels: Int = 1) async throws -> AUEffectInstance {
        try await AUEffectInstance.instantiate(
            try AUFixtures.info(AUFixtures.peakLimiter),
            channels: channels,
            sampleRate: Self.sampleRate)
    }

    /// AUDelay with the wet/dry mix hard over and half a second of delay: for
    /// the length of these tests its output is exactly silence, which makes it
    /// the sharpest possible probe for "did the chain run" and for "did the
    /// bypass switch step".
    private func silentDelay(channels: Int = 1) async throws -> AUEffectInstance {
        let instance = try await AUEffectInstance.instantiate(
            try AUFixtures.info(AUFixtures.delay),
            channels: channels,
            sampleRate: Self.sampleRate)
        let tree = try #require(instance.auAudioUnit.parameterTree)
        tree.parameter(withAddress: AUParameterAddress(kDelayParam_WetDryMix))?.value = 100
        tree.parameter(withAddress: AUParameterAddress(kDelayParam_DelayTime))?.value = 0.5
        return instance
    }

    private func nonZero(_ samples: [Float], above: Float = 1e-6) -> [Int] {
        samples.enumerated().filter { abs($0.element) > above }.map(\.offset)
    }

    private func biggestStep(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    // MARK: - Plug-in delay compensation

    /// The point of PDC: a lane carrying a look-ahead plug-in comes out late,
    /// so every other lane is delayed to match and the impulses stay on the
    /// same frame.
    @Test func compensationKeepsTwoLanesOnTheSameFrame() async throws {
        let instance = try await limiter()
        let latency = instance.latencySamples
        #expect(latency == 96, "AUPeakLimiter's look-ahead at 48 kHz")

        let rig = Rig(inputStreams: [2])
        let laneA = rig.addLane(sources: [(0, 0, 2)])
        let laneB = rig.addLane(sources: [(0, 1, 2)])
        let effectID = UUID()
        rig.host.registerEffect(id: effectID, instance: instance, channels: 1)

        // What `AudioEngine.pushEffectiveDelays()` would write: lane A already
        // waits `latency` inside the plug-in, so lane B is given it explicitly.
        rig.host.setLaneDelay(laneA, samples: 0)
        rig.host.setLaneDelay(laneB, samples: latency)
        rig.publish(
            [(laneA, [(0, 0, 2)]), (laneB, [(0, 1, 2)])],
            laneEffects: [[effectID], []])

        let rendered = rig.renderBlocks(4) { block in
            if block == 0 {
                rig.input[0, 0, 0] = 0.1
                rig.input[0, 1, 0] = 0.1
            }
        }
        let hits = nonZero(rendered.left)
        #expect(hits == [latency], "both impulses have to land on one frame")
        #expect(abs(rendered.left[latency] - 0.2) < 1e-4, "0.1 from each lane")

        // Bypassing the plug-in removes its latency, so the compensation goes
        // away too — and one crossfade later the lanes are aligned again.
        rig.host.setEffectBypass(id: effectID, true)
        rig.host.setLaneDelay(laneB, samples: 0)
        _ = rig.renderBlocks(4)

        let again = rig.renderBlocks(4) { block in
            if block == 0 {
                rig.input[0, 0, 0] = 0.1
                rig.input[0, 1, 0] = 0.1
            }
        }
        #expect(nonZero(again.left) == [0])
        #expect(abs(again.left[0] - 0.2) < 1e-4)

        rig.host.discardEffect(id: effectID)
        rig.publish([(laneA, [(0, 0, 2)]), (laneB, [(0, 1, 2)])])
        _ = rig.renderBlock()
        rig.host.collectGarbage()
        for retired in rig.host.takeRetiredEffects() { retired.teardown() }
    }

    /// The reclamation contract: an effect dropped from the graph is torn down
    /// only after the render thread has demonstrably left the snapshot that
    /// still named it — the same rule lane runtimes follow.
    @Test func removingAnEffectMidRenderDefersTeardown() async throws {
        let instance = try await silentDelay()
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        let effectID = UUID()
        rig.host.registerEffect(id: effectID, instance: instance, channels: 1)
        rig.publish([(lane, [(0, 0, 1)])], laneEffects: [[effectID]])

        let wet = rig.renderBlocks(2) { _ in rig.input.fill(stream: 0, channel: 0) { _ in 0.5 } }
        #expect(nonZero(wet.left).isEmpty, "the chain ran: AUDelay is 100 % wet and still silent")

        // Drop it from the graph. The old snapshot is retired, not freed, and
        // the plug-in is not reclaimable yet.
        rig.host.discardEffect(id: effectID)
        rig.publish([(lane, [(0, 0, 1)])])
        #expect(rig.host.takeRetiredEffects().isEmpty, "the render thread has not moved on yet")
        #expect(rig.host.retiredSnapshotCount == 1)

        // Keep rendering through the swap. Nothing here may touch the freed
        // slot array, and the lane is dry again.
        let dry = rig.renderBlocks(4) { _ in rig.input.fill(stream: 0, channel: 0) { _ in 0.5 } }
        #expect(dry.left.allSatisfy { abs($0 - 0.5) < 1e-5 })

        rig.host.collectGarbage()
        let reclaimed = rig.host.takeRetiredEffects()
        #expect(reclaimed.count == 1)
        #expect(reclaimed.first === instance)
        #expect(rig.host.retiredSnapshotCount == 0)
        for retired in reclaimed { retired.teardown() }
        #expect(!instance.isRenderable)
    }

    // MARK: - Master chain

    @Test func theMasterChainChangesTheSumAndLeavesLaneMetersAlone() async throws {
        func run(masterEffect: AUEffectInstance?) -> (output: [Float], meter: MeterReading) {
            let rig = Rig(inputStreams: [1])
            let lane = rig.addLane(sources: [(0, 0, 1)])
            var ids: [UUID] = []
            if let masterEffect {
                let id = UUID()
                rig.host.registerEffect(id: id, instance: masterEffect, channels: 2)
                ids = [id]
            }
            rig.publish([(lane, [(0, 0, 1)])], masterEffects: ids)
            var frame = 0
            let rendered = rig.renderBlocks(4) { _ in
                rig.input.fill(stream: 0, channel: 0) { index in
                    0.5 * Float(sin(2 * Double.pi * 1000 * Double(frame + index) / Self.sampleRate))
                }
                frame += rig.frames
            }
            let meter = rig.host.laneMeter(lane)
            for retired in rig.host.takeRetiredEffects() { retired.teardown() }
            return (rendered.left, meter)
        }

        let dry = run(masterEffect: nil)
        let delay = try await silentDelay(channels: 2)
        let wet = run(masterEffect: delay)
        delay.teardown()

        #expect(dry.output != wet.output, "the master chain did not run")
        #expect(nonZero(wet.output).isEmpty, "AUDelay at 100 % wet with 0.5 s of delay")
        #expect(dry.output.contains { abs($0) > 0.4 })
        // Lane meters are taken before the master bus, so a master plug-in
        // must not move them.
        #expect(abs(dry.meter.peak - wet.meter.peak) < 1e-6)
        #expect(abs(dry.meter.rms - wet.meter.rms) < 1e-6)
    }

    // MARK: - Bypass crossfade

    /// A hard bypass switch would step by the whole difference between the dry
    /// lane and the plug-in's output — here the entire signal. The crossfade
    /// keeps every sample-to-sample change inside the sine's own slope plus
    /// one crossfade increment.
    @Test func bypassCrossfadesInsteadOfStepping() async throws {
        let instance = try await silentDelay()
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        let effectID = UUID()
        rig.host.registerEffect(id: effectID, instance: instance, channels: 1)
        rig.publish([(lane, [(0, 0, 1)])], laneEffects: [[effectID]])

        let amplitude: Float = 0.5
        var frame = 0
        func sine(_ index: Int) -> Float {
            amplitude * Float(sin(2 * Double.pi * 1000 * Double(frame + index) / Self.sampleRate))
        }

        // Two blocks fully wet (silence), then bypass, then long enough for
        // the fade to land and the dry sine to run on.
        let rendered = rig.renderBlocks(8) { block in
            rig.input.fill(stream: 0, channel: 0, sine)
            frame += rig.frames
            if block == 2 { rig.host.setEffectBypass(id: effectID, true) }
        }

        #expect(nonZero(Array(rendered.left.prefix(rig.frames))).isEmpty, "starts wet")
        let tail = Array(rendered.left.suffix(rig.frames))
        #expect(tail.contains { abs($0) > 0.4 }, "ends dry")

        let slope = amplitude * Float(2 * Double.pi * 1000 / Self.sampleRate)
        let fadeIncrement = amplitude / Float(RTLimits.crossfadeFrames)
        let step = biggestStep(rendered.left)
        #expect(
            step < (slope + fadeIncrement) * 1.05,
            "biggest step \(step) — a hard switch would be about \(amplitude)")
        #expect(step > slope * 0.5, "the sine has to actually be there")

        rig.host.discardEffect(id: effectID)
        rig.publish([(lane, [(0, 0, 1)])])
        _ = rig.renderBlock()
        rig.host.collectGarbage()
        for retired in rig.host.takeRetiredEffects() { retired.teardown() }
    }

    // MARK: - Engine-level chains

    @Test func addingAnEffectToALaneCompensatesEveryOtherLane() async throws {
        let engine = AudioEngine()
        engine.setOutputDevice(uid: "out")
        let laneA = engine.addLane(deviceUID: "mic-a", deviceChannels: [0], name: "A")
        let laneB = engine.addLane(deviceUID: "mic-b", deviceChannels: [0], name: "B")
        defer { engine.shutdown() }

        #expect(engine.outputLatencySamples == 0)
        let config = try await engine.addEffect(
            try AUFixtures.info(AUFixtures.peakLimiter), toLane: laneA.id)

        #expect(engine.effects(forLane: laneA.id).map(\.id) == [config.id])
        #expect(engine.effects(forLane: laneB.id).isEmpty)
        #expect(engine.laneChainLatency(laneA.id) == 96)
        #expect(engine.laneChainLatency(laneB.id) == 0)
        // The plug-in's own latency is lane A's compensation; lane B is given
        // an equal delay so the two stay aligned.
        #expect(engine.pdcSamples[laneA.id] == 0)
        #expect(engine.pdcSamples[laneB.id] == 96)
        #expect(engine.effectiveDelaySamples(forLane: laneB.id) == 96)
        #expect(engine.outputLatencySamples == 96)
        #expect(engine.pdcWarning == nil)

        // Bypass is a pass-through, so it takes the latency away with it.
        engine.setEffectBypass(id: config.id, true)
        #expect(engine.laneChainLatency(laneA.id) == 0)
        #expect(engine.pdcSamples[laneB.id] == 0)
        #expect(engine.outputLatencySamples == 0)

        engine.setEffectBypass(id: config.id, false)
        // A master effect is common to every lane, so it compensates nothing
        // and is only reported as output latency.
        let master = try await engine.addEffect(
            try AUFixtures.info(AUFixtures.peakLimiter), toLane: nil)
        #expect(engine.masterEffects.map(\.id) == [master.id])
        #expect(engine.masterChainLatency == 96)
        #expect(engine.pdcSamples[laneB.id] == 96, "unchanged by the master chain")
        #expect(engine.outputLatencySamples == 192)

        engine.removeEffect(id: config.id)
        #expect(engine.effects(forLane: laneA.id).isEmpty)
        #expect(engine.pdcSamples[laneB.id] == 0)
        #expect(engine.outputLatencySamples == 96)
    }

    /// Auto Sync writes `LaneConfig.delaySamples` through
    /// `setLaneDelaySamples` — the same door the delay field in the UI uses —
    /// and compensation is added on top of it rather than replacing it.
    @Test func measuredDelaysAndCompensationAddUp() async throws {
        let engine = AudioEngine()
        engine.setOutputDevice(uid: "out")
        let laneA = engine.addLane(deviceUID: "mic-a", deviceChannels: [0], name: "A")
        let laneB = engine.addLane(deviceUID: "mic-b", deviceChannels: [0], name: "B")
        defer { engine.shutdown() }

        _ = try await engine.addEffect(try AUFixtures.info(AUFixtures.peakLimiter), toLane: laneA.id)
        // What `SyncSession.apply()` does after a clap.
        engine.setLaneDelaySamples(laneB.id, 4_800)

        #expect(engine.lane(id: laneB.id)?.delaySamples == 4_800, "the measured value is kept as measured")
        #expect(engine.effectiveDelaySamples(forLane: laneB.id) == 4_800 + 96)
        #expect(engine.effectiveDelaySamples(forLane: laneA.id) == 0)
        #expect(engine.pdcWarning == nil)

        // Compensation that would push a lane past the delay line's ceiling is
        // clamped, and the mix is no longer aligned — so say so.
        engine.setLaneDelaySamples(laneB.id, RTLimits.maxDelaySamples)
        #expect(engine.effectiveDelaySamples(forLane: laneB.id) == RTLimits.maxDelaySamples)
        #expect(engine.pdcWarning?.contains("B") == true)
    }

    @Test func removingALaneTakesItsChainWithIt() async throws {
        let engine = AudioEngine()
        engine.setOutputDevice(uid: "out")
        let lane = engine.addLane(deviceUID: "mic-a", deviceChannels: [0], name: "A")
        defer { engine.shutdown() }

        let config = try await engine.addEffect(
            try AUFixtures.info(AUFixtures.delay), toLane: lane.id)
        #expect(engine.effectInstance(id: config.id) != nil)

        engine.removeLane(id: lane.id)
        #expect(engine.effects(forLane: lane.id).isEmpty)
        // Stopped, so nothing can be inside the kernel and the plug-in was
        // reclaimed and torn down immediately.
        #expect(engine.effectInstance(id: config.id) == nil)
    }

    @Test func chainOrderIsEditable() async throws {
        let engine = AudioEngine()
        engine.setOutputDevice(uid: "out")
        let lane = engine.addLane(deviceUID: "mic-a", deviceChannels: [0], name: "A")
        defer { engine.shutdown() }

        let first = try await engine.addEffect(try AUFixtures.info(AUFixtures.delay), toLane: lane.id)
        let second = try await engine.addEffect(
            try AUFixtures.info(AUFixtures.peakLimiter), toLane: lane.id)
        #expect(engine.effects(forLane: lane.id).map(\.id) == [first.id, second.id])

        engine.moveEffect(id: second.id, to: 0)
        #expect(engine.effects(forLane: lane.id).map(\.id) == [second.id, first.id])
        engine.moveEffect(id: second.id, to: 99)
        #expect(engine.effects(forLane: lane.id).map(\.id) == [first.id, second.id])
    }

    // MARK: - Session round trip

    @Test func aChainSurvivesASaveAndRestore() async throws {
        let engine = AudioEngine()
        engine.setOutputDevice(uid: "out")
        let lane = engine.addLane(deviceUID: "mic-a", deviceChannels: [0], name: "A")
        let config = try await engine.addEffect(
            try AUFixtures.info(AUFixtures.delay), toLane: lane.id)
        engine.setEffectBypass(id: config.id, true)
        let master = try await engine.addEffect(
            try AUFixtures.info(AUFixtures.peakLimiter), toLane: nil)

        // Something to notice on the other side.
        let tree = try #require(engine.effectInstance(id: config.id)?.auAudioUnit.parameterTree)
        let delayTime = try #require(
            tree.parameter(withAddress: AUParameterAddress(kDelayParam_DelayTime)))
        delayTime.value = 0.25

        let document = engine.sessionSnapshot
        let bag = try #require(document.laneExtras[lane.id.uuidString]?[EffectChainCodec.extrasKey])
        let saved = EffectChainCodec.decode(bag)
        #expect(saved.map(\.id) == [config.id])
        #expect(saved[0].bypass)
        #expect(saved[0].componentID == "aufx.dely.appl")
        #expect(saved[0].fullState != nil, "AUDelay published no state")
        // A bus carries its chain inline — format 2 no longer routes the
        // master bus's effects through `masterExtras`.
        let masterBus = try #require(document.buses.first)
        #expect(masterBus.effects.map(\.id) == [master.id])
        #expect(document.masterExtras[EffectChainCodec.extrasKey] == nil)

        // Through JSON and back, the way the session file travels.
        let round = try SessionDocument.decode(try document.jsonData())
        #expect(round.laneExtras == document.laneExtras)
        #expect(round.buses == document.buses)
        engine.shutdown()

        let reopened = AudioEngine()
        defer { reopened.shutdown() }
        let report = reopened.restore(round)
        #expect(report.pendingEffects == 2)
        await reopened.waitForEffectRestore()
        #expect(!reopened.restoringEffects)

        let restoredLane = try #require(reopened.lanes.first)
        let chain = reopened.effects(forLane: restoredLane.id)
        #expect(chain.map(\.id) == [config.id], "effect ids have to survive")
        #expect(chain[0].bypass)
        #expect(chain[0].isAvailable)
        #expect(reopened.masterEffects.map(\.id) == [master.id])

        let restoredTree = try #require(
            reopened.effectInstance(id: config.id)?.auAudioUnit.parameterTree)
        let restoredTime = try #require(
            restoredTree.parameter(withAddress: AUParameterAddress(kDelayParam_DelayTime)))
        #expect(abs(restoredTime.value - 0.25) < 1e-4, "fullState did not come back")
    }

    @Test func aPlugInThisMacDoesNotHaveBecomesAPlaceholder() async throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        let lane = LaneConfig(deviceUID: "mic-a", deviceChannels: [0], name: "A")
        let ghost = EffectConfig(
            componentID: "aufx.zzzz.zzzz",
            displayName: "Nonexistent: Ghost",
            fullState: Data([1, 2, 3, 4]))
        let document = SessionDocument(
            lanes: [lane],
            outputDeviceUID: "out",
            laneExtras: [lane.id.uuidString: [
                EffectChainCodec.extrasKey: try EffectChainCodec.encode([ghost])
            ]]
        )

        engine.restore(document)
        await engine.waitForEffectRestore()

        let chain = engine.effects(forLane: lane.id)
        #expect(chain.count == 1)
        #expect(!chain[0].isAvailable)
        #expect(chain[0].unavailableReason?.contains("aufx.zzzz.zzzz") == true)
        // Not published, so it contributes no latency and nothing to the graph.
        #expect(engine.laneChainLatency(lane.id) == 0)
        #expect(engine.effectInstance(id: ghost.id) == nil)

        // And saving again keeps the state rather than dropping it, so the
        // chain comes back on a Mac that does have the plug-in.
        let again = engine.sessionSnapshot
        let saved = EffectChainCodec.decode(
            again.laneExtras[lane.id.uuidString]?[EffectChainCodec.extrasKey])
        #expect(saved.map(\.componentID) == ["aufx.zzzz.zzzz"])
        #expect(saved[0].fullState == Data([1, 2, 3, 4]))
        #expect(saved[0].unavailableReason == nil, "a placeholder is a local fact, not a saved one")
    }

    @Test func effectConfigEncodesItsStateAsBase64() throws {
        let config = EffectConfig(
            componentID: "aufx.dely.appl",
            bypass: true,
            displayName: "Apple: AUDelay",
            fullState: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        let data = try EffectChainCodec.encode([config])
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("3q2+7w=="), "Data has to travel as base64 inside JSON")

        let decoded = EffectChainCodec.decode(data)
        #expect(decoded == [config])
        #expect(EffectChainCodec.decode(Data("not json".utf8)).isEmpty)
        #expect(EffectChainCodec.decode(nil).isEmpty)
    }

    // MARK: - Availability

    @Test func applesOwnEffectsAreReportedAsHostable() throws {
        let delay = try AUFixtures.info(AUFixtures.delay)
        #expect(AUAvailability.reason(for: delay) == nil)
        if let url = delay.bundleURL {
            let native = MachOArchitecture.bundleRunsNatively(at: url)
            #expect(native != false, "a system Audio Unit has to have this machine's slice")
        }
        #expect(MachOArchitecture.cpuTypes(inFileAt: URL(fileURLWithPath: "/etc/hosts")) == nil)
        #expect(MachOArchitecture.cpuTypes(inFileAt: URL(fileURLWithPath: "/no/such/file")) == nil)
        let shell = try #require(MachOArchitecture.cpuTypes(inFileAt: URL(fileURLWithPath: "/bin/sh")))
        #expect(shell.contains(MachOArchitecture.host))
    }
}
