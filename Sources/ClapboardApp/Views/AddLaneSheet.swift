import ClapboardCore
import SwiftUI

/// Picks a device and the channel(s) a new lane takes from it.
///
/// The list deliberately excludes Bluetooth (unstable latency, and input
/// forces the HFP codec), aggregates (they cannot be nested) and whatever is
/// currently the output device (that would feed the mix back into itself).
struct AddLaneSheet: View {
    let engine: AudioEngine
    let registry: AudioDeviceRegistry
    @Environment(\.dismiss) private var dismiss

    @State private var selectedUID: String?
    @State private var stereo = false
    @State private var monoChannel = 0
    @State private var stereoPair = 0

    private var candidates: [AudioDeviceInfo] {
        registry.inputDevices.filter {
            !$0.transport.isBluetooth && $0.uid != engine.outputDeviceUID && $0.inputChannels > 0
        }
    }

    private var selected: AudioDeviceInfo? {
        candidates.first { $0.uid == selectedUID }
    }

    private var stereoPairs: [(Int, Int)] {
        guard let selected else { return [] }
        return stride(from: 0, to: selected.inputChannels - 1, by: 2).map { ($0, $0 + 1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add lane")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            List(candidates, selection: $selectedUID) { device in
                HStack(spacing: 8) {
                    Text(device.name)
                    Text(device.transport.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !device.supports(sampleRate: 48_000) {
                        Text("no 48 kHz")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("\(device.inputChannels) ch")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .tag(device.uid)
            }
            .frame(minHeight: 200)

            channelPicker
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            HStack {
                if let selected, !selected.supports(sampleRate: 48_000) {
                    Label(
                        "This device cannot run at 48 kHz; the engine will refuse to start.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
            .padding(16)
        }
        .frame(width: 520)
        .onAppear { selectedUID = candidates.first?.uid }
        .onChange(of: selectedUID) {
            monoChannel = 0
            stereoPair = 0
            stereo = (selected?.inputChannels ?? 1) >= 2
        }
    }

    @ViewBuilder
    private var channelPicker: some View {
        if let selected {
            HStack(spacing: 12) {
                Picker("Channels", selection: $stereo) {
                    Text("Mono").tag(false)
                    Text("Stereo pair").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .disabled(selected.inputChannels < 2)

                if stereo {
                    Picker("Pair", selection: $stereoPair) {
                        ForEach(Array(stereoPairs.enumerated()), id: \.offset) { index, pair in
                            Text("\(pair.0 + 1) / \(pair.1 + 1)").tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                } else {
                    Picker("Channel", selection: $monoChannel) {
                        ForEach(0..<selected.inputChannels, id: \.self) { channel in
                            Text("Channel \(channel + 1)").tag(channel)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                Spacer()
            }
        } else {
            Text("No usable input devices. Bluetooth devices and the current output device are excluded on purpose.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        guard let selected else { return }
        let channels: [Int]
        let suffix: String
        if stereo, stereoPair < stereoPairs.count {
            let pair = stereoPairs[stereoPair]
            channels = [pair.0, pair.1]
            suffix = " \(pair.0 + 1)/\(pair.1 + 1)"
        } else {
            channels = [min(monoChannel, selected.inputChannels - 1)]
            suffix = selected.inputChannels > 1 ? " \(channels[0] + 1)" : ""
        }
        engine.addLane(deviceUID: selected.uid, deviceChannels: channels, name: selected.name + suffix)
        dismiss()
    }
}
