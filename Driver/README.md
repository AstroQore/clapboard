# ClapboardDriver — virtual audio devices

`ClapboardDriver.driver` is a Core Audio **AudioServerPlugIn**: a CFPlugIn
bundle that `coreaudiod` loads from `/Library/Audio/Plug-Ins/HAL`. It publishes
four loopback devices, **Clapboard Bus 1** … **Clapboard Bus 4**. Whatever any
app plays to a bus, any other app can capture from the same bus — that is the
whole feature. It replaces Loopback on the *output* side: Clapboard sends its
mix to a bus, and OBS, Zoom, Audio Hijack or QuickTime record from it.

The driver is plain C, links only CoreAudio and CoreFoundation, and is built
with `clang` rather than SwiftPM. It shares nothing with `ClapboardCore`; the
app finds the buses like any other Core Audio device.

| | |
|---|---|
| Devices | 4 by default (`ClapboardDeviceCount` in `Info.plist`, 1…16) |
| Name | `Clapboard Bus <n>` |
| Device UID | `com.astroqore.Clapboard.bus.<n>` |
| Model UID | `com.astroqore.Clapboard.bus` |
| Manufacturer | `AstroQore` |
| Transport | `kAudioDeviceTransportTypeVirtual` |
| Channels | 2, interleaved Float32, packed, native endian |
| Sample rates | 44100 / 48000 (default) / 96000 |
| Streams | one input, one output, both always active |
| Controls | output volume + output mute |
| Latency / safety offset | 0 |
| Bundle ID | `com.astroqore.ClapboardDriver` |

## Build, test, install

```sh
./Scripts/build_driver.sh release          # -> .build/ClapboardDriver.driver
./Scripts/build_driver.sh release --harness      # + run the offline test harness
./Scripts/build_driver.sh debug   --harness-asan # + the same under ASan/UBSan
./Scripts/build_driver_pkg.sh              # -> .build/ClapboardDriver.pkg
open .build/ClapboardDriver.pkg            # Installer.app asks for the password
```

The bundle is built universal (`arm64` + `x86_64`) and signed ad-hoc, which is
all `coreaudiod` requires on the machine that built it.

`Scripts/install_driver.sh` validates the bundle and prints what to run; it
never installs anything by itself unless you pass `--open` (hand the package to
Installer.app) or `--run` (the manual `sudo cp` / `chown` / restart path).
`Scripts/uninstall_driver.sh` mirrors it, and
`Scripts/build_driver_uninstaller_pkg.sh` produces a payload-free
`ClapboardDriverUninstaller.pkg` that removes the driver and forgets the
receipt.

Installing or removing the driver **restarts `coreaudiod`**. Every audio app on
the machine loses its device connections for a moment; some need restarting.

To verify afterwards:

```sh
.build/Clapboard.app/Contents/MacOS/Clapboard --list-devices | grep "Clapboard Bus"
system_profiler SPAudioDataType | grep "Clapboard Bus"
# or just open Audio MIDI Setup
```

## How the loopback works

Each device owns one ring buffer of **65536 stereo Float32 frames** (512 KiB),
allocated when the driver is created and freed when the last reference goes
away. The HAL drives the driver with two operations per IO cycle per client:

- **`WriteMix`** — a client's finished output mix. The driver *adds* it into the
  ring at `mOutputTime.mSampleTime`, so several apps playing to the same bus sum
  the way they would into real hardware. The output volume control and the mute
  are applied here.
- **`ReadInput`** — the input side. The driver copies out of the ring at
  `mInputTime.mSampleTime` and then **zeroes what it copied**, so a frame is
  delivered exactly once and silence follows if nobody writes again. Without
  that, a block written once would repeat forever, one ring per period.

The device's `ZeroTimeStampPeriod` is *equal to the ring size*, so the HAL's
sample time and the ring offset agree by construction:

```
offset = (UInt64)sampleTime % 65536
```

A block that runs off the end of the ring is split in two and wraps to the
start. Nothing in `DoIOOperation` allocates, locks, logs or calls into
CoreFoundation.

`GetZeroTimeStamp` runs a free-running clock anchored at the first `StartIO`:

```
ticksPerRing = hostTicksPerSecond * 65536 / sampleRate
if now >= anchor + ticksPerRing * (count + 1): count += 1
sampleTime = count * 65536
hostTime   = anchor + ticksPerRing * count
```

`mach_timebase_info` converts nanoseconds to host ticks. At 48 kHz one period
is 1.365 s; at 96 kHz, 0.683 s. `StartIO` clears the ring and re-anchors the
timeline only for the *first* client, and bumps the seed so the HAL knows the
old timeline is gone.

### Object model

Object IDs are allocated arithmetically so an ID can be decoded without a
lookup table. Device *i* (0-based) owns `10 * (i + 1) + 0…4`:

| offset | object | device 1 | device 2 |
|---|---|---|---|
| 0 | device | 10 | 20 |
| 1 | input stream | 11 | 21 |
| 2 | output stream | 12 | 22 |
| 3 | output volume control | 13 | 23 |
| 4 | output mute control | 14 | 24 |

The plug-in object is `kAudioObjectPlugInObject` (1), as the HAL requires.

`Driver/Sources` is three files: `ClapboardState.c` (device table, lifetime,
timeline and volume maths), `ClapboardProperties.c` (the whole property model)
and `ClapboardDriver.c` (CFPlugIn factory, COM plumbing, IO). All five property
entry points share one `Clapboard_DescribePropertyLocked()`, so `HasProperty`,
`IsPropertySettable` and `GetPropertyDataSize` cannot drift apart from each
other.

### Changing the sample rate

`kAudioDevicePropertyNominalSampleRate` is settable, and so is either stream's
`VirtualFormat`/`PhysicalFormat` (sample rate only — the channel count and
sample type are fixed). A change goes out through the host's
`RequestDeviceConfigurationChange()` and is applied when the host calls back
into `PerformDeviceConfigurationChange()`, which is also where the ring is
cleared and the timeline re-anchored. The host callback is always made with the
state mutex released, because the host may re-enter the driver synchronously.

## Testing without coreaudiod

`Driver/Harness/harness.c` is a plain command-line program. It `dlopen()`s the
built bundle binary, calls `ClapboardDriver_Create`, does the COM
`QueryInterface` dance, hands the driver a **fake
`AudioServerPlugInHostInterface`** — whose
`RequestDeviceConfigurationChange` calls `PerformDeviceConfigurationChange`
straight back, the tightest re-entrancy the driver ever sees — and then drives
the same calls `coreaudiod` would.

253 checks, covering: the plug-in object; every device's name, UID, model UID,
transport, scopes, stream list, control list, formats and sample rates;
`GetPropertyDataSize` agreeing with `GetPropertyData` for every property read;
UID translation including a miss; the volume and mute controls; a sample-rate
round trip to 96 kHz and back; `StartIO` → monotonic zero timestamps that
advance by exactly one ring per period; the loopback itself (a 256-frame ramp
written and read back, a second read returning silence, two clients summing, a
block wrapping the end of the ring, sample times one ring apart aliasing, a
muted device writing nothing, and one bus not leaking into another); `StopIO`;
and `Release` dropping the reference count to zero.

```sh
./Scripts/build_driver.sh release --harness
./Scripts/build_driver.sh debug --harness-asan
```

`--harness-asan` builds a second, sanitized copy of the driver next to the
bundle and points the harness at *that*, so `-fsanitize=address,undefined`
covers the driver's own code and not just the harness's. All sources compile
with `-Wall -Wextra -Werror`.

## Signing and distribution

The build signs ad-hoc (`codesign --force --sign -`). `coreaudiod` accepts
that locally, and the installer package built by `Scripts/build_driver_pkg.sh`
is unsigned, so Gatekeeper will want a right-click → Open the first time it is
run on another machine.

To hand the driver to someone else properly:

1. Sign the bundle with a **Developer ID Application** certificate —
   `CLAPBOARD_CODESIGN_IDENTITY` is not wired into `build_driver.sh` yet, so
   re-sign the built bundle by hand or add the flag.
2. Sign the package with a **Developer ID Installer** certificate:
   `CLAPBOARD_PKG_IDENTITY="Developer ID Installer: … (TEAMID)" ./Scripts/build_driver_pkg.sh`
3. Notarise it: `xcrun notarytool submit .build/ClapboardDriver.pkg --wait …`
   then `xcrun stapler staple .build/ClapboardDriver.pkg`.

The driver is *not* a DriverKit extension and needs no system extension
approval, no kernel extension, and no entitlements.

## License

AGPL-3.0-only, like the rest of Clapboard — see `LICENSE` at the repository
root. The driver is original code written against Apple's `AudioServerPlugIn`
headers; it links nothing but CoreAudio and CoreFoundation and borrows no code
from other virtual audio drivers.

## Known limits

- **One reader per bus.** `ReadInput` zeroes the frames it hands out, so if two
  processes capture the same bus at the same time, the first one to run in a
  cycle gets the audio and the second gets silence. With four buses the answer
  is one bus per consumer. (Not zeroing would make every block repeat forever
  instead.)
- **No drift compensation.** The buses run off `mach_absolute_time()`, not off
  any hardware clock. Aggregating a bus with a real device is the HAL's job and
  needs drift compensation enabled on the sub-device, exactly as `AGENTS.md`
  says for Clapboard's own aggregate.
- **Changing the bus count needs `sudo`.** `ClapboardDeviceCount` lives in the
  installed `Info.plist`, so raising it means editing the file in
  `/Library/Audio/Plug-Ins/HAL` (or reinstalling) and restarting `coreaudiod`.
- **Sample rate is per-bus and global to it.** Every client of a bus sees the
  same rate; changing it stops IO for everyone on that bus.
