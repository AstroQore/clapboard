import Foundation

/// Time difference between two lanes measured from their energy envelopes
/// rather than their waveforms.
///
/// A waveform correlation asks "do these two signals look alike". Two
/// microphones a metre apart, with different capsules, one of them clipped,
/// often do not — and the correlation then has no clear peak even though both
/// plainly recorded the same clap. That is exactly the failure this exists to
/// cover: clipping flattens the peaks of a waveform but barely changes where
/// its energy is, so the envelopes still line up.
///
/// The price is resolution: the answer is only as fine as the envelope hop,
/// around a millimetre-scale 0.25 ms rather than a single sample. It is
/// therefore used to bracket the search, and a waveform estimator refines it
/// inside a few milliseconds of the answer.
enum EnvelopeCorrelator {
    struct Match {
        /// Lag in envelope points: positive means `target` arrived later than
        /// `reference`. Sub-point through parabolic interpolation.
        let lagPoints: Double
        /// Pearson correlation at the peak, over the overlapping region.
        let correlation: Double
        /// Best correlation well away from the peak. An envelope is smooth
        /// over the decay of the clap, so neighbouring lags correlate almost as
        /// well as the winner; the exclusion zone has to be wider than that
        /// decay for this number to mean anything. Treat `correlation` as the
        /// primary quality signal and this ratio as a sanity check.
        let secondBest: Double
        /// Points that actually overlapped at the winning lag.
        let overlapPoints: Int

        var peakRatio: Double {
            let floor = max(abs(secondBest), 1e-6)
            return abs(correlation) / floor
        }
    }

    /// Root-mean-square envelope: one value every `hop` samples over a
    /// `window`-sample span, so consecutive values overlap when
    /// `window > hop`. Uses a prefix sum in Double because a Float
    /// accumulator loses too much over a multi-second take.
    static func envelope(samples: [Float], window: Int, hop: Int) -> [Double] {
        let window = max(1, window)
        let hop = max(1, hop)
        guard samples.count >= window else { return [] }
        var squares = [Double](repeating: 0, count: samples.count + 1)
        var running = 0.0
        for index in 0..<samples.count {
            let value = Double(samples[index])
            running += value * value
            squares[index + 1] = running
        }
        let count = (samples.count - window) / hop + 1
        var result = [Double](repeating: 0, count: count)
        for frame in 0..<count {
            let start = frame * hop
            let energy = squares[start + window] - squares[start]
            result[frame] = (energy / Double(window)).squareRoot()
        }
        return result
    }

    /// Converts an envelope to decibels relative to its own median, which
    /// removes the level difference between a loud and a quiet microphone
    /// before they are compared. Values are clamped from below so silence in
    /// one lane cannot dominate the correlation.
    static func logEnvelope(_ envelope: [Double], floorDB: Double = -60) -> [Double] {
        guard !envelope.isEmpty else { return [] }
        let reference = max(PairwiseAlignment.median(envelope), 1e-12)
        return envelope.map { value in
            let ratio = max(value, 1e-12) / reference
            return max(floorDB, 20 * log10(ratio))
        }
    }

    /// Correlates two envelopes that share an absolute timeline: point `n` of
    /// both was recorded in the same IOProc cycle.
    ///
    /// - Parameters:
    ///   - maxLagPoints: search limit, in envelope points.
    ///   - minimumOverlapFraction: a lag whose overlap is shorter than this
    ///     fraction of the shorter envelope is not considered. Without it a
    ///     large lag can win on a handful of points that happen to agree.
    static func match(
        target: [Double],
        reference: [Double],
        maxLagPoints: Int,
        minimumOverlapFraction: Double = 0.5,
        secondBestExclusionPoints: Int = 40
    ) -> Match? {
        guard !target.isEmpty, !reference.isEmpty, maxLagPoints >= 0 else { return nil }
        let minimumOverlap = max(
            8, Int(Double(min(target.count, reference.count)) * minimumOverlapFraction)
        )

        // Pearson correlation is computed over the overlap for each lag, so a
        // lag is never rewarded for comparing fewer points. Prefix sums make
        // the per-lag statistics O(1); only the cross term costs the overlap.
        let targetStats = PrefixStats(target)
        let referenceStats = PrefixStats(reference)

        var correlations = [Double](repeating: .nan, count: 2 * maxLagPoints + 1)
        for lag in -maxLagPoints...maxLagPoints {
            // r(m) = sum_n target[n] * reference[n - m]
            let start = max(0, lag)
            let end = min(target.count, reference.count + lag)
            let overlap = end - start
            guard overlap >= minimumOverlap else { continue }

            let targetMean = targetStats.mean(from: start, count: overlap)
            let referenceMean = referenceStats.mean(from: start - lag, count: overlap)
            let targetVariance = targetStats.variance(from: start, count: overlap, mean: targetMean)
            let referenceVariance = referenceStats.variance(
                from: start - lag, count: overlap, mean: referenceMean
            )
            guard targetVariance > 1e-12, referenceVariance > 1e-12 else { continue }

            var cross = 0.0
            for index in 0..<overlap {
                cross += (target[start + index] - targetMean)
                    * (reference[start - lag + index] - referenceMean)
            }
            let denominator = (targetVariance * referenceVariance).squareRoot()
                * Double(overlap)
            correlations[lag + maxLagPoints] = cross / denominator
        }

        var bestIndex = -1
        var bestValue = -Double.infinity
        for (index, value) in correlations.enumerated() where value.isFinite {
            if value > bestValue {
                bestValue = value
                bestIndex = index
            }
        }
        guard bestIndex >= 0, bestValue > -Double.infinity else { return nil }

        var secondBest = 0.0
        for (index, value) in correlations.enumerated() where value.isFinite {
            if abs(index - bestIndex) > secondBestExclusionPoints {
                secondBest = max(secondBest, value)
            }
        }

        // Parabolic vertex through the peak and its neighbours.
        var refinement = 0.0
        if bestIndex > 0, bestIndex + 1 < correlations.count {
            let left = correlations[bestIndex - 1]
            let right = correlations[bestIndex + 1]
            if left.isFinite, right.isFinite {
                let denominator = left - 2 * bestValue + right
                if abs(denominator) > 1e-15 {
                    refinement = min(max(0.5 * (left - right) / denominator, -1), 1)
                }
            }
        }

        let lag = Double(bestIndex - maxLagPoints) + refinement
        let start = max(0, bestIndex - maxLagPoints)
        let end = min(target.count, reference.count + (bestIndex - maxLagPoints))
        return Match(
            lagPoints: lag,
            correlation: bestValue,
            secondBest: secondBest,
            overlapPoints: max(0, end - start)
        )
    }

    /// Running sums so a windowed mean and variance cost the same at every lag.
    private struct PrefixStats {
        private let sums: [Double]
        private let squares: [Double]

        init(_ values: [Double]) {
            var sums = [Double](repeating: 0, count: values.count + 1)
            var squares = [Double](repeating: 0, count: values.count + 1)
            var runningSum = 0.0
            var runningSquare = 0.0
            for (index, value) in values.enumerated() {
                runningSum += value
                runningSquare += value * value
                sums[index + 1] = runningSum
                squares[index + 1] = runningSquare
            }
            self.sums = sums
            self.squares = squares
        }

        func mean(from start: Int, count: Int) -> Double {
            guard count > 0, start >= 0, start + count < sums.count else { return 0 }
            return (sums[start + count] - sums[start]) / Double(count)
        }

        /// Mean of squares minus the square of the mean, clamped at zero: the
        /// subtraction can go slightly negative on a constant run.
        func variance(from start: Int, count: Int, mean: Double) -> Double {
            guard count > 0, start >= 0, start + count < squares.count else { return 0 }
            let meanSquare = (squares[start + count] - squares[start]) / Double(count)
            return max(0, meanSquare - mean * mean)
        }
    }
}
