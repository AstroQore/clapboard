import Foundation
import Testing

@testable import ClapboardCore

/// Deterministic noise so a failure can be reproduced from the seed alone.
private struct Noise {
    private var state: UInt64

    init(seed: UInt64) { state = seed | 1 }

    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
}

@Suite("Pairwise alignment")
struct PairwiseAlignmentTests {
    private let lanes = (0..<4).map { _ in UUID() }

    /// Every ordered pair, measured perfectly from a known set of arrivals.
    private func exactPairs(_ arrivals: [Double], weight: Double = 1) -> [PairObservation] {
        var pairs: [PairObservation] = []
        for i in 0..<lanes.count {
            for j in (i + 1)..<lanes.count {
                pairs.append(PairObservation(
                    a: lanes[i], b: lanes[j],
                    offsetSamples: arrivals[i] - arrivals[j],
                    weight: weight, estimator: "exact"
                ))
            }
        }
        return pairs
    }

    @Test func recoversArrivalsFromEveryPairWithNoReferenceLane() throws {
        let truth = [140.0, 0.0, 512.0, 37.0]
        let solution = try #require(
            PairwiseAlignment.solve(lanes: lanes, pairs: exactPairs(truth))
        )
        // The gauge is "earliest lane is zero", so the answer is the truth
        // shifted to its own minimum — no lane is privileged.
        let expected = truth.map { $0 - truth.min()! }
        for (index, lane) in lanes.enumerated() {
            let arrival = try #require(solution.arrivals[lane])
            #expect(abs(arrival - expected[index]) < 1e-9)
            #expect(arrival >= 0)
        }
        #expect(solution.residualRMS < 1e-9)
        #expect(try #require(solution.triangleResidualRMS) < 1e-9)
        #expect(solution.droppedPairs.isEmpty)
        #expect(solution.placedLaneIDs.count == 4)
    }

    @Test func putsTheLatestLaneAtZeroDelayAndEveryoneElsePositive() throws {
        let truth = [140.0, 0.0, 512.0, 37.0]
        let solution = try #require(
            PairwiseAlignment.solve(lanes: lanes, pairs: exactPairs(truth))
        )
        let delays = solution.delaysSamples()
        #expect(delays.count == 4)
        #expect(delays.values.allSatisfy { $0 >= 0 })
        #expect(delays.values.filter { $0 == 0 }.count == 1)
        // Lane 2 arrived last, so it waits for nobody; lane 1 arrived first
        // and has to wait the full spread.
        #expect(delays[lanes[2]] == 0)
        #expect(delays[lanes[1]] == 512)
        #expect(delays[lanes[0]] == 372)
    }

    @Test func findsAndDropsAPairThatDisagreesWithTheRest() throws {
        let truth = [140.0, 0.0, 512.0, 37.0]
        var pairs = exactPairs(truth)
        // Corrupt one measurement the way a mislocated window would: the two
        // lanes are real, the number between them is not.
        let bad = pairs.firstIndex { $0.a == lanes[0] && $0.b == lanes[2] }!
        pairs[bad] = PairObservation(
            a: lanes[0], b: lanes[2], offsetSamples: 1_400, weight: 1, estimator: "corrupt"
        )

        let solution = try #require(PairwiseAlignment.solve(lanes: lanes, pairs: pairs))
        #expect(solution.droppedPairs.count == 1)
        #expect(solution.droppedPairs.first?.estimator == "corrupt")
        let expected = truth.map { $0 - truth.min()! }
        for (index, lane) in lanes.enumerated() {
            let arrival = try #require(solution.arrivals[lane])
            #expect(abs(arrival - expected[index]) < 1e-6)
        }
        #expect(solution.residualRMS < 1e-6)
    }

    @Test func triangleResidualSeesTheBadPairWithoutFittingAnything() {
        let truth = [140.0, 0.0, 512.0, 37.0]
        var pairs = exactPairs(truth)
        let bad = pairs.firstIndex { $0.a == lanes[0] && $0.b == lanes[2] }!
        pairs[bad] = PairObservation(
            a: lanes[0], b: lanes[2], offsetSamples: 1_400, weight: 1, estimator: "corrupt"
        )
        // Computed straight from the measurements: consistent triples sum to
        // zero, so a non-zero sum is proof of a bad measurement rather than a
        // consequence of the fit.
        let residual = PairwiseAlignment.triangleResidualRMS(pairs: pairs)
        #expect((residual ?? 0) > 100)
        #expect((PairwiseAlignment.triangleResidualRMS(pairs: exactPairs(truth)) ?? 1) < 1e-9)
    }

    @Test func aLowWeightDisagreementBarelyMovesTheAnswer() throws {
        let three = Array(lanes.prefix(3))
        let truth = [0.0, 200.0, 450.0]
        let pairs = [
            PairObservation(a: three[0], b: three[1], offsetSamples: -200, weight: 100, estimator: "strong"),
            PairObservation(a: three[1], b: three[2], offsetSamples: -250, weight: 100, estimator: "strong"),
            PairObservation(a: three[0], b: three[2], offsetSamples: -900, weight: 0.01, estimator: "weak")
        ]
        let solution = try #require(PairwiseAlignment.solve(lanes: three, pairs: pairs))
        for (index, lane) in three.enumerated() {
            let arrival = try #require(solution.arrivals[lane])
            // The weak pair is wrong by 450 samples; weighting keeps its pull
            // on the answer under a sample even if it is never dropped.
            #expect(abs(arrival - truth[index]) < 1)
        }
    }

    @Test func twoLanesStillWorkButOfferNoCrossCheck() throws {
        let two = Array(lanes.prefix(2))
        let pairs = [
            PairObservation(a: two[0], b: two[1], offsetSamples: -604.8, weight: 1, estimator: "waveform")
        ]
        let solution = try #require(PairwiseAlignment.solve(lanes: two, pairs: pairs))
        #expect(abs(try #require(solution.arrivals[two[0]])) < 1e-9)
        #expect(abs(try #require(solution.arrivals[two[1]]) - 604.8) < 1e-9)
        // No triangle exists, so there is nothing to check the measurement
        // against and the fit has no spare information for error bars.
        #expect(solution.triangleResidualRMS == nil)
        #expect(solution.standardErrors.values.allSatisfy { $0 == 0 })
        #expect(solution.residualRMS < 1e-9)
    }

    @Test func leavesALaneNothingAgreedWithOutOfTheSolution() throws {
        let truth = [0.0, 120.0, 300.0]
        var pairs: [PairObservation] = []
        for i in 0..<3 {
            for j in (i + 1)..<3 {
                pairs.append(PairObservation(
                    a: lanes[i], b: lanes[j],
                    offsetSamples: truth[i] - truth[j], weight: 1, estimator: "exact"
                ))
            }
        }
        // lanes[3] takes part in no pair at all.
        let solution = try #require(PairwiseAlignment.solve(lanes: lanes, pairs: pairs))
        #expect(solution.placedLaneIDs.count == 3)
        #expect(solution.arrivals[lanes[3]] == nil)
        #expect(solution.delaysSamples()[lanes[3]] == nil)
    }

    @Test func keepsABridgeEvenWhenItFitsBadly() throws {
        // Two clean triangles joined by a single pair. Dropping the bridge
        // would orphan half the take, so it has to survive and show up in the
        // residual instead.
        let extra = UUID()
        let all = lanes + [extra]
        var pairs: [PairObservation] = []
        func add(_ i: Int, _ j: Int, _ offset: Double, _ weight: Double = 1, _ tag: String = "exact") {
            pairs.append(PairObservation(a: all[i], b: all[j], offsetSamples: offset, weight: weight, estimator: tag))
        }
        add(0, 1, 10); add(1, 2, 10); add(0, 2, 20)
        add(3, 4, 5)
        add(2, 3, 999, 1, "bridge")

        let solution = try #require(PairwiseAlignment.solve(lanes: all, pairs: pairs))
        #expect(solution.placedLaneIDs.count == 5)
        #expect(!solution.droppedPairs.contains { $0.estimator == "bridge" })
    }

    @Test func invertsASmallSymmetricMatrix() throws {
        let matrix = [4.0, 1.0, 1.0, 3.0]
        let inverse = try #require(PairwiseAlignment.invertSymmetric(matrix, count: 2))
        // M * M^-1 must be the identity.
        for row in 0..<2 {
            for column in 0..<2 {
                var sum = 0.0
                for k in 0..<2 { sum += matrix[row * 2 + k] * inverse[k * 2 + column] }
                #expect(abs(sum - (row == column ? 1 : 0)) < 1e-12)
            }
        }
        #expect(PairwiseAlignment.invertSymmetric([0.0, 0.0, 0.0, 0.0], count: 2) == nil)
    }

    @Test func robustSigmaIgnoresASingleOutlier() {
        let clean = [0.1, -0.2, 0.05, 0.0, -0.1]
        let withOutlier = clean + [900.0]
        let sigma = PairwiseAlignment.robustSigma(of: withOutlier)
        // A plain standard deviation would be in the hundreds here.
        #expect(sigma < 1)
    }
}

@Suite("Envelope correlator")
struct EnvelopeCorrelatorTests {
    private let sampleRate = 48_000.0
    private var window: Int { 48 }
    private var hop: Int { 12 }

    /// A clap-shaped burst: near-instant attack, exponential decay, on a quiet
    /// noise bed. `at` is the attack's first sample.
    private func take(
        clapAt at: Int,
        length: Int = 48_000 * 2,
        amplitude: Float = 0.6,
        floor: Float = 0.004,
        seed: UInt64 = 42
    ) -> [Float] {
        var noise = Noise(seed: seed)
        var samples = [Float](repeating: 0, count: length)
        for index in 0..<length {
            samples[index] = Float(noise.next()) * floor
        }
        let tau = 0.008 * sampleRate
        var burst = Noise(seed: seed &* 31 &+ 7)
        for offset in 0..<Int(0.05 * sampleRate) {
            let index = at + offset
            guard index < length else { break }
            let decay = Float(exp(-Double(offset) / tau))
            samples[index] += Float(burst.next()) * amplitude * decay
        }
        return samples
    }

    private func logEnvelope(_ samples: [Float]) -> [Double] {
        EnvelopeCorrelator.logEnvelope(
            EnvelopeCorrelator.envelope(samples: samples, window: window, hop: hop)
        )
    }

    @Test func findsAKnownDelay() throws {
        let delay = 1_008  // 21 ms, a plausible wireless offset
        let reference = logEnvelope(take(clapAt: 20_000, seed: 11))
        let target = logEnvelope(take(clapAt: 20_000 + delay, seed: 11))
        let match = try #require(
            EnvelopeCorrelator.match(target: target, reference: reference, maxLagPoints: 1_000)
        )
        let measured = match.lagPoints * Double(hop)
        #expect(abs(measured - Double(delay)) < Double(hop))
        #expect(match.correlation > 0.8)
        #expect(match.peakRatio > 1.2)
    }

    @Test func survivesAClippedLane() throws {
        // The failure this estimator exists for: one microphone driven into
        // clipping, whose waveform no longer resembles the other's.
        let delay = 600
        let reference = logEnvelope(take(clapAt: 24_000, seed: 5))
        var clipped = take(clapAt: 24_000 + delay, amplitude: 0.9, seed: 5)
        for index in clipped.indices {
            clipped[index] = min(max(clipped[index], -0.2), 0.2)
        }
        let match = try #require(
            EnvelopeCorrelator.match(
                target: logEnvelope(clipped), reference: reference, maxLagPoints: 1_000
            )
        )
        let measured = match.lagPoints * Double(hop)
        #expect(abs(measured - Double(delay)) < Double(hop))
    }

    @Test func survivesADifferentMicrophoneResponse() throws {
        let delay = -480  // the target arrived first
        let reference = logEnvelope(take(clapAt: 30_000, seed: 9))
        // One-pole low pass, standing in for a duller capsule.
        var dull = take(clapAt: 30_000 + delay, seed: 9)
        var previous: Float = 0
        for index in dull.indices {
            previous += 0.08 * (dull[index] - previous)
            dull[index] = previous
        }
        let match = try #require(
            EnvelopeCorrelator.match(
                target: logEnvelope(dull), reference: reference, maxLagPoints: 1_000
            )
        )
        let measured = match.lagPoints * Double(hop)
        #expect(abs(measured - Double(delay)) < Double(hop))
    }

    @Test func doesNotInventAMatchBetweenUnrelatedNoise() throws {
        // Two lanes that never heard the same event: whatever peak turns up
        // must not look convincing.
        var first = Noise(seed: 101)
        var second = Noise(seed: 202)
        let count = 48_000
        let a = (0..<count).map { _ in Float(first.next()) * 0.01 }
        let b = (0..<count).map { _ in Float(second.next()) * 0.01 }
        let match = try #require(
            EnvelopeCorrelator.match(
                target: logEnvelope(a), reference: logEnvelope(b), maxLagPoints: 500
            )
        )
        #expect(match.correlation < 0.3)
        #expect(match.peakRatio < 3)
    }

    @Test func envelopeShapeIsIndependentOfTheChunkItWasComputedFrom() {
        let samples = take(clapAt: 12_000, seed: 77)
        let full = EnvelopeCorrelator.envelope(samples: samples, window: window, hop: hop)
        #expect(full.count == (samples.count - window) / hop + 1)
        // A window that does not fit produces nothing rather than a partial
        // value that would drift the timeline.
        #expect(EnvelopeCorrelator.envelope(samples: [0, 0], window: window, hop: hop).isEmpty)
    }
}
