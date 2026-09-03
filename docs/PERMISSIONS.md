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

## System audio capture (process taps)

A lane can be fed by another application's audio instead of by an input
device, through macOS 14.2's Core Audio process taps
(`AudioHardwareCreateProcessTap` + `CATapDescription`; see
`docs/ARCHITECTURE.md`). That capture is governed by a **different permission
from the Microphone one**, and the difference matters in three ways.

### The Info.plist key

`Resources/Info.plist` declares `NSAudioCaptureUsageDescription`. This is the
key Apple documents for the audio-capture TCC service (`kTCCServiceAudioCapture`
— `tccutil reset AudioCapture com.astroqore.Clapboard` addresses it), and it is
what a system prompt would quote if one were raised. It is *not*
`NSMicrophoneUsageDescription`, and granting one says nothing about the other.

### There is no `requestAccess` for it

`AVCaptureDevice.authorizationStatus(for:)`/`requestAccess(for:)` cover the
microphone and the camera. There is no public equivalent for audio capture:
the supported way to find out whether this app may tap is to **create a tap and
see**. `ProcessTapPermission.probe()` therefore builds a real, private, unmuted
system-wide tap (excluding Clapboard itself), destroys it immediately, and
reports the outcome as `SystemAudioAuthorization`. The probe *is* the request —
on a system that gates taps, the first call is what raises the prompt and a
later call reports the user's answer.

The engine surfaces this as `AudioEngine.systemAudioAuthorization`, refreshes
it with `refreshSystemAudioAuthorization()`, and consults it in `start()` **only
when a lane actually wants a tap** (`AudioEngine.usesProcessTaps`) — a
microphone-only mix must not be held up by a permission it never uses. In the
UI it appears at the bottom of the Add Lane sheet's *Application audio* tab,
with a "Check access" button; `--list-taps` prints it as its first line and
exits non-zero when it is refused.

### Refusal is reported, never silent

This is the opposite of the microphone's failure mode. Where an unauthorized
microphone yields digitally silent samples with no error, a refused tap fails
at `AudioHardwareCreateProcessTap`. `AggregateDevice.create` records the reason
in `tapFailures` instead of failing the whole aggregate, so the rest of the mix
runs and the affected lane reports `LaneStatus.deviceMissing` with a sentence in
`AudioEngine.laneStatusReason` — shown on the console strip and printed by
`--engine-test` as a `LANE` line. The same path covers "that app is not playing
anything right now", which is by far the more common case.

### What was actually observed on the development Mac

On macOS 27.0 (build 26A5425a), with `com.astroqore.Clapboard` ad-hoc signed,
creating a private process tap succeeded **without any prompt**: it still
succeeded after `tccutil reset AudioCapture com.astroqore.Clapboard`, and it
still succeeded with `NSAudioCaptureUsageDescription` removed from the bundle
entirely. The captured audio was real, not silence — the tap lane's meter
tracks the tapped app.

So on that machine the permission is currently not enforced for this shape of
tap. The key is declared and the probe is wired anyway, because that is not
something to rely on: the gate exists on other macOS versions and
configurations, and the whole point of `ProcessTapPermission` is that Clapboard
reports a refusal clearly on a machine where it does happen instead of
capturing nothing and calling it a mix.

### Tapping never mutes the app it captures

`CATapDescription.muteBehavior` is always `CATapUnmuted`. The other two modes
(`CATapMuted`, `CATapMutedWhenTapped`) stop the tapped application's audio from
reaching the hardware while the tap is being read. Clapboard is a mixer, not a
recorder that replaces playback: adding a lane on Music must not silence Music,
and the way to stop hearing something is that lane's own `M` button. This is
asserted in `ProcessTapLaneTests`.

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
