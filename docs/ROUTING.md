# Routing model (design, v2)

Status: **design, not implemented**. This is the specification the bus-routing
work is built from. `docs/ARCHITECTURE.md` describes what exists today: lanes
summed into one master with one output device.

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

## Projects

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
strip's output picker lists them first and offers "Auto-assign a Clapboard
Bus" which picks the lowest unused one. Nothing in the routing model depends
on the driver.

## UI

Vertical strips in a horizontally scrolling console: lane strips on the left,
bus strips on the right, separated by a thin divider. Each strip, top to
bottom: name (editable), source / destination pickers, effect chips, delay
(lanes only, with PDC read-out), polarity (lanes only), meter beside a
vertical fader, `M` / `S` buttons. Bus strips add the output device picker and
an "output latency" read-out. The existing row-based mixer is kept behind a
view toggle until the console view has been used for a while.
