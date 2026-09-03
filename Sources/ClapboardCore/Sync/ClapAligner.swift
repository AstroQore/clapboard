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
    /// Span of the envelope taken around each lane's onset. Long enough to
    /// hold a clap and its early reflections, short enough that correlating
    /// it stays cheap. Physical, not a tuning knob.
    static let envelopeSpanSeconds = 0.12
    /// How far the envelope estimator may move away from the onset difference.
    /// This is the budget for a wrong onset, not for a real arrival
    /// difference: arrivals themselves are bounded by `maxLagSeconds`.
    static let envelopeSearchSeconds = 0.03

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

        // An energy envelope per lane, taken around that lane's own onset.
        // These give every pair its coarse bracket, and they are what carries
        // a clipped lane whose waveform no longer resembles anyone else's.
        // Envelopes cover a span rather than the whole take on purpose: the
        // onsets already locate the clap to within a few milliseconds, so
        // correlating minutes of room tone would only cost time.
        let hop = max(1, Int((options.envelopeHopSeconds * sampleRate).rounded()))
        let envelopeWindow = max(
            hop, Int((options.envelopeWindowSeconds * sampleRate).rounded())
        )
        let usable = lanes.filter { preparations[$0.laneID]?.window != nil }
        var envelopes: [UUID: LaneEnvelope] = [:]
        for lane in usable {
            guard let onset = preparations[lane.laneID]?.onset.onsetSample else { continue }
            let start = max(0, onset - Int(options.preRollSeconds * sampleRate))
            let length = min(
                lane.samples.count - start,
                Int(Self.envelopeSpanSeconds * sampleRate)
            )
            guard length > envelopeWindow else { continue }
            let span = Array(lane.samples[start..<(start + length)])
            envelopes[lane.laneID] = LaneEnvelope(
                start: start,
                hop: hop,
                points: EnvelopeCorrelator.logEnvelope(
                    EnvelopeCorrelator.envelope(samples: span, window: envelopeWindow, hop: hop)
                )
            )
        }

        // Every pair is measured on its own, and no lane is a reference: with
        // N lanes there are N(N-1)/2 measurements for N-1 unknown arrival
        // times, and the fit below uses all of them at once. The redundancy is
        // the point — it is what lets a single bad measurement be identified
        // instead of quietly biasing every lane.
        var estimates: [PairKey: PairEstimate] = [:]
        var rejections: [UUID: String] = [:]
        for first in 0..<usable.count {
            for second in (first + 1)..<usable.count {
                let outcome = pairEstimate(
                    a: usable[first], b: usable[second],
                    preparations: preparations, envelopes: envelopes,
                    hop: hop, correlator: correlator, sampleRate: sampleRate
                )
                switch outcome {
                case .measured(let estimate):
                    estimates[PairKey(usable[first].laneID, usable[second].laneID)] = estimate
                case .rejected(let reason):
                    // Keep the most specific complaint per lane: "ambiguous"
                    // tells the user their two microphones heard different
                    // things, which is more use than "nothing matched".
                    for lane in [usable[first].laneID, usable[second].laneID] {
                        if rejections[lane] == nil || reason.contains("ambiguous") {
                            rejections[lane] = reason
                        }
                    }
                }
            }
        }

        let solution = PairwiseAlignment.solve(
            lanes: lanes.map(\.laneID),
            pairs: estimates.values.map(\.observation)
        )

        // Two lanes have to agree on one clap before anything may be written
        // to a delay line. A lane that matched nobody is not a measurement.
        guard let solution, solution.placedLaneIDs.count >= 2 else {
            return failed(
                lanes: lanes,
                wouldBeReferenceID: usable.first?.laneID,
                // Pair-level complaints are the useful ones here: "outside the
                // search window" or "correlation ambiguous" tells the user what
                // to change, where a bare "nothing matched" does not.
                statuses: failures
                    .merging(rejections) { hard, _ in hard }
                    .mapValues { LaneSyncStatus.notDetected(reason: $0) },
                preparations: preparations,
                sampleRate: sampleRate
            )
        }

        return assemble(
            lanes: lanes,
            statuses: laneStatuses(
                lanes: lanes,
                solution: solution,
                estimates: estimates,
                preparations: preparations,
                failures: failures,
                rejections: rejections
            ),
            preparations: preparations,
            solution: solution,
            sampleRate: sampleRate
        )
    }

    // MARK: - Pairs

    /// An unordered lane pair, so one measurement is stored once however it
    /// was taken.
    struct PairKey: Hashable {
        let low: UUID
        let high: UUID

        init(_ a: UUID, _ b: UUID) {
            if a.uuidString < b.uuidString {
                low = a
                high = b
            } else {
                low = b
                high = a
            }
        }

        func contains(_ lane: UUID) -> Bool { low == lane || high == lane }
    }

    /// One lane's envelope with the absolute sample it starts at, so a lag
    /// measured between two of them can be turned back into an arrival
    /// difference on the take's own timeline.
    struct LaneEnvelope {
        let start: Int
        let hop: Int
        let points: [Double]
    }

    /// Why a pair could not be measured, or the measurement itself. The
    /// reason is carried so an unplaced lane can say something better than
    /// "nothing matched".
    enum PairOutcome {
        case measured(PairEstimate)
        case rejected(reason: String)
    }

    struct PairEstimate {
        let observation: PairObservation
        let envelopeCorrelation: Double
        let waveformPeakRatio: Double
        let polarityInverted: Bool
        /// True when the waveform estimator agreed with the envelope bracket,
        /// so its finer answer was the one kept.
        let refinedByWaveform: Bool
    }

    /// Measures one pair twice and keeps the answer the two estimators agree
    /// on.
    ///
    /// The envelope estimator asks when the energy arrived. That survives
    /// clipping, and two microphones with nothing in common but the room they
    /// are standing in. The waveform estimator asks when the two look alike,
    /// which is sub-sample accurate but needs the shapes to actually match.
    /// Requiring them to agree within `waveformAgreementSeconds` is what makes
    /// a confident answer trustworthy; when they disagree the coarse one is
    /// kept, because that is the one that degrades gracefully rather than
    /// locking onto a reflection.
    func pairEstimate(
        a: LaneRecording,
        b: LaneRecording,
        preparations: [UUID: LanePreparation],
        envelopes: [UUID: LaneEnvelope],
        hop: Int,
        correlator: GCCPHAT,
        sampleRate: Double
    ) -> PairOutcome {
        guard let prepA = preparations[a.laneID], let windowA = prepA.window,
              let prepB = preparations[b.laneID], let windowB = prepB.window,
              let envelopeA = envelopes[a.laneID], let envelopeB = envelopes[b.laneID]
        else { return .rejected(reason: "no transient found") }

        let maxLagSamples = options.effectiveMaxLagSeconds * sampleRate
        let searchPoints = max(1, Int((Self.envelopeSearchSeconds * sampleRate / Double(hop)).rounded()))
        let match = EnvelopeCorrelator.match(
            target: envelopeA.points,
            reference: envelopeB.points,
            maxLagPoints: searchPoints
        )
        // No agreement on the envelopes means these two transients did not
        // even arrive together, whatever they looked like.
        guard let match, match.correlation >= options.minEnvelopeCorrelation else {
            return .rejected(reason: String(
                format: "energy did not arrive together (envelope match %.2f)",
                match?.correlation ?? 0
            ))
        }
        // The lag is measured between two spans that start at different
        // absolute samples, so the span offset has to be added back.
        let envelopeOffset = Double(envelopeA.start - envelopeB.start)
            + match.lagPoints * Double(hop)
        guard abs(envelopeOffset) <= maxLagSamples else {
            return .rejected(reason: String(
                format: "arrival %+.0f ms is outside the +/-%.0f ms search window",
                envelopeOffset / sampleRate * 1000, options.effectiveMaxLagSeconds * 1000
            ))
        }

        let measurement = measure(
            target: prepA,
            targetWindow: windowA,
            reference: prepB,
            referenceWindow: windowB,
            correlator: correlator,
            sampleRate: sampleRate,
            expectedOffsetSamples: envelopeOffset
        )
        // The waveform has the final say. Two different transients in the same
        // room have near-identical energy envelopes — every clap decays the
        // same way — so an envelope match alone would happily tie one lane's
        // door slam to another lane's clap. Only the same acoustic event
        // shares a waveform, and inside a bracket a few milliseconds wide a
        // modest peak ratio already settles it.
        let agreement = options.waveformAgreementSeconds * sampleRate
        guard abs(measurement.offsetSamples - envelopeOffset) <= agreement else {
            return .rejected(reason: "the two estimators disagree about this pair")
        }
        guard measurement.peakRatio >= options.minBracketedPeakRatio else {
            return .rejected(reason: String(
                format: "correlation ambiguous (ratio %.1f)", measurement.peakRatio
            ))
        }

        // The weight is relative trust rather than a variance: the envelope
        // correlation says the two lanes heard one event, and the waveform peak
        // ratio says the fine answer is sharp.
        let weight = max(0.05, match.correlation) * min(measurement.peakRatio, 12)

        return .measured(PairEstimate(
            observation: PairObservation(
                a: a.laneID,
                b: b.laneID,
                offsetSamples: measurement.offsetSamples,
                weight: weight,
                estimator: "waveform"
            ),
            envelopeCorrelation: match.correlation,
            waveformPeakRatio: measurement.peakRatio,
            polarityInverted: measurement.polarityInverted,
            refinedByWaveform: true
        ))
    }

    /// Turns the fit into one verdict per lane.
    private func laneStatuses(
        lanes: [LaneRecording],
        solution: AlignmentSolution,
        estimates: [PairKey: PairEstimate],
        preparations: [UUID: LanePreparation],
        failures: [UUID: String],
        rejections: [UUID: String]
    ) -> [UUID: LaneSyncStatus] {
        // Polarity is only ever relative. A lane is called inverted when most
        // of its own pairs say so, and the whole take is flipped when most
        // lanes come out that way — otherwise one backwards-wired microphone
        // would put the marker on everybody else.
        var invertedLanes: Set<UUID> = []
        for lane in lanes where solution.placedLaneIDs.contains(lane.laneID) {
            let mine = estimates.filter {
                $0.key.contains(lane.laneID) && $0.value.refinedByWaveform
            }
            guard !mine.isEmpty else { continue }
            let inverted = mine.filter { $0.value.polarityInverted }.count
            if inverted * 2 > mine.count { invertedLanes.insert(lane.laneID) }
        }
        if invertedLanes.count * 2 > solution.placedLaneIDs.count {
            invertedLanes = solution.placedLaneIDs.subtracting(invertedLanes)
        }

        var statuses: [UUID: LaneSyncStatus] = [:]
        for lane in lanes {
            guard let arrival = solution.arrivals[lane.laneID] else {
                statuses[lane.laneID] = .notDetected(
                    reason: failures[lane.laneID]
                        ?? preparations[lane.laneID]?.failureReason
                        ?? rejections[lane.laneID]
                        ?? "no other lane matched this clap"
                )
                continue
            }
            let mine = estimates.filter { $0.key.contains(lane.laneID) }.values
            let bestRatio = mine.map(\.waveformPeakRatio).max() ?? 1
            statuses[lane.laneID] = .aligned(
                // Arrivals are gauge-fixed to "earliest lane is zero", so this
                // is an absolute position in the take rather than a difference
                // from some chosen lane, and it is never negative.
                offsetSamples: arrival,
                confidence: confidence(
                    standardError: solution.standardErrors[lane.laneID] ?? 0,
                    residualRMS: solution.residualRMS,
                    envelopeCorrelation: mine.map(\.envelopeCorrelation).max() ?? 0,
                    peakRatio: bestRatio,
                    sampleRate: lane.sampleRate
                ),
                peakRatio: bestRatio,
                polarityInverted: invertedLanes.contains(lane.laneID)
            )
        }
        return statuses
    }

    /// The take produced no reference: every lane is `notDetected` and no
    /// delay is suggested, so the sheet can say so and keep Apply switched off.
    private func failed(
        lanes: [LaneRecording],
        wouldBeReferenceID: UUID?,
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

        // Re-gauge to "earliest lane is zero" so several takes read the same
        // way a single take does. The anchor was only ever a common frame to
        // combine the takes in, never a lane the user should see.
        let placed = order.compactMap { statuses[$0]?.offsetSamples }
        if let earliest = placed.min(), earliest != 0 {
            for laneID in order {
                guard case let .aligned(offset, confidence, ratio, inverted) = statuses[laneID]
                else { continue }
                statuses[laneID] = .aligned(
                    offsetSamples: offset - earliest,
                    confidence: confidence,
                    peakRatio: ratio,
                    polarityInverted: inverted
                )
            }
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
        var combined = SyncResult(
            referenceLaneID: nil, lanes: lanes, sampleRate: sampleRate
        )
        combined.arrivals = Dictionary(
            uniqueKeysWithValues: order.compactMap { laneID in
                statuses[laneID]?.offsetSamples.map { (laneID, $0) }
            }
        )
        return combined
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
        sampleRate: Double,
        expectedOffsetSamples: Double? = nil
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
        let windowOffset = Double(target.windowStart - reference.windowStart)
        let exclusion = max(1, Int(options.secondPeakExclusionSeconds * sampleRate) * oversample)

        // With a bracket from the envelope estimator the search is a few
        // milliseconds wide around an answer that is already roughly right,
        // which is what stops a reflection or an unrelated transient from
        // winning. Without one it falls back to the coarse onset difference
        // and the full window.
        let centre: Int
        let searchHalf: Int
        let tolerance: Double
        if let expected = expectedOffsetSamples {
            centre = Int(((expected - windowOffset) * Double(oversample)).rounded())
            searchHalf = max(
                oversample,
                Int(options.waveformAgreementSeconds * sampleRate) * oversample
            )
            // Inside the bracket every lag is equally plausible: the envelope
            // has already ruled out everything outside it.
            tolerance = Double(searchHalf)
        } else {
            centre = (target.anchor - reference.anchor) * oversample
            searchHalf = min(maxLag, windowLength) * oversample
            tolerance = max(1.0, options.onsetProximityToleranceSeconds * sampleRate)
                * Double(oversample)
        }

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
        let coarse = (target.onset.onsetSample ?? 0) - (reference.onset.onsetSample ?? 0)
        let ratio = runnerUp > 1e-18 ? bestScore / runnerUp : Double.greatestFiniteMagnitude

        return Measurement(
            offsetSamples: windowOffset + lagSamples,
            peakRatio: ratio,
            polarityInverted: sample(bestIndex) < 0,
            coarseOffsetSamples: coarse
        )
    }

    /// Confidence for the results sheet, 0...1.
    ///
    /// It leans on the fit rather than on any single correlation: a take
    /// whose pairs disagree with each other cannot look good however sharp
    /// one of them was. With only two lanes the fit has nothing spare to
    /// measure itself with, so the pair quality stands in.
    private func confidence(
        standardError: Double,
        residualRMS: Double,
        envelopeCorrelation: Double,
        peakRatio: Double,
        sampleRate: Double
    ) -> Double {
        // Half a millisecond is the scale that matters to a listener: past it
        // the lanes are audibly not aligned.
        let scale = max(1.0, 0.0005 * sampleRate)
        let fit = standardError > 0
            ? clamp01(1 - standardError / scale)
            : clamp01(0.55 + 0.45 * (min(peakRatio, 8) - 1) / 7)
        let agreement = clamp01(1 - residualRMS / scale)
        let similarity = clamp01(
            (envelopeCorrelation - options.minEnvelopeCorrelation)
                / max(0.01, 1 - options.minEnvelopeCorrelation)
        )
        return clamp01(0.5 * fit + 0.3 * agreement + 0.2 * similarity)
    }

    private func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }

    // MARK: - Assembly

    private func assemble(
        lanes: [LaneRecording],
        statuses: [UUID: LaneSyncStatus],
        preparations: [UUID: LanePreparation],
        solution: AlignmentSolution,
        sampleRate: Double
    ) -> SyncResult {
        let delays = solution.delaysSamples()
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
        var result = SyncResult(
            referenceLaneID: nil, lanes: results, sampleRate: sampleRate
        )
        result.arrivals = solution.arrivals
        result.fitResidualSamples = solution.residualRMS
        result.triangleResidualSamples = solution.triangleResidualRMS
        result.pairs = solution.usedPairs
        result.droppedPairs = solution.droppedPairs
        return result
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
