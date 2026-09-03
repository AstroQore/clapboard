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
    /// Crossfade length when a delay changes: ~10 ms at 48 kHz. The same
    /// length is used when an effect's bypass flips.
    @inline(__always) public static var crossfadeFrames: Int { 480 }
    /// Effects one lane — or one bus — may carry. A cap exists only so the
    /// host can reject a pathological chain before it reaches the render
    /// thread; nothing in the kernel iterates a fixed number of slots.
    @inline(__always) public static var maxEffectsPerChain: Int { 16 }
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

/// Parameters a bus strip exposes to the render thread. Same shape as
/// `LaneParameters`, because a bus strip is the same console strip: gain,
/// mute, meter — plus the delay line plug-in delay compensation drives.
public struct BusParameters: ~Copyable {
    public let gainLinear = Atomic<Float>(1)
    /// Effective enable: `!muted` combined with the solo scope, computed on
    /// the main thread by `SoloLogic`.
    public let enabled = Atomic<Bool>(true)
    /// Compensation delay applied before the bus's effects, so siblings under
    /// one parent arrive together.
    public let delaySamples = Atomic<Int>(0)
    public let meterPeakLeft = Atomic<Float>(0)
    public let meterPeakRight = Atomic<Float>(0)
    public let meterRMS = Atomic<Float>(0)

    public init() {}
}

/// Everything one bus must remember between blocks.
///
/// Allocated once per bus id and kept across graph rebuilds for the same
/// reason `LaneRuntime` is: re-routing a lane must not reset an unrelated
/// bus's delay line or gain smoother, or the mix clicks on every edit.
///
/// The accumulator is where the lanes and child buses pointed at this bus sum
/// themselves; it is cleared at the top of every block before any lane runs.
public struct BusRuntime: ~Copyable {
    public var parameters = BusParameters()

    /// Stereo sum for this block, `maxFramesPerBlock` floats each.
    var accumulatorLeft: UnsafeMutablePointer<Float>
    var accumulatorRight: UnsafeMutablePointer<Float>

    /// The same planar ring the lanes use — `laneChannels * delayCapacity`
    /// floats — driven by the same crossfading read head, so a compensation
    /// change slides instead of clicking.
    var ring: UnsafeMutablePointer<Float>
    var writeIndex: Int = 0
    var activeDelay: Int = 0
    var previousDelay: Int = 0
    var crossfadeRemaining: Int = 0

    var smoothedGain: Float = 0
    var primed: Bool = false
    var peakHoldLeft: Float = 0
    var peakHoldRight: Float = 0

    init(
        accumulatorLeft: UnsafeMutablePointer<Float>,
        accumulatorRight: UnsafeMutablePointer<Float>,
        ring: UnsafeMutablePointer<Float>
    ) {
        self.accumulatorLeft = accumulatorLeft
        self.accumulatorRight = accumulatorRight
        self.ring = ring
    }
}

/// Everything one hosted effect must remember between blocks.
///
/// Allocated once per effect id by `RTEngineHost` and — like `LaneRuntime` —
/// **kept across graph rebuilds**, because the graph snapshot's slot array is
/// rebuilt from scratch on every publish. Putting the bypass crossfade in the
/// slot would therefore restart it every time an unrelated lane is added,
/// which is exactly the click the crossfade exists to prevent.
public struct EffectRuntime: ~Copyable {
    /// The bypass the user asked for.
    ///
    /// Deliberately *not* `AUEffectInstance.bypass`: that flag makes `process`
    /// return before it touches the plug-in, so a host that flipped it
    /// directly would have no wet signal left to crossfade against and the
    /// switch would step. The kernel reads this flag, crossfades towards it,
    /// and only then writes the settled value through to the instance.
    public let bypassRequested = Atomic<Bool>(false)

    /// 0 = the dry lane, 1 = the plug-in's output. Render-thread owned.
    var bypassMix: Float = 1
    /// False until the first block, which snaps the mix to its target instead
    /// of fading in from wherever the previous engine run left it.
    var primed: Bool = false

    public init() {}
}

/// One effect in a chain, as the render thread sees it.
///
/// `Unmanaged` rather than a strong reference: the render thread must not
/// touch a retain count. `RTEngineHost` holds the only strong reference and
/// keeps it until a snapshot that could reach this slot has been reclaimed —
/// the same rule that governs `LaneRuntime`.
public struct RTEffectSlot {
    public var instance: Unmanaged<AUEffectInstance>
    public var runtime: UnsafeMutablePointer<EffectRuntime>
    /// Lane channels the instance was configured for, cached so the render
    /// thread does not have to load it out of the class. 1 or 2; a mono lane
    /// running dual-mono through a stereo plug-in still reads 1, because
    /// `AUEffectInstance.process` does the doubling itself.
    public var channels: Int

    public init(
        instance: Unmanaged<AUEffectInstance>,
        runtime: UnsafeMutablePointer<EffectRuntime>,
        channels: Int
    ) {
        self.instance = instance
        self.runtime = runtime
        self.channels = channels
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
    /// 1 (mono, fed to both bus channels) or 2 (stereo).
    public var channelCount: Int
    /// Index into `RTGraph.buses` of the bus this lane sums into. `-1` marks a
    /// lane whose destination is gone; it still runs its delay line and meter
    /// but reaches nothing.
    public var busIndex: Int
    public var bufferIndex0: Int
    public var channelInBuffer0: Int
    public var channelsInBuffer0: Int
    public var bufferIndex1: Int
    public var channelInBuffer1: Int
    public var channelsInBuffer1: Int
    /// The lane's effect chain, in order, pointing into the snapshot's flat
    /// slot storage. `nil` when the lane carries no effects.
    public var effects: UnsafeMutablePointer<RTEffectSlot>?
    public var effectCount: Int

    public init(
        runtime: UnsafeMutablePointer<LaneRuntime>,
        channelCount: Int,
        busIndex: Int = -1,
        bufferIndex0: Int,
        channelInBuffer0: Int,
        channelsInBuffer0: Int,
        bufferIndex1: Int = -1,
        channelInBuffer1: Int = 0,
        channelsInBuffer1: Int = 0,
        effects: UnsafeMutablePointer<RTEffectSlot>? = nil,
        effectCount: Int = 0
    ) {
        self.runtime = runtime
        self.channelCount = channelCount
        self.busIndex = busIndex
        self.bufferIndex0 = bufferIndex0
        self.channelInBuffer0 = channelInBuffer0
        self.channelsInBuffer0 = channelsInBuffer0
        self.bufferIndex1 = bufferIndex1
        self.channelInBuffer1 = channelInBuffer1
        self.channelsInBuffer1 = channelsInBuffer1
        self.effects = effects
        self.effectCount = effectCount
    }
}

/// One bus as the render thread sees it: its persistent state, its chain, and
/// the two places its output can go.
public struct RTBusNode {
    public var runtime: UnsafeMutablePointer<BusRuntime>
    /// The bus's chain, pointing into the snapshot's flat slot storage.
    public var effects: UnsafeMutablePointer<RTEffectSlot>?
    public var effectCount: Int
    /// Index into `RTGraph.buses` of the bus this one feeds, or `-1`.
    /// Always greater than this bus's own index: the array is topological.
    public var parentBusIndex: Int
    /// Buffer in the IOProc output list this bus writes to, or `-1`.
    public var outputBufferIndex: Int
    public var outputChannelOffset: Int
    public var outputChannelsInBuffer: Int

    public init(
        runtime: UnsafeMutablePointer<BusRuntime>,
        effects: UnsafeMutablePointer<RTEffectSlot>? = nil,
        effectCount: Int = 0,
        parentBusIndex: Int = -1,
        outputBufferIndex: Int = -1,
        outputChannelOffset: Int = 0,
        outputChannelsInBuffer: Int = 0
    ) {
        self.runtime = runtime
        self.effects = effects
        self.effectCount = effectCount
        self.parentBusIndex = parentBusIndex
        self.outputBufferIndex = outputBufferIndex
        self.outputChannelOffset = outputChannelOffset
        self.outputChannelsInBuffer = outputChannelsInBuffer
    }
}

/// Immutable graph topology. Published to the render thread by atomic pointer
/// swap and never mutated once visible.
public struct RTGraph {
    public var generation: UInt64
    public var laneCount: Int
    public var lanes: UnsafeMutablePointer<RTLaneNode>?
    /// Buses in processing order: every bus comes before the bus it feeds, so
    /// one forward pass renders the whole tree.
    public var buses: UnsafeMutablePointer<RTBusNode>?
    public var busCount: Int

    /// Flat storage for every slot in the snapshot: each lane's chain in lane
    /// order, then each bus's chain in bus order. One allocation, freed with
    /// the graph; `RTLaneNode.effects` and `RTBusNode.effects` point into it.
    public var effectSlots: UnsafeMutablePointer<RTEffectSlot>?
    public var effectSlotCount: Int

    public init(
        generation: UInt64,
        laneCount: Int,
        lanes: UnsafeMutablePointer<RTLaneNode>?,
        buses: UnsafeMutablePointer<RTBusNode>? = nil,
        busCount: Int = 0,
        effectSlots: UnsafeMutablePointer<RTEffectSlot>? = nil,
        effectSlotCount: Int = 0
    ) {
        self.generation = generation
        self.laneCount = laneCount
        self.lanes = lanes
        self.buses = buses
        self.busCount = busCount
        self.effectSlots = effectSlots
        self.effectSlotCount = effectSlotCount
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

    /// Per-lane and per-bus scratch, `maxFramesPerBlock` floats each. The
    /// mix accumulators moved into `BusRuntime` when buses landed: every bus
    /// owns its own sum, and only one strip is being rendered at a time.
    var laneLeft: UnsafeMutablePointer<Float>
    var laneRight: UnsafeMutablePointer<Float>
    /// Dry copies taken while an effect's bypass is crossfading. Effects run
    /// strictly one at a time — lane chains in lane order, then each bus's
    /// chain in bus order — so one pair of buffers serves every slot in the
    /// graph.
    var fxDryLeft: UnsafeMutablePointer<Float>
    var fxDryRight: UnsafeMutablePointer<Float>

    /// Frames rendered since the engine started, handed to every plug-in as
    /// its block's sample time. Tempo-synced and modulating plug-ins need it
    /// to advance monotonically; only the render thread touches it.
    var sampleTime: Int64 = 0

    /// Peak-hold decay applied once per block. Set by the host from the
    /// negotiated block size; a fixed per-block factor keeps `powf` off the
    /// render thread.
    var meterDecayPerBlock: Float = 0.98

    init(
        laneLeft: UnsafeMutablePointer<Float>,
        laneRight: UnsafeMutablePointer<Float>,
        fxDryLeft: UnsafeMutablePointer<Float>,
        fxDryRight: UnsafeMutablePointer<Float>
    ) {
        self.laneLeft = laneLeft
        self.laneRight = laneRight
        self.fxDryLeft = fxDryLeft
        self.fxDryRight = fxDryRight
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
            laneLeft: makeSilentBuffer(count: frames),
            laneRight: makeSilentBuffer(count: frames),
            fxDryLeft: makeSilentBuffer(count: frames),
            fxDryRight: makeSilentBuffer(count: frames)
        ))
        return state
    }

    public static func destroyState(_ state: UnsafeMutablePointer<RTState>) {
        state.pointee.laneLeft.deallocate()
        state.pointee.laneRight.deallocate()
        state.pointee.fxDryLeft.deallocate()
        state.pointee.fxDryRight.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    public static func makeEffectRuntime() -> UnsafeMutablePointer<EffectRuntime> {
        let runtime = UnsafeMutablePointer<EffectRuntime>.allocate(capacity: 1)
        runtime.initialize(to: EffectRuntime())
        return runtime
    }

    public static func destroyEffectRuntime(_ runtime: UnsafeMutablePointer<EffectRuntime>) {
        runtime.deinitialize(count: 1)
        runtime.deallocate()
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

    /// Allocates one bus's persistent state: a stereo accumulator plus the same
    /// shape of delay ring a lane uses (reused for the bus's PDC delay line).
    public static func makeBusRuntime() -> UnsafeMutablePointer<BusRuntime> {
        let frames = RTLimits.maxFramesPerBlock
        let ring = makeSilentBuffer(count: RTLimits.laneChannels * RTLimits.delayCapacity)
        let runtime = UnsafeMutablePointer<BusRuntime>.allocate(capacity: 1)
        runtime.initialize(to: BusRuntime(
            accumulatorLeft: makeSilentBuffer(count: frames),
            accumulatorRight: makeSilentBuffer(count: frames),
            ring: ring
        ))
        return runtime
    }

    public static func destroyBusRuntime(_ runtime: UnsafeMutablePointer<BusRuntime>) {
        runtime.pointee.accumulatorLeft.deallocate()
        runtime.pointee.accumulatorRight.deallocate()
        runtime.pointee.ring.deallocate()
        runtime.deinitialize(count: 1)
        runtime.deallocate()
    }

    /// Allocates the snapshot's flat effect-slot storage, or `nil` when the
    /// graph carries no effects at all.
    public static func makeEffectSlots(_ slots: [RTEffectSlot]) -> UnsafeMutablePointer<RTEffectSlot>? {
        guard !slots.isEmpty else { return nil }
        let buffer = UnsafeMutablePointer<RTEffectSlot>.allocate(capacity: slots.count)
        for (index, slot) in slots.enumerated() {
            buffer.advanced(by: index).initialize(to: slot)
        }
        return buffer
    }

    /// - Parameters:
    ///   - laneNodes: lane nodes whose `effects` pointers already point into
    ///     `effectSlots` and whose `busIndex` already refers to `busNodes`.
    ///   - busNodes: bus nodes in topological order (children before
    ///     parents), whose `effects`/`parentBusIndex` are already resolved.
    ///     `RTEngineHost` does all of that patching, because it is the only
    ///     place that knows which chain and which parent belongs to which id.
    ///   - effectSlots: flat slot storage from `makeEffectSlots`, owned by the
    ///     graph from here on.
    public static func makeGraph(
        generation: UInt64,
        laneNodes: [RTLaneNode],
        busNodes: [RTBusNode],
        effectSlots: UnsafeMutablePointer<RTEffectSlot>? = nil,
        effectSlotCount: Int = 0
    ) -> (graph: UnsafeMutablePointer<RTGraph>, lanes: UnsafeMutablePointer<RTLaneNode>?, buses: UnsafeMutablePointer<RTBusNode>?) {
        var lanes: UnsafeMutablePointer<RTLaneNode>?
        if !laneNodes.isEmpty {
            let buffer = UnsafeMutablePointer<RTLaneNode>.allocate(capacity: laneNodes.count)
            for (index, node) in laneNodes.enumerated() {
                buffer.advanced(by: index).initialize(to: node)
            }
            lanes = buffer
        }
        var buses: UnsafeMutablePointer<RTBusNode>?
        if !busNodes.isEmpty {
            let buffer = UnsafeMutablePointer<RTBusNode>.allocate(capacity: busNodes.count)
            for (index, node) in busNodes.enumerated() {
                buffer.advanced(by: index).initialize(to: node)
            }
            buses = buffer
        }
        let graph = UnsafeMutablePointer<RTGraph>.allocate(capacity: 1)
        graph.initialize(to: RTGraph(
            generation: generation,
            laneCount: laneNodes.count,
            lanes: lanes,
            buses: buses,
            busCount: busNodes.count,
            effectSlots: effectSlots,
            effectSlotCount: effectSlotCount
        ))
        return (graph, lanes, buses)
    }

    public static func destroyGraph(
        _ graph: UnsafeMutablePointer<RTGraph>,
        lanes: UnsafeMutablePointer<RTLaneNode>?,
        laneCount: Int,
        buses: UnsafeMutablePointer<RTBusNode>? = nil,
        busCount: Int = 0
    ) {
        if let lanes, laneCount > 0 {
            lanes.deinitialize(count: laneCount)
            lanes.deallocate()
        }
        if let buses, busCount > 0 {
            buses.deinitialize(count: busCount)
            buses.deallocate()
        }
        // The slots themselves are trivial — an `Unmanaged` and two integers —
        // so freeing them releases nothing. The strong references live in
        // `RTEngineHost`, which is what keeps the plug-ins alive until every
        // snapshot that could reach them has been reclaimed.
        if let slots = graph.pointee.effectSlots, graph.pointee.effectSlotCount > 0 {
            slots.deinitialize(count: graph.pointee.effectSlotCount)
            slots.deallocate()
        }
        graph.deinitialize(count: 1)
        graph.deallocate()
    }
}
