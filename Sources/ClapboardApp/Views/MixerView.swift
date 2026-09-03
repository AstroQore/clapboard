import ClapboardCore
import SwiftUI

/// The mixer: lanes on top, master at the bottom, transport in the toolbar.
struct MixerView: View {
    let engine: AudioEngine
    let registry: AudioDeviceRegistry
    let permission: MicrophonePermission

    @State private var showingAddLane = false
    @State private var showingAutoSync = false

    /// Auto Sync measures lanes against each other and records what the IOProc
    /// is already receiving, so it needs a running engine and two lanes.
    private var canAutoSync: Bool {
        engine.runState.isRunning && engine.lanes.count >= 2
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            laneList
            Divider()
            master
        }
        .sheet(isPresented: $showingAddLane) {
            AddLaneSheet(engine: engine, registry: registry)
        }
        .sheet(isPresented: $showingAutoSync) {
            AutoSyncSheet(engine: engine, registry: registry)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    engine.runState.isRunning ? engine.stop() : engine.start()
                } label: {
                    Label(
                        engine.runState.isRunning ? "Stop" : "Run",
                        systemImage: engine.runState.isRunning ? "stop.fill" : "play.fill"
                    )
                }
                .disabled(engine.runState.isBusy || engine.outputDeviceUID == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAutoSync = true
                } label: {
                    Label("Auto Sync", systemImage: "hands.clap")
                }
                .disabled(!canAutoSync)
                .help(canAutoSync
                      ? "Clap once; Clapboard measures each lane's arrival and writes the compensating delay"
                      : "Run the engine with at least two lanes first")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    engine.rebuild(reason: "manual rebuild")
                } label: {
                    Label("Rebuild", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!engine.runState.isRunning)
                .help("Tear down and recreate the aggregate device and IOProc")
            }
        }
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(engine.runState.label)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            if engine.runState.isRunning {
                Label(
                    engine.callbackHealthy ? "callbacks OK" : "no callbacks",
                    systemImage: engine.callbackHealthy ? "waveform" : "waveform.slash"
                )
                .font(.caption)
                .foregroundStyle(engine.callbackHealthy ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))

                Text("overloads \(engine.overloadCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(engine.overloadCount > 0 ? .orange : .secondary)

                Text("48 kHz · \(engine.bufferFrameSize) frames")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if engine.restartCount > 0 {
                    Text("rebuilds \(engine.restartCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if permission.status != .authorized {
                Label(permission.label, systemImage: "mic.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// Largest delay any lane is carrying, in ms — the span Auto Sync closed.
    private var spreadMilliseconds: Double {
        Double(engine.lanes.map(\.delaySamples).max() ?? 0) / engine.sampleRate * 1000
    }

    private var statusColor: Color {
        switch engine.runState {
        case .running: return engine.callbackHealthy ? .green : .orange
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    // MARK: - Lanes

    private var laneList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(engine.lanes) { lane in
                    LaneRowView(engine: engine, registry: registry, lane: lane)
                }
                if engine.lanes.isEmpty {
                    ContentUnavailableView {
                        Label("No lanes", systemImage: "slider.horizontal.3")
                    } description: {
                        Text("Add one lane per microphone. A stereo receiver with two transmitters wants two mono lanes.")
                    } actions: {
                        Button("Add Lane") { showingAddLane = true }
                    }
                    .padding(.top, 30)
                }
            }
            .padding(12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    showingAddLane = true
                } label: {
                    Label("Add Lane", systemImage: "plus")
                }
                .disabled(engine.outputDeviceUID == nil)
                Text("Adding or removing a lane on a device the aggregate already has is a snapshot swap; a new device rebuilds it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    // MARK: - Master

    private var master: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Master")
                    .font(.headline)

                Picker("Output", selection: Binding(
                    get: { engine.outputDeviceUID ?? "" },
                    set: { engine.setOutputDevice(uid: $0.isEmpty ? nil : $0) }
                )) {
                    Text("Choose output…").tag("")
                    ForEach(registry.outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .frame(width: 220)

                Slider(
                    value: Binding(
                        get: { Double(engine.masterGainDB) },
                        set: { engine.masterGainDB = Float($0) }
                    ),
                    in: -60...12
                )
                .frame(minWidth: 120)
                Text(engine.masterGainDB <= -60 ? "−∞" : String(format: "%+.1f dB", engine.masterGainDB))
                    .font(.caption.monospacedDigit())
                    .frame(width: 66, alignment: .trailing)

                LiveMeter(isLive: engine.runState.isRunning, read: { engine.masterMeter }, height: 12)
                    .frame(minWidth: 120)
                MeterReadout(isLive: engine.runState.isRunning) { engine.masterMeter }
            }

            EffectChainView(engine: engine, laneID: nil)

            HStack(spacing: 10) {
                Label(
                    String(format: "sync spread %.1f ms", spreadMilliseconds),
                    systemImage: "arrow.left.and.right"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Largest lane delay currently written into the mix")

                Label(
                    String(format: "output latency %.1f ms", engine.outputLatencyMilliseconds),
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(engine.outputLatencySamples > 0
                                 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .help("\(engine.outputLatencySamples) samples: the slowest lane's plug-in chain, "
                      + "which every other lane is delayed to match, plus the master chain — "
                      + "common to all lanes, so it is reported rather than compensated.")

                if engine.delaysMayBeStale {
                    // Drift compensation puts a resampler in front of every
                    // input sub-device; its latency is unreported and moves
                    // when the aggregate is rebuilt, so measured delays have to
                    // be re-taken.
                    Button {
                        showingAutoSync = true
                    } label: {
                        Label("Delays may be stale — re-measure", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                    .disabled(!canAutoSync)

                    Button("Dismiss") { engine.acknowledgeStaleDelays() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                Spacer()
            }

            if let warning = engine.pdcWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = engine.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let summary = engine.aggregateSummary {
                Text(summary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
