import ClapboardCore
import SwiftUI

/// Auto Sync, end to end: pick the lanes, clap, read the verdict, apply it.
///
/// All the work — capture, analysis, envelopes — happens in `SyncSession`.
/// This view only reads what the session already computed; nothing here loops
/// over samples.
struct AutoSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: SyncSession

    @MainActor
    init(engine: AudioEngine, registry: AudioDeviceRegistry) {
        _session = State(wrappedValue: SyncSession(engine: engine, registry: registry))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .onAppear { session.refreshLanes() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Auto Sync")
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        switch session.phase {
        case .idle: return "Measure how late each microphone is, and correct it."
        case .armed: return "Recording room tone…"
        case .listening(let take, let total):
            return total > 1 ? "Take \(take) of \(total)" : "Listening"
        case .analysing: return "Cross-correlating…"
        case .results:
            return session.lastResult?.failureSummary == nil
                ? "Nothing has been written to the lanes yet."
                : "Nothing was measured."
        case .verifying: return "Re-measuring through the applied delays…"
        case .done: return "Applied."
        case .failed: return "Did not complete."
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle:
            options
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                options
            }
            .padding(.top, 12)
        case .armed, .listening:
            listening
        case .analysing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Finding the clap on every lane…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results, .verifying, .done:
            results
        }
    }

    // MARK: - Step 1: options

    private var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(
                    "Hold the wireless transmitters together and clap once, or clap at the speaking position.",
                    systemImage: "hands.clap"
                )
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Lanes")
                        .font(.subheadline.weight(.semibold))
                    ForEach(session.laneOptions) { lane in
                        Toggle(isOn: Binding(
                            get: { session.includedLaneIDs.contains(lane.id) },
                            set: { session.setIncluded(lane.id, $0) }
                        )) {
                            HStack(spacing: 6) {
                                Text(lane.label)
                                Text(lane.deviceName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if lane.isVirtual {
                                    Text("virtual")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                        .help("A virtual device replays another clock, so it never becomes the reference.")
                                }
                                if lane.currentDelaySamples > 0 {
                                    Text(String(format: "now %.1f ms", Double(lane.currentDelaySamples) / 48))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    if session.laneOptions.isEmpty {
                        Text("No lanes yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Claps")
                        Stepper(value: $session.takeCount, in: 1...3) {
                            Text("\(session.takeCount)")
                                .font(.body.monospacedDigit())
                                .frame(width: 20, alignment: .leading)
                        }
                        Text("Two takes have to agree within 0.5 ms before a lane is accepted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Search window")
                        Picker("", selection: $session.maxLagSeconds) {
                            Text("±100 ms").tag(0.10)
                            Text("±250 ms").tag(0.25)
                            Text("±500 ms").tag(0.50)
                            Text("±1 s").tag(1.00)
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Text("Arrivals further apart than this are refused rather than guessed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Listen for")
                        Picker("", selection: $session.listenSeconds) {
                            Text("3 s").tag(3.0)
                            Text("4 s").tag(4.0)
                            Text("6 s").tag(6.0)
                            Text("8 s").tag(8.0)
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Text("How long CLAP NOW stays up. The take stops early only once a real clap has been heard.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Confidence")
                        Toggle("Relaxed", isOn: $session.relaxed)
                            .toggleStyle(.checkbox)
                        Text("Drops the peak/second-peak requirement from 3 to 2 — for a hard, reflective room.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Step 2: listening

    private var listening: some View {
        VStack(spacing: 18) {
            Spacer()
            switch session.phase {
            case .armed(let remaining):
                Text("Get ready…")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0f", max(1, remaining.rounded(.up))))
                    .font(.system(size: 56, weight: .bold).monospacedDigit())
                Text("Recording room tone — the noise floor is measured from the first 0.3 s.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                Text("CLAP NOW")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(.orange)
                Text(String(format: "%.0f", max(0, session.listenSecondsRemaining.rounded(.up))))
                    .font(.system(size: 40, weight: .bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("One sharp clap, any time in that window. Recording stops a second after it lands.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: session.captureProgress)
                .frame(width: 360)
            if case .listening(let take, let total) = session.phase, total > 1 {
                Text("Take \(take) of \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 3: results

    @ViewBuilder
    private var results: some View {
        if let result = session.lastResult {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let failure = result.failureSummary {
                        failureBanner(failure)
                    } else if let message = session.message {
                        Label(message, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    SyncResultTable(
                        result: result,
                        fitResidualSamples: result.fitResidualSamples,
                        verifications: session.verifications
                    )

                    SyncMeasurementDetail(result: result)

                    if let takes = session.takeEnvelopes {
                        SyncTakePanel(set: takes)
                    }

                    // The zoom is only worth drawing when something lined up.
                    if let envelopes = session.envelopes, !result.alignedLanes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Around the clap")
                                .font(.subheadline.weight(.semibold))
                            HStack(spacing: 10) {
                                SyncWaveformPanel(title: "Before", set: envelopes, shifted: false)
                                SyncWaveformPanel(title: "After", set: envelopes, shifted: true)
                            }
                            Text(String(
                                format: "%.0f ms across the window, %.2f ms per pixel column at 2000 points.",
                                envelopes.spanMilliseconds,
                                envelopes.spanMilliseconds / Double(max(1, envelopes.pointCount))
                            ))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(16)
            }
        } else {
            Text("No result.")
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }

    /// The one thing the user has to read when a take comes back empty.
    private func failureBanner(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(summary, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("No delay was changed. Clap once, hard, while the sheet says CLAP NOW — "
                 + "the whole take is drawn below, so you can see what was heard instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if case .done = session.phase, !session.appliedDelays.isEmpty {
                Label("\(session.appliedDelays.count) lane\(session.appliedDelays.count == 1 ? "" : "s") updated", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()

            switch session.phase {
            case .idle, .failed:
                Button("Close") { dismiss() }
                Button("Start") { session.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.canStart)
            case .armed, .listening, .analysing, .verifying:
                Button("Cancel") { session.cancel() }
            case .results, .done:
                // With nothing measured, clapping again is the only useful
                // thing to do, so Retake takes the return key.
                Button("Retake") { session.retake() }
                    .keyboardShortcut(hasSomethingToApply ? .none : .defaultAction)
                Button("Apply") { session.apply() }
                    .disabled(!hasSomethingToApply)
                Button("Apply + Verify") {
                    Task { await session.applyAndVerify() }
                }
                .keyboardShortcut(hasSomethingToApply ? .defaultAction : .none)
                .disabled(!hasSomethingToApply)
                Button("Close") { dismiss() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var hasSomethingToApply: Bool {
        guard let result = session.lastResult else { return false }
        return result.failureSummary == nil && !result.alignedLanes.isEmpty
    }
}

// MARK: - Result table

private struct SyncResultTable: View {
    let result: SyncResult
    /// How well every pairwise measurement agreed with one set of arrival
    /// times. Shown instead of naming a reference lane: there isn't one.
    let fitResidualSamples: Double?
    let verifications: [SyncVerification]

    private func milliseconds(_ samples: Double) -> Double {
        result.sampleRate > 0 ? samples / result.sampleRate * 1000 : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            ForEach(Array(result.lanes.enumerated()), id: \.element.laneID) { index, lane in
                row(lane)
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                Divider()
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Lane").frame(width: 150, alignment: .leading)
            Text("Arrival").frame(width: 78, alignment: .trailing)
            Text("Delay to add").frame(width: 78, alignment: .trailing)
            Text("Confidence").frame(width: 110, alignment: .leading)
            HStack(spacing: 4) {
                Text("Verdict")
                Spacer(minLength: 0)
                if let residual = fitResidualSamples, residual.isFinite {
                    // The take's own cross-check, in place of naming a lane
                    // everything was measured against: with three or more
                    // lanes it is how far every pairwise measurement had to
                    // bend to agree on one set of arrivals.
                    Text(String(format: "pairs agree to %.2f samples", residual))
                        .foregroundStyle(residual <= 1 ? Color.secondary : Color.orange)
                        .help(
                            "Every pair of lanes is measured on its own and the"
                            + " arrival times are fitted to all of them at once."
                            + " This is how much the measurements disagreed."
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func row(_ lane: LaneSyncResult) -> some View {
        HStack(spacing: 8) {
            Text(lane.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)

            // Arrivals are absolute within the take: the lane that heard the
            // clap first reads 0.00 and nothing is ever negative. No lane is a
            // reference, so none is labelled as one.
            Text(lane.status.offsetSamples.map { String(format: "%.2f ms", milliseconds($0)) } ?? "—")
                .font(.caption.monospacedDigit())
                .frame(width: 78, alignment: .trailing)

            Text(lane.suggestedDelayMs.map { String(format: "%.2f ms", $0) } ?? "—")
                .font(.caption.monospacedDigit().weight(.medium))
                .frame(width: 78, alignment: .trailing)

            confidence(lane)
                .frame(width: 110, alignment: .leading)

            verdict(lane)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func confidence(_ lane: LaneSyncResult) -> some View {
        if let value = lane.status.confidence {
            HStack(spacing: 5) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(value > 0.66 ? Color.green : (value > 0.33 ? Color.yellow : Color.orange))
                            .frame(width: geometry.size.width * CGFloat(max(0, min(1, value))))
                    }
                }
                .frame(height: 6)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        } else {
            Text("—")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func verdict(_ lane: LaneSyncResult) -> some View {
        HStack(spacing: 6) {
            if lane.status.isAligned {
                Label("aligned", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label(lane.status.notDetectedReason ?? "not detected", systemImage: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help("Not detected — this lane's delay was left untouched.")
            }
            if lane.clipped {
                Label("clipped", systemImage: "waveform.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .help("A sample hit full scale. Turn the input gain down and re-measure.")
            }
            if lane.status.polarityInverted {
                Label("Ø", systemImage: "arrow.up.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .help("The correlation peak is negative: this lane is wired out of phase.")
            }
            if let verification = verifications.first(where: { $0.laneID == lane.laneID }) {
                if let residual = verification.residualSamples {
                    Text(String(format: "residual %+.2f sp", residual))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(abs(residual) <= 1 ? .green : .orange)
                } else {
                    Text("residual —")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
