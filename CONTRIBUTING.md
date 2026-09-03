# Contributing to Clapboard

Thanks for taking an interest in Clapboard, a native macOS mixer for people
who record with many microphones at once. This document covers the practical
side of contributing; `AGENTS.md` has the detailed engineering rules (real-time
audio constraints, Core Audio device handling) that every change touching
`Sources/ClapboardCore` must follow — read it before you touch `Core/RT` or
`Core/Audio`.

## Prerequisites

Clapboard targets **macOS 15+** going forward, but the toolchain it is
currently built and tested against is:

- **macOS 26** (the current development machine's OS)
- **Xcode 26** / **Swift 6.2**
- No Xcode project — it is pure SwiftPM, so `xcode-select -p` just needs to
  point at an Xcode 26 install for the Swift toolchain and SDK.

If you are building on an older macOS/Xcode, expect friction until the
`macOS 15+` target is actually verified there; please file an issue with what
broke rather than assuming it is expected to work today.

## Getting the source

```sh
git clone https://github.com/AstroQore/clapboard.git
cd clapboard
```

If you expect to run more than one agent or branch at once, keep each branch
in its own worktree instead of switching branches in place:

```sh
git worktree add -b feat/my-topic .agents/worktrees/feat-my-topic main
cd .agents/worktrees/feat-my-topic
```

`.agents/` is git-ignored, so worktrees under it never show up as untracked
files in the main checkout.

## Build, test, package, verify

Run all four before opening a PR — this is the same sequence `AGENTS.md` asks
of every change and what CI runs:

```sh
swift build
swift test
./Scripts/build_app.sh release
codesign -d --entitlements - .build/Clapboard.app   # must print an empty <dict/>
```

The last command isn't decoration: `Resources/Clapboard.entitlements` is
intentionally empty (no App Sandbox, no hardened runtime) because Clapboard
hosts third-party Audio Unit plug-ins in-process. A non-empty entitlements
dump means something changed that shouldn't have.

### Dependencies

Clapboard has exactly one: [Sparkle](https://github.com/sparkle-project/Sparkle),
which powers **Clapboard › Check for Updates…**. Three things follow from that,
and CI checks all three:

- It is pinned to an **exact** version in `Package.swift`, because
  `Package.resolved` is git-ignored and the pin is the only thing making two
  builds of one commit contain the same Sparkle. Bumping it is a deliberate
  change, with its own PR.
- `Scripts/build_app.sh` embeds `Sparkle.framework` in `Contents/Frameworks`
  and signs its XPC services, `Autoupdate` and `Updater.app` **before** the app
  bundle. Signing anything after the outer bundle invalidates the app's
  signature and `codesign --verify --deep --strict` fails.
- Its license ships in the bundle
  (`Resources/ThirdPartyLicenses/Sparkle.txt`, listed in
  `THIRD_PARTY_NOTICES.md`). Any future dependency needs the same treatment.

`Tests/ClapboardCoreTests/UpdateFeedContractTests.swift` asserts this contract
against the repository, so a change that breaks it fails `swift test` rather
than someone's launch.

Never generate, print, commit or paste a Sparkle **private** key. `RELEASING.md`
explains the key pair and the `SPARKLE_ED_PRIVATE_KEY` repository secret; the
public key in `Resources/Info.plist` is the only half that belongs in git.

### Running the app

Always run the built `.app`, never `swift run`:

```sh
open .build/Clapboard.app
```

`swift run` produces a bare executable with no bundle identifier, so macOS
grants it no Microphone permission — the HAL then hands back silence, not an
error, which is a confusing way to debug a "no audio" report that is actually
a permissions problem.

### Headless commands

The same binary doubles as a CLI for scripting and manual verification,
dispatched in `main.swift` before AppKit starts:

```sh
BIN=.build/Clapboard.app/Contents/MacOS/Clapboard
$BIN --list-devices
$BIN --engine-test 20 --output Loopback --lane "MacBook Pro Microphone" --rebuild-at 8
$BIN --sync-test 8 --output Loopback --lane "Wireless Mic Rx" --lane "MacBook Pro Microphone" --apply
$BIN --session-dump
$BIN --session-autosave-test
```

See the README's "Headless commands" and "Session file" sections for the full
flag set. These are the fastest way to reproduce and describe an audio bug
without a screen recording.

### Reporting audio glitches

If you hit dropouts, clicks, or misalignment, include in your issue or PR
description:

- `--list-devices` output (device names, transports, sample rates).
- The last few lines of an `--engine-test` run — specifically the overload
  counter and callback count, which tell us whether the render thread ever
  missed its deadline.
- Whether the affected device is a virtual device (Loopback, Audio Hijack) or
  physical hardware, and its transport type.
- For Auto Sync issues, the `--sync-test` output including the measured
  offsets and confidence per lane.

## Real-time audio rules

Anything inside the HAL IOProc callback (`Sources/ClapboardCore/RT/`) runs on
a real-time thread with hard deadlines. `AGENTS.md` has the full rule set; the
short version:

- No allocation, no locks, no `print`/`os_log`, no `String`/`Array`/`Dictionary`
  construction, no existentials, no `Date()`, no Dispatch or `Task`.
- No class references may be loaded — RT state lives behind one
  `UnsafeMutablePointer` to a POD struct; parameters are
  `Synchronization.Atomic`; the render graph is an immutable snapshot swapped
  by atomic pointer.
- `ClapboardCore` stays in Swift 5 language mode; it must never enable
  `defaultIsolation(MainActor.self)`.
- Key Core Audio devices by UID, never by `AudioObjectID` — object IDs are not
  stable across a device coming and going.

If a change touches `Core/RT` or the IOProc path in `Core/Audio`, call this
out explicitly in the PR description so reviewers know to check it against
these rules.

## Branch and commit conventions

- Branch prefixes: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/`, `test/`.
- Commit subjects: imperative mood, ≤ 70 characters, no `feat:`/`fix:` prefix.
- End commit messages with a `Co-Authored-By:` trailer for every agent or
  assistant that took part, e.g.:

  ```
  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  ```

- Never force-push `main`.

## Pull request checklist

Before opening a PR, confirm:

- [ ] `swift build`, `swift test`, and `./Scripts/build_app.sh release` all
      pass locally.
- [ ] `codesign -d --entitlements - .build/Clapboard.app` prints an empty
      `<dict/>`.
- [ ] Changes to `Core/RT` or the IOProc path respect the real-time rules
      above, and the PR description says so.
- [ ] Changes to Core Audio device handling key devices by UID, and account
      for the aggregate-device rebuild rules in `AGENTS.md` (sub-device
      removal shifts channel offsets; a rebuild can change drift-resampler
      latency and should mark stored sync delays stale).
- [ ] New behavior has a test in `Tests/ClapboardCoreTests` where practical,
      or a headless-command repro in the PR description where a test isn't.
- [ ] `CHANGELOG.md` has an entry under `Unreleased` if the change is
      user-visible.
- [ ] A change that adds or bumps a dependency updates `Package.swift`,
      `THIRD_PARTY_NOTICES.md` and `Resources/ThirdPartyLicenses/`, and no
      private key material of any kind is in the diff.

## Scope of this repository

Some parts of Clapboard — the virtual-device driver, hotkeys, bus routing —
are being developed on separate branches and are marked "planned" in
`docs/ARCHITECTURE.md` until they land. Please don't assume a feature exists
just because it's referenced there; check the README's Status table.
