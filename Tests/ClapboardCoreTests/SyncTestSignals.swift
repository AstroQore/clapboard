import ClapboardCore
import Foundation

/// Deterministic SplitMix64, so every synthetic take is reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + uniform() * (range.upperBound - range.lowerBound)
    }

    mutating func gaussian() -> Double {
        var u1 = uniform()
        while u1 <= 1e-12 { u1 = uniform() }
        let u2 = uniform()
        return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * Double.pi * u2)
    }
}

enum SyncTestSignals {
    static let sampleRate: Double = 48_000
    static let takeSeconds: Double = 3.0
    /// Level the direct clap is mixed at, leaving headroom for echoes.
    static let clapLevel: Float = 0.5

    /// 0.2 ms linear attack into an exponentially decaying white noise burst
    /// (tau 8 ms, 30 ms long), peak normalised.
    static func makeClap(seed: UInt64, sampleRate: Double = sampleRate) -> [Float] {
        var rng = SeededGenerator(seed: seed)
        let length = Int(0.030 * sampleRate)
        let attack = 0.0002 * sampleRate
        let tau = 0.008 * sampleRate
        var clap = [Float](repeating: 0, count: length)
        for index in 0..<length {
            let t = Double(index)
            let envelope = t < attack ? t / attack : exp(-(t - attack) / tau)
            clap[index] = Float(envelope * rng.gaussian())
        }
        let peak = clap.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return clap }
        return clap.map { $0 / peak }
    }

    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for value in samples { sum += Double(value) * Double(value) }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// 32-tap windowed-sinc fractional delay taps for a fractional shift.
    private static func sincTaps(fraction: Double, taps: Int = 32) -> [Double] {
        let half = taps / 2 - 1
        var coefficients = [Double](repeating: 0, count: taps)
        var sum = 0.0
        for k in 0..<taps {
            let t = Double(k - half) - fraction
            let sinc = abs(t) < 1e-12 ? 1.0 : sin(.pi * t) / (.pi * t)
            let phase = 2 * Double.pi * Double(k) / Double(taps - 1)
            let window = 0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase)
            coefficients[k] = sinc * window
            sum += coefficients[k]
        }
        return coefficients.map { $0 / sum }
    }

    /// Adds `clap` to `buffer` so its first sample lands exactly at the
    /// (fractional) sample position `position`.
    static func add(
        clap: [Float],
        to buffer: inout [Float],
        at position: Double,
        amplitude: Float
    ) {
        let taps = 32
        let base = Int(position.rounded(.down))
        let fraction = position - Double(base)
        let coefficients = sincTaps(fraction: fraction, taps: taps)
        let half = taps / 2 - 1

        for offset in -taps..<(clap.count + taps) {
            let destination = base + offset
            guard destination >= 0, destination < buffer.count else { continue }
            var accumulator = 0.0
            for k in 0..<taps {
                let source = offset - k + half
                guard source >= 0, source < clap.count else { continue }
                accumulator += coefficients[k] * Double(clap[source])
            }
            buffer[destination] += amplitude * Float(accumulator)
        }
    }

    enum Content {
        /// The take's shared clap, at the lane's own arrival time.
        case clap
        /// Digital silence: a virtual device nobody routed anything into.
        case silence
        /// Steady music-like material, no transient anywhere.
        case music
        /// A different clap at an unrelated time: something banged, but not
        /// the clap the other lanes heard.
        case foreignTransient(offsetSeconds: Double)
    }

    struct LaneSpec {
        var label: String
        /// Arrival delay relative to the take's base clap position, samples.
        var delaySamples: Double = 0
        var gain: Float = 1
        var snrdB: Double = 40
        /// Discrete reflections: (delay in ms after the direct sound, amplitude).
        var echoes: [(Double, Float)] = []
        /// Diffuse tail level in dB relative to the direct clap, `nil` for none.
        var reverbTailDB: Double?
        /// Gain applied before hard clipping to +/-1.
        var clipGain: Float = 1
        var isVirtual: Bool = false
        var content: Content = .clap
        /// Extra converter noise floor added after `gain`, as an RMS level.
        var noiseFloorRMS: Float = 0

        init(_ label: String) { self.label = label }
    }

    struct Take {
        var lanes: [LaneRecording]
        /// True arrival delay per lane, samples, on a common timeline.
        var truth: [UUID: Double]
        var clapPosition: Double
    }

    static func makeTake(
        _ specs: [LaneSpec],
        seed: UInt64,
        clapPosition: Double? = nil,
        sampleRate: Double = sampleRate
    ) -> Take {
        var positionRNG = SeededGenerator(seed: seed &* 31 &+ 7)
        let position = clapPosition ?? (positionRNG.uniform(0.5...2.0) * sampleRate)
        let clap = makeClap(seed: seed &+ 1, sampleRate: sampleRate)
        let clapRMS = rms(clap)
        let length = Int(takeSeconds * sampleRate)

        var lanes: [LaneRecording] = []
        var truth: [UUID: Double] = [:]

        for (index, spec) in specs.enumerated() {
            var rng = SeededGenerator(seed: seed &+ 1000 &+ UInt64(index))
            var buffer = [Float](repeating: 0, count: length)

            switch spec.content {
            case .clap:
                add(
                    clap: clap, to: &buffer,
                    at: position + spec.delaySamples, amplitude: clapLevel
                )
                for (echoMs, amplitude) in spec.echoes {
                    add(
                        clap: clap, to: &buffer,
                        at: position + spec.delaySamples + echoMs / 1000 * sampleRate,
                        amplitude: clapLevel * amplitude
                    )
                }
                if let tailDB = spec.reverbTailDB {
                    let tailLevel = Double(clapLevel) * pow(10, tailDB / 20)
                    let tailStart = Int((position + spec.delaySamples).rounded())
                    let tailLength = Int(0.25 * sampleRate)
                    let tau = 0.06 * sampleRate
                    for offset in 0..<tailLength {
                        let destination = tailStart + offset
                        guard destination >= 0, destination < length else { continue }
                        let envelope = exp(-Double(offset) / tau)
                        buffer[destination] += Float(tailLevel * envelope * rng.gaussian() * 0.4)
                    }
                }
            case .silence:
                break
            case .music:
                // Three partials with slow tremolo plus hiss: loud, but with
                // nothing that rises steeply out of its own noise floor.
                for index in 0..<length {
                    let t = Double(index) / sampleRate
                    let tremolo = 0.6 + 0.4 * sin(2 * .pi * 0.7 * t)
                    var value = 0.0
                    value += 0.20 * sin(2 * .pi * 220 * t)
                    value += 0.12 * sin(2 * .pi * 660 * t + 0.4)
                    value += 0.08 * sin(2 * .pi * 1320 * t + 1.1)
                    buffer[index] = Float(value * tremolo + 0.01 * rng.gaussian())
                }
            case let .foreignTransient(offsetSeconds):
                let other = makeClap(seed: seed &+ 5000 &+ UInt64(index), sampleRate: sampleRate)
                add(
                    clap: other, to: &buffer,
                    at: position + offsetSeconds * sampleRate, amplitude: clapLevel
                )
            }

            var addsBackgroundNoise = spec.snrdB.isFinite
            if case .silence = spec.content { addsBackgroundNoise = false }
            if addsBackgroundNoise {
                let noiseRMS = Double(clapLevel) * clapRMS * pow(10, -spec.snrdB / 20)
                for index in 0..<length {
                    buffer[index] += Float(noiseRMS * rng.gaussian())
                }
            }

            if spec.gain != 1 {
                for index in 0..<length { buffer[index] *= spec.gain }
            }
            if spec.noiseFloorRMS > 0 {
                for index in 0..<length {
                    buffer[index] += Float(Double(spec.noiseFloorRMS) * rng.gaussian())
                }
            }
            if spec.clipGain != 1 {
                for index in 0..<length {
                    buffer[index] = min(max(buffer[index] * spec.clipGain, -1), 1)
                }
            }

            let lane = LaneRecording(
                label: spec.label,
                samples: buffer,
                sampleRate: sampleRate,
                isVirtual: spec.isVirtual
            )
            lanes.append(lane)
            truth[lane.laneID] = spec.delaySamples
        }

        return Take(lanes: lanes, truth: truth, clapPosition: position)
    }
}

extension SyncResult {
    /// Offset error of a lane against the true arrival delays, in samples,
    /// expressed against whichever lane the aligner picked as reference.
    func offsetError(laneID: UUID, truth: [UUID: Double]) -> Double? {
        guard let referenceLaneID, let referenceDelay = truth[referenceLaneID],
              let measured = self[laneID]?.status.offsetSamples,
              let trueDelay = truth[laneID]
        else { return nil }
        return measured - (trueDelay - referenceDelay)
    }
}
