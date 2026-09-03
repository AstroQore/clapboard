import Darwin
import Foundation
import Synchronization

/// Main-thread owner of everything the render thread reads.
///
/// It allocates `RTState`, one `LaneRuntime` per lane id, and the immutable
/// graph snapshots; it publishes a snapshot with a single atomic store and
/// reclaims retired ones only once the render thread has demonstrably moved
/// past them.
///
/// Nothing here is called from the render thread.
public final class RTEngineHost {
    private struct Retired {
        let graph: UnsafeMutablePointer<RTGraph>
        let lanes: UnsafeMutablePointer<RTLaneNode>?
        let laneCount: Int
        let generation: UInt64
        /// Lane runtimes whose lanes were removed in the publish that retired
        /// this snapshot. They can only be freed with it.
        let laneRuntimes: [UnsafeMutablePointer<LaneRuntime>]
    }

    /// The single value an IOProc block may capture.
    public let state: UnsafeMutablePointer<RTState>

    private var laneRuntimes: [UUID: UnsafeMutablePointer<LaneRuntime>] = [:]
    private var liveGraph: UnsafeMutablePointer<RTGraph>?
    private var liveLanes: UnsafeMutablePointer<RTLaneNode>?
    private var liveLaneCount = 0
    private var retired: [Retired] = []
    private var pendingRuntimeFrees: [UnsafeMutablePointer<LaneRuntime>] = []
    private var nextGeneration: UInt64 = 1
    /// Lanes that currently own an Auto Sync capture buffer.
    private var captureLaneIDs: [UUID] = []

    public init() {
        state = RTMemory.makeState()
    }

    deinit {
        // The IOProc must already be stopped; AudioDeviceStop guarantees the
        // block is not running when it returns.
        state.pointee.graph.store(nil, ordering: .releasing)
        for entry in retired {
            RTMemory.destroyGraph(entry.graph, lanes: entry.lanes, laneCount: entry.laneCount)
            for runtime in entry.laneRuntimes { RTMemory.destroyLaneRuntime(runtime) }
        }
        retired.removeAll()
        if let liveGraph {
            RTMemory.destroyGraph(liveGraph, lanes: liveLanes, laneCount: liveLaneCount)
        }
        for runtime in pendingRuntimeFrees { RTMemory.destroyLaneRuntime(runtime) }
        for runtime in laneRuntimes.values { RTMemory.destroyLaneRuntime(runtime) }
        captureLaneIDs.removeAll()
        RTMemory.destroyState(state)
    }

    // MARK: - Lane runtimes

    /// Returns the persistent state block for a lane, creating it on first
    /// use. The block outlives graph rebuilds so the delay line and gain
    /// smoother keep running while other lanes come and go.
    @discardableResult
    public func runtime(for laneID: UUID) -> UnsafeMutablePointer<LaneRuntime> {
        if let existing = laneRuntimes[laneID] { return existing }
        let created = RTMemory.makeLaneRuntime()
        laneRuntimes[laneID] = created
        return created
    }

    /// Detaches a lane's state. It is freed with the next retired snapshot,
    /// never immediately: the render thread may still be inside a callback
    /// that references it.
    public func discardRuntime(for laneID: UUID) {
        guard let runtime = laneRuntimes.removeValue(forKey: laneID) else { return }
        pendingRuntimeFrees.append(runtime)
    }

    public func hasRuntime(for laneID: UUID) -> Bool {
        laneRuntimes[laneID] != nil
    }

    // MARK: - Parameters

    public func setLaneGain(_ laneID: UUID, linear: Float) {
        laneRuntimes[laneID]?.pointee.parameters.gainLinear.store(linear, ordering: .relaxed)
    }

    public func setLaneEnabled(_ laneID: UUID, _ enabled: Bool) {
        laneRuntimes[laneID]?.pointee.parameters.enabled.store(enabled, ordering: .relaxed)
    }

    public func setLanePolarity(_ laneID: UUID, inverted: Bool) {
        laneRuntimes[laneID]?.pointee.parameters.polarityInverted.store(inverted, ordering: .relaxed)
    }

    public func setLaneDelay(_ laneID: UUID, samples: Int) {
        let clamped = max(0, min(RTLimits.maxDelaySamples, samples))
        laneRuntimes[laneID]?.pointee.parameters.delaySamples.store(clamped, ordering: .relaxed)
    }

    public func setMasterGain(linear: Float) {
        state.pointee.masterGainLinear.store(linear, ordering: .relaxed)
    }

    /// Peak-hold decay per block, derived from the negotiated block size so
    /// the render thread never calls `powf`.
    public func setMeterDecay(framesPerBlock: Int, sampleRate: Double, decibelsPerSecond: Float = 20) {
        let seconds = Float(max(1, framesPerBlock)) / Float(max(1, sampleRate))
        state.pointee.meterDecayPerBlock = powf(10, -decibelsPerSecond / 20 * seconds)
    }

    // MARK: - Meters

    public func laneMeter(_ laneID: UUID) -> MeterReading {
        guard let runtime = laneRuntimes[laneID] else { return .silent }
        return MeterReading(
            peak: runtime.pointee.parameters.meterPeak.load(ordering: .relaxed),
            rms: runtime.pointee.parameters.meterRMS.load(ordering: .relaxed)
        )
    }

    public var masterMeter: MeterReading {
        let left = state.pointee.masterPeakLeft.load(ordering: .relaxed)
        let right = state.pointee.masterPeakRight.load(ordering: .relaxed)
        return MeterReading(peak: max(left, right), rms: state.pointee.masterRMS.load(ordering: .relaxed))
    }

    public var masterPeaks: (left: Float, right: Float) {
        (state.pointee.masterPeakLeft.load(ordering: .relaxed),
         state.pointee.masterPeakRight.load(ordering: .relaxed))
    }

    public var overloadCount: Int {
        Int(state.pointee.overloadCount.load(ordering: .relaxed))
    }

    public var callbackCount: Int {
        Int(state.pointee.callbackCount.load(ordering: .relaxed))
    }

    public var droppedBlocks: Int {
        Int(state.pointee.droppedBlocks.load(ordering: .relaxed))
    }

    public var lastCallbackHostTime: UInt64 {
        state.pointee.lastCallbackHostTime.load(ordering: .relaxed)
    }

    public func resetCounters() {
        state.pointee.overloadCount.store(0, ordering: .relaxed)
        state.pointee.callbackCount.store(0, ordering: .relaxed)
        state.pointee.droppedBlocks.store(0, ordering: .relaxed)
    }

    // MARK: - Auto Sync capture

    /// Allocates one capture buffer per selected lane and arms the render
    /// thread.
    ///
    /// Every allocation happens here, before the release store the render
    /// thread acquires, so the IOProc never sees a half-built buffer and never
    /// allocates one itself. Lanes that were not selected keep `capture == nil`
    /// and are skipped by the kernel.
    ///
    /// - Returns: the lanes that actually got a buffer.
    @discardableResult
    public func armCapture(laneIDs: [UUID], frames: Int) -> [UUID] {
        releaseCaptureBuffers()
        let capacity = max(1, frames)
        var armed: [UUID] = []
        for laneID in laneIDs {
            guard let runtime = laneRuntimes[laneID], runtime.pointee.capture == nil else { continue }
            runtime.pointee.capture = RTMemory.makeSilentBuffer(count: capacity)
            runtime.pointee.captureCapacity = capacity
            runtime.pointee.captureWritten = 0
            armed.append(laneID)
        }
        captureLaneIDs = armed
        state.pointee.captureRequestedFrames = capacity
        state.pointee.captureFrames.store(0, ordering: .relaxed)
        state.pointee.captureArmed.store(!armed.isEmpty, ordering: .releasing)
        return armed
    }

    /// Stops the capture. The render thread reads the flag once per block, so
    /// a block that had already started can still be writing: wait for two
    /// further callbacks before touching the buffers.
    public func disarmCapture() {
        state.pointee.captureArmed.store(false, ordering: .releasing)
    }

    public var captureArmed: Bool {
        state.pointee.captureArmed.load(ordering: .relaxed)
    }

    /// Frames the render thread has published. Acquire ordering pairs with the
    /// kernel's release store, which is what makes reading that many samples
    /// out of a running capture safe.
    public var capturedFrameCount: Int {
        state.pointee.captureFrames.load(ordering: .acquiring)
    }

    public var captureRequestedFrames: Int {
        state.pointee.captureRequestedFrames
    }

    public var captureLanes: [UUID] { captureLaneIDs }

    /// A slice of one lane's capture, clamped to what the render thread has
    /// published. Safe to call while the capture is still running; used by the
    /// main-thread onset watcher that ends a take early.
    public func capturedSamples(for laneID: UUID, from start: Int, count: Int) -> [Float] {
        guard count > 0, start >= 0,
              let runtime = laneRuntimes[laneID],
              let capture = runtime.pointee.capture
        else { return [] }
        let available = min(capturedFrameCount, runtime.pointee.captureCapacity)
        guard start < available else { return [] }
        let length = min(count, available - start)
        return Array(UnsafeBufferPointer(start: capture.advanced(by: start), count: length))
    }

    /// Copies every armed lane's capture out and frees the buffers.
    ///
    /// Only call after `disarmCapture()` and after the render thread has
    /// demonstrably left the block that last saw the arm flag.
    public func drainCaptureBuffers() -> [UUID: [Float]] {
        var result: [UUID: [Float]] = [:]
        let published = capturedFrameCount
        for laneID in captureLaneIDs {
            guard let runtime = laneRuntimes[laneID], let capture = runtime.pointee.capture else { continue }
            let count = min(published, runtime.pointee.captureCapacity)
            result[laneID] = count > 0
                ? Array(UnsafeBufferPointer(start: capture, count: count))
                : []
        }
        releaseCaptureBuffers()
        return result
    }

    /// Frees the capture buffers without copying anything out. Same timing rule
    /// as `drainCaptureBuffers()`.
    public func releaseCaptureBuffers() {
        state.pointee.captureArmed.store(false, ordering: .releasing)
        for runtime in laneRuntimes.values {
            guard let capture = runtime.pointee.capture else { continue }
            runtime.pointee.capture = nil
            runtime.pointee.captureCapacity = 0
            runtime.pointee.captureWritten = 0
            capture.deallocate()
        }
        captureLaneIDs.removeAll(keepingCapacity: true)
        state.pointee.captureRequestedFrames = 0
        state.pointee.captureFrames.store(0, ordering: .relaxed)
    }

    // MARK: - Graph publication

    /// Publishes a new topology. The previous snapshot is retired, not freed.
    public func publish(
        nodes: [RTLaneNode],
        outputBufferIndex: Int,
        outputChannelsInBuffer: Int,
        outputChannelOffset: Int = 0
    ) {
        let generation = nextGeneration
        nextGeneration += 1
        let made = RTMemory.makeGraph(
            generation: generation,
            nodes: nodes,
            outputBufferIndex: outputBufferIndex,
            outputChannelsInBuffer: outputChannelsInBuffer,
            outputChannelOffset: outputChannelOffset
        )
        let previousGraph = liveGraph
        let previousLanes = liveLanes
        let previousCount = liveLaneCount
        let previousGeneration = previousGraph?.pointee.generation ?? 0

        liveGraph = made.graph
        liveLanes = made.lanes
        liveLaneCount = nodes.count
        state.pointee.graph.store(UnsafeMutableRawPointer(made.graph), ordering: .releasing)

        let freeing = pendingRuntimeFrees
        pendingRuntimeFrees.removeAll(keepingCapacity: true)
        if let previousGraph {
            retired.append(Retired(
                graph: previousGraph,
                lanes: previousLanes,
                laneCount: previousCount,
                generation: previousGeneration,
                laneRuntimes: freeing
            ))
        } else {
            // Nothing was published before, so nothing can be referencing the
            // discarded runtimes.
            for runtime in freeing { RTMemory.destroyLaneRuntime(runtime) }
        }
        collectGarbage()
    }

    /// Stops the render thread from seeing any graph. Call after the IOProc
    /// has stopped; everything retired then becomes free immediately.
    public func unpublish() {
        state.pointee.graph.store(nil, ordering: .releasing)
        if let liveGraph {
            retired.append(Retired(
                graph: liveGraph,
                lanes: liveLanes,
                laneCount: liveLaneCount,
                generation: liveGraph.pointee.generation,
                laneRuntimes: pendingRuntimeFrees
            ))
            pendingRuntimeFrees.removeAll(keepingCapacity: true)
        }
        liveGraph = nil
        liveLanes = nil
        liveLaneCount = 0
        collectGarbage(renderThreadIdle: true)
    }

    /// Frees retired snapshots the render thread has provably left behind.
    ///
    /// `exit` is read before `enter` on purpose: if they are equal the render
    /// thread is between callbacks, and the generation it last used tells us
    /// which snapshots it can no longer reach. Should it enter a new callback
    /// between the two loads, that callback necessarily uses the freshly
    /// published (higher) generation, so the conclusion still holds.
    public func collectGarbage(renderThreadIdle: Bool = false) {
        guard !retired.isEmpty else { return }
        let exitGeneration = state.pointee.exitGeneration.load(ordering: .acquiring)
        let enterGeneration = state.pointee.enterGeneration.load(ordering: .acquiring)
        let quiescent = renderThreadIdle || (enterGeneration == exitGeneration)
        guard quiescent else { return }
        var kept: [Retired] = []
        for entry in retired {
            if renderThreadIdle || exitGeneration > entry.generation {
                RTMemory.destroyGraph(entry.graph, lanes: entry.lanes, laneCount: entry.laneCount)
                for runtime in entry.laneRuntimes { RTMemory.destroyLaneRuntime(runtime) }
            } else {
                kept.append(entry)
            }
        }
        retired = kept
    }

    public var retiredSnapshotCount: Int { retired.count }
}
