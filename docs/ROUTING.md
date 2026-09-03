# Routing model (design, v2)

Status: **implemented**, except Projects and the one "Auto-assign a Clapboard
Bus" action, both marked **not implemented** below. The model (`BusConfig`,
`RoutingGraph`, `SoloLogic`, `LatencyPlan`), the real-time bus graph, a private
aggregate device with several output devices, the `AudioEngine` bus API,
session format 2 with version 1 migration, the console UI, and the headless
`--engine-test`/`--routing-selftest` coverage below are all in `main`.
`docs/ARCHITECTURE.md`'s signal-flow diagram still shows the pre-bus
single-master shape and needs updating to match this document; treat this file
as authoritative for routing until then.

## Goals

- Feel like a console. Every input strip and every bus strip has the same
  controls: gain, mute, solo, effects, meter.
- Route any input to any bus. Buses can feed other buses. Any bus can also be
  sent to an output device (a physical interface, a Loopback device, or one of
  Clapboard's own virtual devices once the driver lands).
- Keep Auto Sync semantics: lanes are aligned to each other in the raw domain,
  and plug-in delay compensation keeps them aligned no matter which bus they
  end up on.
- Save the whole thing as a project and come back to it.

## Objects

```
Lane  (input strip)             Bus  (virtual track / group)
  id: UUID                        id: UUID
  source: LaneSource              name: String
  name, gainDB, muted, solo       gainDB, muted, solo
  polarityInverted                effects: [EffectConfig]
  delaySamples (manual/auto)      destinationBus: UUID?        <- parent bus, nil = none
  effects: [EffectConfig]         outputDeviceUID: String?     <- optional device send
  destinationBus: UUID            outputChannelOffset: Int     <- first channel on that device
```

- `LaneSource` is `.device(uid, channels)` today; `.processTap(...)` is added
  by the process-tap milestone without touching the rest of this model.
- Exactly one bus is created by default and named `Master`; nothing else is
  special about it. Deleting the last bus is refused. Deleting a bus re-routes
  its inputs to the bus it was sending to (or to the first remaining bus).
- A lane always has a destination bus. A bus may have a parent bus, an output
  device, both, or neither (neither = it is a mute group nobody listens to; the
  UI warns).
- Routing is a DAG. `setDestination` rejects any edge that would create a
  cycle; the error names the path.

## Processing order

Lanes first, then buses in topological order (children before parents):

```
for lane in lanes:            input → capture tap → delay → effects → fader/mute → accumulate into bus
for bus in topo order:        sum (already accumulated) → effects → fader/mute → write to parent bus
                                                                                 and/or output stream
```

Every bus owns a persistent `BusRuntime` (stereo accumulator, meter, gain
smoother, a PDC delay line). Bus accumulators are cleared at the start of the
block. Output streams belong to whichever output devices are in the aggregate;
a bus with an output device writes into that device's first output buffer at
`outputChannelOffset` (stereo); several buses may target different devices, and
the first output device in the list is the aggregate's clock main.

## Mute and solo

- `muted` is the switch that exists today (`enabled` inverted); it ramps, never
  steps.
- Solo is scoped to a bus: soloing one lane silences every other **lane feeding
  the same bus** that is not itself soloed. Soloing a bus silences its sibling
  buses (those sharing the same parent). Solo never touches anything upstream
  or downstream of the soloed strip.
- Effective enable for a strip = `!muted && (no solo in its scope || solo)`.
  Computed on the main thread whenever mute/solo/routing changes and pushed as
  the existing per-lane `enabled` atomic; buses get the same atomic.
- Hotkeys act on `muted` only; "mute all" mutes lanes, never buses, and
  remembers which lanes were unmuted so "unmute all" restores exactly those.

## Plug-in delay compensation across the tree

Per lane (exists today): `effective = manual + (maxLaneChain(bus) − laneChain)`,
where the max is taken over the lanes feeding the same bus.

Per bus: siblings under one parent must arrive together, so each bus gets
`busPDC = maxSubtreeLatency(siblings) − subtreeLatency(self)`, where
`subtreeLatency(bus) = busChainLatency + max over its inputs of
(their chain latency + their own PDC contribution)`. It is applied with the
bus's delay line before its effects. The root buses that go straight to output
devices are not compensated against each other (they are different
destinations); their total latency is reported per output as "output latency".

## Session format 2

```json
{
  "formatVersion": 2,
  "lanes":  [ { ...LaneConfig, "destinationBus": "<uuid>" } ],
  "buses":  [ { "id": "...", "name": "Master", "gainDB": 0, "muted": false, "solo": false,
                "destinationBus": null, "outputDeviceUID": "...", "outputChannelOffset": 0,
                "effects": "<base64 chain>" } ],
  "laneExtras": {}, "masterExtras": {}      // kept for one version, migrated on load
}
```

Migration from version 1: create the `Master` bus from `outputDeviceUID`,
`masterGainDB` and `masterExtras.effects`; point every lane at it.

`laneExtras` still carries every lane's chain exactly as before — a
`LaneConfig` has no inline `effects` field, unlike a bus — so it is not
actually vestigial the way `masterExtras` is; it is shown empty above only
because this particular example session has no lane effects. `masterExtras`
itself is read for version 1 migration and otherwise always written empty,
since a bus's chain now travels on `BusConfig.effects` instead, master
included.

One scope note beyond what shipped: only the Master bus's chain is
loaded back into a live Audio Unit instance on restore (`addEffect(toLane:)`
covers lanes and Master; nothing yet offers per-bus effect editing for any
other bus). A chain saved on a non-master bus still round-trips — its
`EffectConfig`s, including `fullState`, come back exactly as saved — but as a
placeholder, the same "state kept, not live" contract an uninstalled plug-in
already gets.

## Projects — not implemented

The autosaved session stays where it is (`~/Library/Application Support/
Clapboard/session.json`) and is what opens on launch. In addition:

- **Save As…** writes the same document to a user-chosen `.clapboard` file
  (JSON, same schema, UTI `com.astroqore.clapboard.project`).
- **Open…** loads one, replaces the live graph (engine stops, restores,
  restarts), and makes it the autosave target until another project is
  opened or "Detach from project" is chosen.
- **Open Recent** keeps the last ten paths (`NSDocumentController` recents
  are fine to reuse even without going document-based).
- The title bar shows the project name and a dirty marker when the live graph
  differs from the file on disk.

## Virtual devices

When the Clapboard driver is installed, its devices appear as ordinary output
devices named `Clapboard Bus n` (UID `com.astroqore.Clapboard.bus.n`). The bus
strip's output picker lists them first — `AudioEngine.busOutputDeviceOrder(_:)`
partitions the registry on the `com.astroqore.Clapboard.bus.` UID prefix and
keeps the registry's order inside each group. Nothing in the routing model
depends on the driver: `setBusOutput`/`AggregateDeviceRequest.outputDeviceUIDs`
treat a `Clapboard Bus n` UID the same as any other output device, and the
ordering is purely which entry the eye lands on first.

**Not implemented:** the "Auto-assign a Clapboard Bus" action that would pick
the lowest unused one.

## UI

The **Console** tab (`ConsoleView`, `ConsoleStripViews`) is the mixer: vertical
strips in a horizontally scrolling row, lane strips on the left, bus strips on
the right, a thin divider between them, each strip a fixed 120 pt column.

Both kinds of strip carry the same things, in the same order — that sameness is
the point:

- an editable name;
- the effect chain as chips (`EffectChainView` laid out vertically instead of
  horizontally);
- a fader beside a meter, the two flush with the bottom of every card so the
  whole row lines up, with the gain and peak read-outs under them;
- `M` and `S`.

A **lane strip** adds: the source device as a menu (`setLaneSource`) with its
channel underneath, the destination bus picker, the delay in ms with ±0.1 ms
steppers and the `N sp` / `PDC +N sp` read-outs, polarity `Ø`, and remove.

A **bus strip** adds: the parent bus picker (including "→ none"), the output
device picker — Clapboard's own virtual devices first, see § Virtual devices —
the output channel offset when the device has more than two channels, an
`out N ms` read-out from `outputLatencySamples(forDevice:)`, its own
`PDC +N sp`, and remove. A bus with neither a parent nor an output device says
`nobody hears this`.

Four things the console does that are worth stating explicitly:

- **Effective mute/solo, not the flags.** A strip silenced because a sibling is
  soloed is drawn dimmed with a `speaker.slash` badge while its own `S` stays
  off. The truth comes from `AudioEngine.effectiveEnable`, the same
  `SoloLogic` result the render thread's atomics get — the view never
  re-derives it.
- **One timer.** A single 30 Hz `TimelineView` wraps the whole strip row and
  hands each strip a `MeterReading`; there is no per-strip timer, and a stopped
  engine schedules nothing at all. Each strip keeps its text fields, pickers
  and menus in child views that do not take the reading, so SwiftUI skips them
  between frames, and effective mute/solo is computed outside the timeline
  closure.
- **Refusals are shown.** Routing edits go through the `Result`-returning API
  and the failure is printed under the picker that caused it. A cycle names its
  path (`Routing loop: A → B → A.`) — `setBusDestination` only reports *that*
  an edit loops, so `cyclePath(ifBus:wereRoutedTo:)` builds a throw-away graph
  to name it. Removing the last bus or the Master bus is refused by the engine
  and the refusal is shown rather than hidden behind a disabled button.
- **Every binding is idempotent.** SwiftUI writes a binding back whenever it
  re-establishes one; an unguarded write would push an identical value through
  the engine, republish, and dirty the session. Every setter in a strip
  compares first.

Scope notes:

- Per-bus **effect editing** is still only Master's. `AudioEngine`'s chain API
  addresses a lane by id and the master bus by `nil`, and session restore only
  instantiates those two (§ Session format 2), so a non-master bus's chips are
  shown read-only with the `+` disabled and a tooltip that says why.
- The row-based mixer is kept beside the console as the **Rows** tab. It is
  unchanged and still runs against the Master bus only, via the thin shims
  `AudioEngine` keeps for it (`setOutputDevice`, `masterGainDB`,
  `masterEffects`, `masterMeter`); it has no way to add a bus, route a lane
  elsewhere, or solo. The console is the default; the choice is remembered in
  `UserDefaults` under `mainPane`, because it is a preference about the window
  rather than part of the mix.

The full `AudioEngine` API is still reachable headlessly too, through the
`--engine-test`/`--routing-selftest` flags documented in the README.
