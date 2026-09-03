# Sync — Auto Sync analysis

From each lane's *pre-delay* recording of a hand clap, work out when the clap
reached that lane and what delay lines it up with the lane that heard it last.
No Core Audio, no real-time code, no UI; `ClapAligner.analyze` is pure.

## Pipeline

1. **Onset** (`OnsetDetector`) — 1 ms RMS envelope, hop 0.25 ms, over the whole
   recording. The **loudest** frame is the only candidate, and it is accepted
   only when it stands `minDominanceDB` above the *median* of that envelope —
   what the room sounds like the rest of the time — **and** `minOnsetSNRdB`
   above the noise floor (the median frame RMS of the first
   `noiseFloorSeconds`, silent frames ignored). The onset is then the frame
   after the last one still `riseDB` below the peak, walking back at most 20 ms
   and never past 3 dB over the median. A second maximum within 6 dB of the
   peak and more than 100 ms away sets `multipleTransients`; the loudest is
   still the one used.

   The dominance test is the whole point. "First frame 12 dB over the floor and
   twice its own recent past" describes every syllable, keyboard and chair in a
   real room — the first take in the user's room fired within milliseconds and
   analysed a window with no clap in it. Only a clap is 20 dB louder than
   everything else in the take.
2. **Reference** — non-virtual lanes with an onset, strongest first; each is
   tried and the one that aligns the most *other* lanes wins, so a lane that
   caught an unrelated bang cannot hijack the take. A candidate no other lane
   matched is not a reference at all: `referenceLaneID` is `nil`, every lane is
   `notDetected` (the candidate with "no other lane matched this clap"), and
   `SyncResult.failureSummary` says so, so nothing can be applied. Virtual
   lanes never lead.
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
   `LaneSyncResult.levels` carries the numbers behind the verdict (peak,
   median, floor, dominance, `multipleTransients`) whatever it was, which is
   what the result page draws and `--sync-test` prints.
6. **Delays** — latest arrival 0, the rest the rounded difference, never
   negative. `analyzeMultiple` medians takes, needing two that agree inside
   `multiTakeAgreementSeconds`; `SyncVerifier.residual` re-measures afterwards.

## Capture (`SyncSession`)

A take records `readySeconds` of room tone — the noise floor needs a clap-free
head — then puts CLAP NOW up for a fixed `listenSeconds` (3…8, 4 by default), so
a human has time to react. It ends early **only** when a dominant transient has
`tailSeconds` of audio behind it, and runs past the listen window (to
`maxTakeSeconds`) when a clap lands late and its tail has not been recorded yet.
`takeEndedEarly`, `takeDuration` and `takeEndReason` say what happened.

`SyncOnsetProbe` is the incremental version of the same rule, polled on the main
thread every 40 ms: a window counts only once a second of audio exists, and only
when it is `minDominanceDB` above a running median kept as a 0.25 dB histogram
(a full sort per window would be quadratic). It keeps following the loudest
transient, so an early bump cannot end the take.

## Tuning

`SyncOptions` defaults suit a 48 kHz hand clap. Raise `maxLagSeconds` (to 1 s)
for laggy radio links, drop `minPeakRatio` towards 2 in a hard room where lanes
get refused, raise `attackTaperSeconds` for a dull clap. `phatBeta` 1 whitens
fully and amplifies empty bands, 0 is plain correlation. `minDominanceDB` is the
gate between a clap and a room: below about 15 dB the room starts getting in,
and a clap recorded at less than roughly 15 dB over the noise no longer clears
20 dB in a 1 ms window — clap harder rather than lowering it.
