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
| M4 Audio Unit hosting with latency compensation | done — every third-party AU on this Mac is Intel-only, so only Apple's have been exercised |
| M5 Session persistence, missing-device handling | done |
| M6 Virtual audio devices (Clapboard Bus 1…4, Core Audio HAL driver) | done — needs an install + coreaudiod restart to confirm on this Mac |
| M7 Bus routing: model, RT graph, multi-output aggregate, session format 2 | done |
| M8 Console UI: vertical strips, per-strip routing, scoped solo, per-bus output | done — per-bus effect editing is still Master-only |
| M9 Process taps as lane sources (capture another app, or all system audio) | done — the audio-capture permission was never enforced on the development Mac; see `docs/PERMISSIONS.md` |

## Install and updates

Download the `.zip` from the [latest release][releases], unzip it, and drag
`Clapboard.app` into `/Applications`.

Clapboard is **ad-hoc signed and not notarized** — there is no Apple Developer
Program membership behind it — so the first launch has to be a **right-click ›
Open** (or an approval in System Settings › Privacy & Security). A plain
double-click will be refused by Gatekeeper. The download's `.sha256` sits
beside it on the release page if you want to check what you got.

### Updates

Clapboard updates itself through [Sparkle][sparkle], on two channels:

| | |
|---|---|
| **Main** | stable releases only — the default |
| **Dev** | preview releases **plus** every Main release |

Pick one in **Clapboard › Update Channel**, and check on demand with
**Clapboard › Check for Updates…**. Clapboard checks once a day, asks before it
installs anything, and never installs in the background — a mixer must not swap
itself out from under a live session.

Every update is signed with an EdDSA key and verified *before* it is unpacked,
which is what makes an unnotarized download safe to accept. The public key
lives in `Resources/Info.plist`; the private key never touches this repository.
`RELEASING.md` has the whole pipeline.

**One rough edge, unavoidable while builds are ad-hoc signed:** an ad-hoc
signature is derived from the binary's own hash, so every update looks to macOS
like a different app. Expect the **microphone prompt to come back after an
update** — and if it does not come back but the meters sit at silence, macOS
has a stale denied entry: `tccutil reset Microphone com.astroqore.Clapboard`,
then relaunch. `docs/PERMISSIONS.md` explains why.

[releases]: https://github.com/AstroQore/clapboard/releases
[sparkle]: https://sparkle-project.org

## Build

Requires macOS 26 and Xcode 26 (Swift 6.2). Pure SwiftPM, no Xcode project.
One dependency: [Sparkle][sparkle], pinned to an exact version, embedded into
the bundle by `Scripts/build_app.sh` and signed before the app is.

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

It exits non-zero if an aggregate device — or a process tap — survives the
teardown. Add `--ignore-tcc` to exercise everything except real capture on a
machine where the microphone prompt has not been answered.

`--list-taps` prints whether this build may capture system audio and every
application the HAL currently reports as playing, and `--lane-tap
<bundle-id|system>` adds a lane fed by a process tap instead of an input
device (`#mono` after it asks for a mono mixdown):

```sh
.build/Clapboard.app/Contents/MacOS/Clapboard --list-taps
.build/Clapboard.app/Contents/MacOS/Clapboard --engine-test 10 --output "Loopback" \
    --lane "MacBook Pro Microphone" --lane-tap system
```

`--lane-effect <name-or-id>` inserts an Audio Unit into the lane named by the
preceding `--lane`, `--master-effect` into the master chain, and `--bypass-at
<sec>` toggles every inserted effect once. Each second it then prints each
lane's chain, its latency, the compensation on top and the delay actually
written to the render thread, so plug-in delay compensation can be checked
from a script.

Always run the `.app`, never `swift run`: microphone access is granted to a
bundle identifier, and a bare executable has none.

## Effects

Every lane has an Audio Unit chain — after the delay line, before the fader —
and the master bus has one of its own, after the sum and before the master
gain. Chips under a lane's controls are the chain: the power button on a chip
bypasses it (lit while the plug-in runs, hollow while it is bypassed), the name
opens the plug-in's own editor, right-click to reorder or remove, `+` to
insert. Editing a chain while the mix is running is a graph snapshot
swap, the same click-free mechanism adding a lane uses, and bypass is
crossfaded over 10 ms rather than switched.

**Delay compensation.** A look-ahead plug-in makes its lane come out late, so
Clapboard delays every other lane to match:

```
lane delay written to the render thread
    = lane.delaySamples                        # manual, or what Auto Sync measured
    + (slowest lane's chain latency − this lane's chain latency)
```

The manual value is left exactly as it was measured; compensation is added on
top, and each lane shows how much as `PDC +N sp`. Bypass is a real
pass-through — the plug-in stops rendering, so its latency goes away too — and
the compensation is recomputed every time one is toggled, a plug-in reports a
new latency, or a chain is edited. The master chain is common to every lane,
so it is not compensated at all, only reported: the master bar shows the total
as `output latency N ms`. If compensation would push a lane past the delay
line's 1000 ms ceiling it is clamped and the mixer says so.

Chains live in the session file, in the `laneExtras` / `masterExtras` bags, as
`{id, componentID, bypass, displayName, fullState}` with each plug-in's state
as a base64 binary property list. Effect ids survive a relaunch. A plug-in the
Mac no longer has comes back as a greyed placeholder that keeps its saved
state, so opening a session on a machine without the plug-in and saving it
again does not throw the settings away.

### Intel-only plug-ins

An AUv2 plug-in is loaded into Clapboard's own process or not at all. On an
Apple Silicon Mac a bundle with no `arm64` slice therefore cannot be hosted:
macOS answers by starting a Rosetta hosting service, and a plug-in in there
never finishes `allocateRenderResources()`, which would wedge the main thread.
Clapboard reads each AUv2 bundle's Mach-O header up front, greys those entries
in the plug-in menu with the reason, and refuses them rather than hanging.

On this machine that is **every third-party effect installed** — the whole
Ozone 9 suite, Melodyne, Relay, Tonal Balance Control. Only Apple's own units
(all of them universal) can be exercised here, which is what M4's tests use.
`--effects-list` prints the verdict for each:

```sh
$BIN --effects-list
aufx.dely.appl	AUv2	x86_64+arm64	Apple	AUDelay	1.6.0
aufx.ZnO9.iZtp	AUv2	x86_64	iZotope	Ozone 9	9.1.0	UNAVAILABLE: Intel-only AUv2 — …
```

AUv3 plug-ins are app extensions and are not affected; Clapboard loads one
in-process when it can and out of process otherwise.

## Virtual devices

Clapboard ships its own Core Audio driver, so the mix can be handed to OBS,
Zoom, Audio Hijack or QuickTime without Loopback on the output side. It
publishes four loopback devices — **Clapboard Bus 1** … **Clapboard Bus 4** —
each 2-channel Float32 at 48 kHz (44.1 and 96 kHz are also offered). Whatever
an app plays to a bus, another app captures from the same bus.

### Installing them

Nothing has to be built or downloaded by hand. `Scripts/build_app.sh` copies
`ClapboardDriver.pkg` and its uninstaller into the app bundle, and the app
offers to install them:

- On first launch the **setup assistant** walks through what Clapboard is, the
  microphone permission, and the virtual devices.
- Any time afterwards: **Clapboard › Set Up Virtual Devices…**, or
  **Clapboard › Show Setup Assistant** for the whole flow.

Pressing *Install…* hands the package to macOS's own **Installer**, which
shows what will be written and asks for the administrator password itself —
Clapboard never sees it and never runs anything as root. Clapboard stops its
engine first, because installing restarts `coreaudiod` and every audio app on
the Mac loses its device connections for a moment. The assistant then watches
for `Clapboard Bus 1` to appear and says so when it does. *Uninstall…* runs
the payload-free uninstaller package the same way.

`--driver-status` prints the same state from the command line:

```
$ .build/Clapboard.app/Contents/MacOS/Clapboard --driver-status
state           notInstalled
bundled         1.0.0 (short 1.0)
devices         absent
summary         Virtual devices are not installed. Clapboard can install them for you (driver 1.0.0).
```

### Building the driver (developer path)

```sh
./Scripts/build_driver.sh release            # -> .build/ClapboardDriver.driver
./Scripts/build_driver.sh release --harness  # + 253 offline checks, no coreaudiod
./Scripts/build_driver_pkg.sh                # -> .build/ClapboardDriver.pkg
open .build/ClapboardDriver.pkg              # Installer.app asks for the password
```

`./Scripts/build_app.sh` runs the two packaging scripts itself. If they fail,
the app is still built — it just reports `installerUnavailable` and points at
`Scripts/build_driver_pkg.sh`. `CLAPBOARD_SKIP_DRIVER_PKG=1` skips them
deliberately. `./Scripts/install_driver.sh` validates the bundle and prints
exactly what will happen without doing it; `./Scripts/uninstall_driver.sh` and
`./Scripts/build_driver_uninstaller_pkg.sh` undo it.

The devices are keyed by UID — `com.astroqore.Clapboard.bus.<n>`, model UID
`com.astroqore.Clapboard.bus` — so the app's device registry recognises them
without a special case. Because reading a bus consumes it, plan on one bus per
capturing app.

`Driver/README.md` has the object model, the ring/timeline arithmetic, the test
harness and the signing/notarisation steps.

## Routing

Lanes no longer sum into one fixed master: they route to a **bus**, buses can
feed other buses, and any bus can carry its own output device — several
buses, several output devices, one private aggregate. Solo is scoped (a lane
solo silences the other lanes on its bus; a bus solo silences its sibling
buses) and plug-in delay compensation runs across the whole tree, not just
per lane. `docs/ROUTING.md` is the full model; the engine API
(`addBus`/`setBusDestination`/`setLaneDestination`/`setBusSolo`/…) and session
format 2 are implemented.

The **Console** tab is where you drive it: vertical channel strips in a
horizontally scrolling row, lane strips on the left and bus strips on the
right, each with a name, effect chips, a fader beside a meter, `M`/`S`, and
its own routing — a destination bus for a lane, a parent bus plus an output
device and channel offset for a bus. A strip silenced by someone else's solo
is drawn dimmed with its own `S` still off, a routing edit that would close a
loop is refused with the loop named, and every meter in the window is driven
by one 30 Hz timer. The row-based mixer is still there as the **Rows** tab.
Everything is also reachable headlessly:

```sh
$BIN --engine-test 10 --output Loopback --lane "MacBook Pro Microphone" \
    --bus Vocals --route "MacBook Pro Microphone"=Vocals --lane "Audio Hijack Input"
$BIN --routing-selftest          # builds a two-output bus tree and checks it end to end
```

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

## Projects

The autosaved session above is what opens until you save a project. **Save
As…** (⇧⌘S) writes the same document to a `.clapboard` file wherever you want
it, and from then on the one-second autosave writes *that* file instead — so a
setup you spent an evening on is a file you can name, keep and come back to.

| | |
|---|---|
| **New** | ⌘N — stops the engine, empties the mixer to a single `Master`, goes back to autosaving the default session |
| **Open…** | ⌘O — replaces the live graph; the engine stops, restores and restarts if it was running |
| **Open Recent** | the last ten, from macOS's own recents list, with **Clear Menu** |
| **Save** | ⌘S — autosave is debounced, this is the flush |
| **Save As…** | ⇧⌘S — writes a `.clapboard` file and makes it the autosave target |

The window title is `<project name> — Clapboard` with the standard edited dot
while the mixer differs from the file on disk, the project file is the window's
represented URL (so the proxy icon works), and the bar at the foot of the
window names the project and says what the last save did.

`.clapboard` files are declared in `Info.plist` as
`com.astroqore.clapboard.project`, conforming to `public.json` — they are
ordinary session JSON, so they double-click open, and you can still read, diff
or repair one by hand.

Two things worth knowing:

- **New goes back to the default session.** A second after you choose it, the
  empty mixer is autosaved over `session.json`. Clapboard asks first whenever
  there is anything to lose and names the file, but that is what "New" means
  here — save a project first if the current mixer matters.
- **A recent entry whose file has moved** reports that and drops itself from
  the menu rather than failing quietly.

The last project is remembered and reopened on the next launch. If it has been
moved or deleted by then, Clapboard falls back to the default session and says
so in the project bar.


## Shortcuts and the menu bar

The point of a mixer you run while streaming is that you never have to look at
it, so Clapboard keeps a microphone in the menu bar — `mic.fill` while
something is live, `mic.slash.fill` when everything is muted, dimmed while the
engine is stopped — and registers **global keyboard shortcuts** that fire while
another app is in front.

Out of the box `⌃⌥M` is 闭麦 / 开麦 on one key: it mutes every lane and
remembers which ones were live, and pressing it again puts exactly that set
back. A lane you had deliberately muted stays muted. "Mute all" and "unmute
all" exist separately for a one-way key, and "unmute all" means *all* — it is
the escape hatch out of a state you no longer trust, so it ignores the memory
the toggle key honours. Any lane can also get a shortcut of its own, and
everything on the keyboard is on the menu-bar menu too, with a checkmark per
lane.

Edit them in **Clapboard › Settings…** (`⌘,`): click a shortcut to record a
new one, `⎋` cancels, `⌫` clears. A key needs ⌃, ⌥ or ⌘ — or is an F-key,
which is what makes F13–F20 on a stream deck the natural mute button.

The shortcuts use Carbon's `RegisterEventHotKey`, not
`NSEvent.addGlobalMonitorForEvents`, so they need **no Accessibility
permission** and they *swallow* the key: press the mute key in OBS and OBS does
not also see it. The one thing macOS will not tell us is whether it has already
claimed a combination for itself — registration succeeds and the system keeps
the key — so the settings sheet flashes the row green when a shortcut actually
reaches Clapboard. A row that never lights up is a key someone else owns.

Bindings live in `~/Library/Application Support/Clapboard/hotkeys.json`,
separately from the session: a mixer gets rebuilt when the rig changes, muscle
memory does not. The file is written atomically and read forgivingly — a
binding this build cannot understand is dropped and reported, never a reason to
lose the rest.

Bus and solo shortcuts are reserved but not implemented; they are decoded and
shown as "coming soon" so a file from a later build survives a round-trip
through this one.

## Headless commands

The executable doubles as a command-line tool. These flags are dispatched in
`main.swift` before AppKit starts, so they work from a shell and never open a
window:

```sh
BIN=.build/Clapboard.app/Contents/MacOS/Clapboard
$BIN --list-devices
$BIN --engine-test 20 --output Loopback --lane "MacBook Pro Microphone" --lane "Audio Hijack Input" --rebuild-at 8 --hot-lane "BlackHole 2ch"
$BIN --engine-test 20 --output Loopback --lane "MacBook Pro Microphone" --lane-effect AUPeakLimiter --lane "Audio Hijack Input" --master-effect AUDelay --bypass-at 10
$BIN --effects-list
$BIN --sync-test 8 --output Loopback --lane "Wireless Mic Rx" --lane "MacBook Pro Microphone" --apply   # clap when it says CLAP NOW
$BIN --engine-test 5 --output Loopback --lane "MacBook Pro Microphone" --save-session --session-path /tmp/s.json
$BIN --restore-session /tmp/s.json --run 3
$BIN --restore-session /tmp/v1-session.json --run 0 --save-session --session-path /tmp/migrated.json  # v1 -> v2
$BIN --session-dump
$BIN --session-autosave-test
$BIN --open-project "/tmp/Take One.clapboard"   # restore a project and print the graph
$BIN --project-selftest                         # save / mutate / New / reopen, in a temp directory
$BIN --hotkeys-selftest                 # register every binding, report per binding, release
$BIN --hotkeys-selftest --hotkeys-path /tmp/hotkeys.json --reset
$BIN --engine-test 10 --output Loopback --lane "MacBook Pro Microphone" --bus Vocals --route "MacBook Pro Microphone"=Vocals
$BIN --routing-selftest
$BIN --list-taps                        # tappable apps + whether system-audio capture is allowed
$BIN --engine-test 10 --output Loopback --lane "MacBook Pro Microphone" --lane-tap system
$BIN --engine-test 10 --output Loopback --lane-tap com.apple.Music#mono
```

`--project-selftest` builds a mixer, saves it as a project, proves the debounced
autosave follows the project rather than the default session, starts a new
session, reopens the project and asserts the graph came back identical — all
inside a temporary directory, against an injected recents list and last-project
pointer, so it cannot touch your real session file, preferences or Open Recent
menu.

`--hotkeys-selftest` loads the hotkey file (writing the default set when there
is none), registers every binding with Carbon, prints `noErr` or the failure
per binding, unregisters and exits — non-zero when any binding was refused. It
is the only way to check the shortcut path without a human pressing keys.

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
block. `Resources/Clapboard.entitlements` is intentionally empty. (Sparkle's
own helper executables *are* signed with the hardened runtime — they are
separate binaries that never host a plug-in.)

Released builds are ad-hoc signed too, which is why an in-app update re-prompts
for the microphone; see "Install and updates" above and `RELEASING.md`.

## Layout

```
Package.swift                 ClapboardApp (SwiftUI) · ClapboardCore (engine) · ClapboardCoreTests
Sources/ClapboardCore/Audio   Core Audio wrappers, device registry, aggregate channel layout
Sources/ClapboardCore/RT      real-time render kernel, delay lines, meters   (M1+)
Sources/ClapboardCore/Sync    onset detection, GCC-PHAT, clap aligner        (M3)
Sources/ClapboardCore/AU      Audio Unit catalog and host                    (M4)
Sources/ClapboardCore/Session JSON session document                          (M5)
Sources/ClapboardApp          app entry, controllers, views
Driver/Sources               ClapboardDriver.driver, a Core Audio AudioServerPlugIn (M6)
Driver/Harness               offline driver tests — no coreaudiod, no install
Driver/Packaging             pkgbuild/productbuild scripts and installer resources
Sources/ClapboardApp/Hotkeys  global shortcuts, key recorder, menu-bar item
Sources/ClapboardApp/AppUpdateController.swift  Sparkle updater + channel choice
Scripts/build_app.sh          bundle + sign .build/Clapboard.app (incl. Sparkle)
Scripts/build_driver.sh       build + sign + test .build/ClapboardDriver.driver
Scripts/build_driver_pkg.sh   wrap the driver into .build/ClapboardDriver.pkg
Scripts/install_driver.sh     validate and install (or print what to run)
Scripts/release_app.sh        zip + checksum + signed appcast item for one tag
Scripts/generate_update_feed.sh  rebuild the shared two-channel appcast
```

## Status, contributing, and license

See the Status table above for what's implemented; `docs/ARCHITECTURE.md`
marks planned-but-not-implemented items (bus routing, hotkeys, a
virtual-device driver) explicitly so this README doesn't have
to be re-checked against the code to know what's real.

**The virtual-device driver installs system-wide.** It is a HAL plug-in under
`/Library/Audio/Plug-Ins/HAL`, so installing it needs administrator rights and
restarts `coreaudiod` for the whole machine. Clapboard offers it, macOS's
Installer performs it — see `docs/PERMISSIONS.md`.

Contributions are welcome — see `CONTRIBUTING.md` for the build/test/package
verification steps, the real-time audio rules, and the PR checklist. Please
also read `CODE_OF_CONDUCT.md` and, for anything security-sensitive,
`SECURITY.md`.

## License

AGPL-3.0-only. See `LICENSE` for the full text and `THIRD_PARTY_NOTICES.md`
for what this project depends on — Sparkle (MIT), which is redistributed
inside the app bundle, and otherwise nothing beyond Apple's system frameworks.
