# Permissions

What Clapboard asks the system for, why, and how to fix the most common
permission-related confusion during development.

## Microphone (TCC)

Clapboard requests microphone access through the standard macOS privacy
system (TCC — Transparency, Consent and Control), declared in
`Resources/Info.plist` as `NSMicrophoneUsageDescription` for bundle id
`com.astroqore.Clapboard`. `Sources/ClapboardApp/MicrophonePermission.swift`
wraps `AVCaptureDevice.authorizationStatus(for: .audio)` /
`requestAccess(for:completionHandler:)`.

Without authorization the HAL does **not** return an error — it silently
delivers digitally silent (zero) samples on the input side. This is the
single most common source of "I recorded nothing" confusion during
development: the engine runs, meters sit at the noise floor, `--engine-test`
reports a healthy callback count with no overloads, and the only symptom is
silence. Always check the Microphone permission first when audio is
unexpectedly silent.

### Why an ad-hoc-signed build re-prompts after every rebuild

`Scripts/build_app.sh` signs ad-hoc by default (`codesign --sign -`). An
ad-hoc signature's designated requirement is derived from the binary's own
hash (`cdhash`), so macOS treats **every rebuild as a different app** even
though the bundle identifier didn't change. Concretely, after each
`./Scripts/build_app.sh`:

- Either the Microphone permission prompt reappears, or
- Access is silently denied (no prompt, no error — just the zero-sample
  behavior above) if TCC already has a denied/stale entry for this bundle id.

Two ways out, both documented in the README and repeated here because they're
permission-specific:

1. **Stable signing identity (recommended for repeated local builds).**
   Create a self-signed *Code Signing* certificate in Keychain Access
   (Certificate Assistant → Create a Certificate…, type "Code Signing"), then:

   ```sh
   CLAPBOARD_CODESIGN_IDENTITY="Your Certificate Name" ./Scripts/build_app.sh release
   ```

   The identity is stable across rebuilds, so TCC recognizes the app as the
   same app and the permission sticks.

2. **Reset the permission after each rebuild.**

   ```sh
   tccutil reset Microphone com.astroqore.Clapboard
   ```

   This clears whatever TCC state exists for the bundle id, so the next
   launch prompts fresh. Useful for a one-off rebuild; tedious if you're
   iterating quickly — use option 1 instead in that case.

Note that `tccutil reset` and the ad-hoc/identity distinction are about the
**app's own build**, not about "asking the user for permission" in the
product sense — there is no in-app way to route around it, by design.

## Why the app is unsandboxed with an empty entitlements file

`Resources/Clapboard.entitlements` is intentionally an empty `<dict/>`: no App
Sandbox, no hardened runtime. This is on purpose, not an oversight —
Clapboard hosts third-party Audio Unit (AUv2) plug-ins in-process (see
`docs/ARCHITECTURE.md`), and both the App Sandbox and the hardened runtime's
library validation would block loading arbitrary third-party plug-in code.
`CONTRIBUTING.md`'s verification step
(`codesign -d --entitlements - .build/Clapboard.app` must print an empty
`<dict/>`) exists to catch an accidental entitlement creeping in.

## Core Audio aggregate devices

Creating a private aggregate device (`AudioHardwareCreateAggregateDevice`)
does not require any TCC permission or admin rights — it's a normal Core
Audio HAL operation available to any process. It does, however, briefly touch
every lane device's nominal sample rate to align them before the aggregate is
built (`AggregateDeviceBuilder.align`), which can interrupt another app that
is actively using one of those devices at a different rate. This is expected
behavior, not a bug, and is why the app should generally not be pointed at a
device another critical process depends on.

## Local storage

Clapboard writes only to
`~/Library/Application Support/Clapboard/session.json` (and its own
`.tmp-*`/`.corrupt-*` siblings during atomic writes and quarantine — see
`docs/ARCHITECTURE.md`). No other files are read or written, and no directory
outside this one is touched.

## Planned: system-audio-capture permission (process taps)

A planned feature (not implemented — see `docs/ARCHITECTURE.md`) is capturing
another app's audio output directly via macOS's process-tap APIs
(`AudioHardwareCreateProcessTap`, macOS 14+) instead of only physical/virtual
devices. Unlike the Microphone permission, this uses a **separate** TCC
permission ("audio capture" / screen-and-system-audio-recording family,
depending on the exact API surface at the time this is implemented) that must
be requested and granted independently. This document will be updated with
the concrete flow once that work lands.

## Admin rights for the virtual-device driver

A planned virtual-device driver (`DriverKit`/`AudioServerPlugin`, not
implemented — see `docs/ARCHITECTURE.md`) will install a system extension or
plug-in under `/Library/Audio/Plug-Ins/HAL`. Installing anything under
`/Library` requires administrator authentication (a standard macOS admin
password prompt, or an installer package requiring elevation) because it
affects every user and every app on the machine, not just Clapboard. This is
categorically different from the per-user, per-app Microphone permission
above — treat it with the same caution you would any installer that asks for
your admin password, and expect the installer to explain what it's adding
before you approve it.
