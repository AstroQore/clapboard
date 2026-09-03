import Foundation

/// One measured time difference between two lanes.
///
/// `offsetSamples` is the arrival on `a` minus the arrival on `b`, so a
/// positive value means `a` heard the clap later. `weight` is the
/// least-squares weight: larger means the measurement is trusted more. It has
/// no unit of its own, only a scale shared with the other pairs of the same
/// take.
public struct PairObservation: Sendable, Hashable {
    public let a: UUID
    public let b: UUID
    public let offsetSamples: Double
    public let weight: Double
    /// Which estimator produced this number, for the measurement detail view.
    public let estimator: String

    public init(a: UUID, b: UUID, offsetSamples: Double, weight: Double, estimator: String) {
        self.a = a
        self.b = b
        self.offsetSamples = offsetSamples
        self.weight = weight
        self.estimator = estimator
    }

    /// The same measurement read the other way round.
    public var reversed: PairObservation {
        PairObservation(a: b, b: a, offsetSamples: -offsetSamples, weight: weight, estimator: estimator)
    }
}

/// Arrival times for every lane that could be tied to the rest, with the
/// evidence that produced them.
public struct AlignmentSolution: Sendable {
    /// Arrival of the clap per lane, in samples, gauge-fixed so the earliest
    /// lane is exactly 0 and every value is >= 0. There is no reference lane:
    /// these come out of a fit over every pair at once.
    public let arrivals: [UUID: Double]
    /// One standard deviation of each arrival, in samples, from the fit. It is
    /// 0 for a two-lane take, where the fit has no spare information.
    public let standardErrors: [UUID: Double]
    /// Root mean square of the fit residuals, in samples. This is the honest
    /// per-take confidence: with three or more lanes it says whether the
    /// pairwise measurements agree with any single set of arrival times.
    public let residualRMS: Double
    /// Residual of each surviving pair, in samples.
    public let pairResiduals: [PairObservation: Double]
    public let usedPairs: [PairObservation]
    /// Pairs thrown out as inconsistent with the rest.
    public let droppedPairs: [PairObservation]
    /// Root mean square of `tau_ij + tau_jk + tau_ki` over every triangle of
    /// surviving pairs. Nil when the graph has no triangle, which is the
    /// normal case for two lanes: there is then nothing to cross-check.
    public let triangleResidualRMS: Double?
    /// Lanes the fit could place. A lane with no usable pair is absent.
    public let placedLaneIDs: Set<UUID>

    public var isEmpty: Bool { arrivals.isEmpty }

    /// Delay each lane needs so every lane lines up on the latest arrival.
    /// Always >= 0, and exactly one lane (the latest) gets 0.
    public func delaysSamples() -> [UUID: Int] {
        guard let latest = arrivals.values.max() else { return [:] }
        return arrivals.mapValues { max(0, Int((latest - $0).rounded())) }
    }
}

/// Solves for per-lane arrival times from pairwise time differences.
///
/// The problem is a weighted least squares over a graph: every pair
/// contributes `t_a - t_b = tau_ab`, and the normal equations are the weighted
/// graph Laplacian. Two properties matter here:
///
/// - **No reference lane.** With N lanes there are up to N(N-1)/2 measurements
///   for N-1 free parameters, so the fit uses all of them at once instead of
///   trusting one lane's window. The absolute origin is unknowable — a clap
///   carries no clock — so the solution is gauge-fixed to "earliest lane = 0"
///   at the end, which is also the only presentation that never shows the user
///   a negative arrival.
/// - **Redundancy is a check.** The residuals say whether the measurements
///   agree; a single bad pair is found and dropped rather than quietly
///   biasing every lane. Triangle sums are reported for the same reason.
public enum PairwiseAlignment {
    /// - Parameters:
    ///   - lanes: every lane in the take, in display order.
    ///   - pairs: measurements. Duplicates of the same unordered pair are
    ///     merged by weight before solving.
    ///   - absoluteToleranceSamples: a fit already this good is left alone. It
    ///     is a physical bound, not a tuning knob: pairwise measurements of one
    ///     clap should agree to about a sample, so there is nothing to gain by
    ///     dropping pairs below it.
    ///   - improvementFactor: how much better the fit must get before a pair is
    ///     called an outlier and removed.
    public static func solve(
        lanes: [UUID],
        pairs: [PairObservation],
        absoluteToleranceSamples: Double = 1,
        improvementFactor: Double = 3
    ) -> AlignmentSolution? {
        let merged = mergeDuplicates(pairs)
        guard !merged.isEmpty else { return nil }

        var active = merged
        var dropped: [PairObservation] = []
        var solution: Solve?

        // Outliers are found by leaving one pair out at a time, not by how far
        // a residual sits from the spread of the others. A least-squares fit
        // smears one bad measurement across every pair that shares a lane with
        // it, so the spread is contaminated by the very thing it is being asked
        // to detect: on a complete four-lane graph a single corrupt pair lifts
        // four residuals at once, and a median-based sigma then declares all of
        // them normal. Refitting without a candidate is immune to that — either
        // the rest of the take agrees much better without it or it does not.
        //
        // A pair that holds the graph together is kept even when it fits badly.
        // Dropping a bridge would silently orphan a lane; keeping it leaves the
        // disagreement visible in the reported residual instead.
        for _ in 0...max(1, merged.count) {
            guard let attempt = solveOnce(lanes: lanes, pairs: active) else { break }
            solution = attempt
            guard attempt.residualRMS > absoluteToleranceSamples, active.count > 2 else { break }

            var bestCandidate: (pair: PairObservation, solve: Solve)?
            for pair in active {
                var candidate = active
                candidate.removeAll { $0 == pair }
                guard keepsGraphConnected(before: active, after: candidate, lanes: lanes),
                      let refit = solveOnce(lanes: lanes, pairs: candidate)
                else { continue }
                if refit.residualRMS < (bestCandidate?.solve.residualRMS ?? .infinity) {
                    bestCandidate = (pair, refit)
                }
            }
            // Only act when removing the pair explains the take dramatically
            // better. `improvementFactor` is a ratio, not a threshold in
            // samples, so it does not need to know how precise a good
            // measurement is.
            guard let bestCandidate,
                  bestCandidate.solve.residualRMS * improvementFactor < attempt.residualRMS
            else { break }
            active.removeAll { $0 == bestCandidate.pair }
            dropped.append(bestCandidate.pair)
            solution = bestCandidate.solve
        }

        guard let solved = solution else { return nil }

        // Gauge: shift so the earliest placed lane sits at zero.
        let earliest = solved.arrivals.values.min() ?? 0
        let arrivals = solved.arrivals.mapValues { $0 - earliest }

        return AlignmentSolution(
            arrivals: arrivals,
            standardErrors: solved.standardErrors,
            residualRMS: solved.residualRMS,
            pairResiduals: solved.residuals,
            usedPairs: active,
            droppedPairs: dropped,
            triangleResidualRMS: triangleResidualRMS(pairs: active),
            placedLaneIDs: Set(arrivals.keys)
        )
    }

    // MARK: - One weighted least squares pass

    private struct Solve {
        let arrivals: [UUID: Double]
        let standardErrors: [UUID: Double]
        let residuals: [PairObservation: Double]
        let residualRMS: Double
    }

    private static func solveOnce(lanes: [UUID], pairs: [PairObservation]) -> Solve? {
        // Only the largest connected component can be placed on one timeline;
        // a lane nothing agreed with is left out rather than invented.
        let component = largestComponent(lanes: lanes, pairs: pairs)
        guard component.count >= 2 else { return nil }
        let ordered = lanes.filter { component.contains($0) }
        var index: [UUID: Int] = [:]
        for (position, lane) in ordered.enumerated() { index[lane] = position }
        let count = ordered.count
        let inside = pairs.filter { component.contains($0.a) && component.contains($0.b) }
        guard !inside.isEmpty else { return nil }

        // Weighted graph Laplacian plus a rank-one term that fixes the gauge.
        // L is singular along the all-ones vector (shifting every arrival by
        // the same amount changes nothing), and adding J/n makes it invertible
        // while leaving the sum-zero solution untouched. The inverse is also
        // what the standard errors need: (L + J/n)^-1 = L^+ + J/n.
        var matrix = [Double](repeating: 0, count: count * count)
        var rhs = [Double](repeating: 0, count: count)
        for pair in inside {
            guard let i = index[pair.a], let j = index[pair.b] else { continue }
            let w = max(pair.weight, 1e-9)
            matrix[i * count + i] += w
            matrix[j * count + j] += w
            matrix[i * count + j] -= w
            matrix[j * count + i] -= w
            rhs[i] += w * pair.offsetSamples
            rhs[j] -= w * pair.offsetSamples
        }
        let gauge = 1.0 / Double(count)
        for row in 0..<count {
            for column in 0..<count {
                matrix[row * count + column] += gauge
            }
        }

        guard let inverse = invertSymmetric(matrix, count: count) else { return nil }
        var solved = [Double](repeating: 0, count: count)
        for row in 0..<count {
            var sum = 0.0
            for column in 0..<count {
                sum += inverse[row * count + column] * rhs[column]
            }
            solved[row] = sum
        }

        var residuals: [PairObservation: Double] = [:]
        var weightedSquareSum = 0.0
        var squareSum = 0.0
        for pair in inside {
            guard let i = index[pair.a], let j = index[pair.b] else { continue }
            let residual = solved[i] - solved[j] - pair.offsetSamples
            residuals[pair] = residual
            weightedSquareSum += max(pair.weight, 1e-9) * residual * residual
            squareSum += residual * residual
        }
        let degreesOfFreedom = max(1, inside.count - (count - 1))
        // Unbiased when the weights are inverse variances; here they are only
        // relative, so this is a scale for the error bars rather than an
        // absolute variance. The reported RMS below stays unweighted, which is
        // what a reader can compare against "one sample".
        let variance = weightedSquareSum / Double(degreesOfFreedom)

        var arrivals: [UUID: Double] = [:]
        var errors: [UUID: Double] = [:]
        let spare = inside.count > count - 1
        for (position, lane) in ordered.enumerated() {
            arrivals[lane] = solved[position]
            let diagonal = inverse[position * count + position] - gauge
            errors[lane] = spare ? (max(0, variance * diagonal)).squareRoot() : 0
        }

        return Solve(
            arrivals: arrivals,
            standardErrors: errors,
            residuals: residuals,
            residualRMS: (squareSum / Double(inside.count)).squareRoot()
        )
    }

    // MARK: - Linear algebra

    /// Gauss-Jordan inverse with partial pivoting. The matrices here are at
    /// most a few dozen lanes across, so a dense inverse is both simpler and
    /// cheaper than reaching for a solver, and it hands back the diagonal the
    /// standard errors need.
    static func invertSymmetric(_ input: [Double], count: Int) -> [Double]? {
        guard count > 0, input.count == count * count else { return nil }
        var work = input
        var inverse = [Double](repeating: 0, count: count * count)
        for i in 0..<count { inverse[i * count + i] = 1 }

        for column in 0..<count {
            var pivotRow = column
            var pivotValue = abs(work[column * count + column])
            for row in (column + 1)..<count {
                let candidate = abs(work[row * count + column])
                if candidate > pivotValue {
                    pivotValue = candidate
                    pivotRow = row
                }
            }
            guard pivotValue > 1e-12 else { return nil }
            if pivotRow != column {
                for k in 0..<count {
                    work.swapAt(column * count + k, pivotRow * count + k)
                    inverse.swapAt(column * count + k, pivotRow * count + k)
                }
            }
            let pivot = work[column * count + column]
            for k in 0..<count {
                work[column * count + k] /= pivot
                inverse[column * count + k] /= pivot
            }
            for row in 0..<count where row != column {
                let factor = work[row * count + column]
                guard factor != 0 else { continue }
                for k in 0..<count {
                    work[row * count + k] -= factor * work[column * count + k]
                    inverse[row * count + k] -= factor * inverse[column * count + k]
                }
            }
        }
        return inverse
    }

    // MARK: - Graph helpers

    private static func mergeDuplicates(_ pairs: [PairObservation]) -> [PairObservation] {
        var byKey: [Set<UUID>: PairObservation] = [:]
        for pair in pairs where pair.a != pair.b && pair.weight > 0 && pair.offsetSamples.isFinite {
            let key: Set<UUID> = [pair.a, pair.b]
            guard let existing = byKey[key] else {
                byKey[key] = pair
                continue
            }
            // Same two lanes measured twice: keep the better-weighted one
            // rather than averaging estimators that may disagree for a reason.
            let incoming = existing.a == pair.a ? pair : pair.reversed
            if incoming.weight > existing.weight { byKey[key] = incoming }
        }
        return Array(byKey.values)
    }

    private static func neighbours(pairs: [PairObservation]) -> [UUID: Set<UUID>] {
        var map: [UUID: Set<UUID>] = [:]
        for pair in pairs {
            map[pair.a, default: []].insert(pair.b)
            map[pair.b, default: []].insert(pair.a)
        }
        return map
    }

    private static func largestComponent(lanes: [UUID], pairs: [PairObservation]) -> Set<UUID> {
        let adjacency = neighbours(pairs: pairs)
        var seen: Set<UUID> = []
        var best: Set<UUID> = []
        for lane in lanes where !seen.contains(lane) {
            guard adjacency[lane] != nil else { continue }
            var component: Set<UUID> = []
            var stack = [lane]
            while let current = stack.popLast() {
                guard !component.contains(current) else { continue }
                component.insert(current)
                seen.insert(current)
                for next in adjacency[current] ?? [] where !component.contains(next) {
                    stack.append(next)
                }
            }
            if component.count > best.count { best = component }
        }
        return best
    }

    private static func largestComponentSize(lanes: [UUID], pairs: [PairObservation]) -> Int {
        largestComponent(lanes: lanes, pairs: pairs).count
    }

    private static func keepsGraphConnected(
        before: [PairObservation],
        after: [PairObservation],
        lanes: [UUID]
    ) -> Bool {
        largestComponent(lanes: lanes, pairs: after).count
            >= largestComponent(lanes: lanes, pairs: before).count
    }

    /// Median absolute deviation, scaled to a standard deviation. Robust to
    /// the very outlier we are trying to find, which the plain standard
    /// deviation is not.
    static func robustSigma(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let centre = median(values)
        let deviations = values.map { abs($0 - centre) }
        return 1.4826 * median(deviations)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// `tau_ij + tau_jk + tau_ki` must vanish for consistent measurements, and
    /// it does not depend on the fit at all — which is what makes it a genuine
    /// independent check rather than a restatement of the residuals.
    static func triangleResidualRMS(pairs: [PairObservation]) -> Double? {
        var lookup: [Set<UUID>: PairObservation] = [:]
        for pair in pairs { lookup[[pair.a, pair.b]] = pair }
        let lanes = Array(Set(pairs.flatMap { [$0.a, $0.b] }))
        guard lanes.count >= 3 else { return nil }

        func offset(_ from: UUID, _ to: UUID) -> Double? {
            guard let pair = lookup[[from, to]] else { return nil }
            return pair.a == from ? pair.offsetSamples : -pair.offsetSamples
        }

        var squares: [Double] = []
        for i in 0..<lanes.count {
            for j in (i + 1)..<lanes.count {
                for k in (j + 1)..<lanes.count {
                    guard let ij = offset(lanes[i], lanes[j]),
                          let jk = offset(lanes[j], lanes[k]),
                          let ki = offset(lanes[k], lanes[i])
                    else { continue }
                    let sum = ij + jk + ki
                    squares.append(sum * sum)
                }
            }
        }
        guard !squares.isEmpty else { return nil }
        return (squares.reduce(0, +) / Double(squares.count)).squareRoot()
    }
}
