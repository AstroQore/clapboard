import ClapboardCore
import SwiftUI

/// The vertical channel strips the console is made of — `docs/ROUTING.md` § UI.
///
/// A lane strip and a bus strip are deliberately the same shape (name, effect
/// chips, fader beside a meter, `M`/`S`), because that sameness is what makes a
/// mixer feel like a console; what differs is only what each one is *routed to*
/// and the read-outs that go with it.
///
/// **Nothing in these bodies polls.** The meter reading arrives as a plain
/// value from the single `TimelineView` `ConsoleView` owns, and every control
/// that costs anything to build — text fields, pickers, menus — lives in a
/// child view whose inputs do not change between frames, so SwiftUI skips it 29
/// times out of 30. See `ConsoleView.strips`.

// MARK: - Shared geometry

enum ConsoleMetrics {
    /// Narrow enough to get eight strips on a laptop screen, wide enough for
    /// "Channel 1/2" in a menu button.
    static let stripWidth: CGFloat = 120
    static let stripSpacing: CGFloat = 8
    /// Fader travel for a strip area `height` points tall.
    ///
    /// One number for every strip in the console, not one per strip: the
    /// control blocks above the faders are not the same height (a lane has a
    /// delay field, a bus has an output picker), so a fader that simply filled
    /// its own card would sit at a different height on every strip, and a
    /// console whose faders do not line up cannot be read at a glance. The
    /// slack goes into a spacer *above* each fader instead, which leaves the
    /// fader, its read-outs and the `M`/`S` row flush with the bottom of every
    /// card. The window still gets the benefit of its height — the whole row
    /// grows together.
    static func faderHeight(forStripArea height: CGFloat) -> CGFloat {
        min(max(height - 250, 140), 420)
    }
    static let faderRange: ClosedRange<Float> = -60...12
}

// MARK: - Strip shell

/// The card every strip is drawn on: fixed width, rounded, tinted by whether
/// the strip is a problem, and dimmed when the mix is not actually hearing it.
private struct StripShell<Content: View>: View {
    /// False when solo elsewhere in this strip's scope is silencing it, or when
    /// it is muted. Drawn, not inferred: the truth comes from
    /// `AudioEngine.effectiveEnable`.
    var audible: Bool
    var isProblem: Bool = false
    var accent: Color = .clear
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 8)
        .frame(width: ConsoleMetrics.stripWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isProblem ? Color.orange.opacity(0.7) : accent.opacity(0.5))
        }
        .opacity(audible ? 1 : 0.55)
    }
}

/// The name field at the top of a strip.
///
/// The setter is guarded: SwiftUI writes a binding back whenever it
/// re-establishes one, and an unguarded write would push an identical value
/// through `AudioEngine` — which republishes, which marks the session dirty,
/// which autosaves. Every binding in a console strip is idempotent for that
/// reason.
private struct StripNameField: View {
    var name: String
    var prompt: String
    var set: (String) -> Void

    var body: some View {
        TextField(prompt, text: Binding(
            get: { name },
            set: { if $0 != name { set($0) } }
        ))
            .textFieldStyle(.plain)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A one-line label under a heading, e.g. `to  Vocals`.
private struct StripCaption: View {
    var text: String
    var systemImage: String?
    var tint: HierarchicalShapeStyle = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 8))
            }
            Text(text)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Fader

/// A console fader: drag it, double-click to snap back to unity, arrow keys
/// through VoiceOver.
///
/// Hand-drawn rather than a rotated `Slider`, because a rotated slider keeps
/// the hit rectangle it had before the rotation and ends up catching drags two
/// strips away.
struct VerticalFader: View {
    var db: Float
    var range: ClosedRange<Float> = ConsoleMetrics.faderRange
    var onChange: (Float) -> Void

    private static let knobHeight: CGFloat = 14
    private static let knobWidth: CGFloat = 28
    private static let trackWidth: CGFloat = 6

    private var fraction: CGFloat {
        CGFloat((min(max(db, range.lowerBound), range.upperBound) - range.lowerBound)
                / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let travel = max(0, height - Self.knobHeight)
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: Self.trackWidth)
                Capsule()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: Self.trackWidth, height: fraction * travel + Self.knobHeight / 2)
                knob
                    .offset(y: -fraction * travel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard travel > 0 else { return }
                        let y = min(max(0, value.location.y - Self.knobHeight / 2), travel)
                        set(fraction: 1 - y / travel)
                    }
            )
            .onTapGesture(count: 2) { onChange(0) }
        }
        .frame(width: Self.knobWidth)
        .accessibilityElement()
        .accessibilityLabel("Gain")
        .accessibilityValue(db <= range.lowerBound ? "minus infinity" : String(format: "%+.1f decibels", db))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(range.upperBound, db + 1))
            case .decrement: onChange(max(range.lowerBound, db - 1))
            @unknown default: break
            }
        }
    }

    private var knob: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.background)
            .frame(width: Self.knobWidth, height: Self.knobHeight)
            .overlay {
                RoundedRectangle(cornerRadius: 3).strokeBorder(.tertiary)
            }
            .overlay {
                Rectangle().fill(.secondary).frame(height: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
    }

    private func set(fraction: CGFloat) {
        let clamped = min(max(0, fraction), 1)
        onChange(Float(clamped) * (range.upperBound - range.lowerBound) + range.lowerBound)
    }
}

/// Fader, meter and the two numbers that go with them.
private struct FaderColumn: View {
    var gainDB: Float
    var reading: MeterReading
    var isLive: Bool
    var height: CGFloat
    var onGain: (Float) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                VerticalFader(db: gainDB, onChange: onGain)
                VerticalMeterBar(reading: isLive ? reading : .silent)
            }
            .frame(height: height)

            HStack(spacing: 4) {
                Text(gainDB <= ConsoleMetrics.faderRange.lowerBound
                     ? "−∞" : String(format: "%+.1f", gainDB))
                    .font(.caption2.monospacedDigit())
                    .help("Fader — drag, or double-click for 0 dB")
                Spacer(minLength: 0)
                Text(isLive && reading.peak > 0 ? String(format: "%+.1f", reading.peakDB) : "−∞")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(reading.peak >= 0.99 && isLive
                                     ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .help("Peak")
            }
        }
    }
}

// MARK: - Mute / solo

/// `M` and `S`, plus whatever extra square a strip wants beside them.
private struct MuteSoloRow<Extra: View>: View {
    var muted: Bool
    var solo: Bool
    /// True when nothing is silencing this strip. `M` off while this is false
    /// is exactly the case the console has to make visible: a solo somewhere
    /// else on the same bus.
    var audible: Bool
    var scopeDescription: String
    var setMuted: (Bool) -> Void
    var setSolo: (Bool) -> Void
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(spacing: 4) {
            square("M", on: muted, tint: .red) { setMuted(!muted) }
                .help(muted ? "Muted — click to unmute" : "Mute")
            square("S", on: solo, tint: .yellow) { setSolo(!solo) }
                .help("Solo \(scopeDescription)")
            extra
            Spacer(minLength: 0)
            if !audible && !muted {
                Image(systemName: "speaker.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Silenced by a solo \(scopeDescription)")
            }
        }
    }

    private func square(_ title: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 15)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(on ? tint : .secondary)
    }
}

// MARK: - Lane strip

struct LaneStripView: View {
    let engine: AudioEngine
    let registry: AudioDeviceRegistry
    let lane: LaneConfig
    /// From `AudioEngine.effectiveEnable` — see `MuteSoloRow.audible`.
    let audible: Bool
    let meter: MeterReading
    let isLive: Bool
    let faderHeight: CGFloat

    private var status: AudioEngine.LaneStatus {
        engine.laneStatus[lane.id] ?? .idle
    }

    var body: some View {
        StripShell(audible: audible, isProblem: status.isProblem) {
            // Split deliberately: only `FaderColumn` sees the meter, so it is
            // the only part of the strip SwiftUI rebuilds at 30 Hz.
            LaneStripControls(engine: engine, registry: registry, lane: lane, status: status)
            Spacer(minLength: 0)
            FaderColumn(gainDB: lane.gainDB, reading: meter, isLive: isLive, height: faderHeight) {
                engine.setLaneGainDB(lane.id, $0)
            }
            LaneStripButtons(engine: engine, lane: lane, audible: audible)
        }
    }
}

/// Everything above the fader: name, source, destination bus, chips, delay.
private struct LaneStripControls: View {
    let engine: AudioEngine
    let registry: AudioDeviceRegistry
    let lane: LaneConfig
    let status: AudioEngine.LaneStatus

    private var deviceName: String {
        registry.device(uid: lane.deviceUID)?.name ?? lane.deviceUID
    }

    /// The same exclusions `AddLaneSheet` applies: Bluetooth is unstable and
    /// forces the HFP codec, an aggregate cannot be nested, and a device that
    /// is currently an output would feed the mix back into itself.
    private var sourceCandidates: [AudioDeviceInfo] {
        let outputs = Set(engine.buses.compactMap(\.outputDeviceUID))
        return registry.inputDevices.filter {
            !$0.transport.isBluetooth && !outputs.contains($0.uid) && $0.inputChannels > 0
        }
    }

    var body: some View {
        StripNameField(name: lane.name, prompt: "Lane") { engine.setLaneName(lane.id, $0) }

        sourceMenu

        if status.isProblem {
            StripCaption(
                text: status == .deviceMissing ? "device missing" : "channel range",
                systemImage: "exclamationmark.triangle.fill",
                tint: .primary
            )
            .foregroundStyle(.orange)
        } else {
            StripCaption(text: lane.channelLabel, systemImage: "waveform", tint: .tertiary)
        }

        destinationPicker

        Divider()

        EffectChainView(engine: engine, subject: .lane(lane.id), axis: .vertical)

        delayControls
    }

    private var sourceMenu: some View {
        Menu {
            if sourceCandidates.isEmpty {
                Text("No usable input devices")
            }
            ForEach(sourceCandidates) { device in
                Menu(device.name) {
                    ForEach(Array(0..<max(1, device.inputChannels)), id: \.self) { channel in
                        Button("Channel \(channel + 1)") {
                            engine.setLaneSource(lane.id, deviceUID: device.uid, deviceChannels: [channel])
                        }
                    }
                    if device.inputChannels >= 2 {
                        Divider()
                        ForEach(Array(stride(from: 0, to: device.inputChannels - 1, by: 2)), id: \.self) { first in
                            Button("Stereo \(first + 1)/\(first + 2)") {
                                engine.setLaneSource(
                                    lane.id, deviceUID: device.uid, deviceChannels: [first, first + 1])
                            }
                        }
                    }
                }
            }
        } label: {
            Text(deviceName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("\(deviceName) · \(lane.channelLabel) — click to re-pick the source device and channels")
    }

    private var destinationPicker: some View {
        Picker("", selection: Binding(
            get: { lane.destinationBus ?? engine.buses.first?.id ?? UUID() },
            set: { if $0 != lane.destinationBus { engine.setLaneDestination(lane.id, bus: $0) } }
        )) {
            ForEach(engine.consoleBusOrder) { bus in
                Text("→ \(bus.name)").tag(bus.id)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .help("The bus this lane sums into. Solo on this lane is scoped to it.")
    }

    /// Delay is edited in ms but stored as whole samples at 48 kHz, which is
    /// what Auto Sync's clap measurement writes.
    private var delayControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                TextField("0", value: Binding(
                    get: { lane.delayMilliseconds() },
                    set: {
                        let samples = LaneConfig.samples(forMilliseconds: $0)
                        if samples != lane.delaySamples {
                            engine.setLaneDelaySamples(lane.id, samples)
                        }
                    }
                ), format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.trailing)
                Text("ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Stepper("") {
                    engine.setLaneDelaySamples(
                        lane.id, LaneConfig.samples(forMilliseconds: lane.delayMilliseconds() + 0.1))
                } onDecrement: {
                    engine.setLaneDelaySamples(
                        lane.id, LaneConfig.samples(forMilliseconds: lane.delayMilliseconds() - 0.1))
                }
                .labelsHidden()
                .controlSize(.mini)
                .help("± 0.1 ms — about 5 samples at 48 kHz")
            }
            HStack(spacing: 4) {
                Text("\(lane.delaySamples) sp")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(delayIsStale ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    .help(delayIsStale
                          ? "The aggregate device was rebuilt after this delay was measured — run Auto Sync again"
                          : "Delay in whole samples at 48 kHz")
                Spacer(minLength: 0)
                pdcReadout
            }
        }
    }

    /// A rebuilt aggregate moves the drift resampler's unreported latency, so a
    /// delay measured before it is no longer trustworthy.
    private var delayIsStale: Bool {
        engine.delaysMayBeStale && lane.delaySamples > 0
    }

    @ViewBuilder
    private var pdcReadout: some View {
        let compensation = engine.pdcSamples[lane.id] ?? 0
        let chain = engine.laneChainLatency(lane.id)
        if compensation > 0 || chain > 0 {
            Text("PDC +\(compensation) sp")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(compensation > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .help("This lane's plug-ins add \(chain) samples of latency; \(compensation) samples "
                      + "of delay are added on top so it stays aligned with the other lanes on this bus.")
        }
    }
}

/// `M`, `S`, polarity, remove.
private struct LaneStripButtons: View {
    let engine: AudioEngine
    let lane: LaneConfig
    let audible: Bool

    var body: some View {
        MuteSoloRow(
            muted: lane.muted,
            solo: lane.solo,
            audible: audible,
            scopeDescription: "on this lane's bus",
            setMuted: { engine.setLaneMuted(lane.id, $0) },
            setSolo: { engine.setLaneSolo(lane.id, $0) }
        ) {
            Button {
                engine.setLanePolarity(lane.id, inverted: !lane.polarityInverted)
            } label: {
                Text("Ø")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 15)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(lane.polarityInverted ? .accentColor : .secondary)
            .help("Invert polarity")

            Button(role: .destructive) {
                engine.removeLane(id: lane.id)
            } label: {
                Image(systemName: "trash").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Remove lane")
        }
    }
}

// MARK: - Bus strip

struct BusStripView: View {
    let engine: AudioEngine
    let registry: AudioDeviceRegistry
    let bus: BusConfig
    let audible: Bool
    let meter: MeterReading
    let isLive: Bool
    let faderHeight: CGFloat

    var body: some View {
        StripShell(
            audible: audible,
            isProblem: bus.isDangling,
            accent: engine.isMasterBus(bus.id) ? .accentColor : .clear
        ) {
            BusStripControls(engine: engine, registry: registry, bus: bus)
            Spacer(minLength: 0)
            FaderColumn(gainDB: bus.gainDB, reading: meter, isLive: isLive, height: faderHeight) {
                engine.setBusGainDB(bus.id, $0)
            }
            BusStripButtons(engine: engine, bus: bus, audible: audible)
        }
    }
}

private struct BusStripControls: View {
    let engine: AudioEngine
    let registry: AudioDeviceRegistry
    let bus: BusConfig

    /// The last routing edit this strip refused, spelled out. Kept per strip so
    /// the message sits under the picker that produced it.
    @State private var refusal: String?

    private var isMaster: Bool { engine.isMasterBus(bus.id) }

    private var outputDevices: [AudioDeviceInfo] {
        AudioEngine.busOutputDeviceOrder(registry.outputDevices)
    }

    private var outputDevice: AudioDeviceInfo? {
        bus.outputDeviceUID.flatMap { registry.device(uid: $0) }
    }

    var body: some View {
        StripNameField(name: bus.name, prompt: "Bus") { engine.renameBus(bus.id, $0) }

        StripCaption(text: isMaster ? "bus · master" : "bus", systemImage: "rectangle.3.group")
            .foregroundStyle(isMaster ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))

        parentPicker
        outputPicker

        if let device = outputDevice, device.outputChannels > 2 {
            channelOffsetStepper(device)
        }

        if let refusal {
            Text(refusal)
                .font(.caption2)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }

        if bus.isDangling {
            StripCaption(text: "nobody hears this", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("This bus has no parent bus and no output device, so it is a group nobody "
                      + "is listening to. Give it a parent or an output device.")
        }

        Divider()

        EffectChainView(
            engine: engine,
            subject: isMaster ? .master : .bus(bus.id),
            axis: .vertical
        )

        latencyReadouts
    }

    private var parentPicker: some View {
        Picker("", selection: Binding<UUID?>(
            get: { bus.destinationBus },
            set: { route(to: $0) }
        )) {
            Text("→ none").tag(UUID?.none)
            ForEach(candidateParents) { candidate in
                Text("→ \(candidate.name)").tag(UUID?.some(candidate.id))
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .help("The bus this one feeds. Buses that would close a routing loop are not offered; "
              + "\"none\" makes this a root bus, heard only through its output device.")
    }

    /// Every other bus that would not close a loop — the engine refuses those
    /// outright, so the picker never offers them in the first place.
    private var candidateParents: [BusConfig] {
        engine.consoleBusOrder.filter {
            $0.id != bus.id && engine.cyclePath(ifBus: bus.id, wereRoutedTo: $0.id) == nil
        }
    }

    private var outputPicker: some View {
        Picker("", selection: Binding(
            get: { bus.outputDeviceUID ?? "" },
            set: { uid in
                let wanted: String? = uid.isEmpty ? nil : uid
                guard wanted != bus.outputDeviceUID else { return }
                engine.setBusOutput(id: bus.id, deviceUID: wanted,
                                    channelOffset: wanted == nil ? 0 : bus.outputChannelOffset)
            }
        )) {
            Text("no output").tag("")
            ForEach(outputDevices) { device in
                Text(device.name).tag(device.uid)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .help("Output device this bus writes to. Clapboard's own virtual devices are listed first. "
              + "A lane already using the device is dropped — a device cannot be both.")
    }

    private func channelOffsetStepper(_ device: AudioDeviceInfo) -> some View {
        Stepper(value: Binding(
            get: { bus.outputChannelOffset },
            set: {
                guard $0 != bus.outputChannelOffset else { return }
                engine.setBusOutput(id: bus.id, deviceUID: bus.outputDeviceUID, channelOffset: $0)
            }
        ), in: 0...max(0, device.outputChannels - 2)) {
            Text("ch \(bus.outputChannelOffset + 1)/\(bus.outputChannelOffset + 2)")
                .font(.caption2.monospacedDigit())
        }
        .controlSize(.mini)
        .help("First channel of the stereo pair this bus writes into on \(device.name)")
    }

    @ViewBuilder
    private var latencyReadouts: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let uid = bus.outputDeviceUID {
                let samples = engine.outputLatencySamples(forDevice: uid)
                StripCaption(
                    text: String(format: "out %.1f ms", Double(samples) / 48_000 * 1000),
                    systemImage: "clock.arrow.circlepath",
                    tint: .secondary
                )
                .help("\(samples) samples end to end at this output: every lane and bus that reaches "
                      + "it, aligned. Root buses are not compensated against each other, so this is "
                      + "reported rather than removed.")
            }
            let compensation = engine.latencyPlan.busCompensation[bus.id] ?? 0
            let chain = engine.busChainLatency(bus.id)
            if compensation > 0 || chain > 0 {
                StripCaption(text: "PDC +\(compensation) sp", tint: .secondary)
                    .help("This bus's own chain adds \(chain) samples; \(compensation) samples of "
                          + "delay are added before it so it stays aligned with its sibling buses.")
            }
        }
    }

    private func route(to parent: UUID?) {
        guard parent != bus.destinationBus else { return }
        switch engine.setBusDestination(id: bus.id, parent: parent) {
        case .success:
            refusal = nil
        case .failure(let error):
            // `.wouldCreateCycle` only says *that* it loops; the path comes
            // from building a candidate graph. `docs/ROUTING.md`: "the error
            // names the path".
            if let path = engine.cyclePath(ifBus: bus.id, wereRoutedTo: parent) {
                refusal = "Routing loop: \(path.joined(separator: " → "))."
            } else {
                refusal = error.localizedDescription
            }
        }
    }
}

private struct BusStripButtons: View {
    let engine: AudioEngine
    let bus: BusConfig
    let audible: Bool

    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            MuteSoloRow(
                muted: bus.muted,
                solo: bus.solo,
                audible: audible,
                scopeDescription: "among this bus's siblings",
                setMuted: { engine.setBusMuted(bus.id, $0) },
                setSolo: { engine.setBusSolo(bus.id, $0) }
            ) {
                Button(role: .destructive) {
                    remove()
                } label: {
                    Image(systemName: "trash").font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help("Remove bus — its lanes and child buses move to the bus it feeds")
            }
            if let refusal {
                Text(refusal)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// The engine refuses the last bus and the Master bus. That refusal is
    /// shown, not hidden behind a disabled button: "why can't I delete this?"
    /// deserves an answer.
    private func remove() {
        switch engine.removeBus(id: bus.id) {
        case .success: refusal = nil
        case .failure(let error): refusal = error.localizedDescription
        }
    }
}
