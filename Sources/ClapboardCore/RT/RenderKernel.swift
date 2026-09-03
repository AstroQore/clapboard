import Accelerate
import CoreAudio
import Darwin
import Synchronization

/// The whole real-time signal path, as one free function so tests can drive it
/// with synthetic `AudioBufferList`s without a HAL device.
///
/// Constraints (see AGENTS.md): no allocation, no locks, no logging, no Swift
/// runtime metadata, no class references. Everything it touches hangs off
/// `state`, which the IOProc block captures by value as a single pointer.
///
/// - Parameters:
///   - state: engine-lifetime state, allocated by `RTMemory.makeState()`.
///   - input: the HAL's input `AudioBufferList` — one interleaved Float32
///     buffer per input stream, in sub-device order. May be `nil`.
///   - output: the HAL's output `AudioBufferList`. Every buffer is cleared;
///     the master mix goes into the buffer the graph nominates.
///   - frames: frames in this block.
public func render(
    state: UnsafeMutablePointer<RTState>,
    input: UnsafePointer<AudioBufferList>?,
    output: UnsafeMutablePointer<AudioBufferList>?,
    frames: Int
) {
    // Silence first: every early return below must leave the device quiet
    // rather than replaying whatever the previous cycle left in the buffers.
    if let output {
        clearOutput(output)
    }

    guard frames > 0 else { return }
    guard frames <= RTLimits.maxFramesPerBlock else {
        state.pointee.droppedBlocks.wrappingAdd(1, ordering: .relaxed)
        return
    }

    let mixLeft = state.pointee.mixLeft
    let mixRight = state.pointee.mixRight
    vDSP_vclr(mixLeft, 1, vDSP_Length(frames))
    vDSP_vclr(mixRight, 1, vDSP_Length(frames))

    guard let graphRaw = state.pointee.graph.load(ordering: .acquiring) else {
        publishMasterMeters(state: state, frames: frames, silent: true)
        return
    }
    let graph = graphRaw.assumingMemoryBound(to: RTGraph.self)
    let generation = graph.pointee.generation

    // Tell the host which graph we are inside. It frees a retired snapshot
    // only once it sees `enter == exit` with a newer generation, which can
    // only happen between two callbacks.
    state.pointee.enterGeneration.store(generation, ordering: .releasing)

    let decay = state.pointee.meterDecayPerBlock
    if let lanes = graph.pointee.lanes {
        let laneCount = graph.pointee.laneCount
        var index = 0
        while index < laneCount {
            renderLane(
                node: lanes.advanced(by: index).pointee,
                state: state,
                input: input,
                frames: frames,
                decay: decay
            )
            index += 1
        }
    }

    applyMasterGain(state: state, frames: frames)
    publishMasterMeters(state: state, frames: frames, silent: false)

    if let output {
        writeMaster(
            state: state,
            output: output,
            frames: frames,
            bufferIndex: graph.pointee.outputBufferIndex,
            channelOffset: graph.pointee.outputChannelOffset
        )
    }

    state.pointee.exitGeneration.store(generation, ordering: .releasing)
}

// MARK: - Lane

@inline(__always)
private func renderLane(
    node: RTLaneNode,
    state: UnsafeMutablePointer<RTState>,
    input: UnsafePointer<AudioBufferList>?,
    frames: Int,
    decay: Float
) {
    let runtime = node.runtime
    let capacity = RTLimits.delayCapacity
    let ring = runtime.pointee.ring
    let channels = node.channelCount < 1 ? 1 : (node.channelCount > 2 ? 2 : node.channelCount)

    // --- 1. Capture: de-interleave this block into the delay ring.
    let writeIndex = runtime.pointee.writeIndex
    var channel = 0
    while channel < channels {
        let bufferIndex = channel == 0 ? node.bufferIndex0 : node.bufferIndex1
        let channelInBuffer = channel == 0 ? node.channelInBuffer0 : node.channelInBuffer1
        let stride = channel == 0 ? node.channelsInBuffer0 : node.channelsInBuffer1
        let destination = ring.advanced(by: channel * capacity)
        let source = sourcePointer(
            input: input,
            bufferIndex: bufferIndex,
            channelInBuffer: channelInBuffer,
            stride: stride,
            frames: frames
        )
        var position = writeIndex
        var frame = 0
        if let source {
            while frame < frames {
                destination[position] = source[frame * stride]
                position += 1
                if position == capacity { position = 0 }
                frame += 1
            }
        } else {
            // Device vanished mid-block, or the HAL handed us a buffer whose
            // shape does not match the graph: feed the lane silence so the
            // delay line stays time-aligned instead of freezing.
            while frame < frames {
                destination[position] = 0
                position += 1
                if position == capacity { position = 0 }
                frame += 1
            }
        }
        channel += 1
    }
    runtime.pointee.writeIndex = (writeIndex + frames) % capacity

    // --- 2. Parameters.
    let enabled = runtime.pointee.parameters.enabled.load(ordering: .relaxed)
    let inverted = runtime.pointee.parameters.polarityInverted.load(ordering: .relaxed)
    let gain = runtime.pointee.parameters.gainLinear.load(ordering: .relaxed)
    var requestedDelay = runtime.pointee.parameters.delaySamples.load(ordering: .relaxed)
    if requestedDelay < 0 { requestedDelay = 0 }
    if requestedDelay > RTLimits.maxDelaySamples { requestedDelay = RTLimits.maxDelaySamples }

    // Polarity is folded into the gain target rather than applied as a
    // separate `* -1`: a flip then ramps through zero over one block instead
    // of stepping by 2x the signal, which would click.
    var targetGain = enabled ? gain : 0
    if inverted { targetGain = -targetGain }

    let primed = runtime.pointee.primed
    var activeDelay = runtime.pointee.activeDelay
    var previousDelay = runtime.pointee.previousDelay
    var crossfadeRemaining = runtime.pointee.crossfadeRemaining
    var smoothedGain = runtime.pointee.smoothedGain

    if !primed {
        runtime.pointee.primed = true
        smoothedGain = targetGain
        activeDelay = requestedDelay
        previousDelay = requestedDelay
        crossfadeRemaining = 0
    } else if requestedDelay != activeDelay {
        previousDelay = activeDelay
        activeDelay = requestedDelay
        crossfadeRemaining = RTLimits.crossfadeFrames
    }

    // --- 3. Playback: read the ring at the current delay, crossfading from
    // the old read head when the delay just changed.
    let laneLeft = state.pointee.laneLeft
    let laneRight = state.pointee.laneRight
    let fadeLength = Float(RTLimits.crossfadeFrames)
    let fadeStart = RTLimits.crossfadeFrames - crossfadeRemaining

    channel = 0
    while channel < channels {
        let base = ring.advanced(by: channel * capacity)
        let target = channel == 0 ? laneLeft : laneRight
        var indexA = (writeIndex + capacity - activeDelay) % capacity
        var indexB = (writeIndex + capacity - previousDelay) % capacity
        var frame = 0
        while frame < frames {
            let a = base[indexA]
            if crossfadeRemaining > frame {
                let position = Float(fadeStart + frame + 1) / fadeLength
                let mix = position > 1 ? 1 : position
                target[frame] = base[indexB] * (1 - mix) + a * mix
            } else {
                target[frame] = a
            }
            indexA += 1
            if indexA == capacity { indexA = 0 }
            indexB += 1
            if indexB == capacity { indexB = 0 }
            frame += 1
        }
        channel += 1
    }
    crossfadeRemaining = crossfadeRemaining > frames ? crossfadeRemaining - frames : 0

    // --- 4. Gain ramp across the block, then sum into the master.
    let step = (targetGain - smoothedGain) / Float(frames)
    let mixLeft = state.pointee.mixLeft
    let mixRight = state.pointee.mixRight
    var peak: Float = 0
    var sumSquares: Float = 0
    var value = smoothedGain
    var frame = 0
    if channels == 1 {
        while frame < frames {
            let sample = laneLeft[frame] * value
            let magnitude = sample < 0 ? -sample : sample
            if magnitude > peak { peak = magnitude }
            sumSquares += sample * sample
            // A mono lane feeds both master channels at unity, matching how a
            // mono source sits centred in a stereo mix.
            mixLeft[frame] += sample
            mixRight[frame] += sample
            value += step
            frame += 1
        }
    } else {
        while frame < frames {
            let left = laneLeft[frame] * value
            let right = laneRight[frame] * value
            let magnitudeL = left < 0 ? -left : left
            let magnitudeR = right < 0 ? -right : right
            if magnitudeL > peak { peak = magnitudeL }
            if magnitudeR > peak { peak = magnitudeR }
            sumSquares += left * left + right * right
            mixLeft[frame] += left
            mixRight[frame] += right
            value += step
            frame += 1
        }
    }
    smoothedGain = targetGain

    // --- 5. Commit state and meters.
    runtime.pointee.smoothedGain = smoothedGain
    runtime.pointee.activeDelay = activeDelay
    runtime.pointee.previousDelay = previousDelay
    runtime.pointee.crossfadeRemaining = crossfadeRemaining

    var hold = runtime.pointee.peakHold * decay
    if peak > hold { hold = peak }
    runtime.pointee.peakHold = hold
    runtime.pointee.parameters.meterPeak.store(hold, ordering: .relaxed)
    let meanSquare = sumSquares / Float(frames * channels)
    runtime.pointee.parameters.meterRMS.store(meanSquare > 0 ? sqrtf(meanSquare) : 0, ordering: .relaxed)
}

// MARK: - Master

@inline(__always)
private func applyMasterGain(state: UnsafeMutablePointer<RTState>, frames: Int) {
    let target = state.pointee.masterGainLinear.load(ordering: .relaxed)
    var value = state.pointee.masterSmoothedGain
    if !state.pointee.masterPrimed {
        state.pointee.masterPrimed = true
        value = target
    }
    let step = (target - value) / Float(frames)
    let mixLeft = state.pointee.mixLeft
    let mixRight = state.pointee.mixRight
    var frame = 0
    while frame < frames {
        mixLeft[frame] *= value
        mixRight[frame] *= value
        value += step
        frame += 1
    }
    state.pointee.masterSmoothedGain = target
}

@inline(__always)
private func publishMasterMeters(state: UnsafeMutablePointer<RTState>, frames: Int, silent: Bool) {
    let decay = state.pointee.meterDecayPerBlock
    var peakLeft: Float = 0
    var peakRight: Float = 0
    var sumSquares: Float = 0
    if !silent {
        let mixLeft = state.pointee.mixLeft
        let mixRight = state.pointee.mixRight
        var frame = 0
        while frame < frames {
            let left = mixLeft[frame]
            let right = mixRight[frame]
            let magnitudeL = left < 0 ? -left : left
            let magnitudeR = right < 0 ? -right : right
            if magnitudeL > peakLeft { peakLeft = magnitudeL }
            if magnitudeR > peakRight { peakRight = magnitudeR }
            sumSquares += left * left + right * right
            frame += 1
        }
    }
    var holdLeft = state.pointee.masterPeakLeft.load(ordering: .relaxed) * decay
    if peakLeft > holdLeft { holdLeft = peakLeft }
    var holdRight = state.pointee.masterPeakRight.load(ordering: .relaxed) * decay
    if peakRight > holdRight { holdRight = peakRight }
    state.pointee.masterPeakLeft.store(holdLeft, ordering: .relaxed)
    state.pointee.masterPeakRight.store(holdRight, ordering: .relaxed)
    let meanSquare = sumSquares / Float(frames * 2)
    state.pointee.masterRMS.store(meanSquare > 0 ? sqrtf(meanSquare) : 0, ordering: .relaxed)
}

// MARK: - AudioBufferList plumbing

@inline(__always)
private func clearOutput(_ output: UnsafeMutablePointer<AudioBufferList>) {
    let list = UnsafeMutableAudioBufferListPointer(output)
    var index = 0
    let count = list.count
    while index < count {
        let buffer = list[index]
        if let data = buffer.mData, buffer.mDataByteSize > 0 {
            memset(data, 0, Int(buffer.mDataByteSize))
        }
        index += 1
    }
}

/// Validates one input buffer against what the graph expects and returns a
/// pointer to the first sample of the requested channel, or nil when the shape
/// does not match (which happens for a block or two around a hot-plug).
@inline(__always)
private func sourcePointer(
    input: UnsafePointer<AudioBufferList>?,
    bufferIndex: Int,
    channelInBuffer: Int,
    stride: Int,
    frames: Int
) -> UnsafeMutablePointer<Float>? {
    guard let input, bufferIndex >= 0, stride > 0, channelInBuffer >= 0, channelInBuffer < stride else {
        return nil
    }
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard bufferIndex < list.count else { return nil }
    let buffer = list[bufferIndex]
    guard Int(buffer.mNumberChannels) == stride else { return nil }
    guard Int(buffer.mDataByteSize) >= frames * stride * MemoryLayout<Float>.size else { return nil }
    guard let data = buffer.mData else { return nil }
    return data.assumingMemoryBound(to: Float.self).advanced(by: channelInBuffer)
}

@inline(__always)
private func writeMaster(
    state: UnsafeMutablePointer<RTState>,
    output: UnsafeMutablePointer<AudioBufferList>,
    frames: Int,
    bufferIndex: Int,
    channelOffset: Int
) {
    guard bufferIndex >= 0, channelOffset >= 0 else { return }
    let list = UnsafeMutableAudioBufferListPointer(output)
    guard bufferIndex < list.count else { return }
    let buffer = list[bufferIndex]
    let channels = Int(buffer.mNumberChannels)
    guard channels > channelOffset, let data = buffer.mData else { return }
    guard Int(buffer.mDataByteSize) >= frames * channels * MemoryLayout<Float>.size else { return }
    let samples = data.assumingMemoryBound(to: Float.self)
    let mixLeft = state.pointee.mixLeft
    let mixRight = state.pointee.mixRight
    let writeRight = channels > channelOffset + 1
    var frame = 0
    while frame < frames {
        let base = frame * channels + channelOffset
        samples[base] = mixLeft[frame]
        if writeRight {
            samples[base + 1] = mixRight[frame]
        }
        frame += 1
    }
}
