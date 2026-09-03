import ClapboardCore
import SwiftUI

/// The one-line engine read-out both mixer views sit under: run state, callback
/// health, overloads, clock, rebuild count and the microphone permission.
///
/// Shared so the console and the row-based mixer can never disagree about
/// whether the engine is running.
struct EngineStatusBar: View {
    let engine: AudioEngine
    let permission: MicrophonePermission

    var body: some View {
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

    private var statusColor: Color {
        switch engine.runState {
        case .running: return engine.callbackHealthy ? .green : .orange
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}

/// Run / Auto Sync / Rebuild — the three transport buttons every mixer view
/// puts in the window toolbar. Only the visible tab's toolbar is installed, so
/// both views can declare it.
struct EngineToolbarButtons: ToolbarContent {
    let engine: AudioEngine
    @Binding var showingAutoSync: Bool

    /// Auto Sync measures lanes against each other and records what the IOProc
    /// is already receiving, so it needs a running engine and two lanes.
    private var canAutoSync: Bool {
        engine.runState.isRunning && engine.lanes.count >= 2
    }

    var body: some ToolbarContent {
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
