import Foundation

/// Which strip an effect chain belongs to.
///
/// Every strip in the console — lane or bus — owns a chain, and every chain is
/// edited through the same six calls (`addEffect(_:to:)`, `removeEffect(id:)`,
/// `moveEffect(id:to:)`, `setEffectBypass(id:_:)`, `effects(for:)`,
/// `openEffectWindow(id:)`). This is the one thing those calls need to know
/// that an effect id cannot tell them: where a *new* effect goes.
///
/// It replaces the older `toLane laneID: UUID?` convention, where `nil` meant
/// "the master bus" and no other bus could be named at all. `AudioEngine` keeps
/// the old spelling as a thin shim (`nil` maps to `.bus(masterBusID)`), so
/// callers written against the single-master API keep working unchanged.
///
/// The distinction is not cosmetic: a lane's plug-ins are instantiated for the
/// lane's own channel count (a mono microphone stays mono through its chain),
/// while a bus is always stereo, and the two chains live in different places —
/// `AudioEngine.laneEffects` for a lane, `BusConfig.effects` for a bus.
public enum EffectTarget: Hashable, Sendable {
    case lane(UUID)
    case bus(UUID)

    /// The strip's id, whichever kind it is. Useful for diagnostics; it is not
    /// enough to address a chain, because a lane and a bus could in principle
    /// carry the same id.
    public var stripID: UUID {
        switch self {
        case .lane(let id), .bus(let id): return id
        }
    }

    public var isLane: Bool {
        if case .lane = self { return true }
        return false
    }

    public var isBus: Bool { !isLane }
}
