import Foundation

/// Measures when a hand clap reached every lane and how much delay each lane
/// needs so all of them line up on the lane that heard it last.
///
/// The pipeline, per take:
///
/// 1. **Onset** — a 1 ms RMS envelope per lane and its single loudest frame,
///    accepted only when it stands `minDominanceDB` above the median of that
///    envelope and `minOnsetSNRdB` above the head noise floor
///    (`OnsetDetector`).
/// 2. **Reference** — the non-virtual lane that explains the most other lanes.
///    The strongest onsets are tried in turn and the candidate that aligns the
///    most *other* lanes wins, so a lane that caught an unrelated bang cannot
///    take the take hostage. A candidate nobody matched is not a reference at
///    all: the take then fails with `SyncResult.failureSummary` rather than
///    showing one confident lane and no measurement. Virtual devices are
///    measured but never lead, because their timeline is somebody else's
///    clock.
/// 3. **Windows** — `analysisWindowSeconds` starting `preRollSeconds` before
///    each lane's own onset, mean-removed, RMS-normalised, and tapered with an
///    exponential anchored at the onset so late reflections weigh less.
/// 4. **Correlation** — band-limited GCC-PHAT against the reference window
///    (`GCCPHAT`), searched on a quarter-sample grid, with peaks far from the
///    coarse onset difference penalised.
/// 5. **Verdict** — accept when the onset clears `minOnsetSNRdB` and the peak
///    clears `minPeakRatio`; otherwise say why, and leave the lane's delay
///    alone.
/// 6. **Delays** — the latest arrival gets 0, everyone else gets the rounded
///    difference, never negative.
///
/// `analyze` and `analyzeMultiple` are pure: no Core Audio, no I/O, no shared
/// state.
public struct ClapAligner: Sendable {
    public let options: SyncOptions

    public init(options: SyncOptions = .init()) {
        self.options = options
    }

    // MARK: - Single take

    /// Analyses one clap across all lanes of a take.
    ///
    /// - Parameter lanes: pre-delay recordings sharing a sample rate and a
    ///   common time origin.
    public func analyze(_ lanes: [LaneRecording]) -> SyncResult {
        guard let sampleRate = lanes.first?.sampleRate, sampleRate > 0 else {
            return SyncResult(referenceLaneID: nil, lanes: [], sampleRate: 0)
        }

        var preparations: [UUID: LanePreparation] = [:]
        var failures: [UUID: String] = [:]
        for lane in lanes {
            guard lane.sampleRate == sampleRate else {
                failures[lane.laneID] =
                    "sample rate \(Int(lane.sampleRate)) Hz does not match the take"
                continue
            }
            let preparation = prepare(lane, sampleRate: sampleRate)
            preparations[lane.laneID] = preparation
            if let reason = preparation.failureReason { failures[lane.laneID] = reason }
        }

        // Candidate references, strongest onset first. A lane that caught a
        // spurious bang can have the best onset SNR and yet correlate with
        // nobody, so every plausible candidate is tried and the one that
        // explains the most lanes wins. Four candidates is plenty and costs a
        // handful of 2048-point FFTs.
        let candidates = lanes
            .compactMap { preparations[$0.laneID] }
            .filter { !$0.recording.isVirtual && $0.window != nil }
            .sorted { ($0.onset.onsetSNRdB ?? 0) > ($1.onset.onsetSNRdB ?? 0) }
            .prefix(4)

        guard !candidates.isEmpty else {
            let results = lanes.map { lane -> LaneSyncResult in
                let preparation = preparations[lane.laneID]
                let reason = failures[lane.laneID] ?? "no reference lane heard the clap"
                return LaneSyncResult(
                    laneID: lane.laneID,
                    label: lane.label,
                    status: .notDetected(reason: reason),
                    onsetSample: preparation?.onset.onsetSample,
                    onsetSNRdB: preparation?.onset.onsetSNRdB,
                    clipped: preparation?.clipped ?? false,
                    suggestedDelaySamples: nil,
                    suggestedDelayMs: nil,
                    levels: preparation.flatMap { LaneLevels($0.onset) }
                )
            }
            return SyncResult(
                referenceLaneID: nil, lanes: results, sampleRate: sampleRate,
                failureSummary: SyncResult.noClapFailureSummary
            )
        }

        let windowLength = max(16, Int(options.analysisWindowSeconds * sampleRate))
        guard let correlator = GCCPHAT(minimumSize: 2 * windowLength + 2) else {
            let results = lanes.map { lane in
                LaneSyncResult(
                    laneID: lane.laneID, label: lane.label,
                    status: .notDetected(reason: "internal error: FFT setup failed"),
                    onsetSample: nil, onsetSNRdB: nil, clipped: false,
                    suggestedDelaySamples: nil, suggestedDelayMs: nil
                )
            }
            return SyncResult(
                referenceLaneID: nil, lanes: results, sampleRate: sampleRate,
                failureSummary: "Auto Sync could not start its analyser."
            )
        }

        var bestReference = candidates[candidates.startIndex]
        var bestStatuses: [UUID: LaneSyncStatus] = [:]
        var bestScore = -1
        for candidate in candidates {
            guard let referenceWindow = candidate.window else { continue }
            var statuses: [UUID: LaneSyncStatus] = [:]
            var score = 0
            for lane in lanes {
                guard let preparation = preparations[lane.laneID], let window = preparation.window
                else {
                    statuses[lane.laneID] = .notDetected(
                        reason: failures[lane.laneID] ?? "no transient found"
                    )
                    continue
                }
                let measurement = measure(
                    target: preparation,
                    targetWindow: window,
                    reference: candidate,
                    referenceWindow: referenceWindow,
                    correlator: correlator,
                    sampleRate: sampleRate
                )
                let status = verdict(
                    measurement: measurement,
                    snrdB: preparation.onset.onsetSNRdB ?? 0,
                    isReference: lane.laneID == candidate.recording.laneID,
                    sampleRate: sampleRate
                )
                // Only *other* lanes count: a reference is always aligned
                // with itself, and that is exactly the tautology that used to
                // let a take with no clap show one confident lane.
                if status.isAligned, lane.laneID != candidate.recording.laneID { score += 1 }
                statuses[lane.laneID] = status
            }
            if score > bestScore {
                bestScore = score
                bestStatuses = statuses
                bestReference = candidate
            }
        }
        let reference = bestReference

        // Nobody matched the best candidate, so there is no common clap: two
        // lanes have to agree before anything may be written to a delay line.
        guard bestScore > 0 else {
            return failed(
                lanes: lanes,
                wouldBeReferenceID: reference.recording.laneID,
                statuses: bestStatuses,
                preparations: preparations,
                sampleRate: sampleRate
            )
        }

        let statuses = normalisePolarity(bestStatuses)

        return assemble(
            lanes: lanes,
            referenceLaneID: reference.recording.laneID,
            statuses: statuses,
            preparations: preparations,
            sampleRate: sampleRate
        )
    }

    /// The take produced no reference: every lane is `notDetected` and no
    /// delay is suggested, so the sheet can say so and keep Apply switched off.
    private func failed(
        lanes: [LaneRecording],
        wouldBeReferenceID: UUID,
        statuses: [UUID: LaneSyncStatus],
        preparations: [UUID: LanePreparation],
        sampleRate: Double
    ) -> SyncResult {
        let results = lanes.map { lane -> LaneSyncResult in
            let preparation = preparations[lane.laneID]
            let reason: String
            if lane.laneID == wouldBeReferenceID {
                reason = "no other lane matched this clap"
            } else {
                reason = statuses[lane.laneID]?.notDetectedReason
                    ?? preparation?.failureReason
                    ?? "no other lane matched this clap"
            }
            return LaneSyncResult(
                laneID: lane.laneID,
                label: lane.label,
                status: .notDetected(reason: reason),
                onsetSample: preparation?.onset.onsetSample,
                onsetSNRdB: preparation?.onset.onsetSNRdB,
                clipped: preparation?.clipped ?? false,
                suggestedDelaySamples: nil,
                suggestedDelayMs: nil,
                levels: preparation.flatMap { LaneLevels($0.onset) }
            )
        }
        return SyncResult(
            referenceLaneID: nil, lanes: results, sampleRate: sampleRate,
            failureSummary: SyncResult.noClapFailureSummary
        )
    }

    // MARK: - Several takes

    /// Combines several claps into one verdict per lane.
    ///
    /// Each take is analysed on its own — so each take has already had to find
    /// the same clap on two lanes — the per-take offsets are re-expressed
    /// against a lane that was found in as many takes as possible, and the
    /// median across takes is kept. A lane is only `aligned` when at least two
    /// takes agree to within `multiTakeAgreementSeconds` (one take is enough
    /// when only one was given); the median absolute deviation of the takes
    /// scales the reported confidence, so a wobbly measurement never looks as
    /// good as a repeatable one.
    public func analyzeMultiple(_ takes: [[LaneRecording]]) -> SyncResult {
        let takes = takes.filter { !$0.isEmpty }
        guard !takes.isEmpty else {
            return SyncResult(referenceLaneID: nil, lanes: [], sampleRate: 0)
        }
        guard takes.count > 1 else { return analyze(takes[0]) }

        let results = takes.map { analyze($0) }
        let sampleRate = results.first(where: { $0.sampleRate > 0 })?.sampleRate ?? 0

        // Lane order and labels come from the first take that mentions them.
        var order: [UUID] = []
        var labels: [UUID: String] = [:]
        var isVirtual: [UUID: Bool] = [:]
        for take in takes {
            for lane in take where labels[lane.laneID] == nil {
                order.append(lane.laneID)
                labels[lane.laneID] = lane.label
                isVirtual[lane.laneID] = lane.isVirtual
            }
        }

        // A lane that is aligned in the most takes anchors the common frame.
        var alignedCount: [UUID: Int] = [:]
        var confidenceSum: [UUID: Double] = [:]
        for result in results {
            for lane in result.alignedLanes {
                alignedCount[lane.laneID, default: 0] += 1
                confidenceSum[lane.laneID, default: 0] += lane.status.confidence ?? 0
            }
        }
        let anchor = order
            .filter { isVirtual[$0] == false && (alignedCount[$0] ?? 0) > 0 }
            .max { lhs, rhs in
                let left = (alignedCount[lhs] ?? 0, confidenceSum[lhs] ?? 0)
                let right = (alignedCount[rhs] ?? 0, confidenceSum[rhs] ?? 0)
                return left < right
            }

        guard let anchor else {
            let lanes = order.map { laneID in
                let seen = results.compactMap { $0[laneID] }
                return LaneSyncResult(
                    laneID: laneID,
                    label: labels[laneID] ?? "",
                    status: .notDetected(
                        reason: seen.first?.status.notDetectedReason
                            ?? "no other lane matched this clap"
                    ),
                    onsetSample: seen.first?.onsetSample,
                    onsetSNRdB: seen.first?.onsetSNRdB,
                    clipped: seen.contains { $0.clipped },
                    suggestedDelaySamples: nil, suggestedDelayMs: nil,
                    levels: seen.first?.levels
                )
            }
            return SyncResult(
                referenceLaneID: nil, lanes: lanes, sampleRate: sampleRate,
                failureSummary: SyncResult.noClapFailureSummary
            )
        }

        let tolerance = options.multiTakeAgreementSeconds * sampleRate
        var statuses: [UUID: LaneSyncStatus] = [:]
        var onsetSamples: [UUID: Int] = [:]
        var onsetSNRs: [UUID: Double] = [:]
        var levels: [UUID: LaneLevels] = [:]
        var clipped: Set<UUID> = []

        for laneID in order {
            var offsets: [Double] = []
            var confidences: [Double] = []
            var ratios: [Double] = []
            var inversions = 0
            var reasons: [String] = []

            for result in results {
                guard let anchorLane = result[anchor],
                      let anchorOffset = anchorLane.status.offsetSamples,
                      let lane = result[laneID]
                else { continue }
                if lane.clipped { clipped.insert(laneID) }
                if onsetSamples[laneID] == nil, let onset = lane.onsetSample {
                    onsetSamples[laneID] = onset
                    onsetSNRs[laneID] = lane.onsetSNRdB
                }
                if levels[laneID] == nil { levels[laneID] = lane.levels }
                guard case let .aligned(offset, confidence, ratio, inverted) = lane.status else {
                    if let reason = lane.status.notDetectedReason { reasons.append(reason) }
                    continue
                }
                offsets.append(offset - anchorOffset)
                confidences.append(confidence)
                ratios.append(ratio)
                if inverted { inversions += 1 }
            }

            guard !offsets.isEmpty else {
                statuses[laneID] = .notDetected(reason: reasons.first ?? "no transient found")
                continue
            }

            let centre = OnsetDetector.median(offsets)
            let deviations = offsets.map { abs($0 - centre) }
            let inlierIndices = deviations.indices.filter { deviations[$0] <= tolerance }
            let required = min(2, results.count)
            guard inlierIndices.count >= required else {
                let spreadMs = (deviations.max() ?? 0) / sampleRate * 1000
                statuses[laneID] = .notDetected(
                    reason: String(format: "takes disagree by %.1f ms", spreadMs)
                )
                continue
            }

            let inlierOffsets = inlierIndices.map { offsets[$0] }
            let mad = OnsetDetector.median(inlierOffsets.map { abs($0 - centre) })
            let agreement = max(0.5, 1 - (mad / max(tolerance, 1)) * 0.5)
            let confidence = inlierIndices.map { confidences[$0] }.reduce(0, +)
                / Double(inlierIndices.count)
            statuses[laneID] = .aligned(
                offsetSamples: OnsetDetector.median(inlierOffsets),
                confidence: min(1, confidence * agreement),
                peakRatio: OnsetDetector.median(inlierIndices.map { ratios[$0] }),
                polarityInverted: inversions * 2 > offsets.count
            )
        }

        // The anchor is aligned with itself by construction. If the takes
        // agreed about nobody else there is still nothing to measure against,
        // and the take fails exactly as a single one would.
        let matched = statuses.contains { $0.key != anchor && $0.value.isAligned }
        guard matched else {
            let lanes = order.map { laneID in
                LaneSyncResult(
                    laneID: laneID,
                    label: labels[laneID] ?? "",
                    status: .notDetected(
                        reason: laneID == anchor
                            ? "no other lane matched this clap"
                            : (statuses[laneID]?.notDetectedReason ?? "no transient found")
                    ),
                    onsetSample: onsetSamples[laneID],
                    onsetSNRdB: onsetSNRs[laneID],
                    clipped: clipped.contains(laneID),
                    suggestedDelaySamples: nil, suggestedDelayMs: nil,
                    levels: levels[laneID]
                )
            }
            return SyncResult(
                referenceLaneID: nil, lanes: lanes, sampleRate: sampleRate,
                failureSummary: SyncResult.noClapFailureSummary
            )
        }

        let delays = suggestedDelays(order: order, statuses: statuses, sampleRate: sampleRate)
        let lanes = order.map { laneID in
            LaneSyncResult(
                laneID: laneID,
                label: labels[laneID] ?? "",
                status: statuses[laneID] ?? .notDetected(reason: "no transient found"),
                onsetSample: onsetSamples[laneID],
                onsetSNRdB: onsetSNRs[laneID],
                clipped: clipped.contains(laneID),
                suggestedDelaySamples: delays[laneID],
                suggestedDelayMs: delays[laneID].map { Double($0) / sampleRate * 1000 },
                levels: levels[laneID]
            )
        }
        return SyncResult(referenceLaneID: anchor, lanes: lanes, sampleRate: sampleRate)
    }

    // MARK: - Lane preparation

    struct LanePreparation {
        let recording: LaneRecording
        let onset: OnsetAnalysis
        /// First sample of the analysis window inside `recording.samples`.
        let windowStart: Int
        /// Offset of the coarse onset inside the window.
        let anchor: Int
        let window: [Double]?
        let clipped: Bool
        let failureReason: String?
    }

    func prepare(_ lane: LaneRecording, sampleRate: Double) -> LanePreparation {
        let onset = OnsetDetector.analyze(
            samples: lane.samples, sampleRate: sampleRate, options: options
        )
        guard let onsetSample = onset.onsetSample else {
            return LanePreparation(
                recording: lane, onset: onset, windowStart: 0, anchor: 0,
                window: nil,
                clipped: anyClipped(lane.samples, range: 0..<lane.samples.count),
                failureReason: onset.failure?.reason ?? "no dominant transient"
            )
        }

        let windowLength = max(16, Int(options.analysisWindowSeconds * sampleRate))
        let preRoll = max(0, Int(options.preRollSeconds * sampleRate))
        let desiredStart = onsetSample - preRoll
        let start = max(0, desiredStart)
        let end = min(lane.samples.count, desiredStart + windowLength)
        let available = end - start
        let clipped = anyClipped(lane.samples, range: start..<max(start, end))
        guard available >= windowLength / 2 else {
            return LanePreparation(
                recording: lane, onset: onset, windowStart: start, anchor: 0,
                window: nil, clipped: clipped,
                failureReason: "clap too close to the edge of the recording"
            )
        }

        let anchor = onsetSample - start
        var window = [Double](repeating: 0, count: available)
        var sum = 0.0
        for index in 0..<available {
            let value = Double(lane.samples[start + index])
            window[index] = value
            sum += value
        }
        let mean = sum / Double(available)
        var energy = 0.0
        for index in 0..<available {
            window[index] -= mean
            energy += window[index] * window[index]
        }
        let rms = (energy / Double(available)).squareRoot()
        let scale = rms > 1e-12 ? 1 / rms : 0

        // Exponential taper anchored on the onset. exp(-(t - d)/tau) factors
        // into exp(d/tau) * exp(-t/tau), so a window placed a little early or
        // late only rescales the correlation instead of skewing its peak,
        // while an echo arriving d seconds after the direct sound is damped by
        // exp(-d/tau).
        let tau = max(1.0, options.attackTaperSeconds * sampleRate)
        let fade = max(1, min(available / 8, Int(0.001 * sampleRate)))
        for index in 0..<available {
            let distance = Double(index - anchor)
            var weight = distance <= 0 ? 1.0 : exp(-distance / tau)
            if index < fade {
                weight *= 0.5 * (1 - cos(Double.pi * Double(index) / Double(fade)))
            }
            let fromEnd = available - 1 - index
            if fromEnd < fade {
                weight *= 0.5 * (1 - cos(Double.pi * Double(fromEnd) / Double(fade)))
            }
            window[index] *= scale * weight
        }

        return LanePreparation(
            recording: lane, onset: onset, windowStart: start, anchor: anchor,
            window: window, clipped: clipped, failureReason: nil
        )
    }

    private func anyClipped(_ samples: [Float], range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return false }
        let threshold = options.clipThreshold
        for index in range where abs(samples[index]) >= threshold { return true }
        return false
    }

    // MARK: - Correlation

    struct Measurement {
        /// Arrival on this lane minus arrival on the reference, in samples.
        let offsetSamples: Double
        let peakRatio: Double
        let polarityInverted: Bool
        /// Coarse onset difference, used for the search-window check.
        let coarseOffsetSamples: Int
    }

    func measure(
        target: LanePreparation,
        targetWindow: [Double],
        reference: LanePreparation,
        referenceWindow: [Double],
        correlator: GCCPHAT,
        sampleRate: Double
    ) -> Measurement {
        let correlation = correlator.crossCorrelation(
            target: targetWindow,
            reference: referenceWindow,
            sampleRate: sampleRate,
            options: options
        )
        let oversample = correlator.oversample
        let fineCount = correlator.fineCount

        let windowLength = max(16, Int(options.analysisWindowSeconds * sampleRate))
        let maxLag = Int(options.effectiveMaxLagSeconds * sampleRate)
        let searchHalf = min(maxLag, windowLength) * oversample
        let tolerance = max(1.0, options.onsetProximityToleranceSeconds * sampleRate)
            * Double(oversample)
        let centre = (target.anchor - reference.anchor) * oversample
        let exclusion = max(1, Int(options.secondPeakExclusionSeconds * sampleRate) * oversample)

        func weight(_ fineLag: Int) -> Double {
            let distance = abs(Double(fineLag - centre))
            guard distance > tolerance else { return 1 }
            return exp(-(distance - tolerance) / tolerance)
        }

        var bestIndex = centre
        var bestScore = -1.0
        var index = centre - searchHalf
        while index <= centre + searchHalf {
            let wrapped = ((index % fineCount) + fineCount) % fineCount
            let score = abs(correlation[wrapped]) * weight(index)
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
            index += 1
        }

        var runnerUp = 0.0
        index = centre - searchHalf
        while index <= centre + searchHalf {
            if abs(index - bestIndex) > exclusion {
                let wrapped = ((index % fineCount) + fineCount) % fineCount
                runnerUp = max(runnerUp, abs(correlation[wrapped]) * weight(index))
            }
            index += 1
        }

        func sample(_ fineLag: Int) -> Double {
            let wrapped = ((fineLag % fineCount) + fineCount) % fineCount
            return correlation[wrapped]
        }

        // Parabolic vertex on the quarter-sample grid. The grid is exact sinc
        // interpolation of a band-limited function, so three points bracket the
        // peak tightly and the residual bias stays far below a sample.
        let left = abs(sample(bestIndex - 1))
        let peak = abs(sample(bestIndex))
        let right = abs(sample(bestIndex + 1))
        let denominator = left - 2 * peak + right
        var refinement = 0.0
        if abs(denominator) > 1e-18 {
            refinement = 0.5 * (left - right) / denominator
            refinement = min(max(refinement, -1), 1)
        }

        let fineLag = Double(bestIndex) + refinement
        let lagSamples = fineLag / Double(oversample)
        let windowOffset = Double(target.windowStart - reference.windowStart)
        let coarse = (target.onset.onsetSample ?? 0) - (reference.onset.onsetSample ?? 0)
        let ratio = runnerUp > 1e-18 ? bestScore / runnerUp : Double.greatestFiniteMagnitude

        return Measurement(
            offsetSamples: windowOffset + lagSamples,
            peakRatio: ratio,
            polarityInverted: sample(bestIndex) < 0,
            coarseOffsetSamples: coarse
        )
    }

    /// Polarity is measured against the reference lane, so picking a lane that
    /// happens to be wired backwards would flag everybody else. When most
    /// aligned lanes come out inverted the reference is the odd one, so the
    /// flags are turned around. With two lanes there is no majority and the
    /// flag stays relative to the reference.
    private func normalisePolarity(_ statuses: [UUID: LaneSyncStatus]) -> [UUID: LaneSyncStatus] {
        let aligned = statuses.values.filter(\.isAligned)
        let inverted = aligned.filter(\.polarityInverted).count
        guard inverted * 2 > aligned.count else { return statuses }
        return statuses.mapValues { status in
            guard case let .aligned(offset, confidence, ratio, wasInverted) = status else {
                return status
            }
            return .aligned(
                offsetSamples: offset,
                confidence: confidence,
                peakRatio: ratio,
                polarityInverted: !wasInverted
            )
        }
    }

    // MARK: - Verdict

    private func verdict(
        measurement: Measurement,
        snrdB: Double,
        isReference: Bool,
        sampleRate: Double
    ) -> LaneSyncStatus {
        let ratio = min(measurement.peakRatio, 1e6)
        if isReference {
            return .aligned(
                offsetSamples: 0,
                confidence: confidence(peakRatio: ratio, snrdB: snrdB),
                peakRatio: ratio,
                polarityInverted: false
            )
        }
        let maxLag = options.effectiveMaxLagSeconds * sampleRate
        guard Double(abs(measurement.coarseOffsetSamples)) <= maxLag,
              abs(measurement.offsetSamples) <= maxLag
        else {
            let arrival = Double(measurement.coarseOffsetSamples) / sampleRate * 1000
            return .notDetected(reason: String(
                format: "arrival %+.0f ms is outside the ±%.0f ms search window",
                arrival, options.effectiveMaxLagSeconds * 1000
            ))
        }
        guard snrdB >= options.minOnsetSNRdB else {
            return .notDetected(reason: String(
                format: "onset only %.1f dB above the noise floor", snrdB
            ))
        }
        guard ratio >= options.minPeakRatio else {
            return .notDetected(reason: String(
                format: "correlation ambiguous (ratio %.1f)", ratio
            ))
        }
        return .aligned(
            offsetSamples: measurement.offsetSamples,
            confidence: confidence(peakRatio: ratio, snrdB: snrdB),
            peakRatio: ratio,
            polarityInverted: measurement.polarityInverted
        )
    }

    /// Heuristic 0...1 blend of peak sharpness and onset strength. It exists to
    /// colour the result page, not to gate anything: the gates are
    /// `minPeakRatio` and `minOnsetSNRdB`.
    private func confidence(peakRatio: Double, snrdB: Double) -> Double {
        let ratioSpan = max(options.minPeakRatio * 2 - 1, 0.5)
        let ratioScore = clamp01((peakRatio - 1) / ratioSpan)
        let snrScore = clamp01(0.3 + 0.7 * (snrdB - options.minOnsetSNRdB) / 18)
        return clamp01(0.65 * ratioScore + 0.35 * snrScore)
    }

    private func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }

    // MARK: - Assembly

    private func assemble(
        lanes: [LaneRecording],
        referenceLaneID: UUID,
        statuses: [UUID: LaneSyncStatus],
        preparations: [UUID: LanePreparation],
        sampleRate: Double
    ) -> SyncResult {
        let delays = suggestedDelays(
            order: lanes.map(\.laneID), statuses: statuses, sampleRate: sampleRate
        )
        let results = lanes.map { lane -> LaneSyncResult in
            let preparation = preparations[lane.laneID]
            let delay = delays[lane.laneID]
            return LaneSyncResult(
                laneID: lane.laneID,
                label: lane.label,
                status: statuses[lane.laneID] ?? .notDetected(reason: "no transient found"),
                onsetSample: preparation?.onset.onsetSample,
                onsetSNRdB: preparation?.onset.onsetSNRdB,
                clipped: preparation?.clipped ?? false,
                suggestedDelaySamples: delay,
                suggestedDelayMs: delay.map { Double($0) / sampleRate * 1000 },
                levels: preparation.flatMap { LaneLevels($0.onset) }
            )
        }
        return SyncResult(
            referenceLaneID: referenceLaneID, lanes: results, sampleRate: sampleRate
        )
    }

    /// Latest arrival gets 0, everybody else gets a rounded catch-up delay.
    /// Lanes that were not detected are absent from the result.
    private func suggestedDelays(
        order: [UUID],
        statuses: [UUID: LaneSyncStatus],
        sampleRate: Double
    ) -> [UUID: Int] {
        let offsets = order.compactMap { statuses[$0]?.offsetSamples }
        guard let latest = offsets.max() else { return [:] }
        var delays: [UUID: Int] = [:]
        for laneID in order {
            guard let offset = statuses[laneID]?.offsetSamples else { continue }
            delays[laneID] = max(0, Int((latest - offset).rounded()))
        }
        return delays
    }
}
