import Foundation

/// Re-measures a lane after its Auto Sync delay has been applied.
///
/// This is the "Verify" step of the Auto Sync flow: once the suggested delays
/// are written into the lanes, a second clap should land on every lane at the
/// same instant. Feed the recording of that clap back in and the residual says
/// how far off the alignment still is.
public enum SyncVerifier {
    /// Residual misalignment, in samples, of `lane` delayed by
    /// `appliedDelaySamples` against `reference`.
    ///
    /// Pass the lane that Auto Sync gave a delay of 0 (the latest arrival) as
    /// `reference`; a correct measurement then returns something within a
    /// sample of zero. Positive means the delayed lane is still late.
    ///
    /// - Returns: `nil` when either recording fails detection, in which case
    ///   there is nothing to compare.
    public static func residual(
        reference: LaneRecording,
        lane: LaneRecording,
        appliedDelaySamples: Int,
        options: SyncOptions = SyncOptions()
    ) -> Double? {
        guard reference.sampleRate == lane.sampleRate, reference.sampleRate > 0 else { return nil }
        let sampleRate = reference.sampleRate

        let padding = max(0, appliedDelaySamples)
        var delayed = [Float](repeating: 0, count: padding)
        delayed.append(contentsOf: lane.samples)
        let delayedLane = LaneRecording(
            laneID: lane.laneID,
            label: lane.label,
            samples: delayed,
            sampleRate: sampleRate,
            isVirtual: lane.isVirtual
        )

        let aligner = ClapAligner(options: options)
        let referencePreparation = aligner.prepare(reference, sampleRate: sampleRate)
        let lanePreparation = aligner.prepare(delayedLane, sampleRate: sampleRate)
        guard let referenceWindow = referencePreparation.window,
              let laneWindow = lanePreparation.window,
              let referenceSNR = referencePreparation.onset.onsetSNRdB,
              let laneSNR = lanePreparation.onset.onsetSNRdB,
              referenceSNR >= options.minOnsetSNRdB,
              laneSNR >= options.minOnsetSNRdB
        else { return nil }

        let windowLength = max(16, Int(options.analysisWindowSeconds * sampleRate))
        guard let correlator = GCCPHAT(minimumSize: 2 * windowLength + 2) else { return nil }
        let measurement = aligner.measure(
            target: lanePreparation,
            targetWindow: laneWindow,
            reference: referencePreparation,
            referenceWindow: referenceWindow,
            correlator: correlator,
            sampleRate: sampleRate
        )
        guard measurement.peakRatio >= options.minPeakRatio else { return nil }
        return measurement.offsetSamples
    }
}
