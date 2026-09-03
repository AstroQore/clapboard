import ClapboardCore
import SwiftUI

/// The console: vertical channel strips in a horizontally scrolling row, lane
/// strips on the left, bus strips on the right, a divider between them.
/// `docs/ROUTING.md` § UI.
///
/// This is the view that makes the bus model reachable. The row-based
/// `MixerView` drives only the Master bus through the engine's compatibility
/// shims; everything else the engine can do — routing a lane to any bus,
/// stacking buses, sending a bus to its own output device, scoped solo,
/// plug-in delay compensation across the tree — has a control here.
///
/// ## Why there is exactly one timer
///
/// Meters are read from the render thread's atomics, and reading them is
/// free — but *scheduling* is not, and a `TimelineView` per strip would put a
/// dozen 30 Hz run-loop sources in a window that has one thing to animate. So
/// there is a single `TimelineView` around the whole strip row; it reads every
/// meter once per frame and hands each strip a plain `MeterReading`. Each strip
/// then keeps its expensive controls (text fields, pickers, menus) in child
/// views that do not take the reading, so SwiftUI compares their unchanged
/// inputs and skips them. Everything that can be computed per change —
/// effective mute/solo above all — is computed outside the timeline closure.
struct ConsoleView: View {
    let engine: AudioEngine
    let registry: AudioDeviceRegistry
    let permission: MicrophonePermission

    @State private var showingAddLane = false
    @State private var showingAutoSync = false

    var body: some View {
        VStack(spacing: 0) {
            EngineStatusBar(engine: engine, permission: permission)
            Divider()
            // The strip area's height is read once here and handed to every
            // strip, so all the faders are the same length and line up.
            GeometryReader { geometry in
                strips(faderHeight: ConsoleMetrics.faderHeight(forStripArea: geometry.size.height))
            }
            Divider()
            footer
        }
        .sheet(isPresented: $showingAddLane) {
            AddLaneSheet(engine: engine, registry: registry)
        }
        .sheet(isPresented: $showingAutoSync) {
            AutoSyncSheet(engine: engine, registry: registry)
        }
        .toolbar {
            EngineToolbarButtons(engine: engine, showingAutoSync: $showingAutoSync)
        }
    }

    // MARK: - Strips

    @ViewBuilder
    private func strips(faderHeight: CGFloat) -> some View {
        // Computed here, outside the timeline closure: solo scope changes when
        // a route or a switch changes, never at 30 Hz.
        let effective = engine.effectiveEnable
        if engine.runState.isRunning {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                scroller(isLive: true, effective: effective, faderHeight: faderHeight)
            }
        } else {
            // A stopped engine has nothing to meter, so it gets no timer at all.
            scroller(isLive: false, effective: effective, faderHeight: faderHeight)
        }
    }

    private func scroller(
        isLive: Bool,
        effective: (lanes: [UUID: Bool], buses: [UUID: Bool]),
        faderHeight: CGFloat
    ) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: ConsoleMetrics.stripSpacing) {
                if engine.lanes.isEmpty {
                    noLanesColumn
                }
                ForEach(engine.lanes) { lane in
                    LaneStripView(
                        engine: engine,
                        registry: registry,
                        lane: lane,
                        audible: effective.lanes[lane.id] ?? lane.enabled,
                        meter: isLive ? engine.meter(laneID: lane.id) : .silent,
                        isLive: isLive,
                        faderHeight: faderHeight
                    )
                }
                addLaneColumn

                sectionDivider

                ForEach(engine.consoleBusOrder) { bus in
                    BusStripView(
                        engine: engine,
                        registry: registry,
                        bus: bus,
                        audible: effective.buses[bus.id] ?? !bus.muted,
                        meter: isLive ? engine.busMeter(id: bus.id) : .silent,
                        isLive: isLive,
                        faderHeight: faderHeight
                    )
                }
                addBusColumn
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Lanes left, buses right. Thin on purpose — it separates two kinds of
    /// strip, it is not a section header.
    private var sectionDivider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 5)
    }

    private var noLanesColumn: some View {
        placeholderColumn(
            title: "No lanes",
            systemImage: "mic",
            detail: "Add one lane per microphone. A stereo receiver with two "
                + "transmitters wants two mono lanes."
        )
    }

    private var addLaneColumn: some View {
        VStack(spacing: 6) {
            Button {
                showingAddLane = true
            } label: {
                Label("Add Lane", systemImage: "plus")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(engine.outputDeviceUID == nil)
            .help(engine.outputDeviceUID == nil
                  ? "Give the Master bus an output device first"
                  : "Adding a lane on a device the aggregate already has is a snapshot swap; "
                    + "a new device rebuilds it.")
            Spacer(minLength: 0)
        }
        .frame(width: ConsoleMetrics.stripWidth)
    }

    private var addBusColumn: some View {
        VStack(spacing: 6) {
            Button {
                engine.addBus(name: nextBusName())
            } label: {
                Label("Add Bus", systemImage: "plus")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help("A new bus starts with no parent and no output device — route it with the "
                  + "two pickers on its strip.")
            if engine.buses.count == 1 {
                Text("One bus, `Master`. Add another to group lanes, then point it at Master or "
                     + "at its own output device.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(width: ConsoleMetrics.stripWidth)
    }

    /// `Bus 2`, `Bus 3`, … — the lowest number not already taken.
    private func nextBusName() -> String {
        let taken = Set(engine.buses.map(\.name))
        var index = engine.buses.count + 1
        while taken.contains("Bus \(index)") { index += 1 }
        return "Bus \(index)"
    }

    private func placeholderColumn(title: String, systemImage: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: ConsoleMetrics.stripWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.quaternary)
        }
    }

    // MARK: - Footer

    /// Largest delay any lane is carrying, in ms — the span Auto Sync closed.
    private var spreadMilliseconds: Double {
        Double(engine.lanes.map(\.delaySamples).max() ?? 0) / engine.sampleRate * 1000
    }

    private var canAutoSync: Bool {
        engine.runState.isRunning && engine.lanes.count >= 2
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label(
                    String(format: "sync spread %.1f ms", spreadMilliseconds),
                    systemImage: "arrow.left.and.right"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Largest lane delay currently written into the mix")

                Text("\(engine.lanes.count) lanes · \(engine.buses.count) buses")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

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

            if let routingError = engine.routingError {
                // Only reachable from a hand-edited session file: every edit
                // the console can make is validated before it is applied.
                Label(routingError.description, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
        .padding(.vertical, 8)
        .background(.bar)
    }
}
