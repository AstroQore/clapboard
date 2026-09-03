# Clapboard

Clapboard is a native macOS mixer for people who record with many
microphones at once. It captures every USB or wireless receiver and virtual
device (Loopback, Audio Hijack) you point it at, runs each one through a
lane — gain, on/off switch, delay, optional Audio Unit effects — sums them,
and sends the mix to one output device.

Its reason to exist is **Auto Sync**: wireless microphones add 20–100 ms of
latency that macOS never reports, so multi-mic mixes drift out of alignment.
Press Auto Sync, clap once, and Clapboard measures the arrival time of the
clap on every lane and writes the compensating delay into each one.

## Status

| Milestone | State |
|---|---|
| M0 Scaffold, device list, hot-plug | done |
| M1 Multi-device capture + mix + output (private aggregate device, HAL IOProc) | done |
| M2 Per-lane gain / switch / delay / polarity, meters | done |
| M3 Auto Sync (onset detection + band-limited GCC-PHAT, results sheet, verify) | done — acoustic accuracy still to be confirmed with a real clap |
| M4 Audio Unit hosting with latency compensation | in progress |
| M5 Session persistence, missing-device handling | done |

## Build

Requires macOS 26 and Xcode 26 (Swift 6.2). Pure SwiftPM, no Xcode project.

```sh
swift build
swift test
./Scripts/build_app.sh release        # -> .build/Clapboard.app
open .build/Clapboard.app
```

`.build/Clapboard.app/Contents/MacOS/Clapboard --list-devices` prints every
Core Audio device the app sees and exits; handy for scripts.

`--engine-test <seconds>` runs the engine headlessly and prints one line per
second — callback count, overload count, watchdog age and every meter — so the
whole capture path can be checked from a script:

```sh
.build/Clapboard.app/Contents/MacOS/Clapboard --engine-test 120 \
    --output "Loopback" --lane "MacBook Pro Microphone" --lane "Audio Hijack Input" \
    --rebuild-at 20 --hot-lane "Mic Mix"
```

It exits non-zero if an aggregate device survives the teardown. Add
`--ignore-tcc` to exercise everything except real capture on a machine where
the microphone prompt has not been answered.

Always run the `.app`, never `swift run`: microphone access is granted to a
bundle identifier, and a bare executable has none.

## Session file

Clapboard remembers its mixer in
`~/Library/Application Support/Clapboard/session.json`: every lane (device UID,
channels, name, gain, on/off, polarity, delay — and their order), the output
device, and the master gain. Meters and run state are not part of it.

It is written one second after the last change, and again on quit and before
sleep, so dragging a fader costs one write rather than sixty. Writes are
atomic — a temporary file in the same directory, renamed over the old one — so
a crash or a full disk mid-save leaves the previous session intact instead of a
truncated file. A file that does not parse is never discarded: it is renamed to
`session.json.corrupt-<timestamp>`, the failure is reported, and the app starts
empty.

A lane whose device is not plugged in is **kept** exactly as it was saved. It
reports `deviceMissing`, the rest of the mix runs without it, and it rebinds by
itself when the device comes back. Lane ids survive a relaunch, so anything
keyed on them — M3's measured delays, M4's plug-in state — stays attached to the
right lane.

The format is deliberately tolerant, because a session file outlives the build
that wrote it and may be edited by hand: unknown keys are ignored, missing
fields fall back to their defaults, one unreadable lane does not take the other
lanes down with it, and a `formatVersion` from a newer Clapboard is reported
rather than refused.

Headless:

```sh
Clapboard --session-dump                       # print the current session file
Clapboard --engine-test 5 --output "Loopback" --lane "MacBook Pro Microphone" \
    --save-session --session-path /tmp/session.json
Clapboard --restore-session /tmp/session.json --run 5
```

`--restore-session` loads a file into a fresh engine, prints the lanes it got
back — including which ones point at devices that are not here — and runs the
engine for a few seconds, so the lane statuses are measured rather than assumed.

## Headless commands

The executable doubles as a command-line tool. These flags are dispatched in
`main.swift` before AppKit starts, so they work from a shell and never open a
window:

```sh
BIN=.build/Clapboard.app/Contents/MacOS/Clapboard
$BIN --list-devices
$BIN --engine-test 20 --output Loopback --lane "MacBook Pro Microphone" --lane "Audio Hijack Input" --rebuild-at 8 --hot-lane "监听"
$BIN --sync-test 8 --output Loopback --lane "Wireless Mic Rx" --lane "MacBook Pro Microphone" --apply   # clap when it says CLAP NOW
$BIN --engine-test 5 --output Loopback --lane "MacBook Pro Microphone" --save-session --session-path /tmp/s.json
$BIN --restore-session /tmp/s.json --run 3
$BIN --session-dump
$BIN --session-autosave-test
```

Every mode destroys its private aggregate device on exit, including on
SIGTERM / SIGINT (`pkill`, Ctrl-C). Do not `kill -9` a running instance: a
process that dies with its aggregate registered can leave coreaudiod unable
to accept new clients until it is restarted (`sudo killall coreaudiod`).

## Microphone permission and code signing

`build_app.sh` signs ad-hoc by default. An ad-hoc signature's designated
requirement is the binary's own hash, so macOS treats **every rebuild as a
different app**: the Microphone prompt comes back, or access is silently
denied and the engine captures silence.

Two ways out:

1. Create a self-signed *Code Signing* certificate in Keychain Access
   (Certificate Assistant › Create a Certificate…, type "Code Signing") and
   build with

   ```sh
   CLAPBOARD_CODESIGN_IDENTITY="Your Certificate Name" ./Scripts/build_app.sh release
   ```

   The identity is stable across rebuilds and the permission sticks.

2. Reset the permission after a rebuild:

   ```sh
   tccutil reset Microphone com.astroqore.Clapboard
   ```

The app is unsandboxed and does not enable the hardened runtime, on purpose:
it hosts third-party AUv2 plug-ins in-process, which library validation would
block. `Resources/Clapboard.entitlements` is intentionally empty.

## Layout

```
Package.swift                 ClapboardApp (SwiftUI) · ClapboardCore (engine) · ClapboardCoreTests
Sources/ClapboardCore/Audio   Core Audio wrappers, device registry, aggregate channel layout
Sources/ClapboardCore/RT      real-time render kernel, delay lines, meters   (M1+)
Sources/ClapboardCore/Sync    onset detection, GCC-PHAT, clap aligner        (M3)
Sources/ClapboardCore/AU      Audio Unit catalog and host                    (M4)
Sources/ClapboardCore/Session JSON session document                          (M5)
Sources/ClapboardApp          app entry, controllers, views
Scripts/build_app.sh          bundle + sign .build/Clapboard.app
```

## License

TBD.
