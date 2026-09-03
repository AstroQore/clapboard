# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project does not yet follow Semantic Versioning tags — it has not cut
a release.

## [Unreleased]

Everything below exists in `main` today; nothing has been tagged as a release
yet.

### Added

- Device registry and hot-plug handling: enumerates Core Audio devices,
  watches for changes, and keys everything by device UID rather than
  `AudioObjectID`.
- Multi-device capture, mix and output through one private Core Audio
  aggregate device driven by a single HAL IOProc, instead of `AVAudioEngine`
  (see `docs/ARCHITECTURE.md` for why).
- Per-lane controls — gain, on/off, delay, polarity — and peak/RMS meters, all
  running through a lock-free real-time render kernel.
- **Auto Sync**: onset detection plus band-limited GCC-PHAT clap alignment,
  with a results sheet and a verify pass. Acoustic accuracy is implemented and
  tested against synthetic signals; confirmation against a real recorded clap
  is still open.
- Audio Unit (AUv2/AUv3) hosting core: plug-in catalog, in-process instance
  hosting, latency observation. Per-lane insertion, UI, and plug-in delay
  compensation are in progress.
- Session persistence to `~/Library/Application Support/Clapboard/session.json`:
  atomic writes, tolerant decoding, corrupt-file quarantine, and
  missing-device handling that keeps a lane's settings intact until its
  device comes back.
- Headless CLI commands (`--list-devices`, `--engine-test`, `--sync-test`,
  `--session-dump`, `--restore-session`, `--session-autosave-test`) dispatched
  before AppKit starts, for scripted verification without a window.
- `TerminationGuard`: tears down every live engine and its private aggregate
  device on `SIGTERM`/`SIGINT`/`SIGHUP`, so a killed process cannot leave
  `coreaudiod` stuck with a dangling aggregate.
- `Scripts/build_app.sh`: builds, bundles and ad-hoc (or identity-)signs
  `.build/Clapboard.app`.
- **Bus routing** (`docs/ROUTING.md`): lanes route to a `BusConfig` instead of
  summing straight into one master, buses can feed other buses, and any bus
  can carry its own output device — several buses, several output devices,
  one private aggregate carrying all of them
  (`AggregateDeviceRequest.outputDeviceUIDs`). `RoutingGraph` validates the
  tree and rejects cycles; `SoloLogic` scopes solo to a lane's bus or a bus's
  siblings; `LatencyPlan` runs plug-in delay compensation across the whole
  tree, not just per lane. The real-time render kernel gives every bus its
  own persistent accumulator, gain smoother, meter and PDC delay line, and
  renders the tree children-before-parents. Session format 2 adds `buses:
  [BusConfig]` and a version 1 file migrates its implicit master into an
  explicit `Master` bus on restore. New `AudioEngine` API: `addBus`/
  `removeBus`/`renameBus`/`setBusGainDB`/`setBusMuted`/`setBusSolo`/
  `setBusDestination`/`setBusOutput`, `setLaneDestination`/`setLaneMuted`/
  `setLaneSolo`, `muteAllLanes`/`unmuteAllLanes`/`toggleAllLanes`,
  `busMeter`/`busChainLatency`/`outputLatencySamples(forDevice:)`.
  `setOutputDevice`/`masterGainDB`/`masterEffects`/`masterMeter` keep working
  unchanged as thin shims onto the Master bus. New headless flags:
  `--bus`/`--route`/`--bus-parent`/`--bus-output`/`--solo`/`--mute` on
  `--engine-test`, and `--routing-selftest`, which builds a two-output-device
  bus tree and checks it end to end.
- **Per-bus effect chains**: every bus carries an editable Audio Unit chain,
  not just Master. `AudioEngine`'s chain API now names an `EffectTarget`
  (`.lane(id)` / `.bus(id)`) instead of the old "a lane id, or `nil` for the
  master bus" convention — `addEffect(_:to:)`, `effects(for:)`,
  `target(ofEffect:)`, `masterEffectTarget`, with `removeEffect`/`moveEffect`/
  `setEffectBypass`/`openEffectWindow` resolving the target from the effect
  id. Bus plug-ins are instantiated with two channels (a bus is a stereo
  sum); lanes keep their own channel count. Session restore instantiates a
  live plug-in for every bus's saved chain, so a placeholder now means only
  what it means on a lane — the component is missing, or macOS refused to
  host it — and still keeps its `fullState` so re-saving cannot lose it.
  Removing a bus tears its chain down on the same snapshot-generation terms
  `removeLane` uses. In the console, a bus strip's chips are editable and its
  `+` works, exactly like a lane's. `addEffect(_:toLane:)` and
  `effects(forLane:)` remain as thin forwards.
- **Process taps as lane sources** (`docs/ARCHITECTURE.md` § Process taps as
  lane sources): a lane can be fed by another application's audio — or by
  everything this Mac plays — through macOS 14.2's
  `AudioHardwareCreateProcessTap`, with no Loopback, no Audio Hijack and no
  driver in between. A lane's source is now a `LaneSource`
  (`.device(uid:channels:)` or `.processTap(TapSpec)`); `TapSpec` names an app
  by bundle id or says "system audio", because HAL process object ids are not
  stable across a relaunch. `LaneConfig.deviceUID`/`deviceChannels` stay as
  computed shims over it, so Auto Sync, the row mixer and everything keyed on a
  lane id keep working unchanged. Taps are created by `ProcessTapFactory`, join
  the one private aggregate device through `kAudioAggregateDeviceTapListKey`,
  and get their buffer index and channel offset from the aggregate's real
  stream configuration — checked on every bring-up, never assumed. Session
  format 2 is unchanged: `source` is additive and a file written before this
  loads as a device lane. Every tap uses `CATapUnmuted`, so capturing an app
  never silences it, and a system-wide tap excludes Clapboard itself so the mix
  cannot feed back into a lane. A tap that will not build — the app is not
  playing, or macOS refuses the capture — leaves the rest of the mix running
  and reports the reason on the lane (`AudioEngine.laneStatusReason`) instead of
  capturing silence. New UI: an "Application audio" tab in the Add Lane sheet
  and an "Application audio" submenu in the console lane strip's source menu.
  New headless flags: `--list-taps`, and `--lane-tap <bundle-id|system>` for
  `--engine-test`. The permission is a separate TCC service with no
  `requestAccess` API — see `docs/PERMISSIONS.md`, including what was and was
  not actually enforced on the development Mac.

### Known limitations

- No console UI for buses yet: the row-based mixer still runs against the
  Master bus only, through the shims above. Routing is reachable today only
  through the `AudioEngine` API and the headless flags.
- `--engine-test` can insert an effect into a lane (`--lane-effect`) or the
  Master bus (`--master-effect`), but has no flag for a chain on any other
  bus; drive one through the `AudioEngine` API or a session file and
  `--restore-session`, which prints every bus's chain and whether each entry
  came back loaded.
- Projects (Save As / Open / Open Recent / a dirty-state title bar) are
  designed in `docs/ROUTING.md` but not implemented.
- A process-tap lane is not classified as "virtual" by Auto Sync: it is
  offered and treated as a physical lane, because `SyncSession` decides that by
  looking the lane's key up in the device registry. Untick a tap lane before
  measuring — it cannot hear a clap.
- A tap lane whose application is not playing when the engine starts stays
  silent until the app starts playing (which rebuilds the aggregate) — a tap
  cannot be added to a live aggregate device.
- No signed/notarized release build exists; see `SECURITY.md`.

[Unreleased]: https://github.com/AstroQore/clapboard/commits/main
