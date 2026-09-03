import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import Synchronization

/// Everything that can go wrong between "the user picked a plug-in" and "the
/// plug-in is ready to render".
public enum AUHostError: Error, CustomStringConvertible {
    case instantiationFailed(AUComponentInfo, underlying: Error?)
    case unsupportedChannelCount(AUComponentInfo, requested: Int)
    case formatRejected(AUComponentInfo, channels: Int, underlying: Error)
    case renderResourcesFailed(AUComponentInfo, channels: Int, underlying: Error)
    /// An AUv2 bundle that would only load out of process. See
    /// `AUEffectInstance.instantiate(_:channels:sampleRate:maximumFrames:allowOutOfProcessV2:)`.
    case outOfProcessV2Unsupported(AUComponentInfo)
    case invalidState(String)

    public var description: String {
        switch self {
        case let .instantiationFailed(info, underlying):
            let reason = underlying.map { " (\($0))" } ?? ""
            return "could not instantiate \(info.displayName)\(reason)"
        case let .unsupportedChannelCount(info, requested):
            return "\(info.displayName) does not accept \(requested) channel(s)"
        case let .formatRejected(info, channels, underlying):
            return "\(info.displayName) refused a \(channels)-channel 32-bit float format (\(underlying))"
        case let .renderResourcesFailed(info, channels, underlying):
            return "\(info.displayName) failed to allocate render resources at \(channels) channel(s) (\(underlying))"
        case let .outOfProcessV2Unsupported(info):
            return "\(info.displayName) is an AUv2 plug-in that will not load into this process — "
                + "on Apple Silicon that means an Intel-only build. macOS will host it out of "
                + "process under Rosetta, but such a plug-in never finishes allocating its render "
                + "resources, so Clapboard refuses it instead of hanging. Install a version built "
                + "for Apple Silicon."
        case let .invalidState(message):
            return message
        }
    }
}

/// The POD half of a hosted plug-in: everything `process` touches.
///
/// Manually allocated and owned by `AUEffectInstance`, for the same reason
/// `RTState` is: the render thread must reach it through one pointer, without
/// loading a class reference, and `Atomic` is noncopyable so it cannot live in
/// a plain stored property that gets copied around.
struct AUProcessState: ~Copyable {
    /// Host-level hard bypass. See `AUEffectInstance.bypass`.
    let bypassed = Atomic<Bool>(false)
    /// False until render resources are allocated and again from the moment
    /// teardown starts, so a `process` call that races a teardown passes audio
    /// through instead of entering a half-torn-down plug-in.
    let renderable = Atomic<Bool>(false)
    let renderErrors = Atomic<UInt64>(0)
    let renderedBlocks = Atomic<UInt64>(0)
    let refusedBlocks = Atomic<UInt64>(0)
    let lastRenderStatus = Atomic<Int32>(0)
    /// `latency` seconds converted to samples, republished by the KVO observer.
    let latencySamples = Atomic<Int>(0)

    /// Preallocated input side. `inputList` is what the pull block hands the
    /// plug-in; `inputBuffers` is the same storage as a plain array pointer,
    /// which is what the render thread writes through.
    var inputList: UnsafeMutablePointer<AudioBufferList>
    var inputBuffers: UnsafeMutablePointer<AudioBuffer>
    var outputList: UnsafeMutablePointer<AudioBufferList>
    var outputBuffers: UnsafeMutablePointer<AudioBuffer>
    var inputStorage: UnsafeMutablePointer<Float>
    var outputStorage: UnsafeMutablePointer<Float>
    /// Channels the plug-in's busses carry: 1, or 2 for stereo and dual-mono.
    var channels: Int
    var maxFrames: Int

    init(
        inputList: UnsafeMutablePointer<AudioBufferList>,
        inputBuffers: UnsafeMutablePointer<AudioBuffer>,
        outputList: UnsafeMutablePointer<AudioBufferList>,
        outputBuffers: UnsafeMutablePointer<AudioBuffer>,
        inputStorage: UnsafeMutablePointer<Float>,
        outputStorage: UnsafeMutablePointer<Float>,
        channels: Int,
        maxFrames: Int
    ) {
        self.inputList = inputList
        self.inputBuffers = inputBuffers
        self.outputList = outputList
        self.outputBuffers = outputBuffers
        self.inputStorage = inputStorage
        self.outputStorage = outputStorage
        self.channels = channels
        self.maxFrames = maxFrames
    }
}

/// The `AudioBuffer` array inside an `AudioBufferList`.
///
/// `AudioBufferList` is a C flexible-array header — `UInt32 mNumberBuffers`
/// followed by `AudioBuffer mBuffers[1]` — so the array starts exactly one
/// `AudioBuffer` short of the end of the struct. Both operands are compile-time
/// constants, so this folds to an eight-byte offset; it exists to keep the
/// render path off `UnsafeMutableAudioBufferListPointer`'s generic collection
/// machinery.
@inline(__always)
func auBufferArray(_ list: UnsafeMutablePointer<AudioBufferList>) -> UnsafeMutablePointer<AudioBuffer> {
    UnsafeMutableRawPointer(list)
        .advanced(by: MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size)
        .assumingMemoryBound(to: AudioBuffer.self)
}

/// One Audio Unit effect, instantiated and ready to be handed blocks of audio.
///
/// Lifecycle — instantiation, UI, presets, teardown — is main-thread work and
/// marked `@MainActor`. `process` is the only member the render thread calls,
/// and it is deliberately not isolated: it reads nothing but the pointer to
/// `AUProcessState`, two preallocated buffer lists and the cached render block.
///
/// ## Contract with the render thread
///
/// The instance must be published to the render graph only after
/// `instantiate` has returned, and **unpublished before it is released**:
/// `deinit` deallocates the plug-in's render resources and frees the buffer
/// lists `process` writes into, and nothing here can tell whether a render
/// thread is still inside `process`. M4 part 2's graph snapshot swap — publish
/// the new snapshot, wait for the render thread's generation counter to pass
/// it, then release the old one — is what makes that safe; `RTState`'s
/// `enterGeneration` / `exitGeneration` pair already implements exactly this
/// hand-off for lanes.
public final class AUEffectInstance: @unchecked Sendable {
    /// Which plug-in this is, for the UI, the session file and error messages.
    public let componentInfo: AUComponentInfo
    /// The hosted unit. Public because parameters, presets and the view all
    /// live on it — touch it from the main thread only.
    public let auAudioUnit: AUAudioUnit

    /// Channels the lane hands to `process`: 1 or 2.
    public let laneChannels: Int
    /// Channels the plug-in's busses are configured with.
    public let channels: Int
    /// A mono lane running through a plug-in that refused a mono
    /// configuration. `process` writes the lane to both input channels and
    /// takes the left output channel back.
    public let dualMono: Bool
    /// `false` when the plug-in had to be loaded into a separate process,
    /// which costs an IPC hop per block. AUv2 bundles are always in-process.
    public let isInProcess: Bool
    public let sampleRate: Double
    public let maximumFrames: Int

    /// Called on the main actor whenever the plug-in reports a new latency, so
    /// M4 part 2 can recompute plug-in delay compensation. Also fired once
    /// with the initial value.
    @MainActor public var onLatencyChange: ((Int) -> Void)?

    private let state: UnsafeMutablePointer<AUProcessState>
    /// Cached once: `AUAudioUnit.renderBlock` is documented as expensive to
    /// fetch and must not be fetched on the render thread.
    private let renderBlock: AURenderBlock
    /// Built once, at instantiation. It captures four POD values — never
    /// `self` — so invoking it costs no reference counting.
    private let pullInput: AURenderPullInputBlock
    private var latencyObservation: NSKeyValueObservation?
    private var isTornDown = false

    private init(
        componentInfo: AUComponentInfo,
        auAudioUnit: AUAudioUnit,
        laneChannels: Int,
        plan: AUChannelPlan,
        sampleRate: Double,
        maximumFrames: Int
    ) {
        self.componentInfo = componentInfo
        self.auAudioUnit = auAudioUnit
        self.laneChannels = laneChannels
        self.channels = plan.channels
        self.dualMono = plan.dualMono
        self.isInProcess = auAudioUnit.isLoadedInProcess
        self.sampleRate = sampleRate
        self.maximumFrames = maximumFrames

        let channels = plan.channels
        let inputStorage = UnsafeMutablePointer<Float>.allocate(capacity: channels * maximumFrames)
        inputStorage.initialize(repeating: 0, count: channels * maximumFrames)
        let outputStorage = UnsafeMutablePointer<Float>.allocate(capacity: channels * maximumFrames)
        outputStorage.initialize(repeating: 0, count: channels * maximumFrames)

        let inputList = Self.makeBufferList(
            channels: channels, frames: maximumFrames, storage: inputStorage)
        let outputList = Self.makeBufferList(
            channels: channels, frames: maximumFrames, storage: outputStorage)

        let allocated = UnsafeMutablePointer<AUProcessState>.allocate(capacity: 1)
        allocated.initialize(to: AUProcessState(
            inputList: inputList,
            inputBuffers: auBufferArray(inputList),
            outputList: outputList,
            outputBuffers: auBufferArray(outputList),
            inputStorage: inputStorage,
            outputStorage: outputStorage,
            channels: channels,
            maxFrames: maximumFrames
        ))
        state = allocated

        renderBlock = auAudioUnit.renderBlock

        // Captures the buffer pointer, the channel count and the frame limit
        // by value. No `self`, no allocation, nothing to retain.
        let inputBuffers = auBufferArray(inputList)
        let maxFrames = maximumFrames
        pullInput = { _, _, frameCount, _, inputData in
            let frames = Int(frameCount)
            if frames > maxFrames { return kAudioUnitErr_TooManyFramesToProcess }
            let bytes = UInt32(frames * MemoryLayout<Float>.size)
            let destination = auBufferArray(inputData)
            let destinationCount = Int(inputData.pointee.mNumberBuffers)
            var index = 0
            while index < destinationCount {
                // The plug-in either hands us an empty buffer list to fill in
                // (the common case, and free: we lend it our own storage), or
                // one that already points at its own memory, which has to be
                // copied into.
                if index < channels {
                    if destination[index].mData == nil {
                        destination[index].mData = inputBuffers[index].mData
                        destination[index].mNumberChannels = 1
                        destination[index].mDataByteSize = bytes
                    } else if let source = inputBuffers[index].mData {
                        let capacity = Int(destination[index].mDataByteSize)
                        memcpy(destination[index].mData!, source, min(capacity, Int(bytes)))
                        destination[index].mDataByteSize = bytes
                    }
                } else if let extra = destination[index].mData {
                    // A plug-in asking for more input channels than we
                    // configured gets silence rather than stale memory.
                    memset(extra, 0, Int(min(destination[index].mDataByteSize, bytes)))
                    destination[index].mDataByteSize = bytes
                }
                index += 1
            }
            return noErr
        }
    }

    deinit {
        // Not `teardown()`: that is main-actor isolated because it talks to the
        // plug-in, and a deinit has no actor. The same calls are safe here
        // because the contract above says no render thread can still be inside
        // `process`.
        state.pointee.renderable.store(false, ordering: .releasing)
        latencyObservation?.invalidate()
        latencyObservation = nil
        if !isTornDown {
            auAudioUnit.reset()
            if auAudioUnit.renderResourcesAllocated {
                auAudioUnit.deallocateRenderResources()
            }
        }
        free(state.pointee.inputList)
        free(state.pointee.outputList)
        state.pointee.inputStorage.deallocate()
        state.pointee.outputStorage.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    // MARK: - Instantiation

    /// Load a plug-in and get it ready to render.
    ///
    /// Main-actor because AUv2 plug-ins routinely touch AppKit while
    /// initialising, and because the completion handler ordering below is only
    /// simple if one thread owns it.
    ///
    /// - Parameters:
    ///   - info: the plug-in, from `AUCatalog`.
    ///   - channels: the lane's channel count, 1 or 2.
    ///   - sampleRate: the engine's sample rate.
    ///   - maximumFrames: the largest block `process` will ever be handed.
    ///     Defaults to `RTLimits.maxFramesPerBlock` so a HAL format change
    ///     cannot hand the plug-in more frames than it allocated for.
    @MainActor
    public static func instantiate(
        _ info: AUComponentInfo,
        channels: Int,
        sampleRate: Double,
        maximumFrames: Int = RTLimits.maxFramesPerBlock,
        allowOutOfProcessV2: Bool = false
    ) async throws -> AUEffectInstance {
        guard channels == 1 || channels == 2 else {
            throw AUHostError.unsupportedChannelCount(info, requested: channels)
        }
        guard maximumFrames > 0, maximumFrames <= RTLimits.maxFramesPerBlock else {
            throw AUHostError.invalidState(
                "maximumFrames \(maximumFrames) outside 1...\(RTLimits.maxFramesPerBlock)")
        }

        let unit = try await loadAudioUnit(info)

        // An AUv2 bundle is in-process or it is nothing. If it had to fall
        // back to the hosting service, it is a plug-in whose binary does not
        // contain this machine's architecture — every third-party effect on an
        // Apple Silicon Mac that still ships x86_64 only. macOS *will*
        // instantiate it there under Rosetta, and then
        // `allocateRenderResources()` never returns, which would wedge the
        // main thread with no way back. Refusing it costs the user a legible
        // error instead of a beachball.
        if !info.isAUv3, !unit.isLoadedInProcess, !allowOutOfProcessV2 {
            throw AUHostError.outOfProcessV2Unsupported(info)
        }

        let capabilities = (unit.channelCapabilities ?? []).map(\.intValue)
        var plan = AUChannelCapabilities.plan(forLaneChannels: channels, capabilities: capabilities)
        do {
            try configure(unit, info: info, plan: plan, sampleRate: sampleRate, maximumFrames: maximumFrames)
        } catch {
            // `channelCapabilities` is advisory and plenty of plug-ins publish
            // nothing at all, so a refused mono configuration is retried as
            // dual-mono before it becomes an error.
            guard plan.channels == 1 else { throw error }
            unit.reset()
            plan = AUChannelPlan(channels: 2, dualMono: true)
            try configure(unit, info: info, plan: plan, sampleRate: sampleRate, maximumFrames: maximumFrames)
        }

        let instance = AUEffectInstance(
            componentInfo: info,
            auAudioUnit: unit,
            laneChannels: channels,
            plan: plan,
            sampleRate: sampleRate,
            maximumFrames: maximumFrames
        )
        instance.startObservingLatency()
        instance.state.pointee.renderable.store(true, ordering: .releasing)
        return instance
    }

    /// In-process first: an AUv2 bundle is in-process either way, and an AUv3
    /// that can load in-process saves an IPC hop per block. Out-of-process is
    /// the fallback, not the default.
    @MainActor
    private static func loadAudioUnit(_ info: AUComponentInfo) async throws -> AUAudioUnit {
        let description = info.audioComponentDescription
        do {
            return try await makeAudioUnit(description, options: .loadInProcess)
        } catch {
            do {
                return try await makeAudioUnit(description, options: [])
            } catch {
                throw AUHostError.instantiationFailed(info, underlying: error)
            }
        }
    }

    private static func makeAudioUnit(
        _ description: AudioComponentDescription,
        options: AudioComponentInstantiationOptions
    ) async throws -> AUAudioUnit {
        try await withCheckedThrowingContinuation { continuation in
            AUAudioUnit.instantiate(with: description, options: options) { unit, error in
                if let unit {
                    continuation.resume(returning: unit)
                } else {
                    continuation.resume(
                        throwing: error ?? AUHostError.invalidState("instantiate returned no unit"))
                }
            }
        }
    }

    /// Format, then frame limit, then resources — in that order. `AUAudioUnit`
    /// sizes its internal buffers inside `allocateRenderResources()`, so
    /// `maximumFramesToRender` set afterwards is a promise the plug-in has
    /// already broken.
    @MainActor
    private static func configure(
        _ unit: AUAudioUnit,
        info: AUComponentInfo,
        plan: AUChannelPlan,
        sampleRate: Double,
        maximumFrames: Int
    ) throws {
        if unit.renderResourcesAllocated { unit.deallocateRenderResources() }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(plan.channels)
        ) else {
            throw AUHostError.unsupportedChannelCount(info, requested: plan.channels)
        }
        // Bus 0 of each scope. An effect always has both; a plug-in that
        // publishes neither is not something this host can drive.
        guard unit.inputBusses.count > 0, unit.outputBusses.count > 0 else {
            throw AUHostError.invalidState(
                "\(info.displayName) publishes \(unit.inputBusses.count) input and "
                    + "\(unit.outputBusses.count) output busses")
        }
        do {
            let input = unit.inputBusses[0]
            try input.setFormat(format)
            input.isEnabled = true
            let output = unit.outputBusses[0]
            try output.setFormat(format)
            output.isEnabled = true
        } catch {
            throw AUHostError.formatRejected(info, channels: plan.channels, underlying: error)
        }

        unit.maximumFramesToRender = AUAudioFrameCount(maximumFrames)
        do {
            try unit.allocateRenderResources()
        } catch {
            throw AUHostError.renderResourcesFailed(info, channels: plan.channels, underlying: error)
        }
    }

    private static func makeBufferList(
        channels: Int,
        frames: Int,
        storage: UnsafeMutablePointer<Float>
    ) -> UnsafeMutablePointer<AudioBufferList> {
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        list.count = channels
        for channel in 0..<channels {
            list[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(storage.advanced(by: channel * frames))
            )
        }
        return list.unsafeMutablePointer
    }

    // MARK: - Real-time entry point

    /// Run one block of a lane through the plug-in, in place.
    ///
    /// Safe to call from the HAL's render thread once `instantiate` has
    /// returned. Every buffer it touches was allocated at instantiation; it
    /// takes no locks, allocates nothing, logs nothing and loads no class
    /// references beyond the two cached blocks.
    ///
    /// - Parameters:
    ///   - left: the lane's first channel, read and written in place.
    ///   - right: the second channel, or `nil` for a mono lane.
    ///   - frames: frames in this block, at most `maximumFrames`.
    ///   - sampleTime: the block's sample time, passed straight to the
    ///     plug-in — tempo-synced and modulating plug-ins need it to be
    ///     monotonic across blocks.
    public func process(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>?,
        frames: Int,
        sampleTime: Int64
    ) {
        guard frames > 0 else { return }
        guard frames <= state.pointee.maxFrames else {
            state.pointee.refusedBlocks.wrappingAdd(1, ordering: .relaxed)
            return
        }
        // Both early-outs leave the caller's buffers untouched, which is a
        // sample-exact pass-through.
        guard state.pointee.renderable.load(ordering: .acquiring) else { return }
        guard !state.pointee.bypassed.load(ordering: .relaxed) else { return }

        let channels = state.pointee.channels
        let maxFrames = state.pointee.maxFrames
        let byteCount = frames * MemoryLayout<Float>.size
        let inputStorage = state.pointee.inputStorage
        let outputStorage = state.pointee.outputStorage
        let inputBuffers = state.pointee.inputBuffers
        let outputBuffers = state.pointee.outputBuffers

        // Lane -> preallocated planar input. A mono lane feeding a stereo
        // plug-in (dual mono) goes to both channels.
        memcpy(inputStorage, left, byteCount)
        inputBuffers[0].mDataByteSize = UInt32(byteCount)
        if channels == 2 {
            memcpy(inputStorage.advanced(by: maxFrames), right ?? left, byteCount)
            inputBuffers[1].mDataByteSize = UInt32(byteCount)
        }

        // A plug-in is allowed to hand back its own buffers by replacing
        // `mData`, so the output list is restored to our storage every block
        // rather than assumed to have survived the last one.
        state.pointee.outputList.pointee.mNumberBuffers = UInt32(channels)
        var channel = 0
        while channel < channels {
            outputBuffers[channel].mNumberChannels = 1
            outputBuffers[channel].mDataByteSize = UInt32(byteCount)
            outputBuffers[channel].mData =
                UnsafeMutableRawPointer(outputStorage.advanced(by: channel * maxFrames))
            channel += 1
        }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = Double(sampleTime)
        timestamp.mFlags = .sampleTimeValid

        let status = renderBlock(
            &flags,
            &timestamp,
            AUAudioFrameCount(frames),
            0,
            state.pointee.outputList,
            pullInput
        )

        guard status == noErr else {
            state.pointee.renderErrors.wrappingAdd(1, ordering: .relaxed)
            state.pointee.lastRenderStatus.store(status, ordering: .relaxed)
            // A plug-in that failed mid-block has left the output buffers in
            // an unknown state; silence is the only safe thing to hand the mix.
            memset(left, 0, byteCount)
            if let right { memset(right, 0, byteCount) }
            return
        }

        // Read `mData` back rather than reusing our pointer: see above.
        if let produced = outputBuffers[0].mData {
            memcpy(left, produced, byteCount)
        }
        if let right, channels == 2, let produced = outputBuffers[1].mData {
            memcpy(right, produced, byteCount)
        }
        state.pointee.renderedBlocks.wrappingAdd(1, ordering: .relaxed)
    }

    // MARK: - Reporting

    /// Host-level hard bypass: `process` returns before it touches the
    /// plug-in, so the lane is passed through bit for bit.
    ///
    /// Deliberately *not* `AUAudioUnit.shouldBypassEffect`. That keeps the
    /// plug-in rendering, which preserves its tail but also its latency — the
    /// signal still comes out `latency` samples late, so switching it on and
    /// off would shift the lane against the others and defeat the point of
    /// Auto Sync. Part 2 crossfades around this flag to avoid a click.
    public var bypass: Bool {
        get { state.pointee.bypassed.load(ordering: .relaxed) }
        set { state.pointee.bypassed.store(newValue, ordering: .relaxed) }
    }

    /// The plug-in's reported latency in samples at the engine's sample rate.
    /// Updated by KVO; readable from any thread.
    public var latencySamples: Int {
        state.pointee.latencySamples.load(ordering: .relaxed)
    }

    /// How long the plug-in keeps producing output after its input stops.
    /// Main thread only.
    @MainActor public var tailSeconds: TimeInterval { auAudioUnit.tailTime }

    /// Blocks the plug-in refused to render. Non-zero means a lane is silent.
    public var renderErrorCount: UInt64 { state.pointee.renderErrors.load(ordering: .relaxed) }
    /// Blocks handed to `process` that were larger than `maximumFrames` and
    /// were therefore passed through untouched.
    public var refusedBlockCount: UInt64 { state.pointee.refusedBlocks.load(ordering: .relaxed) }
    public var renderedBlockCount: UInt64 { state.pointee.renderedBlocks.load(ordering: .relaxed) }
    public var lastRenderStatus: OSStatus { state.pointee.lastRenderStatus.load(ordering: .relaxed) }
    public var isRenderable: Bool { state.pointee.renderable.load(ordering: .acquiring) }

    // MARK: - State

    /// The plug-in's full state as a binary property list, ready to go into
    /// `SessionDocument.laneExtras`.
    ///
    /// Binary rather than XML because a plug-in's state is routinely hundreds
    /// of kilobytes of coefficients, and the session file is JSON with these
    /// blobs base64-encoded inside it.
    @MainActor
    public func fullState() -> Data? {
        guard let state = auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: state, format: .binary, options: 0)
    }

    /// Restore what `fullState()` returned. A blob that does not decode is
    /// reported rather than applied, so one corrupt plug-in state cannot take
    /// a session down with it.
    @MainActor
    public func restore(fullState data: Data) throws {
        let decoded = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        guard let dictionary = decoded as? [String: Any] else {
            throw AUHostError.invalidState(
                "\(componentInfo.displayName): fullState is not a dictionary")
        }
        auAudioUnit.fullState = dictionary
    }

    // MARK: - Lifecycle

    /// Clear the plug-in's tail. Call when a lane is re-inserted or the engine
    /// restarts, never while the render thread can be inside `process`.
    @MainActor
    public func reset() {
        auAudioUnit.reset()
    }

    /// Release the plug-in's render resources.
    ///
    /// The caller must have unpublished the instance from the render graph
    /// first — see the type's contract. `process` becomes a pass-through from
    /// the moment this is entered.
    @MainActor
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        state.pointee.renderable.store(false, ordering: .releasing)
        latencyObservation?.invalidate()
        latencyObservation = nil
        auAudioUnit.reset()
        if auAudioUnit.renderResourcesAllocated {
            auAudioUnit.deallocateRenderResources()
        }
    }

    /// A plug-in may change its latency at any time — a linear-phase EQ that
    /// switches filter mode, a look-ahead limiter whose window is a parameter —
    /// and the host has to notice, because M4's delay compensation is computed
    /// from it.
    @MainActor
    private func startObservingLatency() {
        publishLatency(auAudioUnit.latency)
        latencyObservation = auAudioUnit.observe(\.latency, options: [.new]) { [weak self] unit, _ in
            guard let self else { return }
            let seconds = unit.latency
            let samples = self.publishLatency(seconds)
            // KVO fires on whichever thread the plug-in changed the value on.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onLatencyChange?(samples) }
            }
        }
    }

    @discardableResult
    private func publishLatency(_ seconds: TimeInterval) -> Int {
        let samples = max(0, Int((seconds * sampleRate).rounded()))
        state.pointee.latencySamples.store(samples, ordering: .relaxed)
        return samples
    }
}
