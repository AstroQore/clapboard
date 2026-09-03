import Foundation

/// Everything Clapboard remembers between launches: the lanes, their order,
/// the output device and the master gain.
///
/// The file is JSON — pretty-printed with sorted keys — because a session is
/// something a user may want to read, diff, copy between machines or repair by
/// hand. That makes tolerant decoding a requirement rather than a nicety:
///
/// - unknown keys are ignored, so a file written by a newer Clapboard still
///   loads here;
/// - every field except a lane's `deviceUID` is optional and falls back to the
///   same default the in-memory type uses;
/// - a lane that cannot be decoded at all is dropped, and the rest of the
///   session still loads;
/// - a `formatVersion` from the future is *reported*, not refused.
public struct SessionDocument: Codable, Sendable, Equatable {
    /// Bumped only when a reader has to behave differently, not on every
    /// additive field: adding a key that older builds ignore is exactly what
    /// the tolerant decoding above is for.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// Lane order is part of the session — it is the order the UI shows and
    /// the order the aggregate device lists its sub-devices in.
    public var lanes: [LaneConfig]
    /// Kept even when the device is not plugged in right now. The engine
    /// reports such a lane as `deviceMissing` and rebinds it when it returns.
    public var outputDeviceUID: String?
    public var masterGainDB: Float
    /// Whole seconds, so the ISO-8601 form in the file round-trips exactly.
    public var savedAt: Date

    /// Forward-compatible bag for per-lane state this version does not model,
    /// keyed by `LaneConfig.id.uuidString` and then by an owner-chosen name.
    ///
    /// M4's per-lane effect chains are meant to land here as one entry holding
    /// an `AUAudioUnit.fullState` binary plist. Nothing in M5 writes it; it
    /// exists so that a build which does write it cannot have its settings
    /// silently erased by an older build, which loads the bag, leaves it alone
    /// and saves it back out.
    public var laneExtras: [String: [String: Data]]
    /// The same, for the master bus.
    public var masterExtras: [String: Data]

    public init(
        formatVersion: Int = SessionDocument.currentFormatVersion,
        lanes: [LaneConfig] = [],
        outputDeviceUID: String? = nil,
        masterGainDB: Float = 0,
        savedAt: Date = Date(),
        laneExtras: [String: [String: Data]] = [:],
        masterExtras: [String: Data] = [:]
    ) {
        self.formatVersion = formatVersion
        self.lanes = lanes
        self.outputDeviceUID = outputDeviceUID
        self.masterGainDB = masterGainDB
        self.savedAt = SessionDocument.wholeSeconds(savedAt)
        self.laneExtras = laneExtras
        self.masterExtras = masterExtras
    }

    /// True when the file was written by a Clapboard that knows more than this
    /// one. Everything this build understands has still been loaded; callers
    /// use this to warn before overwriting the file.
    public var isFromNewerFormat: Bool { formatVersion > Self.currentFormatVersion }

    /// `.iso8601` has no sub-second resolution, so timestamps are rounded on
    /// the way in and a saved document equals the one that comes back.
    public static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded())
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case formatVersion, lanes, outputDeviceUID, masterGainDB, savedAt, laneExtras, masterExtras
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lanes = container.lenientOptional([LenientlyDecoded<LaneConfig>].self, .lanes) ?? []
        self.init(
            formatVersion: container.lenient(Int.self, .formatVersion, SessionDocument.currentFormatVersion),
            lanes: lanes.compactMap(\.value),
            outputDeviceUID: container.lenientOptional(String.self, .outputDeviceUID),
            masterGainDB: container.lenient(Float.self, .masterGainDB, 0),
            savedAt: container.lenient(Date.self, .savedAt, Date(timeIntervalSince1970: 0)),
            laneExtras: container.lenient([String: [String: Data]].self, .laneExtras, [:]),
            masterExtras: container.lenient([String: Data].self, .masterExtras, [:])
        )
    }

    // MARK: - JSON

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func jsonData() throws -> Data {
        var data = try SessionDocument.makeEncoder().encode(self)
        data.append(0x0A)  // trailing newline, so the file is `cat`-friendly
        return data
    }

    public static func decode(_ data: Data) throws -> SessionDocument {
        try makeDecoder().decode(SessionDocument.self, from: data)
    }
}

/// Decodes `T` or nothing, without failing the array it sits in.
///
/// The wrapper itself never throws, so the unkeyed container always advances
/// and one broken lane cannot swallow the lanes after it.
struct LenientlyDecoded<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// A missing key, an explicit `null`, or a value of the wrong type all
    /// yield `nil` rather than failing the whole document.
    func lenientOptional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)).flatMap { $0 }
    }

    func lenient<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T) -> T {
        lenientOptional(type, key) ?? fallback
    }
}
