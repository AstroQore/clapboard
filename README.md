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
| M3 Auto Sync (onset detection + band-limited GCC-PHAT) | planned |
| M4 Audio Unit hosting with latency compensation | planned |
| M5 Session persistence, missing-device handling | planned |

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
