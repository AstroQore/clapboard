import ClapboardCore
import SwiftUI

/// A horizontal peak/RMS bar on a dB scale.
///
/// The decay is applied by the render thread, not here, so a 30 Hz poll can
/// never miss a transient. This view only maps amplitude to a width.
struct MeterBar: View {
    var reading: MeterReading
    var floorDB: Float = -60
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: width * fraction(reading.rms))
                if reading.peak > 0 {
                    Capsule()
                        .fill(peakColor)
                        .frame(width: 2)
                        .offset(x: max(0, width * fraction(reading.peak) - 2))
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Level")
        .accessibilityValue(label)
    }

    private var peakColor: Color {
        reading.peak >= 0.99 ? .red : (reading.peakDB > -3 ? .orange : .primary)
    }

    private var label: String {
        reading.peak > 0 ? String(format: "%.1f dB peak", reading.peakDB) : "silent"
    }

    private func fraction(_ amplitude: Float) -> CGFloat {
        guard amplitude > 0 else { return 0 }
        let db = MeterReading.decibels(amplitude)
        guard db.isFinite else { return 0 }
        let clamped = min(0, max(floorDB, db))
        return CGFloat((clamped - floorDB) / -floorDB)
    }
}

/// Wraps a meter in a 30 Hz timeline while the engine runs, and freezes it
/// when it does not. `body` reads atomics only — no allocation, no work that
/// would make 30 Hz expensive.
struct LiveMeter: View {
    var isLive: Bool
    var read: () -> MeterReading
    var height: CGFloat = 10

    var body: some View {
        if isLive {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                MeterBar(reading: read(), height: height)
            }
        } else {
            MeterBar(reading: .silent, height: height)
        }
    }
}

/// Numeric read-out next to a meter.
struct MeterReadout: View {
    var isLive: Bool
    var read: () -> MeterReading

    var body: some View {
        if isLive {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                text(read())
            }
        } else {
            text(.silent)
        }
    }

    private func text(_ reading: MeterReading) -> some View {
        Text(reading.peak > 0 ? String(format: "%+.1f", reading.peakDB) : "−∞")
            .font(.caption.monospacedDigit())
            .foregroundStyle(reading.peak >= 0.99 ? .red : .secondary)
            .frame(width: 42, alignment: .trailing)
    }
}
