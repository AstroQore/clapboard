import Foundation

/// Result of running the RMS envelope onset detector over one lane.
struct OnsetAnalysis {
    enum Failure {
        /// Nothing but digital silence (or below `silenceThreshold`).
        case silent
        /// There is signal, but nothing that rises steeply out of the noise.
        case noTransient
        /// Fewer samples than the analyser needs.
        case tooShort

        var reason: String {
            switch self {
            case .silent: return "silent"
            case .noTransient: return "no transient found"
            case .tooShort: return "recording too short"
            }
        }
    }

    /// Frame-wise RMS, one value every `hop` samples over a `window`-sample
    /// span. Kept so the UI can draw the envelope next to the result.
    let envelope: [Double]
    let hop: Int
    let window: Int
    /// Median RMS of the clap-free head of the recording.
    let noiseFloor: Double
    let peakAmplitude: Float
    /// First sample of the frame where the transient crosses the threshold.
    let onsetSample: Int?
    let onsetSNRdB: Double?
    let failure: Failure?

    var hasOnset: Bool { onsetSample != nil }
}

/// Coarse "when did the clap arrive" detector.
///
/// A 1 ms RMS envelope is compared against the median RMS of the recording's
/// first `noiseFloorSeconds`. The onset is the first frame that is both
/// `minOnsetSNRdB` above that floor and at least `riseFactor` above the recent
/// past, which keeps slow swells (music, a fan spinning up) from registering
/// as transients.
enum OnsetDetector {
    /// Frames of history a candidate frame is compared against for steepness.
    static let riseHistorySeconds = 0.005
    /// How much a frame must exceed its recent history to count as a rise.
    static let riseFactor = 2.0
    /// Numerical floor, roughly -180 dBFS, so silent lanes cannot divide by 0.
    static let floorEpsilon = 1e-9

    static func analyze(
        samples: [Float],
        sampleRate: Double,
        options: SyncOptions
    ) -> OnsetAnalysis {
        let window = max(4, Int((options.envelopeWindowSeconds * sampleRate).rounded()))
        let hop = max(1, window / 4)

        var peak: Float = 0
        for value in samples {
            let magnitude = abs(value)
            if magnitude > peak { peak = magnitude }
        }

        guard samples.count >= window * 4 else {
            return OnsetAnalysis(
                envelope: [], hop: hop, window: window, noiseFloor: 0,
                peakAmplitude: peak, onsetSample: nil, onsetSNRdB: nil,
                failure: .tooShort
            )
        }

        // Prefix sum of squares in Double: a Float accumulator loses too much
        // precision over the hundreds of thousands of samples in a take.
        var squares = [Double](repeating: 0, count: samples.count + 1)
        var running = 0.0
        for index in 0..<samples.count {
            let value = Double(samples[index])
            running += value * value
            squares[index + 1] = running
        }

        let frameCount = (samples.count - window) / hop + 1
        var envelope = [Double](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let start = frame * hop
            let energy = squares[start + window] - squares[start]
            envelope[frame] = (energy / Double(window)).squareRoot()
        }

        guard peak >= options.silenceThreshold else {
            return OnsetAnalysis(
                envelope: envelope, hop: hop, window: window, noiseFloor: 0,
                peakAmplitude: peak, onsetSample: nil, onsetSNRdB: nil,
                failure: .silent
            )
        }

        let noiseFloor = estimateNoiseFloor(
            envelope: envelope, hop: hop, window: window,
            sampleRate: sampleRate, options: options
        )
        let threshold = noiseFloor * pow(10, options.minOnsetSNRdB / 20)
        let historyFrames = max(1, Int(riseHistorySeconds * sampleRate) / hop)

        var onsetFrame: Int?
        for frame in 0..<frameCount where envelope[frame] >= threshold {
            let historyStart = max(0, frame - historyFrames)
            guard historyStart < frame else {
                onsetFrame = frame
                break
            }
            let history = median(Array(envelope[historyStart..<frame]))
            if envelope[frame] >= riseFactor * max(history, floorEpsilon) {
                onsetFrame = frame
                break
            }
        }

        guard var frame = onsetFrame else {
            return OnsetAnalysis(
                envelope: envelope, hop: hop, window: window, noiseFloor: noiseFloor,
                peakAmplitude: peak, onsetSample: nil, onsetSNRdB: nil,
                failure: .noTransient
            )
        }

        let snr = 20 * log10(max(envelope[frame], floorEpsilon) / max(noiseFloor, floorEpsilon))

        // Back off to the first frame that already carries the attack, so a
        // late threshold crossing on a quiet lane does not push the window
        // past the transient. Bounded, so preceding material cannot drag the
        // onset backwards indefinitely.
        let backOffLimit = max(1, Int(0.004 * sampleRate) / hop)
        let backOffFloor = noiseFloor * pow(10, 6.0 / 20)
        var steps = 0
        while frame > 0, steps < backOffLimit, envelope[frame - 1] >= backOffFloor {
            frame -= 1
            steps += 1
        }

        return OnsetAnalysis(
            envelope: envelope, hop: hop, window: window, noiseFloor: noiseFloor,
            peakAmplitude: peak, onsetSample: frame * hop, onsetSNRdB: snr,
            failure: nil
        )
    }

    /// Median RMS of the clap-free head of the recording, ignoring digitally
    /// silent frames (a lane delayed by `SyncVerifier` starts with zeros).
    private static func estimateNoiseFloor(
        envelope: [Double],
        hop: Int,
        window: Int,
        sampleRate: Double,
        options: SyncOptions
    ) -> Double {
        guard !envelope.isEmpty else { return 0 }
        let noiseSamples = Int(options.noiseFloorSeconds * sampleRate)
        var lastFrame = (noiseSamples - window) / hop
        lastFrame = min(lastFrame, envelope.count - 1)
        // Never let the estimate use more than half the recording.
        lastFrame = min(lastFrame, max(0, envelope.count / 2 - 1))
        guard lastFrame >= 0 else { return 0 }

        let head = envelope[0...lastFrame].filter { $0 > 0 }
        guard !head.isEmpty else { return 0 }
        return median(Array(head))
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
