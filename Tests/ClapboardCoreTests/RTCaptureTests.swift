import ClapboardCore
import CoreAudio
import Foundation
import Testing

/// Auto Sync's capture tap inside the render kernel.
///
/// The tap has to hand `ClapAligner` exactly what it documents: the lane's
/// *raw, pre-delay* input, and a common time origin across lanes — sample `n`
/// of every lane captured in the same IOProc cycle.
@Suite("RT capture")
struct RTCaptureTests {

    // (a) Raw, pre-delay: the delay line must not be in the way.
    @Test func anArmedLaneCapturesTheRawInputRatherThanTheDelayedOutput() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.host.setLaneDelay(lane, samples: 700)
        rig.publish([(lane, [(0, 0, 1)])])
        rig.host.armCapture(laneIDs: [lane], frames: 1024)

        let rendered = rig.renderBlocks(2) { block in
            if block == 0 { rig.input[0, 0, 0] = 1 }
        }
        // The mix is still silent — 700 samples have not elapsed — but the
        // capture already has the impulse at its true arrival time.
        #expect(rendered.left.allSatisfy { $0 == 0 })

        rig.host.disarmCapture()
        let captured = rig.host.drainCaptureBuffers()[lane] ?? []
        #expect(captured.count == 512)
        #expect(captured[0] == 1)
        #expect(captured.enumerated().filter { $0.element != 0 }.map(\.offset) == [0])
    }

    // (b) Common time origin: two lanes, one clock.
    @Test func twoLanesCaptureTheSameBlocksSoTheirTimelinesLineUp() {
        let rig = Rig(inputStreams: [1, 1])
        let first = rig.addLane(sources: [(0, 0, 1)])
        let second = rig.addLane(sources: [(1, 0, 1)])
        rig.publish([(first, [(0, 0, 1)]), (second, [(1, 0, 1)])])
        rig.host.armCapture(laneIDs: [first, second], frames: 2048)

        // Lane A hears a transient at absolute frame 5, lane B at 300 — a
        // whole block apart, so a per-lane origin would hide the difference.
        _ = rig.renderBlocks(3) { block in
            if block == 0 { rig.input[0, 0, 5] = 1 }
            if block == 1 { rig.input[1, 0, 44] = 1 }   // 256 + 44 = 300
        }
        rig.host.disarmCapture()
        let captured = rig.host.drainCaptureBuffers()

        #expect(captured[first]?.enumerated().filter { $0.element != 0 }.map(\.offset) == [5])
        #expect(captured[second]?.enumerated().filter { $0.element != 0 }.map(\.offset) == [300])
        #expect(captured[first]?.count == captured[second]?.count)
        #expect(rig.host.captureRequestedFrames == 0)   // freed by the drain
    }

    // (c) The kernel never allocates, so the buffer simply stops accepting.
    @Test func captureStopsAtCapacityInsteadOfGrowing() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])])
        rig.host.armCapture(laneIDs: [lane], frames: 300)

        _ = rig.renderBlocks(4) { _ in
            rig.input.fill(stream: 0, channel: 0) { _ in 0.5 }
        }
        #expect(rig.host.capturedFrameCount == 300)

        rig.host.disarmCapture()
        let captured = rig.host.drainCaptureBuffers()[lane] ?? []
        #expect(captured.count == 300)
        #expect(captured.allSatisfy { $0 == 0.5 })
    }

    @Test func progressIsPublishedAsTheCaptureFills() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])])
        rig.host.armCapture(laneIDs: [lane], frames: 1024)
        #expect(rig.host.capturedFrameCount == 0)
        #expect(rig.host.captureArmed)

        _ = rig.renderBlock()
        #expect(rig.host.capturedFrameCount == 256)
        // Readable while it is still running, which is what the take's early
        // stop watches.
        #expect(rig.host.capturedSamples(for: lane, from: 0, count: 4096).count == 256)
        _ = rig.renderBlock()
        #expect(rig.host.capturedFrameCount == 512)
        rig.host.releaseCaptureBuffers()
        #expect(!rig.host.captureArmed)
    }

    // (d) Unarmed lanes are untouched, and so are lanes left out of the take.
    @Test func anUnarmedLaneCapturesNothing() {
        let rig = Rig(inputStreams: [1, 1])
        let armed = rig.addLane(sources: [(0, 0, 1)])
        let excluded = rig.addLane(sources: [(1, 0, 1)])
        rig.publish([(armed, [(0, 0, 1)]), (excluded, [(1, 0, 1)])])
        rig.host.armCapture(laneIDs: [armed], frames: 1024)

        _ = rig.renderBlocks(2) { _ in
            rig.input.fill(stream: 0, channel: 0) { _ in 0.25 }
            rig.input.fill(stream: 1, channel: 0) { _ in 0.75 }
        }
        rig.host.disarmCapture()
        let captured = rig.host.drainCaptureBuffers()
        #expect(captured[armed]?.count == 512)
        #expect(captured[excluded] == nil)
        #expect(rig.host.capturedSamples(for: excluded, from: 0, count: 512).isEmpty)
    }

    @Test func nothingIsCapturedBeforeArmingOrAfterDisarming() {
        let rig = Rig(inputStreams: [1])
        let lane = rig.addLane(sources: [(0, 0, 1)])
        rig.publish([(lane, [(0, 0, 1)])])

        // Before: no buffer at all.
        _ = rig.renderBlocks(2) { _ in rig.input.fill(stream: 0, channel: 0) { _ in 1 } }
        #expect(rig.host.capturedSamples(for: lane, from: 0, count: 512).isEmpty)

        rig.host.armCapture(laneIDs: [lane], frames: 4096)
        _ = rig.renderBlocks(1) { _ in rig.input.fill(stream: 0, channel: 0) { _ in 0.5 } }
        rig.host.disarmCapture()
        // After: the kernel reads the flag once per block, so this block is not
        // recorded even though the buffer still exists.
        _ = rig.renderBlocks(3) { _ in rig.input.fill(stream: 0, channel: 0) { _ in 0.9 } }

        let captured = rig.host.drainCaptureBuffers()[lane] ?? []
        #expect(captured.count == 256)
        #expect(captured.allSatisfy { $0 == 0.5 })
    }

    @Test func aLaneRemovedMidCaptureDoesNotLeakItsBuffer() {
        // The runtime is retired by `discardRuntime` and freed with the next
        // snapshot; the capture buffer has to go with it.
        let rig = Rig(inputStreams: [1, 1])
        let keep = rig.addLane(sources: [(0, 0, 1)])
        let going = rig.addLane(sources: [(1, 0, 1)])
        rig.publish([(keep, [(0, 0, 1)]), (going, [(1, 0, 1)])])
        rig.host.armCapture(laneIDs: [keep, going], frames: 1024)
        _ = rig.renderBlock()

        rig.host.discardRuntime(for: going)
        rig.publish([(keep, [(0, 0, 1)])])
        _ = rig.renderBlock()
        rig.host.collectGarbage(renderThreadIdle: true)

        rig.host.disarmCapture()
        let captured = rig.host.drainCaptureBuffers()
        #expect(captured[keep]?.count == 512)
        #expect(captured[going] == nil)
    }
}
