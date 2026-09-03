import Foundation

/// One bus: a virtual track that sums the lanes and buses pointed at it, runs
/// its own effect chain and fader, and sends the result to a parent bus, to an
/// output device, or to both.
///
/// A bus is deliberately the same shape as a lane strip — gain, mute, solo,
/// effects, meter — because that is what makes the mixer feel like a console.
/// Exactly one bus exists by default and is named `Master`; nothing else about
/// it is special, and its id is persisted so per-bus data stays attached to it
/// across a relaunch.
///
/// `destinationBus == nil` means the bus is a root: it has no parent and is
/// only heard through `outputDeviceUID`. A bus with neither is legal — it is a
/// group nobody is listening to — and the UI is expected to say so.
public struct BusConfig: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var gainDB: Float
    /// The switch the hotkeys and the `M` button drive. Ramps, never steps.
    public var muted: Bool
    /// Solo is scoped to the sibling set — the buses sharing this bus's
    /// parent, or every root bus when it has none.
    public var solo: Bool
    /// This bus's chain, after the sum and before the fader. Buses carry their
    /// chain inline (lanes keep theirs in `AudioEngine.laneEffects`) because a
    /// bus *is* its chain plus a fader; there is nothing else to key it on.
    public var effects: [EffectConfig]
    /// Parent bus, or `nil` for a root bus.
    public var destinationBus: UUID?
    /// Optional device send. Several buses may name different devices, and the
    /// first one in bus order becomes the aggregate's clock main.
    public var outputDeviceUID: String?
    /// First channel of the stereo pair inside that device's first output
    /// stream.
    public var outputChannelOffset: Int

    public init(
        id: UUID = UUID(),
        name: String,
        gainDB: Float = 0,
        muted: Bool = false,
        solo: Bool = false,
        effects: [EffectConfig] = [],
        destinationBus: UUID? = nil,
        outputDeviceUID: String? = nil,
        outputChannelOffset: Int = 0
    ) {
        self.id = id
        self.name = name
        self.gainDB = gainDB
        self.muted = muted
        self.solo = solo
        self.effects = effects
        self.destinationBus = destinationBus
        self.outputDeviceUID = outputDeviceUID
        self.outputChannelOffset = max(0, outputChannelOffset)
    }

    /// The name the default bus is created with, and the one a version 1
    /// session is migrated into.
    public static let masterName = "Master"

    /// A bus nothing can hear: no parent and no device.
    public var isDangling: Bool { destinationBus == nil && outputDeviceUID == nil }
}

// MARK: - Persistence

/// Buses decode as tolerantly as lanes do: only `id` and `name` are required,
/// everything else falls back to the memberwise default, and unknown keys are
/// ignored so a file written by a newer Clapboard still loads.
///
/// The chain travels as one base64 blob produced by `EffectChainCodec` — the
/// same encoding the version 1 extras bag used — so a plug-in's `fullState`
/// stays out of the readable part of the document.
extension BusConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, gainDB, muted, solo, effects, destinationBus, outputDeviceUID, outputChannelOffset
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        self.init(
            id: id,
            name: name,
            gainDB: container.lenient(Float.self, .gainDB, 0),
            muted: container.lenient(Bool.self, .muted, false),
            solo: container.lenient(Bool.self, .solo, false),
            effects: EffectChainCodec.decode(container.lenientOptional(Data.self, .effects)),
            destinationBus: container.lenientOptional(UUID.self, .destinationBus),
            outputDeviceUID: container.lenientOptional(String.self, .outputDeviceUID),
            outputChannelOffset: container.lenient(Int.self, .outputChannelOffset, 0)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(gainDB, forKey: .gainDB)
        try container.encode(muted, forKey: .muted)
        try container.encode(solo, forKey: .solo)
        if !effects.isEmpty {
            try container.encode(EffectChainCodec.encode(effects), forKey: .effects)
        }
        try container.encodeIfPresent(destinationBus, forKey: .destinationBus)
        try container.encodeIfPresent(outputDeviceUID, forKey: .outputDeviceUID)
        try container.encode(outputChannelOffset, forKey: .outputChannelOffset)
    }
}
