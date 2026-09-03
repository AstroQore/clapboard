# AGENTS.md — operating notes for coding agents

Chat with the maintainer in Chinese; code, comments, commit messages and
docs are English.

## Layout and build

- Pure SwiftPM. `ClapboardApp` (SwiftUI/AppKit executable) depends on
  `ClapboardCore` (engine, Core Audio, DSP, session model). Anything
  testable lives in Core.
- Verify every change with all four:

  ```sh
  swift build
  swift test
  ./Scripts/build_app.sh release
  codesign -d --entitlements - .build/Clapboard.app   # must print an empty <dict/>
  ```

- Run the app only as `.build/Clapboard.app` (`open` it). `swift run` has no
  bundle identifier and therefore no microphone permission; the HAL then
  delivers silence, not an error. Rebuilding an ad-hoc-signed app resets
  the permission — see README.

## Git

- Work on a topic branch in a separate worktree under `.agents/worktrees/<branch>`
  (git-ignored). Branch prefixes: `feat/`, `fix/`, `chore/`, `docs/`,
  `refactor/`, `test/`. Never force-push `main`.
- Commit subjects: imperative, ≤ 70 chars, no `feat:` prefixes. End the
  message with a `Co-Authored-By:` trailer for every agent that took part.

## Real-time audio rules (Core/RT)

The HAL IOProc runs on a real-time thread. Inside it:

- No allocation, no locks, no `print`/`os_log`, no `String`/`Array`/`Dictionary`
  construction, no existentials, no `Date()`, no Dispatch or `Task`.
- No class references are loaded: RT state is a POD struct behind one
  `UnsafeMutablePointer`, parameters are `Synchronization.Atomic`, and the
  graph is an immutable snapshot swapped by atomic pointer.
- vDSP is fine. Gain changes are smoothed; delay changes crossfade.
- `ClapboardCore` stays in Swift 5 language mode and must not enable
  `defaultIsolation(MainActor.self)`.

## Core Audio rules

- Key devices by UID, never by `AudioObjectID`.
- Any change to the HAL device list → stop, rebuild the private aggregate
  device, restart. Sub-device removal shifts channel offsets silently.
- The aggregate device is private, uses the output device as clock main,
  and enables drift compensation on every input sub-device. Rebuilding it
  can change the drift resampler's latency, so mark stored sync delays stale
  after a rebuild.
- Never add Bluetooth devices, aggregates, or the selected output device as
  a lane source.
