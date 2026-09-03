import Foundation

/// Tunables for `ClapAligner`, `OnsetDetector` and `SyncVerifier`.
///
/// Every duration is in seconds and is converted to samples against the
/// recording's own sample rate, so one option set works at any rate.
/// The defaults are tuned for a hand clap recorded at 48 kHz.
public struct SyncOptions: Sendable, Equatable {
    /// Largest arrival difference the analyser will accept between a lane and
    /// the reference lane. Lanes further away are reported as `notDetected`
    /// rather than silently wrapped onto a wrong peak. Clamped to 1 s.
    public var maxLagSeconds: Double

    /// A lane's onset must rise this far above its own noise floor to count as
    /// a transient.
    public var minOnsetSNRdB: Double

    /// How far the loudest 1 ms window must stand above the *median* 1 ms
    /// window of the whole take before it is called a clap.
    ///
    /// This is the gate that separates a clap from a room: speech, a chair and
    /// a door are all 10–15 dB above the floor and so is half of a busy room's
    /// noise, but only a clap is 20 dB louder than everything else in the take.
    public var minDominanceDB: Double

    /// How far below the peak the attack search walks back to find the onset.
    /// The onset is the first frame after the last one still `riseDB` under
    /// the peak.
    public var riseDB: Double

    /// Main correlation peak divided by the strongest competing peak. Below
    /// this the match is called ambiguous and the lane is left alone.
    public var minPeakRatio: Double

    /// Length of the window taken around each lane's coarse onset and fed to
    /// the cross correlation. Short enough to keep late reflections out.
    public var analysisWindowSeconds: Double

    /// How much of the signal before the coarse onset the window keeps, so a
    /// slightly late onset estimate still contains the true attack.
    public var preRollSeconds: Double

    /// Frequency band the cross correlation is restricted to. Below the band
    /// live rumble and handling noise, above it live the parts of a clap that
    /// differ most between microphones.
    public var bandHz: ClosedRange<Double>

    /// PHAT exponent. 0 = plain cross correlation, 1 = phase only. Values near
    /// 0.7 whiten the room response without amplifying empty bands.
    public var phatBeta: Double

    /// Samples at or above this magnitude mark the lane as clipped.
    public var clipThreshold: Float

    /// Leading part of the recording used to estimate the noise floor. Must be
    /// clap-free; the aligner also ignores digitally silent frames in it.
    public var noiseFloorSeconds: Double

    /// RMS envelope window (and its hop is a quarter of it).
    public var envelopeWindowSeconds: Double

    /// Time constant of the exponential taper applied to the analysis window,
    /// anchored at the coarse onset. Because an exponential factorises, a
    /// small misplacement of the window only scales the correlation and does
    /// not bias its peak, while echoes arriving `d` seconds late are
    /// attenuated by `exp(-d / attackTaperSeconds)`.
    public var attackTaperSeconds: Double

    /// Correlation peaks further than this from the coarse onset difference
    /// are penalised, which stops a strong late reflection or an unrelated
    /// transient from winning the search.
    public var onsetProximityToleranceSeconds: Double

    /// Half-width of the region around the main peak excluded when looking for
    /// the competing peak that forms `peakRatio`.
    public var secondPeakExclusionSeconds: Double

    /// A lane whose peak magnitude stays below this is reported as silent.
    public var silenceThreshold: Float

    /// `analyzeMultiple` calls two takes agreeing when their offsets differ by
    /// less than this.
    public var multiTakeAgreementSeconds: Double

    /// Hop of the energy envelope used by the pair estimator. It sets the
    /// resolution of the coarse bracket, not of the final answer.
    public var envelopeHopSeconds: Double

    /// Pearson correlation an envelope match must reach before a pair is
    /// believed. Envelopes of the same clap on two microphones correlate well
    /// above 0.8; unrelated noise sits near zero.
    public var minEnvelopeCorrelation: Double

    /// How far the waveform estimator may sit from the envelope bracket and
    /// still be believed. Beyond it the two disagree and the pair is refused
    /// rather than guessed at.
    public var waveformAgreementSeconds: Double

    /// Peak-to-runner-up ratio the waveform correlation must reach *inside*
    /// the envelope bracket.
    ///
    /// It is lower than `minPeakRatio` on purpose. That one guarded a search
    /// across the whole +/-250 ms window, where a spurious peak has hundreds of
    /// milliseconds of noise to win in; here the search is a few milliseconds
    /// wide, so the same ratio is much stronger evidence. This is the gate
    /// that proves two lanes recorded the *same* event rather than two events
    /// that merely look alike: every clap has a similar energy envelope, but
    /// only the same clap shares a waveform.
    public var minBracketedPeakRatio: Double

    public init(
        maxLagSeconds: Double = 0.25,
        minOnsetSNRdB: Double = 12,
        minDominanceDB: Double = 20,
        riseDB: Double = 20,
        minPeakRatio: Double = 3.0,
        analysisWindowSeconds: Double = 0.02,
        preRollSeconds: Double = 0.005,
        bandHz: ClosedRange<Double> = 500...8000,
        phatBeta: Double = 0.7,
        clipThreshold: Float = 0.99,
        noiseFloorSeconds: Double = 0.3,
        envelopeWindowSeconds: Double = 0.001,
        attackTaperSeconds: Double = 0.006,
        onsetProximityToleranceSeconds: Double = 0.010,
        secondPeakExclusionSeconds: Double = 0.001,
        silenceThreshold: Float = 1e-5,
        multiTakeAgreementSeconds: Double = 0.0005,
        envelopeHopSeconds: Double = 0.00025,
        minEnvelopeCorrelation: Double = 0.4,
        waveformAgreementSeconds: Double = 0.003,
        minBracketedPeakRatio: Double = 1.8
    ) {
        self.maxLagSeconds = maxLagSeconds
        self.minOnsetSNRdB = minOnsetSNRdB
        self.minDominanceDB = minDominanceDB
        self.riseDB = riseDB
        self.minPeakRatio = minPeakRatio
        self.analysisWindowSeconds = analysisWindowSeconds
        self.preRollSeconds = preRollSeconds
        self.bandHz = bandHz
        self.phatBeta = phatBeta
        self.clipThreshold = clipThreshold
        self.noiseFloorSeconds = noiseFloorSeconds
        self.envelopeWindowSeconds = envelopeWindowSeconds
        self.attackTaperSeconds = attackTaperSeconds
        self.onsetProximityToleranceSeconds = onsetProximityToleranceSeconds
        self.secondPeakExclusionSeconds = secondPeakExclusionSeconds
        self.silenceThreshold = silenceThreshold
        self.multiTakeAgreementSeconds = multiTakeAgreementSeconds
        self.envelopeHopSeconds = envelopeHopSeconds
        self.minEnvelopeCorrelation = minEnvelopeCorrelation
        self.waveformAgreementSeconds = waveformAgreementSeconds
        self.minBracketedPeakRatio = minBracketedPeakRatio
    }

    /// `maxLagSeconds` clamped to the supported 1 ms ... 1 s range.
    public var effectiveMaxLagSeconds: Double {
        min(max(maxLagSeconds, 0.001), 1.0)
    }
}
