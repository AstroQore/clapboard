import Foundation

/// One mixer lane: a device plus the channels taken from it, and the manual
/// controls applied to them.
///
/// A lane is *(device UID, channel indices)* rather than "one device, one
/// lane", because dual-transmitter receivers (DJI, Sennheiser) put TX1 and TX2
/// on the left and right of a single stereo device and each transmitter needs
/// its own gain and its own delay.
public struct LaneConfig: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Stable device key. Never an `AudioObjectID`.
    public var deviceUID: String
    /// Device-local channel indices, counted across all of that device's input
    /// streams. One entry for a mono lane, two for a stereo lane.
    public var deviceChannels: [Int]
    public var name: String
    public var gainDB: Float
    public var enabled: Bool
    public var polarityInverted: Bool
    /// Integer samples at 48 kHz. M3 writes this from the clap measurement.
    public var delaySamples: Int

    public init(
        id: UUID = UUID(),
        deviceUID: String,
        deviceChannels: [Int],
        name: String,
        gainDB: Float = 0,
        enabled: Bool = true,
        polarityInverted: Bool = false,
        delaySamples: Int = 0
    ) {
        self.id = id
        self.deviceUID = deviceUID
        self.deviceChannels = Array(deviceChannels.prefix(2))
        self.name = name
        self.gainDB = gainDB
        self.enabled = enabled
        self.polarityInverted = polarityInverted
        self.delaySamples = delaySamples
    }

    public var isStereo: Bool { deviceChannels.count >= 2 }

    public var channelLabel: String {
        if deviceChannels.count >= 2 {
            return "ch \(deviceChannels[0] + 1)/\(deviceChannels[1] + 1)"
        }
        return "ch \(( deviceChannels.first ?? 0) + 1)"
    }

    public func delayMilliseconds(sampleRate: Double = 48_000) -> Double {
        Double(delaySamples) / sampleRate * 1000
    }

    public static func samples(forMilliseconds ms: Double, sampleRate: Double = 48_000) -> Int {
        Int((ms / 1000 * sampleRate).rounded())
    }
}

/// dB ↔ linear, shared by the engine and the UI.
public enum Decibels {
    /// Below this a fader is treated as −∞ so a lane at the bottom of its
    /// range is genuinely silent.
    public static let floorDB: Float = -60

    public static func linear(_ db: Float) -> Float {
        db <= floorDB ? 0 : powf(10, db / 20)
    }

    public static func decibels(_ linear: Float) -> Float {
        linear > 1e-7 ? 20 * log10f(linear) : -Float.infinity
    }
}
