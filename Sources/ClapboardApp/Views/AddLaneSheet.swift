import ClapboardCore
import SwiftUI

/// Picks what a new lane listens to: an input device and the channel(s) taken
/// from it, or another application's audio through a Core Audio process tap.
///
/// The device list deliberately excludes Bluetooth (unstable latency, and
/// input forces the HFP codec), aggregates (they cannot be nested) and
/// whatever is currently the output device (that would feed the mix back into
/// itself). The application list is the other way round: it shows what the HAL
/// says is playing right now, plus a "System audio" entry for everything at
/// once.
struct AddLaneSheet: View {
    let engine: AudioEngine
    let registry: AudioDeviceRegistry
    @Environment(\.dismiss) private var dismiss

    private enum Kind: Hashable { case device, application }

    @State private var kind: Kind = .device
    @State private var selectedUID: String?
    @State private var stereo = false
    @State private var monoChannel = 0
    @State private var stereoPair = 0

    /// A `TapSpec.sourceKey` — `"tap:system"` or `"tap:<bundle id>"`. Using
    /// the same key the model uses keeps "System audio" from having to be a
    /// nested optional in the list's selection.
    @State private var selectedTapKey: String = TapSpec(target: .systemAudio, name: "").sourceKey
    @State private var tapStereo = true

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

    /// Only processes macOS gives a bundle id for can be offered: a tap is
    /// rebuilt from its bundle id every time the engine starts, so a lane on a
    /// bare command-line process could never come back.
    private var tapCandidates: [TappableProcess] {
        engine.tappableProcesses.filter { $0.bundleID != nil }
    }

    private var canAdd: Bool {
        switch kind {
        case .device: return selected != nil
        case .application: return !selectedTapKey.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add lane")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Picker("Source", selection: $kind) {
                Text("Input device").tag(Kind.device)
                Text("Application audio").tag(Kind.application)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            switch kind {
            case .device:
                deviceList
                channelPicker
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            case .application:
                applicationList
                tapOptions
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }

            Divider()

            HStack {
                footnote
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding(16)
        }
        .frame(width: 520)
        .onAppear {
            selectedUID = candidates.first?.uid
            engine.refreshTappableProcesses()
        }
        .onChange(of: kind) {
            if kind == .application { engine.refreshTappableProcesses() }
        }
        .onChange(of: selectedUID) {
            monoChannel = 0
            stereoPair = 0
            stereo = (selected?.inputChannels ?? 1) >= 2
        }
    }

    // MARK: - Input devices

    private var deviceList: some View {
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

    // MARK: - Application audio

    private var applicationList: some View {
        List(selection: $selectedTapKey) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.3")
                    .foregroundStyle(.secondary)
                Text("System audio")
                Text("everything except Clapboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .tag(TapSpec(target: .systemAudio, name: "").sourceKey)

            ForEach(tapCandidates) { process in
                HStack(spacing: 8) {
                    Image(systemName: "app")
                        .foregroundStyle(.secondary)
                    Text(process.name)
                    Text(process.bundleID ?? "")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if process.isRunningOutput {
                        Text("playing")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(TapSpec(target: .app(bundleID: process.bundleID ?? ""), name: "").sourceKey)
            }
        }
        .frame(minHeight: 200)
    }

    private var tapOptions: some View {
        HStack(spacing: 12) {
            Picker("Channels", selection: $tapStereo) {
                Text("Mono").tag(false)
                Text("Stereo").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Button("Check access") { engine.refreshSystemAudioAuthorization() }
                .controlSize(.small)
            Spacer()
        }
    }

    // MARK: - Footnote

    @ViewBuilder
    private var footnote: some View {
        switch kind {
        case .device:
            if let selected, !selected.supports(sampleRate: 48_000) {
                Label(
                    "This device cannot run at 48 kHz; the engine will refuse to start.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        case .application:
            // Capturing another app needs its own permission, separate from
            // the Microphone one — see `docs/PERMISSIONS.md`. Say so here
            // rather than letting the lane come up silent.
            switch engine.systemAudioAuthorization {
            case .authorized:
                Label("System audio access granted.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .notDetermined:
                Text("Capturing another app asks for system-audio access the first time. "
                     + "Tapping an app never silences it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330, alignment: .leading)
            case .denied(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330, alignment: .leading)
            }
        }
    }

    // MARK: - Adding

    private func add() {
        switch kind {
        case .device:
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
        case .application:
            let spec: TapSpec
            if let process = tapCandidates.first(where: {
                TapSpec(target: .app(bundleID: $0.bundleID ?? ""), name: "").sourceKey == selectedTapKey
            }), let bundleID = process.bundleID {
                spec = TapSpec(target: .app(bundleID: bundleID), name: process.name, mono: !tapStereo)
            } else {
                spec = TapSpec(target: .systemAudio, name: "System audio", mono: !tapStereo)
            }
            engine.addTapLane(spec)
        }
        dismiss()
    }
}
