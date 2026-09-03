import Foundation

/// Result of running the RMS envelope onset detector over one lane.
struct OnsetAnalysis {
    enum Failure: Equatable {
        /// Nothing but digital silence (or below `silenceThreshold`).
        case silent
        /// There is signal, but nothing stands far enough above what the room
        /// sounds like the rest of the time. Speech, keys and a chair scraping
        /// all land here; a clap does not.
        case notDominant(dominanceDB: Double)
        /// The loudest thing in the take does stand out, but it is still too
        /// close to the noise floor measured in the clap-free head.
        case belowNoiseFloor(snrdB: Double)
        /// Fewer samples than the analyser needs.
        case tooShort

        var reason: String {
            switch self {
            case .silent:
                return "silent"
            case let .notDominant(dominance):
                return String(
                    format: "no dominant transient (peak only %.1f dB above the room)", dominance
                )
            case let .belowNoiseFloor(snrdB):
                return String(
                    format: "no dominant transient (peak only %.1f dB above the noise floor)", snrdB
                )
            case .tooShort:
                return "recording too short"
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
    /// Median RMS of the *whole* recording: what the room sounds like most of
    /// the time, transients included but outvoted.
    let medianLevel: Double
    /// Loudest envelope frame.
    let peakLevel: Double
    let peakAmplitude: Float
    /// First sample of the frame where the attack of the loudest transient
    /// starts.
    let onsetSample: Int?
    /// How far the loudest transient rose above the noise floor.
    let onsetSNRdB: Double?
    /// How far the loudest transient rose above `medianLevel`. Reported even
    /// when the lane is rejected — it is the number that explains why.
    let dominanceDB: Double?
    /// First sample of the loudest envelope frame.
    let peakSample: Int?
    /// A second maximum within `secondPeakToleranceDB` of the peak sits more
    /// than `secondPeakSeparationSeconds` away: the take has more than one
    /// bang in it. The loudest is still the one that is used.
    let multipleTransients: Bool
    let failure: Failure?

    var hasOnset: Bool { onsetSample != nil }
}

/// Coarse "when did the clap arrive" detector.
///
/// A 1 ms RMS envelope is taken over the whole recording and the **loudest**
/// frame is the only candidate. It is accepted when it stands `minDominanceDB`
/// above the median of that same envelope — what the room sounds like the rest
/// of the time — *and* `minOnsetSNRdB` above the noise floor measured in the
/// clap-free head. The onset is then found by walking back from the peak to
/// where the attack leaves the room behind (`riseDB`).
///
/// The rule matters more than it looks: an "is this frame louder than the last
/// five milliseconds" test accepts the first door, keyboard or syllable in a
/// real room, because 1 ms windows there swing 20 dB on their own. Only a clap
/// is 20 dB louder than everything else in the take.
enum OnsetDetector {
    /// How far a second, distant maximum may sit below the peak and still say
    /// the take holds more than one transient.
    static let secondPeakToleranceDB = 6.0
    /// How far apart two maxima must be before they count as separate events.
    static let secondPeakSeparationSeconds = 0.1
    /// Longest the attack search walks back from the peak.
    static let riseWalkBackSeconds = 0.02
    /// The walk-back also stops this far above the room's median level, so a
    /// take whose dominance only just clears the gate cannot drag the onset
    /// backwards through half the noise floor.
    static let riseFloorMarginDB = 3.0
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
                envelope: [], hop: hop, window: window, noiseFloor: 0, medianLevel: 0,
                peakLevel: 0, peakAmplitude: peak, onsetSample: nil, onsetSNRdB: nil,
                dominanceDB: nil, peakSample: nil, multipleTransients: false,
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
        var peakFrame = 0
        var peakLevel = 0.0
        for frame in 0..<frameCount {
            let start = frame * hop
            let energy = squares[start + window] - squares[start]
            let level = (energy / Double(window)).squareRoot()
            envelope[frame] = level
            if level > peakLevel {
                peakLevel = level
                peakFrame = frame
            }
        }

        let medianLevel = median(envelope)
        let noiseFloor = estimateNoiseFloor(
            envelope: envelope, hop: hop, window: window,
            sampleRate: sampleRate, options: options
        )
        let dominance = 20 * log10(max(peakLevel, floorEpsilon) / max(medianLevel, floorEpsilon))
        let snr = 20 * log10(max(peakLevel, floorEpsilon) / max(noiseFloor, floorEpsilon))

        func rejected(_ failure: OnsetAnalysis.Failure) -> OnsetAnalysis {
            OnsetAnalysis(
                envelope: envelope, hop: hop, window: window, noiseFloor: noiseFloor,
                medianLevel: medianLevel, peakLevel: peakLevel, peakAmplitude: peak,
                onsetSample: nil, onsetSNRdB: nil, dominanceDB: dominance,
                peakSample: peakFrame * hop,
                multipleTransients: false, failure: failure
            )
        }

        guard peak >= options.silenceThreshold else { return rejected(.silent) }
        guard peakLevel >= max(medianLevel, floorEpsilon)
            * pow(10, options.minDominanceDB / 20)
        else { return rejected(.notDominant(dominanceDB: dominance)) }
        guard peakLevel >= max(noiseFloor, floorEpsilon)
            * pow(10, options.minOnsetSNRdB / 20)
        else { return rejected(.belowNoiseFloor(snrdB: snr)) }

        // Walk back from the peak to where the attack starts: the frame after
        // the last one that is still down in the room. The margin above the
        // median is what stops the walk when the peak only just clears the
        // dominance gate and half the noise frames sit above peak - riseDB.
        let riseThreshold = max(
            peakLevel * pow(10, -options.riseDB / 20),
            max(medianLevel, floorEpsilon) * pow(10, riseFloorMarginDB / 20)
        )
        let walkLimit = max(0, peakFrame - max(1, Int(riseWalkBackSeconds * sampleRate) / hop))
        var onsetFrame = peakFrame
        while onsetFrame > walkLimit, envelope[onsetFrame - 1] >= riseThreshold {
            onsetFrame -= 1
        }

        let separation = max(1, Int(secondPeakSeparationSeconds * sampleRate) / hop)
        let secondThreshold = peakLevel * pow(10, -secondPeakToleranceDB / 20)
        var multiple = false
        for frame in 0..<frameCount where abs(frame - peakFrame) > separation {
            if envelope[frame] >= secondThreshold {
                multiple = true
                break
            }
        }

        return OnsetAnalysis(
            envelope: envelope, hop: hop, window: window, noiseFloor: noiseFloor,
            medianLevel: medianLevel, peakLevel: peakLevel, peakAmplitude: peak,
            onsetSample: onsetFrame * hop, onsetSNRdB: snr, dominanceDB: dominance,
            peakSample: peakFrame * hop, multipleTransients: multiple, failure: nil
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

extension LaneLevels {
    /// The levels the result page and `--sync-test` print, straight from the
    /// envelope the detector already built.
    init?(_ analysis: OnsetAnalysis) {
        guard let dominanceDB = analysis.dominanceDB else { return nil }
        func decibels(_ amplitude: Double) -> Double {
            amplitude > OnsetDetector.floorEpsilon ? 20 * log10(amplitude) : -999
        }
        self.init(
            peakDBFS: decibels(analysis.peakLevel),
            medianDBFS: decibels(analysis.medianLevel),
            noiseFloorDBFS: decibels(analysis.noiseFloor),
            dominanceDB: dominanceDB,
            samplePeakDBFS: decibels(Double(analysis.peakAmplitude)),
            peakSample: analysis.peakSample ?? 0,
            multipleTransients: analysis.multipleTransients
        )
    }
}
