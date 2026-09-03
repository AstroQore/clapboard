import ClapboardCore
import CoreAudio
import Foundation
import Testing

/// The bus tree through the actual render kernel — accumulator clear, lane
/// fan-in, per-bus PDC/effects/gain, and fan-out into a parent accumulator or
/// an output buffer (`docs/ROUTING.md` "Processing order"). `RenderKernelTests`
/// covers the single-bus shape in detail; this file is only the multi-bus
/// wiring `Rig` cannot reach.
@Suite("Render kernel buses")
struct RenderKernelBusTests {
    /// Two lanes, each on its own child bus, both feeding one root bus that
    /// owns the output device.
    private struct Tree {
        let host = RTEngineHost()
        let input: BufferListBox
        let output: BufferListBox
        let laneA = UUID()
        let laneB = UUID()
        let busA = UUID()
        let busB = UUID()
        let master = UUID()
        let frames = 256

        init() {
            input = BufferListBox(streams: [1, 1], frames: frames)
            output = BufferListBox(streams: [2], frames: frames)
            host.setMeterDecay(framesPerBlock: frames, sampleRate: 48_000)
            _ = host.runtime(forBus: busA)
            _ = host.runtime(forBus: busB)
            _ = host.runtime(forBus: master)
        }

        /// Children first — `busA`, `busB` — then the parent, matching the
        /// topological order `RoutingGraph.order` produces.
        func publish(busADelay: Int = 0) {
            host.setBusDelay(busA, samples: busADelay)
            let laneNodes = [
                RTLaneNode(
                    runtime: host.runtime(for: laneA), channelCount: 1,
                    bufferIndex0: 0, channelInBuffer0: 0, channelsInBuffer0: 1
                ),
                RTLaneNode(
                    runtime: host.runtime(for: laneB), channelCount: 1,
                    bufferIndex0: 1, channelInBuffer0: 0, channelsInBuffer0: 1
                )
            ]
            host.publish(
                laneNodes: laneNodes,
                laneBusIDs: [busA, busB],
                buses: [
                    RTEngineHost.BusPublishInfo(id: busA, parentID: master),
                    RTEngineHost.BusPublishInfo(id: busB, parentID: master),
                    RTEngineHost.BusPublishInfo(
                        id: master, outputBufferIndex: 0, outputChannelsInBuffer: 2)
                ]
            )
        }

        @discardableResult
        func renderBlock() -> (left: [Float], right: [Float]) {
            render(state: host.state, input: input.pointer, output: output.pointer, frames: frames)
            var left = [Float](repeating: 0, count: frames)
            var right = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                left[frame] = output[0, 0, frame]
                right[frame] = output[0, 1, frame]
            }
            return (left, right)
        }
    }

    @Test func twoChildBusesSumIntoTheirParentsAccumulator() {
        let tree = Tree()
        tree.publish()
        tree.input.fill(stream: 0, channel: 0) { _ in 0.2 }
        tree.input.fill(stream: 1, channel: 0) { _ in 0.3 }
        let rendered = tree.renderBlock()

        #expect(rendered.left.allSatisfy { abs($0 - 0.5) < 1e-6 })
        #expect(rendered.right.allSatisfy { abs($0 - 0.5) < 1e-6 })
        // Each bus's own meter reflects only its own lane, not the sum.
        #expect(abs(tree.host.busMeter(tree.busA).peak - 0.2) < 1e-6)
        #expect(abs(tree.host.busMeter(tree.busB).peak - 0.3) < 1e-6)
        #expect(abs(tree.host.busMeter(tree.master).peak - 0.5) < 1e-6)
    }

    @Test func mutingAChildBusRemovesItFromTheParentButKeepsItsSiblingIntact() {
        let tree = Tree()
        tree.publish()
        tree.host.setBusEnabled(tree.busA, false)
        tree.input.fill(stream: 0, channel: 0) { _ in 0.2 }
        tree.input.fill(stream: 1, channel: 0) { _ in 0.3 }
        // Block 0 ramps busA's gain to zero across the block; block 1 starts
        // already at the settled target, so its whole output is busB alone.
        _ = tree.renderBlock()
        tree.input.clear()
        tree.input.fill(stream: 0, channel: 0) { _ in 0.2 }
        tree.input.fill(stream: 1, channel: 0) { _ in 0.3 }
        let rendered = tree.renderBlock()

        #expect(rendered.left.allSatisfy { abs($0 - 0.3) < 1e-6 })
    }

    @Test func aBusGainChangeScalesOnlyItsOwnContribution() {
        let tree = Tree()
        tree.publish()
        tree.host.setBusGain(tree.busA, linear: 0.5)
        tree.input.fill(stream: 0, channel: 0) { _ in 0.2 }
        tree.input.fill(stream: 1, channel: 0) { _ in 0.3 }
        // Block 0 ramps busA's gain from unity to 0.5; block 1 is settled.
        _ = tree.renderBlock()
        tree.input.clear()
        tree.input.fill(stream: 0, channel: 0) { _ in 0.2 }
        tree.input.fill(stream: 1, channel: 0) { _ in 0.3 }
        let rendered = tree.renderBlock()

        // busA: 0.2 * 0.5 = 0.1, busB unchanged at 0.3 -> 0.4 at the root.
        #expect(rendered.left.allSatisfy { abs($0 - 0.4) < 1e-5 })
    }

    /// A bus's own PDC delay line shifts its contribution before it reaches
    /// its parent — the mechanism `LatencyPlan` drives.
    @Test func busDelayShiftsItsContributionBeforeTheParentSeesIt() {
        let tree = Tree()
        let delay = 100
        tree.publish(busADelay: delay)

        var leftOut: [Float] = []
        for block in 0..<4 {
            tree.input.clear()
            if block == 0 { tree.input[0, 0, 0] = 1 }
            leftOut += tree.renderBlock().left
        }
        let hits = leftOut.enumerated().filter { $0.element != 0 }.map(\.offset)
        #expect(hits == [delay])
    }

    @Test func aRootBusWithNoOutputDeviceProducesNoOutputButStillMeters() {
        let tree = Tree()
        // Republish with the root bus carrying no output device at all.
        let laneNodes = [
            RTLaneNode(
                runtime: tree.host.runtime(for: tree.laneA), channelCount: 1,
                bufferIndex0: 0, channelInBuffer0: 0, channelsInBuffer0: 1
            )
        ]
        tree.host.publish(
            laneNodes: laneNodes,
            laneBusIDs: [tree.master],
            buses: [RTEngineHost.BusPublishInfo(id: tree.master)]
        )
        tree.input.fill(stream: 0, channel: 0) { _ in 0.7 }
        let rendered = tree.renderBlock()
        #expect(rendered.left.allSatisfy { $0 == 0 })
        #expect(abs(tree.host.busMeter(tree.master).peak - 0.7) < 1e-6)
    }
}
