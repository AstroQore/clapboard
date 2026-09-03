import ClapboardCore
import SwiftUI

/// One mixer lane: name, source, on/off, gain, delay, polarity, meter.
struct LaneRowView: View {
    let engine: AudioEngine
    let registry: AudioDeviceRegistry
    let lane: LaneConfig

    private var status: AudioEngine.LaneStatus {
        engine.laneStatus[lane.id] ?? .idle
    }

    /// A rebuilt aggregate moves the drift resampler's unreported latency, so
    /// a delay measured before it is no longer trustworthy.
    private var delayIsStale: Bool {
        engine.delaysMayBeStale && lane.delaySamples > 0
    }

    private var deviceName: String {
        registry.device(uid: lane.deviceUID)?.name ?? lane.deviceUID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            controls
            EffectChainView(engine: engine, laneID: lane.id)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(status.isProblem ? Color.orange.opacity(0.7) : Color.clear)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { lane.enabled },
                set: { engine.setLaneEnabled(lane.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Mute / unmute this lane")

            TextField("Lane", text: Binding(
                get: { lane.name },
                set: { engine.setLaneName(lane.id, $0) }
            ))
            .textFieldStyle(.plain)
            .font(.headline)
            .frame(minWidth: 90, maxWidth: 180)

            Text("\(deviceName) · \(lane.channelLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if status.isProblem {
                Label(
                    status == .deviceMissing ? "device missing" : "channel out of range",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Spacer()

            Button {
                engine.setLanePolarity(lane.id, inverted: !lane.polarityInverted)
            } label: {
                Text("Ø")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 20)
            }
            .buttonStyle(.bordered)
            .tint(lane.polarityInverted ? .accentColor : .secondary)
            .help("Invert polarity")

            Button(role: .destructive) {
                engine.removeLane(id: lane.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove lane")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(lane.gainDB) },
                        set: { engine.setLaneGainDB(lane.id, Float($0)) }
                    ),
                    in: -60...12
                )
                .frame(minWidth: 120)
                Text(lane.gainDB <= -60 ? "−∞" : String(format: "%+.1f", lane.gainDB))
                    .font(.caption.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
                Text("dB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 16)

            delayField

            Divider().frame(height: 16)

            LiveMeter(isLive: engine.runState.isRunning) { engine.meter(laneID: lane.id) }
                .frame(minWidth: 90)
            MeterReadout(isLive: engine.runState.isRunning) { engine.meter(laneID: lane.id) }
        }
    }

    /// Delay is edited in ms but stored as whole samples at 48 kHz, which is
    /// what M3's clap measurement writes.
    private var delayField: some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("0", value: Binding(
                get: { lane.delayMilliseconds() },
                set: { engine.setLaneDelaySamples(lane.id, LaneConfig.samples(forMilliseconds: $0)) }
            ), format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 62)
            .multilineTextAlignment(.trailing)
            Text("ms")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper("") {
                engine.setLaneDelaySamples(lane.id, LaneConfig.samples(forMilliseconds: lane.delayMilliseconds() + 0.1))
            } onDecrement: {
                engine.setLaneDelaySamples(lane.id, LaneConfig.samples(forMilliseconds: lane.delayMilliseconds() - 0.1))
            }
            .labelsHidden()
            .help("± 0.1 ms — about 5 samples at 48 kHz")
            Text("\(lane.delaySamples) sp")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(delayIsStale ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                .frame(width: 52, alignment: .leading)
                .help(delayIsStale
                      ? "The aggregate device was rebuilt after this delay was measured — run Auto Sync again"
                      : "Delay in whole samples at 48 kHz. Plug-in delay compensation is "
                        + "added on top; the chain row shows how much.")
        }
    }
}
