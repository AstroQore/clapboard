import Darwin
import CoreAudio
import Synchronization

/// Fixed sizes the real-time path is built around.
///
/// These are computed properties on purpose: a `static let` is a lazily
/// initialised global and every read from the render thread would pay a
/// `swift_once` check. Computed properties returning a literal are folded
/// into immediate values.
public enum RTLimits {
    /// Largest block the render kernel accepts. The HAL is asked for 256, but
    /// a device may hand us more after a format change.
    @inline(__always) public static var maxFramesPerBlock: Int { 8192 }
    /// Largest per-lane delay, i.e. 1000 ms at 48 kHz.
    @inline(__always) public static var maxDelaySamples: Int { 48_000 }
    /// Frames held per lane channel. Must exceed `maxDelaySamples` by at least
    /// one block so a read head never overtakes the write head.
    @inline(__always) public static var delayCapacity: Int { 48_000 + 8192 }
    /// Channels a lane can carry (mono uses channel 0 only).
    @inline(__always) public static var laneChannels: Int { 2 }
    /// Crossfade length when a delay changes: ~10 ms at 48 kHz.
    @inline(__always) public static var crossfadeFrames: Int { 480 }
}

/// A peak/RMS pair as the UI sees it. Linear amplitude, not dB.
public struct MeterReading: Hashable, Sendable {
    public var peak: Float
    public var rms: Float

    public init(peak: Float = 0, rms: Float = 0) {
        self.peak = peak
        self.rms = rms
    }

    public static let silent = MeterReading()

    public static func decibels(_ amplitude: Float) -> Float {
        amplitude > 1e-7 ? 20 * log10f(amplitude) : -Float.infinity
    }

    public var peakDB: Float { Self.decibels(peak) }
    public var rmsDB: Float { Self.decibels(rms) }
}

/// Parameters the UI writes and the render thread reads. Every field is an
/// atomic so neither side ever blocks the other.
///
/// Noncopyable because `Atomic` is; instances live inside manually allocated
/// `LaneRuntime` storage and are never copied.
public struct LaneParameters: ~Copyable {
    /// Linear gain, already converted from dB by the host side.
    public let gainLinear = Atomic<Float>(1)
    public let delaySamples = Atomic<Int>(0)
    public let enabled = Atomic<Bool>(true)
    public let polarityInverted = Atomic<Bool>(false)
    /// Post-gain peak with a decay applied by the render thread, so a 30 Hz
    /// UI poll cannot miss a transient that happened between two frames.
    public let meterPeak = Atomic<Float>(0)
    /// Post-gain RMS of the most recent block.
    public let meterRMS = Atomic<Float>(0)

    public init() {}
}

/// Everything one lane must remember between blocks.
///
/// Allocated once per lane id and *kept across graph rebuilds*: adding or
/// removing another lane must not reset this lane's delay line, gain smoother
/// or meter, otherwise the mix clicks every time the topology changes.
public struct LaneRuntime: ~Copyable {
    public var parameters = LaneParameters()

    /// `laneChannels * delayCapacity` floats, planar: channel `c` occupies
    /// `[c * delayCapacity, (c + 1) * delayCapacity)`.
    var ring: UnsafeMutablePointer<Float>
    /// Absolute write position modulo `delayCapacity`.
    var writeIndex: Int = 0

    /// Current smoothed gain, signed: polarity is folded in so a polarity flip
    /// ramps through zero instead of stepping.
    var smoothedGain: Float = 0

    var activeDelay: Int = 0
    var previousDelay: Int = 0
    var crossfadeRemaining: Int = 0

    var peakHold: Float = 0

    /// False until the first block, which snaps the smoothers to their targets
    /// instead of ramping up from silence.
    var primed: Bool = false

    /// Auto Sync capture buffer, or `nil` on a lane the user left out of the
    /// take. Allocated and freed by `RTEngineHost` on the main thread; the
    /// render thread only appends to it, and only while `RTState.captureArmed`
    /// is set. Plain fields, not atomics: they are written before the release
    /// store that arms the capture and read after the acquire load that sees
    /// it, so the handoff is already ordered.
    var capture: UnsafeMutablePointer<Float>?
    var captureCapacity: Int = 0
    var captureWritten: Int = 0

    init(ring: UnsafeMutablePointer<Float>) {
        self.ring = ring
    }
}

/// One lane as the render thread sees it: where its samples come from and
/// which persistent state block to use.
///
/// A source is `(bufferIndex, channelInBuffer, channelsInBuffer)` because the
/// HAL hands an aggregate's input over as one interleaved `AudioBuffer` per
/// stream. `bufferIndex < 0` marks a source whose device has gone away; the
/// kernel feeds it silence rather than dropping the lane.
public struct RTLaneNode {
    public var runtime: UnsafeMutablePointer<LaneRuntime>
    /// 1 (mono, fed to both master channels) or 2 (stereo).
    public var channelCount: Int
    public var bufferIndex0: Int
    public var channelInBuffer0: Int
    public var channelsInBuffer0: Int
    public var bufferIndex1: Int
    public var channelInBuffer1: Int
    public var channelsInBuffer1: Int

    public init(
        runtime: UnsafeMutablePointer<LaneRuntime>,
        channelCount: Int,
        bufferIndex0: Int,
        channelInBuffer0: Int,
        channelsInBuffer0: Int,
        bufferIndex1: Int = -1,
        channelInBuffer1: Int = 0,
        channelsInBuffer1: Int = 0
    ) {
        self.runtime = runtime
        self.channelCount = channelCount
        self.bufferIndex0 = bufferIndex0
        self.channelInBuffer0 = channelInBuffer0
        self.channelsInBuffer0 = channelsInBuffer0
        self.bufferIndex1 = bufferIndex1
        self.channelInBuffer1 = channelInBuffer1
        self.channelsInBuffer1 = channelsInBuffer1
    }
}

/// Immutable graph topology. Published to the render thread by atomic pointer
/// swap and never mutated once visible.
public struct RTGraph {
    public var generation: UInt64
    public var laneCount: Int
    public var lanes: UnsafeMutablePointer<RTLaneNode>?
    /// Index of the output `AudioBuffer` the master mix is written into. This
    /// is *not* always 0: an input sub-device that also has output streams
    /// contributes buffers ahead of the chosen output device.
    public var outputBufferIndex: Int
    public var outputChannelsInBuffer: Int
    /// First master channel inside that buffer (0 for a plain stereo stream).
    public var outputChannelOffset: Int

    public init(
        generation: UInt64,
        laneCount: Int,
        lanes: UnsafeMutablePointer<RTLaneNode>?,
        outputBufferIndex: Int,
        outputChannelsInBuffer: Int,
        outputChannelOffset: Int = 0
    ) {
        self.generation = generation
        self.laneCount = laneCount
        self.lanes = lanes
        self.outputBufferIndex = outputBufferIndex
        self.outputChannelsInBuffer = outputChannelsInBuffer
        self.outputChannelOffset = outputChannelOffset
    }
}

/// The single value the IOProc block captures. One pointer, no class
/// references, no Swift runtime calls on the render thread.
public struct RTState: ~Copyable {
    /// Published `RTGraph` pointer. `nil` means "output silence".
    public let graph = Atomic<UnsafeMutableRawPointer?>(nil)
    /// Generation the render thread has entered, published before it reads the
    /// graph.
    public let enterGeneration = Atomic<UInt64>(0)
    /// Generation the render thread has finished with. When `enter == exit`
    /// the render thread holds no graph, which is what makes retired
    /// snapshots safe to free.
    public let exitGeneration = Atomic<UInt64>(0)

    public let masterGainLinear = Atomic<Float>(1)
    public let masterPeakLeft = Atomic<Float>(0)
    public let masterPeakRight = Atomic<Float>(0)
    public let masterRMS = Atomic<Float>(0)

    public let overloadCount = Atomic<UInt64>(0)
    public let callbackCount = Atomic<UInt64>(0)
    /// Mach absolute time of the most recent callback, for the main-thread
    /// watchdog.
    public let lastCallbackHostTime = Atomic<UInt64>(0)
    /// Blocks the kernel refused (frames larger than `maxFramesPerBlock`).
    public let droppedBlocks = Atomic<UInt64>(0)

    /// Auto Sync capture switch. Read once per block, before any lane runs, so
    /// every selected lane records the same frames of the same IOProc cycle —
    /// which is exactly the common time origin `LaneRecording` requires.
    public let captureArmed = Atomic<Bool>(false)
    /// Frames captured so far, published by the render thread for the UI's
    /// progress bar and for the host's incremental reads of the buffers.
    public let captureFrames = Atomic<Int>(0)
    /// Frames the host asked for, and the capacity of every capture buffer.
    /// Plain: written before `captureArmed` is released.
    var captureRequestedFrames: Int = 0

    /// Master accumulators, `maxFramesPerBlock` floats each.
    var mixLeft: UnsafeMutablePointer<Float>
    var mixRight: UnsafeMutablePointer<Float>
    /// Per-lane scratch, `maxFramesPerBlock` floats each.
    var laneLeft: UnsafeMutablePointer<Float>
    var laneRight: UnsafeMutablePointer<Float>

    var masterSmoothedGain: Float = 1
    var masterPrimed: Bool = false

    /// Peak-hold decay applied once per block. Set by the host from the
    /// negotiated block size; a fixed per-block factor keeps `powf` off the
    /// render thread.
    var meterDecayPerBlock: Float = 0.98

    init(
        mixLeft: UnsafeMutablePointer<Float>,
        mixRight: UnsafeMutablePointer<Float>,
        laneLeft: UnsafeMutablePointer<Float>,
        laneRight: UnsafeMutablePointer<Float>
    ) {
        self.mixLeft = mixLeft
        self.mixRight = mixRight
        self.laneLeft = laneLeft
        self.laneRight = laneRight
    }
}

/// Manual allocation helpers. Everything the render thread touches is created
/// and destroyed here, on the main thread, never inside the IOProc.
public enum RTMemory {
    public static func makeSilentBuffer(count: Int) -> UnsafeMutablePointer<Float> {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
        return pointer
    }

    public static func makeState() -> UnsafeMutablePointer<RTState> {
        let frames = RTLimits.maxFramesPerBlock
        let state = UnsafeMutablePointer<RTState>.allocate(capacity: 1)
        state.initialize(to: RTState(
            mixLeft: makeSilentBuffer(count: frames),
            mixRight: makeSilentBuffer(count: frames),
            laneLeft: makeSilentBuffer(count: frames),
            laneRight: makeSilentBuffer(count: frames)
        ))
        return state
    }

    public static func destroyState(_ state: UnsafeMutablePointer<RTState>) {
        state.pointee.mixLeft.deallocate()
        state.pointee.mixRight.deallocate()
        state.pointee.laneLeft.deallocate()
        state.pointee.laneRight.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    public static func makeLaneRuntime() -> UnsafeMutablePointer<LaneRuntime> {
        let ring = makeSilentBuffer(count: RTLimits.laneChannels * RTLimits.delayCapacity)
        let runtime = UnsafeMutablePointer<LaneRuntime>.allocate(capacity: 1)
        runtime.initialize(to: LaneRuntime(ring: ring))
        return runtime
    }

    public static func destroyLaneRuntime(_ runtime: UnsafeMutablePointer<LaneRuntime>) {
        // A lane removed mid-capture takes its capture buffer with it.
        if let capture = runtime.pointee.capture {
            capture.deallocate()
            runtime.pointee.capture = nil
        }
        runtime.pointee.ring.deallocate()
        runtime.deinitialize(count: 1)
        runtime.deallocate()
    }

    public static func makeGraph(
        generation: UInt64,
        nodes: [RTLaneNode],
        outputBufferIndex: Int,
        outputChannelsInBuffer: Int,
        outputChannelOffset: Int
    ) -> (graph: UnsafeMutablePointer<RTGraph>, lanes: UnsafeMutablePointer<RTLaneNode>?) {
        var lanes: UnsafeMutablePointer<RTLaneNode>?
        if !nodes.isEmpty {
            let buffer = UnsafeMutablePointer<RTLaneNode>.allocate(capacity: nodes.count)
            for (index, node) in nodes.enumerated() {
                buffer.advanced(by: index).initialize(to: node)
            }
            lanes = buffer
        }
        let graph = UnsafeMutablePointer<RTGraph>.allocate(capacity: 1)
        graph.initialize(to: RTGraph(
            generation: generation,
            laneCount: nodes.count,
            lanes: lanes,
            outputBufferIndex: outputBufferIndex,
            outputChannelsInBuffer: outputChannelsInBuffer,
            outputChannelOffset: outputChannelOffset
        ))
        return (graph, lanes)
    }

    public static func destroyGraph(
        _ graph: UnsafeMutablePointer<RTGraph>,
        lanes: UnsafeMutablePointer<RTLaneNode>?,
        laneCount: Int
    ) {
        if let lanes, laneCount > 0 {
            lanes.deinitialize(count: laneCount)
            lanes.deallocate()
        }
        graph.deinitialize(count: 1)
        graph.deallocate()
    }
}
