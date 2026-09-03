# Third-party notices

## Direct dependencies

### Sparkle 2.9.4

- Project: [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)
- Use in Clapboard: in-app update discovery, EdDSA appcast signature
  verification, and update installation — **Clapboard › Check for Updates…**
  and the Main/Dev channels described in `RELEASING.md`.
- How it is consumed: pinned to an exact version in `Package.swift` and, unlike
  everything else Clapboard links, **redistributed as a binary**.
  `Scripts/build_app.sh` copies `Sparkle.framework` into
  `Clapboard.app/Contents/Frameworks` — including its `Autoupdate` helper,
  `Updater.app`, and the `Installer.xpc` / `Downloader.xpc` XPC services — so
  the notice below travels with the binary and not only with this repository.
- License: [MIT](Resources/ThirdPartyLicenses/Sparkle.txt)
  ([upstream](https://github.com/sparkle-project/Sparkle/blob/2.9.4/LICENSE)).
  The bundled file is Sparkle's own `LICENSE`, verbatim, which also carries the
  notices for the external components Sparkle itself vendors.

Apart from Sparkle, Clapboard links only against Apple's system frameworks
(CoreAudio, AudioToolbox, AVFoundation, Accelerate, Synchronization,
SwiftUI/AppKit), which ship with the OS and are not vendored or redistributed
by this repository.

If another dependency is ever added, list it here alongside its license, keep
it in step with `Package.swift`, and put the license text under
`Resources/ThirdPartyLicenses/` so `Scripts/build_app.sh` ships it.

## Ported or adapted source

None. The DSP in `Sources/ClapboardCore/Sync/` (onset detection, band-limited
GCC-PHAT cross-correlation, clap alignment) implements well-known,
textbook-level signal-processing techniques from scratch against Apple's
Accelerate framework; it is not a port of another project's code.

## Planned: the virtual-device driver

The virtual audio device driver described as "planned" in
`docs/ARCHITECTURE.md` (a `DriverKit`/`AudioServerPlugin`-based HAL plug-in,
developed on a separate branch) is intended to be a clean-room implementation
against Apple's public `AudioServerPlugIn`/DriverKit APIs, not a fork or
derivative of an existing virtual-audio-device project (such as BlackHole or
Loopback). This file will be updated if that changes before the driver lands.

## Trademarks

All product names and trademarks mentioned in this repository's
documentation (macOS, Xcode, Swift, Core Audio, Loopback, Audio Hijack, and
others) belong to their respective owners. Mentioning a product here does not
imply affiliation, sponsorship, or endorsement, and exists only to describe
interoperability (for example, that Clapboard can capture audio from a
Loopback virtual device).
