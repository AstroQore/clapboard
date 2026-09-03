# Third-party notices

## Direct dependencies

None. `Package.swift` declares no external package dependencies — Clapboard
links only against Apple's system frameworks (CoreAudio, AudioToolbox,
AVFoundation, Accelerate, Synchronization, SwiftUI/AppKit), which ship with
the OS and are not vendored or redistributed by this repository.

If a dependency is ever added, it will be listed here alongside its license,
kept in step with `Package.swift`/`Package.resolved`.

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
