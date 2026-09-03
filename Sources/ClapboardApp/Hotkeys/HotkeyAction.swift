import ClapboardCore
import Foundation

/// What a hotkey does.
///
/// Encoded as `{"kind": "...", "laneID": "..."}` rather than as Swift's
/// default enum representation, because this file is going to gain cases (the
/// bus and solo ones below) and lose none: a tagged object survives that,
/// where the default `{"toggleLaneMute": {"_0": …}}` shape does not read well
/// when a user opens the file to fix a lane id by hand.
enum HotkeyAction: Codable, Hashable, Sendable {
    /// Flip one lane between live and muted.
    case toggleLaneMute(laneID: UUID)
    /// Silence everything, remembering what was live.
    case muteAllLanes
    /// Put back the set that was live before the last mute.
    case unmuteAllLanes
    /// 闭麦 / 开麦 on one key: mute while anything is live, otherwise restore.
    case toggleAllLanes

    // Reserved. The bus routing model does not exist yet, and solo is defined
    // against it (soloing a lane mutes every *other* lane on the same bus), so
    // both are decoded and displayed but never registered or dispatched. A
    // session written by a future build must survive a round-trip through this
    // one, which is why they are here rather than absent.
    case toggleBusMute(busID: UUID)
    case toggleLaneSolo(laneID: UUID)

    /// `false` for the reserved cases: the settings sheet greys them out and
    /// the manager refuses to register them.
    var isImplemented: Bool {
        switch self {
        case .toggleLaneMute, .muteAllLanes, .unmuteAllLanes, .toggleAllLanes:
            return true
        case .toggleBusMute, .toggleLaneSolo:
            return false
        }
    }

    /// Actions that are not tied to one lane, in the order the settings sheet
    /// and the menu show them.
    static let globalActions: [HotkeyAction] = [.toggleAllLanes, .muteAllLanes, .unmuteAllLanes]

    var laneID: UUID? {
        switch self {
        case .toggleLaneMute(let id), .toggleLaneSolo(let id): return id
        default: return nil
        }
    }

    /// A label that does not need the mixer to make sense.
    var title: String {
        switch self {
        case .toggleAllLanes: return "Toggle all microphones"
        case .muteAllLanes: return "Mute all microphones"
        case .unmuteAllLanes: return "Unmute all microphones"
        case .toggleLaneMute: return "Toggle lane"
        case .toggleLaneSolo: return "Solo lane"
        case .toggleBusMute: return "Toggle bus"
        }
    }

    /// The same label with the lane's current name filled in, for the settings
    /// list and the menu bar. A lane that has been deleted keeps its row —
    /// silently dropping the binding would be worse than showing it as stale.
    func title(lanes: [LaneConfig]) -> String {
        switch self {
        case .toggleLaneMute(let id):
            return "Toggle \(laneName(id, in: lanes))"
        case .toggleLaneSolo(let id):
            return "Solo \(laneName(id, in: lanes))"
        case .toggleBusMute:
            return "Toggle bus"
        default:
            return title
        }
    }

    private func laneName(_ id: UUID, in lanes: [LaneConfig]) -> String {
        lanes.first { $0.id == id }?.name ?? "missing lane"
    }

    /// Shown beside the reserved cases.
    var unavailableNote: String? {
        switch self {
        case .toggleBusMute: return "coming soon — needs the bus routing model"
        case .toggleLaneSolo: return "coming soon — solo is defined against buses"
        default: return nil
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind, laneID, busID
    }

    private enum Kind: String, Codable {
        case toggleLaneMute, muteAllLanes, unmuteAllLanes, toggleAllLanes
        case toggleBusMute, toggleLaneSolo
    }

    /// Thrown for a `kind` this build has never heard of. `HotkeyStore` drops
    /// the entry and keeps the rest of the file.
    struct UnknownKind: Error, CustomStringConvertible {
        let kind: String
        var description: String { "unknown hotkey action \"\(kind)\"" }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: raw) else { throw UnknownKind(kind: raw) }
        switch kind {
        case .muteAllLanes: self = .muteAllLanes
        case .unmuteAllLanes: self = .unmuteAllLanes
        case .toggleAllLanes: self = .toggleAllLanes
        case .toggleLaneMute: self = .toggleLaneMute(laneID: try container.decode(UUID.self, forKey: .laneID))
        case .toggleLaneSolo: self = .toggleLaneSolo(laneID: try container.decode(UUID.self, forKey: .laneID))
        case .toggleBusMute: self = .toggleBusMute(busID: try container.decode(UUID.self, forKey: .busID))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .muteAllLanes:
            try container.encode(Kind.muteAllLanes.rawValue, forKey: .kind)
        case .unmuteAllLanes:
            try container.encode(Kind.unmuteAllLanes.rawValue, forKey: .kind)
        case .toggleAllLanes:
            try container.encode(Kind.toggleAllLanes.rawValue, forKey: .kind)
        case .toggleLaneMute(let id):
            try container.encode(Kind.toggleLaneMute.rawValue, forKey: .kind)
            try container.encode(id, forKey: .laneID)
        case .toggleLaneSolo(let id):
            try container.encode(Kind.toggleLaneSolo.rawValue, forKey: .kind)
            try container.encode(id, forKey: .laneID)
        case .toggleBusMute(let id):
            try container.encode(Kind.toggleBusMute.rawValue, forKey: .kind)
            try container.encode(id, forKey: .busID)
        }
    }
}

/// One row of `hotkeys.json`: an action and the key that fires it.
struct HotkeyEntry: Codable, Hashable, Sendable, Identifiable {
    var action: HotkeyAction
    /// `nil` means "listed but not bound" — the settings sheet keeps the row
    /// so the user can record a key into it.
    var binding: KeyBinding?

    var id: HotkeyAction { action }

    init(action: HotkeyAction, binding: KeyBinding?) {
        self.action = action
        self.binding = binding
    }
}
