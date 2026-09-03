# Architecture

This document describes Clapboard as it exists in `main` today. Anything
described as **planned** does not exist yet — it is called out explicitly so
this file does not silently drift into aspirational documentation. See the
README's Status table for the authoritative milestone state.

## Signal flow

```
 Lane devices (USB mics, wireless receivers, Loopback/Audio Hijack, ...)
       │            │            │
       ▼            ▼            ▼
 ┌─────────────────────────────────────────────┐
 │   Private Core Audio aggregate device        │   <- one per engine run,
 │   (all lane inputs + the chosen output,      │      created and destroyed
 │    driven by one HAL IOProc)                 │      by AggregateDevice
 └─────────────────────────────────────────────┘
       │ one interleaved AudioBuffer per stream, delivered together
       ▼
 ┌─────────────────────────────────────────────┐
 │  render(state:input:output:frames:)          │   RenderKernel.swift
 │  (real-time thread, RT rules apply)          │
 │                                               │
 │  for each lane:                              │
 │    de-interleave -> delay ring buffer         │
 │      -> [ planned: AU effect chain ]          │
 │    -> gain ramp + polarity -> sum into master │
 │                                               │
 │  master gain ramp -> peak/RMS meters          │
 └─────────────────────────────────────────────┘
       │ interleaved AudioBuffer for the output device's stream(s)
       ▼
   Output device (speakers, interface, virtual output device, ...)
```

Everything above the render kernel — the UI, `AudioEngine`, device
enumeration, session persistence — runs on the main thread/actor and only
*publishes* parameters and topology into the structures the render thread
reads. Nothing on the main thread blocks on the render thread, and nothing on
the render thread blocks on the main thread.

## Why one private aggregate device + one IOProc, not `AVAudioEngine`

`AVAudioEngine` is built around one input node and one output node, each
implicitly bound to the system's default input/output device (or, with real
work, one non-default device each). Clapboard's whole reason to exist is
capturing an arbitrary number of *simultaneous, independent* input devices
(§ README) and aligning them against each other and against one output — a
shape `AVAudioEngine` does not model.

The alternative that does model it is a Core Audio **aggregate device**: the
HAL lets you compose several physical/virtual devices into one virtual device
with a unified stream layout, run by a single IOProc callback that hands you
input and output for the same audio slice together. Concretely:

- **One clock, one buffer size, one IOProc.** All lane devices and the output
  device become sub-devices of one aggregate, so they can't drift against each
  other in ways the drift compensation isn't accounting for, and there is only
  one real-time callback to reason about instead of N independent ones with
  independently jittering schedules.
- **Timestamps match by construction.** `AudioDeviceCreateIOProcIDWithBlock`
  with a nil dispatch queue runs the block on the HAL's own real-time thread
  and hands input and output for the same cycle in one call — no
  `EnableIO`/`CurrentDevice` AUHAL configuration to get subtly wrong, and no
  risk of input and output ending up on different callback graphs the way two
  `AVAudioEngine` instances (or an engine plus a raw AUHAL unit) would.
- **Private, ephemeral, never user-visible.** The aggregate is created with
  `kAudioAggregateDeviceIsPrivateKey = 1`, so it never appears in Audio MIDI
  Setup or any other app's device list, and the HAL destroys it automatically
  if the process dies. Clapboard also destroys it explicitly — on stop,
  on rebuild, and on receipt of `SIGTERM`/`SIGINT`/`SIGHUP` via
  `TerminationGuard` — because a private aggregate left registered can wedge
  `coreaudiod` against new clients until it's restarted.
- **The output device is the clock main, never a lane source.** The aggregate
  description sets the chosen output device as
  `kAudioAggregateDeviceMainSubDeviceKey` (and, when the HAL accepts it,
  `kAudioAggregateDeviceClockDeviceKey`), and every input sub-device gets
  `kAudioSubDeviceDriftCompensationKey = 1`. `AggregateDeviceBuilder.swift`
  refuses to add the output device, an aggregate, or a Bluetooth device as a
  lane source — Bluetooth's input path forces the HFP codec and is not usable
  for multi-mic work, and nesting aggregates is not supported by the HAL.

The trade-off this buys is complexity that `AVAudioEngine` would have hidden:
Clapboard owns channel-offset bookkeeping (`AggregateInputLayout`,
`AggregateStreamLayout` — a sub-device that also exposes output streams, like
Loopback, shifts where the *next* sub-device's channels land), sample-rate
alignment across every sub-device before creation, and a wait loop for
sub-devices to actually activate before the IOProc starts. `AGENTS.md`'s Core
Audio rules capture this: any change to the HAL device list means stop →
rebuild the aggregate → restart, because sub-device removal shifts channel
offsets silently, and a rebuild can change the drift resampler's latency,
which is why stored sync delays are marked stale after one.

## The real-time render path

`Sources/ClapboardCore/RT/` implements the render kernel under hard real-time
constraints (`AGENTS.md` "Real-time audio rules"): no allocation, no locks, no
`print`/logging, no `String`/`Array`/`Dictionary` construction, no
existentials, no `Date()`, no Dispatch or `Task`, and — the constraint that
shapes everything else — **no class references may be loaded on the render
thread**.

That last rule is why the RT types (`RTTypes.swift`) are plain, manually
allocated, `~Copyable` structs behind `UnsafeMutablePointer`, not classes:

- `RTState` is the single value the IOProc block captures, allocated once by
  `RTMemory.makeState()`. It holds atomics (mix accumulators' scratch buffers,
  counters, the published graph pointer) and nothing that needs the Swift
  runtime to load a reference.
- `LaneRuntime` is one lane's persistent state — its delay ring buffer, gain
  smoother, peak hold, and (while Auto Sync is capturing) its capture buffer.
  It's allocated once per lane id by `RTEngineHost.runtime(for:)` and **kept
  across graph rebuilds**, so adding or removing an unrelated lane doesn't
  reset another lane's delay line or click the mix.
- `RTGraph` is the immutable topology — which lane reads from which aggregate
  buffer/channel, and where the master mix should be written — published by a
  single atomic pointer store (`RTState.graph`) and never mutated once
  visible. `RTEngineHost.publish(nodes:...)` builds a new graph, atomically
  swaps it in, and *retires* (does not free) the previous one.

### Snapshot generation reclamation

Freeing a retired graph — or a `LaneRuntime` for a lane that was just removed
— cannot happen the instant a new one is published, because the render thread
may still be mid-callback on the old snapshot. `RTEngineHost` solves this with
a generation counter, not a lock:

1. Every published `RTGraph` carries a monotonically increasing `generation`.
2. The render kernel stores the generation it is about to use into
   `RTState.enterGeneration` (release) before reading `graph`, and the
   generation it finished with into `RTState.exitGeneration` (release) at the
   end of the callback.
3. `RTEngineHost.collectGarbage()` reads `exitGeneration` and then
   `enterGeneration` (both acquire) — in that order, deliberately: if the two
   are equal, the render thread is between callbacks, and whatever generation
   `exitGeneration` names is one it can no longer reach, so every retired
   snapshot older than it is safe to actually deallocate. If a new callback
   starts between the two reads, it necessarily enters at the freshly
   published (higher) generation, so the conclusion still holds.
4. `LaneRuntime`s for lanes removed in the same publish that retired a graph
   are freed together with that graph, never before — a lane pointer that a
   retired-but-still-referenced graph points at must not be freed out from
   under it.

This is the same handshake `AUEffectInstance`'s doc comment describes for M4's
planned per-lane effect chains: publish the new snapshot, wait for
`exitGeneration` to pass it, then release the old one.

## Auto Sync

Wireless microphone receivers add 20–100 ms of latency that macOS never
reports in any device property, so a multi-mic mix drifts out of alignment in
a way no amount of manual ear-and-fader tuning fixes reliably. Auto Sync
measures it directly: capture a clap on every lane at once, find when it
arrived on each, and turn the differences into per-lane delays.

Pipeline (`Sources/ClapboardCore/Sync/`):

1. **Capture.** `RTEngineHost.armCapture(laneIDs:frames:)` allocates one
   capture buffer per selected lane *before* arming, so the render thread
   never allocates one itself; the kernel appends each lane's raw, pre-delay
   channel-0 samples to its buffer once per block, all reading the same
   `captureArmed` flag once per callback so every lane's capture shares a
   common time origin — the thing the whole alignment computation assumes.
2. **Onset detection** (`OnsetDetector`) — a 1 ms RMS envelope per lane,
   compared against the median RMS of the first `noiseFloorSeconds` (the
   noise floor), with the onset defined as the first frame that is both
   `minOnsetSNRdB` above that floor and rises steeply out of its own recent
   history (`riseFactor`), so a slow swell (music, a fan spinning up) doesn't
   register as a clap.
3. **Reference selection.** The non-virtual lane with the strongest onset is
   tried first; several strong candidates are tried and the one that aligns
   the most other lanes wins the "reference" role, so one lane catching an
   unrelated bang can't hijack the take. Virtual devices (Loopback, Audio
   Hijack, a planned process tap) are measured but never selected as the
   reference, because their timeline is somebody else's clock, not the
   aggregate's.
4. **Windowing.** Around each lane's onset, a short window is mean-removed,
   RMS-normalised, and tapered with an exponential anchored at the onset so
   late reflections weigh less than the direct sound.
5. **Correlation** (`GCCPHAT`) — a band-limited generalised cross-correlation
   with phase transform between each lane's window and the reference's,
   computed via FFT and refined to a quarter-sample lag by parabolic
   interpolation around the correlation peak. The frequency band and search
   window are configurable (`SyncOptions`); peaks far from the coarse onset
   difference are penalised so an unrelated ambient correlation can't win.
6. **Verdict** (`ClapAligner.verdict`) — a lane is `aligned` only when its
   onset SNR clears `minOnsetSNRdB` *and* the correlation peak clears
   `minPeakRatio` against the next-best peak; otherwise the lane is
   `notDetected` with a human-readable reason, and its delay is left alone
   rather than guessed.
7. **Delays.** The latest arrival across aligned lanes gets delay 0; every
   other lane gets the rounded catch-up delay, never negative.
8. **Multiple takes** (`analyzeMultiple`) can be combined: each take is
   analyzed independently, offsets are re-expressed against a common anchor
   lane, and the median across takes is kept, with confidence scaled down by
   how much the takes disagree.
9. **Verify** (`SyncVerifier`) — after the suggested delays are applied,
   record a second clap; `SyncVerifier.residual` delays the lane's new
   recording by the applied amount and re-measures against the reference, so
   a near-zero residual confirms the alignment actually worked rather than
   trusting the first measurement blindly.

Status: the DSP above is implemented and covered by tests against synthetic
signals (`SyncClapAlignerTests`, `SyncInternalsTests`). Acoustic accuracy
against a real recorded clap on real hardware is still to be confirmed (see
the README Status table).

## Audio Unit hosting and plug-in delay compensation

`Sources/ClapboardCore/AU/` hosts third-party Audio Unit effects in-process:

- `AUCatalog` enumerates installed `aufx`/`aumf` components via
  `AVAudioUnitComponentManager` — a genuinely slow call (it may open every
  bundle under `/Library/Audio/Plug-Ins/Components`), so it's a plain
  synchronous function the caller is expected to call off the main thread.
- `AUEffectInstance` instantiates one plug-in, prefers loading it in-process
  (an AUv2 bundle is in-process or nothing; an AUv3 that can load in-process
  saves an IPC hop per block), and refuses an AUv2 bundle that macOS would
  only load out-of-process under Rosetta — such a plug-in's
  `allocateRenderResources()` never returns, which would otherwise wedge the
  main thread instead of producing a legible error.
- Its real-time entry point, `process(left:right:frames:sampleTime:)`, follows
  the same "one pointer, no class references, no allocation" discipline as the
  render kernel: buffers are preallocated at instantiation, and a render
  failure mid-block silences the lane rather than passing through whatever
  the plug-in left in its output buffers.
- Latency is observed via KVO on `AUAudioUnit.latency` and republished as a
  sample count (`AUProcessState.latencySamples`), because a plug-in can change
  its reported latency at any time (a linear-phase EQ switching filter mode, a
  look-ahead limiter changing its window).

**Planned, not yet implemented:** wiring `AUEffectInstance` into each lane's
render path (currently the render kernel has no AU stage — see the diagram
above), and **plug-in delay compensation** — using the latency each hosted
plug-in reports to keep lanes with different effect chains time-aligned
against each other, the same way Auto Sync keeps physically-delayed lanes
aligned. The type-level doc comments describe the intended mechanism: publish
the new lane graph (with the plug-in wired in) only after instantiation
returns, and release the old one only after the render thread's
`exitGeneration` has provably passed it — the same generation handshake
described above for lane runtimes.

## Session file contract

Clapboard remembers its mixer state in
`~/Library/Application Support/Clapboard/session.json`
(`Sources/ClapboardCore/Session/`):

- **Contents:** every lane (device UID, channel indices, name, gain dB,
  on/off, polarity, delay samples — and their order), the output device UID,
  and the master gain. Meters and run state are not persisted.
- **`formatVersion`:** bumped only when a reader would need to behave
  differently, not for every additive field — an unknown key is ignored by
  design, so adding a field a future build understands and an old one doesn't
  is exactly what the tolerant decoding exists for. A file with a
  `formatVersion` from a newer Clapboard is *reported*, never refused.
- **Atomic write:** `SessionStore.save` writes to a temporary file in the same
  directory (so it's on the same volume) and swaps it in with
  `FileManager.replaceItemAt`, which is atomic — a crash or a full disk
  mid-save leaves the previous session file intact rather than truncated.
  Writes are coalesced to one second after the last change, plus on quit and
  before sleep, so dragging a fader costs one write, not sixty.
- **Quarantine, not deletion:** a file that fails to parse is renamed to
  `session.json.corrupt-<timestamp>` rather than overwritten or deleted, the
  failure is surfaced, and the app starts with an empty session. One
  unreadable lane inside an otherwise valid file is dropped
  (`LenientlyDecoded`) without taking the rest of the session down with it.
- **Missing-device handling:** a lane whose device is unplugged is *kept*
  exactly as saved, reports `deviceMissing`, and rebinds itself automatically
  when the device returns — because lane ids are stable across a relaunch,
  anything keyed on them (Auto Sync's measured delays, the planned per-lane
  plug-in state) stays attached to the right lane the whole time.
- **Forward-compatible extras bag:** `laneExtras`/`masterExtras` hold
  per-lane and per-master binary blobs keyed by an owner-chosen name, unused
  today, reserved so a future build can store AU `fullState` plists there
  without an older build silently discarding them on the next save.

## Headless entry point

`Sources/ClapboardApp/main.swift` inspects `CommandLine.arguments` *before*
`ClapboardApp.main()` (the SwiftUI/AppKit entry point) runs, and dispatches
recognized flags (`HeadlessCommand.matches`) synchronously on the main actor
without ever starting `NSApplication`. This exists because a SwiftUI app
restores its window state on launch, and that restoration can block
indefinitely when the executable is started from a shell after the GUI has
been opened at least once — which made every `--list-devices`/`--engine-test`
invocation hang intermittently before this ordering was fixed.

`HeadlessCommand.run` fans out to `EngineSmokeTest`, `SyncSmokeTest`, and
`SessionSmokeTest` in `Sources/ClapboardApp/`, which drive a real
`AudioEngine` end to end (device enumeration, aggregate creation, capture,
Auto Sync, session save/restore) and print machine-readable summaries — the
same commands `CONTRIBUTING.md` asks bug reports to include output from.

## Planned, explicitly not implemented

These are referenced elsewhere in the docs or exist on other branches, and are
listed here so this document doesn't imply they're already in `main`:

- **Bus routing** — sending a lane or a group of lanes to more than one
  output.
- **Global hotkeys** — mute/solo or Auto Sync trigger bound to a system-wide
  key combination.
- **Virtual-device driver** — a `DriverKit`/`AudioServerPlugin`-based virtual
  audio device installed under `/Library/Audio/Plug-Ins/HAL`, so other apps
  can select Clapboard's mix as an input without routing through a physical
  output. Requires administrator rights to install; see `SECURITY.md`.
- **Process taps** — capturing another app's audio output directly (macOS
  14+ `AudioHardwareCreateProcessTap`) instead of only physical/virtual
  devices, which would need its own TCC permission distinct from the
  Microphone one; see `docs/PERMISSIONS.md`.
- **Per-lane AU insertion and plug-in delay compensation** — see "Audio Unit
  hosting" above; the hosting core exists, the render-graph wiring does not.
