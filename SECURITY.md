# Security Policy

Clapboard is a local, offline macOS mixer. It has no network access and sends
no telemetry. What it does touch:

- **Microphone input**, through the standard macOS TCC prompt
  (`NSMicrophoneUsageDescription` in `Resources/Info.plist`, bundle id
  `com.astroqore.Clapboard`). It captures audio only from the devices you
  explicitly add as lanes.
- **Core Audio**, by creating a private aggregate device (`AudioHardwareCreateAggregateDevice`)
  that unions your lane devices and the chosen output device. Private means it
  never appears in Audio MIDI Setup or other apps' device lists, and it is
  destroyed on every stop, rebuild and process exit — including on
  `SIGTERM`/`SIGINT` (`TerminationGuard`). It also hosts third-party Audio Unit
  (AUv2/AUv3) plug-ins in-process, which is why the app ships unsandboxed and
  without the hardened runtime (see `docs/PERMISSIONS.md`).
- **Local storage**, under `~/Library/Application Support/Clapboard/`: the
  mixer session (`session.json`) and nothing else. See the README's "Session
  file" section for the write and recovery contract.
- **The virtual-device driver** (planned, lands on a separate branch): a
  `DriverKit`/`AudioServerPlugin` installed under
  `/Library/Audio/Plug-Ins/HAL`, which requires administrator rights to
  install and affects every app on the system, not just Clapboard.

Clapboard does not open sockets, does not phone home, and does not read files
outside the paths above.

## Reporting a Vulnerability

Please use [GitHub private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
on this repository (Security tab → "Report a vulnerability") if it is enabled.
If it is not available, open a minimal public issue that describes the
affected area without exploit details or secrets, and ask for a private
channel to follow up in.

Please do not include in a public report:

- Full unsanitized `--engine-test` / `--sync-test` output that reveals device
  names or serial numbers you consider private.
- Session files, crash logs, or other local files verbatim — describe the
  problem, or share a redacted excerpt.

## Signing and Notarization

Release builds from `Scripts/build_app.sh` are ad-hoc signed by default (see
`docs/PERMISSIONS.md` for what that means for the Microphone prompt) and are
**not notarized**. There is no public release channel yet; build from source.
This will be revisited before any signed/notarized distribution ships.

## Supported Versions

Clapboard is pre-1.0, single-branch software. Security fixes target `main`
first; there are no maintained release branches yet.
