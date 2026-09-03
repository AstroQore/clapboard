import Foundation

/// One effect in a lane's chain — or the master's — as the UI and the session
/// file see it.
///
/// The plug-in itself is an `AUEffectInstance` the engine owns; this is the
/// value that names it, remembers whether it is bypassed, and carries its
/// saved state. `id` is Clapboard's, not the plug-in's: the same plug-in can
/// appear twice in one chain, and the session file has to be able to tell the
/// two apart across a relaunch.
public struct EffectConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// `AUComponentInfo.id` — "aufx.dely.appl". The only stable identity an
    /// Audio Unit has, and what a restored session looks the plug-in up by.
    public var componentID: String
    public var bypass: Bool
    /// Cached at insertion so a chain whose plug-in has since been
    /// uninstalled still has something legible to show.
    public var displayName: String
    /// `AUAudioUnit.fullState` as a binary property list.
    ///
    /// Only populated on the way into a session file and on a placeholder:
    /// while the plug-in is loaded, the instance is the truth and this is
    /// stale. Keeping it on a placeholder is what lets a session that was
    /// opened on a machine without the plug-in be saved again without
    /// throwing the plug-in's settings away.
    public var fullState: Data?
    /// Why this entry is not running: the component is not installed, or
    /// macOS would only host it out of process. `nil` means it is live.
    ///
    /// Not persisted — it is a fact about this machine right now, and the
    /// same file on another machine may load the plug-in perfectly well.
    public var unavailableReason: String?

    public init(
        id: UUID = UUID(),
        componentID: String,
        bypass: Bool = false,
        displayName: String,
        fullState: Data? = nil,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.componentID = componentID
        self.bypass = bypass
        self.displayName = displayName
        self.fullState = fullState
        self.unavailableReason = unavailableReason
    }

    public var isAvailable: Bool { unavailableReason == nil }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case id, componentID, bypass, displayName, fullState
    }

    /// As tolerant as the rest of the session format: only `componentID` is
    /// required, and an entry with a state blob this build cannot decode is
    /// still restored — without its state — rather than dropped.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let componentID = try container.decode(String.self, forKey: .componentID)
        self.init(
            id: container.lenient(UUID.self, .id, UUID()),
            componentID: componentID,
            bypass: container.lenient(Bool.self, .bypass, false),
            displayName: container.lenient(String.self, .displayName, componentID),
            fullState: container.lenientOptional(Data.self, .fullState)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(componentID, forKey: .componentID)
        try container.encode(bypass, forKey: .bypass)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(fullState, forKey: .fullState)
    }
}

/// How a chain travels through `SessionDocument.laneExtras` / `masterExtras`.
///
/// The extras bags hold `Data`, so a chain is a JSON array encoded into one
/// value under the key `effects`. `Data` inside it — the plug-in states —
/// becomes base64, which is exactly what the session file wants: a plug-in's
/// state is routinely hundreds of kilobytes of binary coefficients.
public enum EffectChainCodec {
    public static let extrasKey = "effects"

    public static func encode(_ chain: [EffectConfig]) throws -> Data {
        try JSONEncoder().encode(chain)
    }

    /// A bag entry that does not decode yields an empty chain rather than
    /// failing the session: one unreadable chain must not cost the user their
    /// lanes.
    public static func decode(_ data: Data?) -> [EffectConfig] {
        guard let data, !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([EffectConfig].self, from: data)) ?? []
    }
}
