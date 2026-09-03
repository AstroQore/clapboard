# Sync — Auto Sync analysis

From each lane's *pre-delay* recording of a hand clap, work out when the clap
reached that lane and what delay lines it up with the lane that heard it last.
No Core Audio, no real-time code, no UI; `ClapAligner.analyze` is pure.

## Pipeline

1. **Onset** (`OnsetDetector`) — 1 ms RMS envelope, hop 0.25 ms. Noise floor is
   the median frame RMS of the first `noiseFloorSeconds`, silent frames ignored.
   The onset is the first frame both `minOnsetSNRdB` above it and twice its own
   recent past, which keeps swells and steady music out.
2. **Reference** — non-virtual lanes with an onset, strongest first; each is
   tried and the one that aligns the most lanes wins, so a lane that caught an
   unrelated bang cannot hijack the take. Virtual lanes never lead.
3. **Window** — `analysisWindowSeconds` from `preRollSeconds` before that lane's
   own onset, mean removed, RMS normalised, tapered by `exp(-t/tau)` (tau =
   `attackTaperSeconds`) anchored at the onset. Exponentials factorise, so a
   window placed a millisecond early only rescales the correlation instead of
   biasing its peak, while a reflection `d` later is damped by `exp(-d/tau)` —
   this, not the window length, is what stops 5–40 ms echoes stealing the peak.
4. **Correlation** (`GCCPHAT`) — `target * conj(reference)` weighted by
   `|·|^-phatBeta`, zeroed outside `bandHz`, inverse transformed four times
   oversampled (zero padding the spectrum is exact sinc interpolation), peaks
   far from the coarse onset difference penalised, vertex refined parabolically.
   `peakRatio` is the main peak over the best competitor more than
   `secondPeakExclusionSeconds` away; a negative peak sets `polarityInverted`.
5. **Verdict** — aligned when onset SNR ≥ `minOnsetSNRdB`, `peakRatio` ≥
   `minPeakRatio` and the arrival is inside ±`maxLagSeconds`; otherwise
   `notDetected` with a reason to show, and the lane's delay is left alone.
6. **Delays** — latest arrival 0, the rest the rounded difference, never
   negative. `analyzeMultiple` medians takes, needing two that agree inside
   `multiTakeAgreementSeconds`; `SyncVerifier.residual` re-measures afterwards.

## Tuning

`SyncOptions` defaults suit a 48 kHz hand clap. Raise `maxLagSeconds` (to 1 s)
for laggy radio links, drop `minPeakRatio` towards 2 in a hard room where lanes
get refused, raise `attackTaperSeconds` for a dull clap. `phatBeta` 1 whitens
fully and amplifies empty bands, 0 is plain correlation.
