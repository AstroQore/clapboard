import AudioToolbox
import ClapboardCore
import Darwin
import Foundation
import Testing

// MARK: - Signals and drivers

private let engineSampleRate = 48_000.0

private func sine(frequency: Double, frames: Int, amplitude: Float = 0.5) -> [Float] {
    (0..<frames).map { frame in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / engineSampleRate))
    }
}

private func square(frequency: Double, frames: Int, amplitude: Float = 1.0) -> [Float] {
    let period = engineSampleRate / frequency
    return (0..<frames).map { frame in
        (Double(frame).truncatingRemainder(dividingBy: period) < period / 2) ? amplitude : -amplitude
    }
}

private func peak(_ samples: [Float]) -> Float {
    samples.reduce(0) { max($0, abs($1)) }
}

/// Drive a mono lane through the plug-in in `blockSize`-frame blocks, the way
/// the IOProc will, and hand back what came out.
private func processMono(
    _ instance: AUEffectInstance,
    _ signal: [Float],
    blockSize: Int = 256
) -> [Float] {
    var buffer = signal
    buffer.withUnsafeMutableBufferPointer { pointer in
        guard let base = pointer.baseAddress else { return }
        var frame = 0
        while frame < pointer.count {
            let frames = min(blockSize, pointer.count - frame)
            instance.process(
                left: base + frame, right: nil, frames: frames, sampleTime: Int64(frame))
            frame += frames
        }
    }
    return buffer
}

private func processStereo(
    _ instance: AUEffectInstance,
    left: [Float],
    right: [Float],
    blockSize: Int = 256
) -> (left: [Float], right: [Float]) {
    var leftBuffer = left
    var rightBuffer = right
    leftBuffer.withUnsafeMutableBufferPointer { leftPointer in
        rightBuffer.withUnsafeMutableBufferPointer { rightPointer in
            guard let leftBase = leftPointer.baseAddress,
                  let rightBase = rightPointer.baseAddress else { return }
            var frame = 0
            while frame < leftPointer.count {
                let frames = min(blockSize, leftPointer.count - frame)
                instance.process(
                    left: leftBase + frame,
                    right: rightBase + frame,
                    frames: frames,
                    sampleTime: Int64(frame))
                frame += frames
            }
        }
    }
    return (leftBuffer, rightBuffer)
}

private func parameter(
    _ instance: AUEffectInstance,
    _ address: AudioUnitParameterID
) throws -> AUParameter {
    try #require(
        instance.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(address)),
        "plug-in has no parameter at address \(address)")
}

// MARK: - Tests

@Suite("AUEffectInstance")
@MainActor
struct AUEffectInstanceTests {
    @Test func aMonoDelayChangesTheSignalItIsGiven() async throws {
        let instance = try await AUEffectInstance.instantiate(
            try AUFixtures.info(AUFixtures.delay), channels: 1, sampleRate: engineSampleRate)
        defer { instance.teardown() }

        #expect(instance.componentInfo.id == "aufx.dely.appl")
        #expect(instance.laneChannels == 1)
        #expect(instance.channels == 1)
        #expect(instance.dualMono == false)
        #expect(instance.isInProcess, "an AUv2 bundle is always in-process")
        #expect(instance.isRenderable)

        try parameter(instance, AudioUnitParameterID(kDelayParam_DelayTime)).value = 0.01
        try parameter(instance, AudioUnitParameterID(kDelayParam_WetDryMix)).value = 50
        try parameter(instance, AudioUnitParameterID(kDelayParam_Feedback)).value = 50

        let input = sine(frequency: 1000, frames: 48_000)
        let output = processMono(instance, input)

        #expect(output != input, "the delay left the signal untouched")
        #expect(peak(output) > 0.01, "the delay produced silence")
        #expect(output.allSatisfy { $0.isFinite })
        #expect(instance.renderErrorCount == 0)
        #expect(instance.refusedBlockCount == 0)
        #expect(instance.renderedBlockCount == 188, "48000 frames in 256-frame blocks")
        print("[au] AUDelay mono: peak in \(peak(input)), peak out \(peak(output)), "
            + "latency \(instance.latencySamples) samples, tail \(instance.tailSeconds) s")
    }

    @Test func bypassIsABitIdenticalPassThrough() async throws {
        let instance = try await AUEffectInstance.instantiate(
            try AUFixtures.info(AUFixtures.delay), channels: 1, sampleRate: engineSampleRate)
        defer { instance.teardown() }

        try parameter(instance, AudioUnitParameterID(kDelayParam_DelayTime)).value = 0.01
        try parameter(instance, AudioUnitParameterID(kDelayParam_WetDryMix)).value = 100

        let input = sine(frequency: 1000, frames: 48_000)
        #expect(processMono(instance, input) != input)

        instance.bypass = true
        let bypassed = processMono(instance, input)
        #expect(bypassed == input, "bypass must not touch a single sample")
        #expect(instance.renderedBlockCount == 188, "bypass must not reach the plug-in")

        instance.bypass = false
        #expect(processMono(instance, input) != input, "bypass did not switch back off")
        #expect(instance.renderErrorCount == 0)
    }

    @Test func aStereoPeakLimiterReportsLatencyAndKeepsPeaksBelowUnity() async throws {
        let instance = try await AUEffectInstance.instantiate(
            try AUFixtures.info(AUFixtures.peakLimiter), channels: 2, sampleRate: engineSampleRate)
        defer { instance.teardown() }

        #expect(instance.channels == 2)
        #expect(instance.dualMono == false)

        let reported = instance.auAudioUnit.latency
        let expected = max(0, Int((reported * engineSampleRate).rounded()))
        #expect(instance.latencySamples >= 0)
        #expect(instance.latencySamples == expected,
                "latencySamples must be auAudioUnit.latency in samples")

        let input = square(frequency: 200, frames: 48_000, amplitude: 1.0)
        let output = processStereo(instance, left: input, right: input)

        #expect(peak(output.left) <= 1.0, "a peak limiter let the signal past unity")
        #expect(peak(output.right) <= 1.0)
        #expect(peak(output.left) > 0.01, "the limiter produced silence")
        #expect(output.left == output.right, "the same signal on both channels must limit the same")
        #expect(instance.renderErrorCount == 0)
        print("[au] AUPeakLimiter stereo: latency \(reported) s = \(instance.latencySamples) samples, "
            + "peak in \(peak(input)), peak out \(peak(output.left))")
    }

    @Test func fullStateRoundTripsIntoAFreshInstance() async throws {
        let info = try AUFixtures.info(AUFixtures.delay)
        let saved: Data
        let savedValue: AUValue = 0.237

        let source = try await AUEffectInstance.instantiate(
            info, channels: 1, sampleRate: engineSampleRate)
        let sourceParameter = try parameter(source, AudioUnitParameterID(kDelayParam_DelayTime))
        let defaultValue = sourceParameter.value
        sourceParameter.value = savedValue
        #expect(abs(sourceParameter.value - savedValue) < 1e-4)
        saved = try #require(source.fullState(), "AUDelay reported no fullState")
        source.teardown()

        #expect(saved.starts(with: Array("bplist00".utf8)), "fullState must be a binary plist")

        let restored = try await AUEffectInstance.instantiate(
            info, channels: 1, sampleRate: engineSampleRate)
        defer { restored.teardown() }
        #expect(abs(try parameter(restored, AudioUnitParameterID(kDelayParam_DelayTime)).value
            - defaultValue) < 1e-4, "a fresh instance should start at the default")

        try restored.restore(fullState: saved)

        let restoredValue = try parameter(restored, AudioUnitParameterID(kDelayParam_DelayTime)).value
        #expect(abs(restoredValue - savedValue) < 1e-4,
                "delay time came back as \(restoredValue), not \(savedValue)")
        print("[au] fullState: \(saved.count) bytes, delay time \(savedValue) restored as \(restoredValue)")
    }

    @Test func garbageIsRejectedRatherThanApplied() async throws {
        let instance = try await AUEffectInstance.instantiate(
            try AUFixtures.info(AUFixtures.delay), channels: 1, sampleRate: engineSampleRate)
        defer { instance.teardown() }
        #expect(throws: (any Error).self) {
            try instance.restore(fullState: Data([0x00, 0x01, 0x02, 0x03]))
        }
    }

    @Test func aMonoLaneThroughAStereoOnlyPluginRunsDualMono() async throws {
        let instance = try await AUEffectInstance.instantiate(
            try AUFixtures.info(AUFixtures.matrixReverb), channels: 1, sampleRate: engineSampleRate)
        defer { instance.teardown() }

        let capabilities = (instance.auAudioUnit.channelCapabilities ?? []).map(\.intValue)
        #expect(!AUChannelCapabilities.supports(
            inputChannels: 1, outputChannels: 1, capabilities: capabilities),
            "AUMatrixReverb was expected to refuse a mono output; it published \(capabilities)")

        #expect(instance.laneChannels == 1)
        #expect(instance.channels == 2)
        #expect(instance.dualMono)

        let input = sine(frequency: 440, frames: 24_000)
        let output = processMono(instance, input)
        #expect(output != input)
        #expect(peak(output) > 0.001, "the dual-mono path produced silence")
        #expect(output.allSatisfy { $0.isFinite })
        #expect(instance.renderErrorCount == 0)
        print("[au] AUMatrixReverb dual-mono: capabilities \(capabilities), "
            + "peak out \(peak(output))")
    }

    @Test func aBlockLargerThanTheAllocatedMaximumIsPassedThrough() async throws {
        let instance = try await AUEffectInstance.instantiate(
            try AUFixtures.info(AUFixtures.delay),
            channels: 1,
            sampleRate: engineSampleRate,
            maximumFrames: 512)
        defer { instance.teardown() }
        #expect(instance.maximumFrames == 512)

        let untouched = [Float](repeating: 0.25, count: 1024)
        var buffer = untouched
        buffer.withUnsafeMutableBufferPointer { pointer in
            instance.process(
                left: pointer.baseAddress!, right: nil, frames: 1024, sampleTime: 0)
        }
        #expect(buffer == untouched, "an oversized block must pass through untouched")
        #expect(instance.refusedBlockCount == 1)
        #expect(instance.renderedBlockCount == 0)
        #expect(instance.renderErrorCount == 0)
    }

    @Test func teardownTurnsProcessIntoAPassThrough() async throws {
        let instance = try await AUEffectInstance.instantiate(
            try AUFixtures.info(AUFixtures.delay), channels: 1, sampleRate: engineSampleRate)
        let input = sine(frequency: 1000, frames: 2048)
        #expect(processMono(instance, input) != input)

        instance.teardown()
        #expect(!instance.isRenderable)
        #expect(processMono(instance, input) == input,
                "a torn-down instance must pass audio through, not render into freed resources")
        instance.teardown()  // idempotent
    }

    /// The render path must not allocate: a `malloc` on the HAL's real-time
    /// thread is a lock, and a lock there is a dropout.
    ///
    /// A perfect check would count every `malloc` call, which needs a malloc
    /// hook and is not something to install inside a test process. What this
    /// does instead is watch the number of *live* blocks in the default zone
    /// across 20 000 render calls, which is what catches the failure modes
    /// that actually happen here: a block re-wrapped per call, an
    /// `AURenderPullInputBlock` reconstructed per call, or Objective-C
    /// autoreleased objects piling up on a thread with no pool. Per-block
    /// allocation would show up as growth proportional to the block count.
    @Test func processDoesNotAccumulateAllocations() async throws {
        let instance = try await AUEffectInstance.instantiate(
            try AUFixtures.info(AUFixtures.delay), channels: 2, sampleRate: engineSampleRate)
        defer { instance.teardown() }

        let frames = 256
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            left[index] = Float(sin(Double(index) * 0.05)) * 0.5
            right[index] = left[index]
        }

        func liveBlocks() -> UInt32 {
            var statistics = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &statistics)
            return statistics.blocks_in_use
        }

        func run(blocks: Int) {
            left.withUnsafeMutableBufferPointer { leftPointer in
                right.withUnsafeMutableBufferPointer { rightPointer in
                    for block in 0..<blocks {
                        instance.process(
                            left: leftPointer.baseAddress!,
                            right: rightPointer.baseAddress!,
                            frames: frames,
                            sampleTime: Int64(block * frames))
                    }
                }
            }
        }

        run(blocks: 2_000)  // let the plug-in settle whatever it allocates once
        let before = liveBlocks()
        run(blocks: 20_000)
        let after = liveBlocks()
        let growth = Int(after) - Int(before)

        #expect(instance.renderedBlockCount == 22_000)
        #expect(instance.renderErrorCount == 0)
        #expect(growth < 200,
                "20 000 render calls added \(growth) live heap blocks; the render path allocates")
        print("[au] 20 000 render calls: live heap blocks \(before) -> \(after) (\(growth))")
    }

    /// Third-party plug-ins are reported, never asserted on: what is installed
    /// on one machine says nothing about the next.
    @Test func reportThirdPartyPlugins() async throws {
        let others = AUCatalog.effects().filter {
            $0.componentManufacturer != kAudioUnitManufacturer_Apple
        }
        guard let candidate = others.first(where: { $0.name.hasPrefix("Ozone 9") })
            ?? others.first else {
            print("[au] no third-party effects installed")
            return
        }

        for (label, options) in [
            ("in-process", AudioComponentInstantiationOptions.loadInProcess),
            ("out-of-process", AudioComponentInstantiationOptions())
        ] {
            let outcome: String = await withCheckedContinuation { continuation in
                AUAudioUnit.instantiate(
                    with: candidate.audioComponentDescription, options: options
                ) { unit, error in
                    if let unit {
                        continuation.resume(returning:
                            "loaded (inProcess=\(unit.isLoadedInProcess), latency=\(unit.latency) s,"
                            + " tail=\(unit.tailTime) s)")
                    } else {
                        continuation.resume(returning: "failed: \(error.map { "\($0)" } ?? "no error")")
                    }
                }
            }
            print("[au] \(candidate.displayName) \(label): \(outcome)")
        }

        // And then the whole way through this host, which tries in-process
        // first and falls back on its own. On an Apple Silicon Mac an
        // Intel-only AUv2 gets as far as the hosting service and is then
        // refused, because allocating its render resources never returns.
        do {
            let instance = try await AUEffectInstance.instantiate(
                candidate, channels: 2, sampleRate: engineSampleRate)
            defer { instance.teardown() }
            let input = sine(frequency: 1000, frames: 48_000)
            let output = processStereo(instance, left: input, right: input)
            print("[au] \(candidate.displayName) through AUEffectInstance: "
                + "inProcess=\(instance.isInProcess) channels=\(instance.channels) "
                + "dualMono=\(instance.dualMono) latency=\(instance.latencySamples) samples "
                + "tail=\(instance.tailSeconds) s peakIn=\(peak(input)) "
                + "peakOut=\(peak(output.left)) renderErrors=\(instance.renderErrorCount) "
                + "blocks=\(instance.renderedBlockCount)")
        } catch let error as AUHostError {
            print("[au] \(candidate.displayName) through AUEffectInstance: refused: \(error)")
        } catch {
            print("[au] \(candidate.displayName) through AUEffectInstance: failed: \(error)")
        }
    }

    /// An Intel-only AUv2 must be refused, not hosted: macOS loads it into the
    /// Rosetta hosting service and `allocateRenderResources()` then never
    /// returns, which would wedge whichever thread asked for it. Skipped on a
    /// machine with no such plug-in installed.
    @Test func anIntelOnlyAUv2IsRefusedRatherThanHung() async throws {
        let candidates = AUCatalog.effects().filter {
            $0.componentManufacturer != kAudioUnitManufacturer_Apple && !$0.isAUv3
        }
        guard let candidate = candidates.first else {
            print("[au] no third-party AUv2 installed; nothing to refuse")
            return
        }
        do {
            let instance = try await AUEffectInstance.instantiate(
                candidate, channels: 2, sampleRate: engineSampleRate)
            instance.teardown()
            #expect(instance.isInProcess,
                    "an accepted AUv2 must be in-process")
            print("[au] \(candidate.displayName) loaded in-process; nothing to refuse")
        } catch let error as AUHostError {
            guard case let .outOfProcessV2Unsupported(refused) = error else {
                Issue.record("unexpected error hosting \(candidate.displayName): \(error)")
                return
            }
            #expect(refused.id == candidate.id)
            print("[au] refused \(candidate.displayName): \(error)")
        }
    }
}
