import ClapboardCore
import CoreAudio
import Foundation
import Testing

/// A heap `AudioBufferList` shaped like the one the HAL hands an IOProc: one
/// interleaved Float32 buffer per stream.
final class BufferListBox {
    let streams: [Int]
    let frames: Int
    private let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    init(streams: [Int], frames: Int) {
        self.streams = streams
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: max(1, streams.count))
        list.count = streams.count
        for (index, channels) in streams.enumerated() {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: channels * frames)
            samples.initialize(repeating: 0, count: channels * frames)
            storage.append(samples)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(channels * frames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(samples)
            )
        }
    }

    deinit {
        for pointer in storage { pointer.deallocate() }
        free(list.unsafeMutablePointer)
    }

    var pointer: UnsafeMutablePointer<AudioBufferList> { list.unsafeMutablePointer }

    subscript(stream: Int, channel: Int, frame: Int) -> Float {
        get { storage[stream][frame * streams[stream] + channel] }
        set { storage[stream][frame * streams[stream] + channel] = newValue }
    }

    func fill(stream: Int, channel: Int, _ body: (Int) -> Float) {
        for frame in 0..<frames { self[stream, channel, frame] = body(frame) }
    }

    func clear() {
        for (index, channels) in streams.enumerated() {
            storage[index].update(repeating: 0, count: channels * frames)
        }
    }
}

/// One lane, one stereo output stream, driven block by block.
final class Rig {
    let host = RTEngineHost()
    let input: BufferListBox
    let output: BufferListBox
    let frames: Int
    private(set) var laneIDs: [UUID] = []

    init(inputStreams: [Int], frames: Int = 256, outputChannels: Int = 2) {
        self.frames = frames
        input = BufferListBox(streams: inputStreams, frames: frames)
        output = BufferListBox(streams: [outputChannels], frames: frames)
        // 256 frames at 48 kHz, the size the engine negotiates.
        host.setMeterDecay(framesPerBlock: frames, sampleRate: 48_000)
    }

    /// `sources` are `(bufferIndex, channelInBuffer, channelsInBuffer)`.
    @discardableResult
    func addLane(sources: [(Int, Int, Int)]) -> UUID {
        let id = UUID()
        laneIDs.append(id)
        _ = host.runtime(for: id)
        return id
    }

    func publish(_ nodes: [(id: UUID, sources: [(Int, Int, Int)])], outputBufferIndex: Int = 0) {
        let laneNodes = nodes.map { entry -> RTLaneNode in
            let first = entry.sources[0]
            let second = entry.sources.count > 1 ? entry.sources[1] : nil
            return RTLaneNode(
                runtime: host.runtime(for: entry.id),
                channelCount: entry.sources.count,
                bufferIndex0: first.0,
                channelInBuffer0: first.1,
                channelsInBuffer0: first.2,
                bufferIndex1: second?.0 ?? -1,
                channelInBuffer1: second?.1 ?? 0,
                channelsInBuffer1: second?.2 ?? 0
            )
        }
        host.publish(nodes: laneNodes, outputBufferIndex: outputBufferIndex, outputChannelsInBuffer: 2)
    }

    /// Renders one block and returns the master left/right it produced.
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

    /// Renders `count` blocks, concatenating the master left channel.
    func renderBlocks(_ count: Int, beforeEach: (Int) -> Void = { _ in }) -> (left: [Float], right: [Float]) {
        var left: [Float] = []
        var right: [Float] = []
        for block in 0..<count {
            input.clear()
            beforeEach(block)
            let rendered = renderBlock()
            left.append(contentsOf: rendered.left)
            right.append(contentsOf: rendered.right)
        }
        return (left, right)
    }
}

@Suite("Render kernel")
struct RenderKernelTests {

    // (a) Delay line: an impulse comes out D frames late, and nowhere else.
    @Test func impulseArrivesAfterExactlyTheConfiguredDelay() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        let delay = 700
        rig.host.setLaneDelay(lane, samples: delay)
        rig.publish([(lane, [(0, 0, 1)])])

        // Impulse on the very first frame of the first block.
        let rendered = rig.renderBlocks(6) { block in
            if block == 0 { rig.input[0, 0, 0] = 1 }
        }
        let hits = rendered.left.enumerated().filter { $0.element != 0 }.map(\.offset)
        #expect(hits == [delay])
        #expect(rendered.left[delay] == 1)
        #expect(rendered.right[delay] == 1)
    }

    @Test func zeroDelayPassesTheBlockThroughUntouched() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])])
        rig.input.fill(stream: 0, channel: 0) { Float($0 % 7) / 7 }
        let rendered = rig.renderBlock()
        for frame in 0..<rig.frames {
            #expect(abs(rendered.left[frame] - Float(frame % 7) / 7) < 1e-6)
        }
    }

    // (b) Gain: reaches the target within one block, with no step in between.
    @Test func gainRampReachesTargetWithoutDiscontinuity() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])])

        // Block 0 at unity, block 1 ramping to −6 dB, block 2 settled.
        var blocks: [[Float]] = []
        for block in 0..<3 {
            rig.input.clear()
            rig.input.fill(stream: 0, channel: 0) { _ in 1 }
            if block == 1 { rig.host.setLaneGain(lane, linear: 0.5) }
            blocks.append(rig.renderBlock().left)
        }
        #expect(blocks[0].allSatisfy { abs($0 - 1) < 1e-6 })
        // Starts where the previous block ended, ends at (essentially) the target.
        #expect(abs(blocks[1][0] - 1) < 1e-6)
        #expect(abs(blocks[1][rig.frames - 1] - 0.5) < 0.01)
        #expect(blocks[2].allSatisfy { abs($0 - 0.5) < 1e-6 })
        // No step anywhere across the join.
        let joined = blocks[0] + blocks[1] + blocks[2]
        let biggestStep = zip(joined, joined.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(biggestStep < 0.5 / Float(rig.frames) + 1e-6)
    }

    // (c) Switching a lane off ramps to silence rather than cutting.
    @Test func disablingALaneRampsToSilence() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])])

        var blocks: [[Float]] = []
        for block in 0..<3 {
            rig.input.clear()
            rig.input.fill(stream: 0, channel: 0) { _ in 1 }
            if block == 1 { rig.host.setLaneEnabled(lane, false) }
            blocks.append(rig.renderBlock().left)
        }
        #expect(abs(blocks[1][0] - 1) < 1e-6)
        #expect(blocks[1][rig.frames - 1] < 0.01)
        #expect(blocks[2].allSatisfy { $0 == 0 })
        let ramp = blocks[1]
        let biggestStep = zip(ramp, ramp.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(biggestStep < 1.0 / Float(rig.frames) + 1e-6)
    }

    @Test func polarityInversionRampsThroughZeroInsteadOfStepping() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])])

        rig.input.fill(stream: 0, channel: 0) { _ in 1 }
        _ = rig.renderBlock()
        rig.input.clear()
        rig.input.fill(stream: 0, channel: 0) { _ in 1 }
        rig.host.setLanePolarity(lane, inverted: true)
        let ramp = rig.renderBlock().left
        #expect(abs(ramp[0] - 1) < 1e-6)
        #expect(abs(ramp[rig.frames - 1] + 1) < 0.01)
        let biggestStep = zip(ramp, ramp.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(biggestStep < 2.0 / Float(rig.frames) + 1e-6)
    }

    // (d) Routing.
    @Test func monoLaneFeedsBothMasterChannels() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])])
        rig.input.fill(stream: 0, channel: 0) { _ in 0.25 }
        let rendered = rig.renderBlock()
        #expect(rendered.left.allSatisfy { abs($0 - 0.25) < 1e-6 })
        #expect(rendered.right.allSatisfy { abs($0 - 0.25) < 1e-6 })
    }

    @Test func stereoLaneKeepsLeftAndRightApart() {
        // One interleaved stereo stream, as a Loopback device presents it.
        let rig = Rig(inputStreams: [2])
        let lane = rig.addLane(sources: [(0, 0, 2), (0, 1, 2)])
        rig.publish([(lane, [(0, 0, 2), (0, 1, 2)])])
        rig.input.fill(stream: 0, channel: 0) { _ in 0.3 }
        rig.input.fill(stream: 0, channel: 1) { _ in -0.7 }
        let rendered = rig.renderBlock()
        #expect(rendered.left.allSatisfy { abs($0 - 0.3) < 1e-6 })
        #expect(rendered.right.allSatisfy { abs($0 + 0.7) < 1e-6 })
    }

    @Test func lanesOnDifferentSubDeviceStreamsSumIntoOneMaster() {
        // Two sub-devices: a mono mic (buffer 0) and a stereo device (buffer 1).
        let rig = Rig(inputStreams: [1, 2])
        let mono = rig.addLane(sources: [(0, 0, 1)])
        let right = rig.addLane(sources: [(1, 1, 2)])
        rig.publish([(mono, [(0, 0, 1)]), (right, [(1, 1, 2)])])
        rig.input.fill(stream: 0, channel: 0) { _ in 0.1 }
        rig.input.fill(stream: 1, channel: 0) { _ in 9 }   // channel we did not select
        rig.input.fill(stream: 1, channel: 1) { _ in 0.2 }
        let rendered = rig.renderBlock()
        #expect(rendered.left.allSatisfy { abs($0 - 0.3) < 1e-6 })
        #expect(rendered.right.allSatisfy { abs($0 - 0.3) < 1e-6 })
    }

    // (e) Meters.
    @Test func metersReadMinus20dBFSForAMinus20dBFSSine() {
        // 480 frames at 48 kHz is exactly ten cycles of 1 kHz, so the block
        // RMS is the analytic one.
        let rig = Rig(inputStreams: [1], frames: 480)
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])])
        let amplitude: Float = 0.1   // −20 dBFS
        rig.input.fill(stream: 0, channel: 0) { frame in
            amplitude * sinf(2 * .pi * 1000 * Float(frame) / 48_000)
        }
        _ = rig.renderBlock()

        let lanes = rig.host.laneMeter(lane)
        #expect(abs(MeterReading.decibels(lanes.peak) + 20) < 0.1)
        // A sine's RMS sits 3.01 dB under its peak.
        #expect(abs(MeterReading.decibels(lanes.rms) + 23.01) < 0.1)

        let master = rig.host.masterMeter
        #expect(abs(MeterReading.decibels(master.peak) + 20) < 0.1)
        #expect(abs(MeterReading.decibels(master.rms) + 23.01) < 0.1)
    }

    @Test func metersReadSilenceWithNoInput() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])])
        _ = rig.renderBlock()
        #expect(rig.host.laneMeter(lane).peak == 0)
        #expect(rig.host.laneMeter(lane).peakDB == -.infinity)
        #expect(rig.host.masterMeter.peak == 0)
    }

    @Test func peakMeterDecaysInsteadOfDroppingToZero() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])])
        rig.input.fill(stream: 0, channel: 0) { _ in 1 }
        _ = rig.renderBlock()
        #expect(rig.host.laneMeter(lane).peak == 1)
        // A single silent block must not erase the reading a 30 Hz UI has
        // not polled yet.
        rig.input.clear()
        _ = rig.renderBlock()
        let decayed = rig.host.laneMeter(lane).peak
        #expect(decayed < 1 && decayed > 0.98)
    }

    // Delay changes.
    @Test func changingDelayCrossfadesWithoutAClick() {
        let rig = Rig(inputStreams: [1], frames: 256)
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.host.setLaneDelay(lane, samples: 100)
        rig.publish([(lane, [(0, 0, 1)])])

        // A slow sine so any jump from re-seeking the ring is obvious.
        let rendered = rig.renderBlocks(8) { block in
            rig.input.fill(stream: 0, channel: 0) { frame in
                sinf(2 * .pi * 200 * Float(block * 256 + frame) / 48_000)
            }
            if block == 4 { rig.host.setLaneDelay(lane, samples: 340) }
        }
        // Skip the first block: the ring starts empty, so the transition from
        // primed silence into the signal is a legitimate edge.
        let tail = Array(rendered.left.dropFirst(512))
        let biggestStep = zip(tail, tail.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        // One sample of a 200 Hz sine moves at most 0.027; a hard re-seek of
        // 240 samples would step by up to 2.
        #expect(biggestStep < 0.05)
    }

    @Test func delayIsClampedToTheRingCapacity() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.host.setLaneDelay(lane, samples: 10_000_000)
        rig.publish([(lane, [(0, 0, 1)])])
        rig.input.fill(stream: 0, channel: 0) { _ in 1 }
        let rendered = rig.renderBlock()
        // Nothing has been through the line yet, so silence — but crucially no
        // out-of-bounds read.
        #expect(rendered.left.allSatisfy { $0 == 0 })
    }

    // Robustness.
    @Test func laneWhoseDeviceVanishedRendersSilenceInsteadOfCrashing() {
        let rig = Rig(inputStreams: [1])
        let good = rig.addLane(sources: [(0, 0, 1)])
        let gone = rig.addLane(sources: [(-1, 0, 0)])
        rig.publish([(good, [(0, 0, 1)]), (gone, [(-1, 0, 0)])])
        rig.input.fill(stream: 0, channel: 0) { _ in 0.5 }
        let rendered = rig.renderBlock()
        #expect(rendered.left.allSatisfy { abs($0 - 0.5) < 1e-6 })
        #expect(rig.host.laneMeter(gone).peak == 0)
    }

    @Test func mismatchedInputBufferShapeIsIgnored() {
        // The graph says the source stream is stereo, the ABL says mono: the
        // shape the HAL hands over after a hot-plug, before we rebuild.
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 2)])
        rig.publish([(lane, [(0, 0, 2)])])
        rig.input.fill(stream: 0, channel: 0) { _ in 1 }
        let rendered = rig.renderBlock()
        #expect(rendered.left.allSatisfy { $0 == 0 })
    }

    @Test func masterGainAppliesToTheSum() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])])
        rig.host.setMasterGain(linear: 0.25)
        rig.input.fill(stream: 0, channel: 0) { _ in 1 }
        let rendered = rig.renderBlock()
        #expect(rendered.left.allSatisfy { abs($0 - 0.25) < 1e-6 })
    }

    @Test func outputBuffersOtherThanTheNominatedOneStaySilent() {
        // Two output streams: an input sub-device's own outputs first, the
        // chosen output device second. Only the second may be written.
        let rig = Rig(inputStreams: [1])
        let extra = BufferListBox(streams: [2, 2], frames: rig.frames)
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])], outputBufferIndex: 1)
        rig.input.fill(stream: 0, channel: 0) { _ in 0.4 }
        // Pre-dirty both buffers to prove the kernel clears them.
        for frame in 0..<rig.frames {
            extra[0, 0, frame] = 9
            extra[1, 0, frame] = 9
        }
        render(state: rig.host.state, input: rig.input.pointer, output: extra.pointer, frames: rig.frames)
        for frame in 0..<rig.frames {
            #expect(extra[0, 0, frame] == 0)
            #expect(extra[0, 1, frame] == 0)
            #expect(abs(extra[1, 0, frame] - 0.4) < 1e-6)
            #expect(abs(extra[1, 1, frame] - 0.4) < 1e-6)
        }
    }

    @Test func noPublishedGraphMeansSilence() {
        let rig = Rig(inputStreams: [1])
        for frame in 0..<rig.frames { rig.output[0, 0, frame] = 9 }
        render(state: rig.host.state, input: rig.input.pointer, output: rig.output.pointer, frames: rig.frames)
        for frame in 0..<rig.frames { #expect(rig.output[0, 0, frame] == 0) }
    }

    @Test func oversizedBlocksAreRefusedRatherThanOverrunningScratch() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])])
        render(
            state: rig.host.state,
            input: rig.input.pointer,
            output: rig.output.pointer,
            frames: RTLimits.maxFramesPerBlock + 1
        )
        #expect(rig.host.droppedBlocks == 1)
    }

    // Lane state must survive a graph rebuild, or every add/remove clicks.
    @Test func laneStateSurvivesAGraphRepublish() {
        let rig = Rig(inputStreams: [1, 1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.host.setLaneDelay(lane, samples: 300)
        rig.publish([(lane, [(0, 0, 1)])])

        // Push an impulse in, then add a second lane before it comes out.
        rig.input.clear()
        rig.input[0, 0, 0] = 1
        _ = rig.renderBlock()

        let second = rig.addLane(sources: [(1, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)]), (second, [(1, 0, 1)])])

        let rendered = rig.renderBlocks(2)
        // 300 − 256 = 44 frames into the block after the republish.
        #expect(rendered.left[44] == 1)
        #expect(rendered.left.enumerated().filter { $0.element != 0 }.map(\.offset) == [44])
        #expect(rig.host.retiredSnapshotCount <= 1)
    }
}
