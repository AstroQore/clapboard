import ClapboardCore
import SwiftUI

/// The evidence behind the arrival times: every pair that was measured, which
/// estimator settled it, and how far the pairs had to bend to agree.
///
/// It is collapsed by default. Nobody needs it to press Apply — but when a
/// lane comes back refused, or two takes disagree, this is the only place that
/// says *why* rather than restating the verdict.
struct SyncMeasurementDetail: View {
    let result: SyncResult
    @State private var expanded = false

    var body: some View {
        if !result.pairs.isEmpty || !result.droppedPairs.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    explanation
                    Divider()
                    ForEach(Array(sortedPairs.enumerated()), id: \.offset) { _, pair in
                        pairRow(pair, dropped: false)
                    }
                    ForEach(Array(result.droppedPairs.enumerated()), id: \.offset) { _, pair in
                        pairRow(pair, dropped: true)
                    }
                    if let triangles = result.triangleResidualSamples {
                        Text(String(
                            format: "Triangle check: %.2f samples. Any three lanes' offsets must"
                                + " sum to zero, and that holds whatever the fit decided.",
                            triangles
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    } else if result.pairs.count == 1 {
                        Text(
                            "Only one pair, so there is nothing to cross-check it against."
                                + " A third lane would make the measurement self-verifying."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Measurement detail")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var explanation: some View {
        Text(
            "Each pair of lanes is measured on its own, then all the measurements are"
                + " fitted to one set of arrival times. No lane is a reference:"
                + " the earliest arrival is simply called zero."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sortedPairs: [PairObservation] {
        result.pairs.sorted { label(for: $0) < label(for: $1) }
    }

    private func pairRow(_ pair: PairObservation, dropped: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label(for: pair))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%+.2f ms", milliseconds(pair.offsetSamples)))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
            Text(pair.estimator)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            if dropped {
                Label("dropped", systemImage: "minus.circle")
                    .foregroundStyle(.orange)
                    .help(
                        "Refitting without this pair explained the take much better,"
                            + " so it was left out."
                    )
            } else if let residual = result.pairResidual(for: pair) {
                Text(String(format: "%+.2f sp", residual))
                    .monospacedDigit()
                    .foregroundStyle(abs(residual) <= 1 ? Color.secondary : Color.orange)
                    .help("How far this pair sits from the fitted arrival times.")
            }
        }
        .font(.caption)
    }

    private func label(for pair: PairObservation) -> String {
        let a = result[pair.a]?.label ?? "?"
        let b = result[pair.b]?.label ?? "?"
        return "\(a) vs \(b)"
    }

    private func milliseconds(_ samples: Double) -> Double {
        result.sampleRate > 0 ? samples / result.sampleRate * 1000 : 0
    }
}
