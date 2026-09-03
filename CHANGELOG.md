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

### Known limitations

- Bus routing, global hotkeys, a virtual-device driver, and process-tap
  system-audio capture are planned but not implemented yet — see
  `docs/ARCHITECTURE.md`.
- No signed/notarized release build exists; see `SECURITY.md`.

[Unreleased]: https://github.com/AstroQore/clapboard/commits/main
