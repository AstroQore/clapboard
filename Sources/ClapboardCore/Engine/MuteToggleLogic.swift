import Foundation

/// The arithmetic behind "mute everything" and "give me back what I had".
///
/// One key has to serve both halves of 闭麦 / 开麦, so muting cannot simply set
/// every lane to off and unmuting cannot simply set every lane to on: a
/// streamer who keeps a music lane deliberately muted expects it to stay muted
/// when the microphones come back. The rule is therefore *remember and
/// restore* — muting records the set that was live, unmuting replays it.
///
/// This is deliberately free of the engine, of AppKit and of the hotkey layer:
/// it takes lanes and a remembered set, and returns the enabled map to apply.
/// The caller writes it through `AudioEngine.setLaneEnabled`.
public enum MuteToggleLogic {
    /// What a mute/unmute decision comes to.
    public struct Outcome: Equatable, Sendable {
        /// The state every current lane should end up in. Complete: a lane
        /// missing from here would be a bug, not "leave it alone".
        public var enabled: [UUID: Bool]
        /// The set to hand back to the next call. Muting fills it, unmuting
        /// empties it.
        public var remembered: Set<UUID>
        /// `true` when this call silenced the lanes, `false` when it restored
        /// them. Drives the menu-bar icon and the UI flash.
        public var didMute: Bool

        public init(enabled: [UUID: Bool], remembered: Set<UUID>, didMute: Bool) {
            self.enabled = enabled
            self.remembered = remembered
            self.didMute = didMute
        }

        /// Only the lanes whose state actually changes, so a caller can avoid
        /// touching the engine — and the session file — for a no-op.
        public func changes(from lanes: [LaneConfig]) -> [UUID: Bool] {
            var result: [UUID: Bool] = [:]
            for lane in lanes where enabled[lane.id] != lane.enabled {
                if let wanted = enabled[lane.id] { result[lane.id] = wanted }
            }
            return result
        }
    }

    /// `true` when at least one lane is live, i.e. when "toggle" means "mute".
    public static func anyEnabled(_ lanes: [LaneConfig]) -> Bool {
        lanes.contains { $0.enabled }
    }

    /// Silences every lane, remembering the ones that were live.
    ///
    /// Muting an already-silent mixer keeps the previous memory rather than
    /// overwriting it with the empty set: two panicked presses of the mute key
    /// must not cost the user the state they are about to restore.
    public static func muteAll(lanes: [LaneConfig], remembered: Set<UUID>) -> Outcome {
        let live = Set(lanes.filter(\.enabled).map(\.id))
        return Outcome(
            enabled: Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, false) }),
            remembered: live.isEmpty ? remembered : live,
            didMute: true
        )
    }

    /// Puts back the set that was live before the last mute.
    ///
    /// The remembered set wins when any of it still exists. When nothing was
    /// remembered — a cold start, or every remembered lane has since been
    /// removed — every lane is enabled, because a user pressing 开麦 wants
    /// sound, not a correctly empty mixer.
    public static func restore(lanes: [LaneConfig], remembered: Set<UUID>) -> Outcome {
        let present = Set(lanes.map(\.id))
        let restorable = remembered.intersection(present)
        let enabled: [UUID: Bool]
        if restorable.isEmpty {
            enabled = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, true) })
        } else {
            enabled = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, restorable.contains($0.id)) })
        }
        return Outcome(enabled: enabled, remembered: [], didMute: false)
    }

    /// Turns on *every* lane, deliberately ignoring the remembered set.
    ///
    /// This is the difference between 开麦 and "unmute all": the toggle key
    /// gives you back what you had, but a control labelled "unmute all" that
    /// left a lane silent would be lying, and it is the escape hatch a user
    /// reaches for when they no longer trust the state they are in.
    public static func unmuteAll(lanes: [LaneConfig]) -> Outcome {
        Outcome(
            enabled: Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, true) }),
            remembered: [],
            didMute: false
        )
    }

    /// One key for both directions: mute while anything is live, otherwise put
    /// back what was live before.
    public static func toggleAll(lanes: [LaneConfig], remembered: Set<UUID>) -> Outcome {
        anyEnabled(lanes)
            ? muteAll(lanes: lanes, remembered: remembered)
            : restore(lanes: lanes, remembered: remembered)
    }
}
