import ClapboardCore
import SwiftUI

/// The waveform half of the Auto Sync result page.
///
/// Two things are drawn, and they answer different questions. The whole-take
/// panel answers "was the thing you measured a clap?" — one spike out of a
/// flat room, or the dense grass that means the window held speech and chairs.
/// The zoomed overlay below answers "did the lanes line up?".
///
/// Every point drawn here was computed in `SyncSession`; nothing in these
/// bodies loops over samples.

// MARK: - Whole take

struct SyncTakePanel: View {
    let set: SyncTakeEnvelopeSet

    private static let rowHeight: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Whole take")
                    .font(.subheadline.weight(.semibold))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(set.lanes) { lane in
                    SyncTakeRow(lane: lane, set: set)
                        .frame(height: Self.rowHeight)
                    Divider()
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 10) {
                legend(colour: .orange, text: "onset")
                legend(colour: .red, text: "loudest 1 ms")
                Text("A clap is one spike well clear of the rest of the take.")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var caption: String {
        let duration = String(format: "%.2f s", set.durationSeconds)
        return set.endedEarly
            ? "\(duration) — stopped as soon as the clap had its tail"
            : "\(duration) — the full listen window"
    }

    private func legend(colour: Color, text: String) -> some View {
        HStack(spacing: 3) {
            Rectangle().fill(colour).frame(width: 6, height: 1.5)
            Text(text)
        }
    }
}

private struct SyncTakeRow: View {
    let lane: SyncTakeEnvelope
    let set: SyncTakeEnvelopeSet

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(lane.label)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(lane.isAligned ? .secondary : Color.orange.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 190, alignment: .leading)

            Canvas { context, size in
                let count = lane.points.count
                guard count > 1 else { return }
                let scaleX = size.width / CGFloat(count)
                let base = size.height - 2
                let amplitude = size.height - 6

                var path = Path()
                path.move(to: CGPoint(x: 0, y: base))
                for point in 0..<count {
                    path.addLine(to: CGPoint(
                        x: CGFloat(point) * scaleX,
                        y: base - CGFloat(lane.points[point]) * amplitude
                    ))
                }
                path.addLine(to: CGPoint(x: CGFloat(count - 1) * scaleX, y: base))
                path.closeSubpath()
                context.fill(
                    path,
                    with: .color(lane.isAligned ? Color.accentColor.opacity(0.6)
                                                : Color.secondary.opacity(0.45))
                )

                func mark(_ point: Double, _ colour: Color, dashed: Bool) {
                    let x = CGFloat(point) * scaleX
                    guard x.isFinite, x >= 0, x <= size.width else { return }
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(
                        line, with: .color(colour),
                        style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 2] : [])
                    )
                }
                if let peak = lane.peakPoint { mark(peak, .red.opacity(0.7), dashed: true) }
                if let onset = lane.onsetPoint { mark(onset, .orange, dashed: false) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
        }
        .padding(.horizontal, 8)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let dominance = lane.dominanceDB {
            parts.append(String(format: "%.0f dB over the room", dominance))
        }
        if lane.multipleTransients { parts.append("more than one bang") }
        if let reason = lane.notDetectedReason { parts.append(reason) }
        return parts.isEmpty ? "aligned" : parts.joined(separator: " · ")
    }
}

// MARK: - Zoomed overlay

struct SyncWaveformPanel: View {
    let title: String
    let set: SyncEnvelopeSet
    let shifted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            SyncWaveformOverlay(set: set, shifted: shifted)
                .frame(height: 150)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Every lane's envelope on one time axis, drawn twice by the caller: as
/// recorded, and shifted right by the delay Auto Sync suggests. Lined up, the
/// onsets in the right-hand panel form one vertical column.
private struct SyncWaveformOverlay: View {
    let set: SyncEnvelopeSet
    let shifted: Bool

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown]

    var body: some View {
        Canvas { context, size in
            let lanes = set.lanes
            let count = set.pointCount
            guard count > 1, !lanes.isEmpty else { return }
            let scaleX = size.width / CGFloat(count)
            let rowHeight = size.height / CGFloat(lanes.count)

            // Where the aligned lanes should end up: the latest arrival.
            let target = lanes.compactMap { lane -> Double? in
                guard lane.isAligned, let onset = lane.onsetPoint else { return nil }
                return onset + (shifted ? lane.shiftPoints : 0)
            }.max()

            for (index, lane) in lanes.enumerated() {
                let colour = Self.palette[index % Self.palette.count]
                let top = rowHeight * CGFloat(index)
                let base = top + rowHeight - 3
                let amplitude = rowHeight - 8
                let shift = CGFloat(shifted ? lane.shiftPoints : 0) * scaleX

                var path = Path()
                path.move(to: CGPoint(x: shift, y: base))
                for point in 0..<count {
                    path.addLine(to: CGPoint(
                        x: CGFloat(point) * scaleX + shift,
                        y: base - CGFloat(lane.points[point]) * amplitude
                    ))
                }
                path.addLine(to: CGPoint(x: CGFloat(count - 1) * scaleX + shift, y: base))
                path.closeSubpath()

                context.fill(path, with: .color(colour.opacity(lane.isAligned ? 0.55 : 0.2)))
                context.stroke(
                    Path { line in
                        line.move(to: CGPoint(x: 0, y: base))
                        line.addLine(to: CGPoint(x: size.width, y: base))
                    },
                    with: .color(.secondary.opacity(0.25)),
                    lineWidth: 0.5
                )
                context.draw(
                    Text(lane.label)
                        .font(.system(size: 9))
                        .foregroundStyle(lane.isAligned ? colour : Color.secondary),
                    at: CGPoint(x: 4, y: top + 7),
                    anchor: .topLeading
                )
            }

            if let target {
                var guideline = Path()
                let x = CGFloat(target) * scaleX
                guideline.move(to: CGPoint(x: x, y: 0))
                guideline.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    guideline,
                    with: .color(.red.opacity(0.6)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(shifted ? "Waveforms after alignment" : "Waveforms as recorded")
    }
}
