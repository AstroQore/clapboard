import ClapboardCore
import SwiftUI

/// Amplitude → bar length, shared by the horizontal and vertical meters so the
/// two never disagree about where −20 dB sits.
enum MeterScale {
    /// Bottom of every meter in the app.
    static let floorDB: Float = -60

    static func fraction(_ amplitude: Float, floorDB: Float = MeterScale.floorDB) -> CGFloat {
        guard amplitude > 0 else { return 0 }
        let db = MeterReading.decibels(amplitude)
        guard db.isFinite else { return 0 }
        let clamped = min(0, max(floorDB, db))
        return CGFloat((clamped - floorDB) / -floorDB)
    }

    /// Green through orange to red: the last 3 dB and clipping are the two
    /// things a glance has to catch.
    static func peakColor(_ reading: MeterReading) -> Color {
        reading.peak >= 0.99 ? .red : (reading.peakDB > -3 ? .orange : .primary)
    }

    static func label(_ reading: MeterReading) -> String {
        reading.peak > 0 ? String(format: "%.1f dB peak", reading.peakDB) : "silent"
    }
}

/// A horizontal peak/RMS bar on a dB scale.
///
/// The decay is applied by the render thread, not here, so a 30 Hz poll can
/// never miss a transient. This view only maps amplitude to a width.
struct MeterBar: View {
    var reading: MeterReading
    var floorDB: Float = MeterScale.floorDB
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: width * MeterScale.fraction(reading.rms, floorDB: floorDB))
                if reading.peak > 0 {
                    Capsule()
                        .fill(MeterScale.peakColor(reading))
                        .frame(width: 2)
                        .offset(x: max(0, width * MeterScale.fraction(reading.peak, floorDB: floorDB) - 2))
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Level")
        .accessibilityValue(MeterScale.label(reading))
    }
}

/// The console strip's meter: the same scale as `MeterBar`, stood on end.
///
/// Deliberately timer-free. Every meter in the console is driven by the one
/// `TimelineView` `ConsoleView` owns, which hands each strip a reading that has
/// already been read out of the render thread's atomics.
struct VerticalMeterBar: View {
    var reading: MeterReading
    var floorDB: Float = MeterScale.floorDB
    var width: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: width / 2)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: width / 2)
                    .fill(.tint)
                    .frame(height: height * MeterScale.fraction(reading.rms, floorDB: floorDB))
                if reading.peak > 0 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(MeterScale.peakColor(reading))
                        .frame(height: 2)
                        .offset(y: -max(0, height * MeterScale.fraction(reading.peak, floorDB: floorDB) - 2))
                }
            }
        }
        .frame(width: width)
        .accessibilityLabel("Level")
        .accessibilityValue(MeterScale.label(reading))
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
