import Foundation

/// What a process tap should capture, in a form that survives a relaunch.
///
/// A tap is built from HAL *process object ids*, and those are not stable —
/// they appear when a process starts doing audio and come back as different
/// numbers next time. So nothing about a process object is persisted: a
/// `TapSpec` names an application by bundle id (or says "everything"), and
/// `ProcessTapFactory` resolves that to whatever object ids exist at the moment
/// the tap is built.
public struct TapSpec: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        /// One application, by bundle id. Several HAL process objects can
        /// share a bundle id (helper processes); all of them are tapped.
        case app(bundleID: String)
        /// Everything this Mac plays, except Clapboard itself — see
        /// `ProcessTapFactory.make` for why the exclusion is not optional.
        case systemAudio
    }

    public var target: Target
    /// What to call the lane and the tap. Purely cosmetic; a bundle id is not
    /// something to show in a 120 pt console strip.
    public var name: String
    /// A mono tap mixes the app down to one channel, a stereo one to two.
    /// This is chosen when the lane is created and is part of what has to be
    /// rebuilt, because it decides the tap's stream format.
    public var mono: Bool

    public init(target: Target, name: String, mono: Bool = false) {
        self.target = target
        self.name = name
        self.mono = mono
    }

    /// The key a tap's channels are registered under in the aggregate device's
    /// input layout, and what `LaneConfig.deviceUID` reports for a tap lane.
    ///
    /// Prefixed so it can never collide with a real Core Audio device UID, and
    /// stable across relaunches so two lanes on the same app share one tap.
    public var sourceKey: String {
        switch target {
        case .systemAudio: return "tap:system"
        case .app(let bundleID): return "tap:\(bundleID)"
        }
    }

    public var channelCount: Int { mono ? 1 : 2 }

    public var bundleID: String? {
        if case .app(let bundleID) = target { return bundleID }
        return nil
    }

    public var isSystemAudio: Bool { target == .systemAudio }
}

// `Target` is written as a tagged object rather than as Swift's default
// enum encoding, so a session file stays something a person can read and edit.
extension TapSpec.Target: Codable {
    private enum CodingKeys: String, CodingKey { case kind, bundleID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = container.lenient(String.self, .kind, "system")
        if kind == "app", let bundleID = container.lenientOptional(String.self, .bundleID),
           !bundleID.isEmpty {
            self = .app(bundleID: bundleID)
        } else {
            self = .systemAudio
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemAudio:
            try container.encode("system", forKey: .kind)
        case .app(let bundleID):
            try container.encode("app", forKey: .kind)
            try container.encode(bundleID, forKey: .bundleID)
        }
    }
}

extension TapSpec: Codable {
    private enum CodingKeys: String, CodingKey { case target, name, mono }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let target = container.lenient(Target.self, .target, .systemAudio)
        self.init(
            target: target,
            name: container.lenient(String.self, .name, target.defaultName),
            mono: container.lenient(Bool.self, .mono, false)
        )
    }
}

extension TapSpec.Target {
    var defaultName: String {
        switch self {
        case .systemAudio: return "System audio"
        case .app(let bundleID): return bundleID
        }
    }
}

/// Where a lane's samples come from.
///
/// A lane used to be *(device UID, channel indices)* and nothing else. It still
/// is most of the time — `.device` is exactly that pair — but macOS 14.2's
/// Core Audio process taps let a lane be fed by another application's output
/// with no hardware and no third-party driver in between, so the pair became
/// one case of an enum rather than the whole story.
///
/// Both cases resolve to the same thing downstream: a key the aggregate
/// device's input layout knows (`sourceKey`) plus the channel indices to take
/// from whatever that key contributes. That is why `AudioEngine.republishGraph`
/// needs no case analysis at all.
public enum LaneSource: Hashable, Sendable {
    case device(uid: String, channels: [Int])
    case processTap(TapSpec)

    /// What `AggregateInputLayout` files this source's channels under: a real
    /// device UID, or `TapSpec.sourceKey`.
    public var sourceKey: String {
        switch self {
        case .device(let uid, _): return uid
        case .processTap(let spec): return spec.sourceKey
        }
    }

    /// Channel indices local to the source. A tap contributes exactly its own
    /// one or two channels, so they are always `[0]` or `[0, 1]`.
    public var channels: [Int] {
        switch self {
        case .device(_, let channels): return channels
        case .processTap(let spec): return spec.mono ? [0] : [0, 1]
        }
    }

    public var tap: TapSpec? {
        if case .processTap(let spec) = self { return spec }
        return nil
    }

    public var isProcessTap: Bool { tap != nil }
}

extension LaneSource: Codable {
    private enum CodingKeys: String, CodingKey { case kind, deviceUID, channels, tap }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = container.lenient(String.self, .kind, "device")
        if kind == "processTap", let spec = container.lenientOptional(TapSpec.self, .tap) {
            self = .processTap(spec)
            return
        }
        let uid = try container.decode(String.self, forKey: .deviceUID)
        self = .device(
            uid: uid,
            channels: LaneConfig.sanitized(channels: container.lenient([Int].self, .channels, [0]))
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .device(let uid, let channels):
            try container.encode("device", forKey: .kind)
            try container.encode(uid, forKey: .deviceUID)
            try container.encode(channels, forKey: .channels)
        case .processTap(let spec):
            try container.encode("processTap", forKey: .kind)
            try container.encode(spec, forKey: .tap)
        }
    }
}


/// One mixer lane: a device plus the channels taken from it, and the manual
/// controls applied to them.
///
/// A lane is *(device UID, channel indices)* rather than "one device, one
/// lane", because dual-transmitter receivers (DJI, Sennheiser) put TX1 and TX2
/// on the left and right of a single stereo device and each transmitter needs
/// its own gain and its own delay.
public struct LaneConfig: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Where this lane's samples come from: an input device and the channels
    /// taken from it, or a process tap on another application.
    public var source: LaneSource
    public var name: String
    public var gainDB: Float
    /// The switch the `M` button and the global hotkeys drive.
    ///
    /// This replaced the older `enabled` flag when buses landed, because a
    /// console strip mutes rather than switches off and solo has to be able to
    /// silence a strip without touching what the user set. `enabled` is kept
    /// as its inverse so existing call sites and session files keep working.
    public var muted: Bool
    /// Solo is scoped to the destination bus: soloing one lane silences the
    /// other lanes feeding the same bus, and nothing else.
    public var solo: Bool
    public var polarityInverted: Bool
    /// Integer samples at 48 kHz. M3 writes this from the clap measurement.
    public var delaySamples: Int
    /// The bus this lane sums into.
    ///
    /// Optional only so a `LaneConfig` can be built — or decoded from a
    /// version 1 session — before any bus exists. `AudioEngine` fills it in
    /// with the `Master` bus the moment the lane is added, so a lane held by a
    /// live engine always has one.
    public var destinationBus: UUID?

    public init(
        id: UUID = UUID(),
        source: LaneSource,
        name: String,
        gainDB: Float = 0,
        enabled: Bool = true,
        polarityInverted: Bool = false,
        delaySamples: Int = 0,
        solo: Bool = false,
        destinationBus: UUID? = nil
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.gainDB = gainDB
        self.muted = !enabled
        self.solo = solo
        self.polarityInverted = polarityInverted
        self.delaySamples = delaySamples
        self.destinationBus = destinationBus
    }

    /// The device-lane spelling, which is still what nearly every call site
    /// wants. Kept as its own initialiser rather than making callers write
    /// `.device(uid:channels:)` everywhere.
    public init(
        id: UUID = UUID(),
        deviceUID: String,
        deviceChannels: [Int],
        name: String,
        gainDB: Float = 0,
        enabled: Bool = true,
        polarityInverted: Bool = false,
        delaySamples: Int = 0,
        solo: Bool = false,
        destinationBus: UUID? = nil
    ) {
        self.init(
            id: id,
            source: .device(uid: deviceUID, channels: Array(deviceChannels.prefix(2))),
            name: name,
            gainDB: gainDB,
            enabled: enabled,
            polarityInverted: polarityInverted,
            delaySamples: delaySamples,
            solo: solo,
            destinationBus: destinationBus
        )
    }

    /// The inverse of `muted`, kept so the row-based mixer's toggle and every
    /// session file written before buses existed keep working unchanged.
    public var enabled: Bool {
        get { !muted }
        set { muted = !newValue }
    }

    /// The key the aggregate device's input layout files this lane's channels
    /// under. A real device UID for a device lane; `TapSpec.sourceKey` — which
    /// can never look like a device UID — for a tap lane.
    ///
    /// This is a computed shim over `source` rather than stored state so that
    /// everything written against the pre-tap "(device UID, channels)" lane —
    /// Auto Sync, the row mixer, the session tests — keeps working unchanged.
    /// Assigning to it turns the lane back into a device lane, which is what
    /// `setLaneSource(_:deviceUID:deviceChannels:)` means by it.
    public var deviceUID: String {
        get { source.sourceKey }
        set { source = .device(uid: newValue, channels: source.channels) }
    }

    /// Channel indices local to the source, counted across all of its input
    /// streams. One entry for a mono lane, two for a stereo lane. A tap
    /// contributes only its own channels, so a tap lane reports `[0]` or
    /// `[0, 1]`; assigning decides whether the tap is mono or stereo.
    public var deviceChannels: [Int] {
        get { source.channels }
        set {
            let cleaned = Array(newValue.prefix(2))
            switch source {
            case .device(let uid, _):
                source = .device(uid: uid, channels: cleaned)
            case .processTap(var spec):
                spec.mono = cleaned.count < 2
                source = .processTap(spec)
            }
        }
    }

    public var isStereo: Bool { deviceChannels.count >= 2 }

    public var channelLabel: String {
        if let tap = source.tap {
            return tap.mono ? "tap · mono" : "tap · stereo"
        }
        let channels = source.channels
        if channels.count >= 2 {
            return "ch \(channels[0] + 1)/\(channels[1] + 1)"
        }
        return "ch \((channels.first ?? 0) + 1)"
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

// MARK: - Persistence

/// Session files outlive the build that wrote them and may be edited by hand,
/// so decoding is deliberately forgiving: only `deviceUID` is required, every
/// other field falls back to the default the memberwise initialiser uses, and
/// unknown keys are ignored. That is what lets a lane written by a newer
/// Clapboard — with, say, an effect chain attached — still load here.
///
/// `id` is encoded and restored so that data keyed on it (M3 sync results, M4
/// plug-in state) stays attached to the same lane across relaunches.
///
/// `source` is the same story one level down. A file written before process
/// taps existed has no `source` key at all, only `deviceUID`/`deviceChannels`,
/// and loads as a `.device` lane — so a version 2 session from an older build
/// still opens without a format bump. Every file written from here on carries
/// `source` *and* the two old keys, so an older Clapboard reading a tap lane
/// sees a lane on an unknown device and reports it missing rather than
/// dropping the lane (and everything keyed on its id) on the floor.
extension LaneConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, source, deviceUID, deviceChannels, name, gainDB, enabled, muted, solo
        case polarityInverted, delaySamples, destinationBus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source: LaneSource
        if let decoded = container.lenientOptional(LaneSource.self, .source) {
            source = decoded
        } else {
            source = .device(
                uid: try container.decode(String.self, forKey: .deviceUID),
                channels: LaneConfig.sanitized(
                    channels: container.lenient([Int].self, .deviceChannels, [0])
                )
            )
        }
        self.init(
            id: container.lenient(UUID.self, .id, UUID()),
            source: source,
            name: container.lenient(String.self, .name, source.tap?.name ?? source.sourceKey),
            gainDB: container.lenient(Float.self, .gainDB, 0),
            // `muted` is what version 2 writes; `enabled` is what version 1
            // wrote and what an older build still understands, so a file
            // carrying only the old key migrates by itself.
            enabled: container.lenientOptional(Bool.self, .muted).map { !$0 }
                ?? container.lenient(Bool.self, .enabled, true),
            polarityInverted: container.lenient(Bool.self, .polarityInverted, false),
            delaySamples: container.lenient(Int.self, .delaySamples, 0),
            solo: container.lenient(Bool.self, .solo, false),
            destinationBus: container.lenientOptional(UUID.self, .destinationBus)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        // The pre-tap spelling, kept so a Clapboard that predates `source`
        // still finds a lane where it expects one. For a device lane these are
        // the truth; for a tap lane they are `tap:<bundle id>` and its channel
        // count, which an older build reports as a missing device.
        try container.encode(deviceUID, forKey: .deviceUID)
        try container.encode(deviceChannels, forKey: .deviceChannels)
        try container.encode(name, forKey: .name)
        try container.encode(gainDB, forKey: .gainDB)
        // Both spellings: `muted` is the truth, `enabled` keeps a Clapboard
        // that predates buses able to read the file.
        try container.encode(muted, forKey: .muted)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(solo, forKey: .solo)
        try container.encode(polarityInverted, forKey: .polarityInverted)
        try container.encode(delaySamples, forKey: .delaySamples)
        try container.encodeIfPresent(destinationBus, forKey: .destinationBus)
    }

    /// A lane always drives at least one channel; negative indices and a third
    /// channel are edits the render kernel cannot honour.
    static func sanitized(channels: [Int]) -> [Int] {
        let cleaned = channels.filter { $0 >= 0 }.prefix(2)
        return cleaned.isEmpty ? [0] : Array(cleaned)
    }
}
