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

### Known limitations

- No console UI for buses yet: the row-based mixer still runs against the
  Master bus only, through the shims above. Routing is reachable today only
  through the `AudioEngine` API and the headless flags.
- Per-bus effect editing exists only for the Master bus; a chain saved on any
  other bus round-trips through a session file but comes back as a
  placeholder rather than a live plug-in (`docs/ROUTING.md`).
- Projects (Save As / Open / Open Recent / a dirty-state title bar) are
  designed in `docs/ROUTING.md` but not implemented.
- Global hotkeys, a virtual-device driver, and process-tap system-audio
  capture are planned but not implemented yet — see `docs/ARCHITECTURE.md`.
- No signed/notarized release build exists; see `SECURITY.md`.

[Unreleased]: https://github.com/AstroQore/clapboard/commits/main
