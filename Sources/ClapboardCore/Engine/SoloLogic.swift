import Foundation

/// Turns mute and solo flags into the single "is this strip audible" bit the
/// render thread reads.
///
/// Solo is *scoped*, which is the whole reason this is a type of its own:
/// soloing a lane silences the other lanes feeding the same bus and nothing
/// else, and soloing a bus silences its siblings — the buses sharing its
/// parent, or every root bus when it has none. A solo never reaches upstream
/// or downstream of the strip it is on, so soloing a lane does not mute the
/// bus it feeds and soloing a bus does not mute the lanes inside it.
///
/// Pure and value-typed: `AudioEngine` runs it on the main thread whenever a
/// mute, a solo or a route changes, and pushes the result into the existing
/// per-strip `enabled` atomics.
public enum SoloLogic {
    /// One strip as this computation sees it, independent of whether it is a
    /// lane or a bus.
    public struct Strip<Scope: Hashable & Sendable>: Hashable, Sendable {
        public var id: UUID
        public var muted: Bool
        public var solo: Bool
        /// Everything sharing a scope competes for the same solo.
        public var scope: Scope

        public init(id: UUID, muted: Bool, solo: Bool, scope: Scope) {
            self.id = id
            self.muted = muted
            self.solo = solo
            self.scope = scope
        }
    }

    /// `!muted && (nothing in this scope is soloed || this strip is soloed)`.
    public static func effectiveEnabled<Scope>(_ strips: [Strip<Scope>]) -> [UUID: Bool] {
        var soloedScopes = Set<Scope>()
        for strip in strips where strip.solo { soloedScopes.insert(strip.scope) }
        var result: [UUID: Bool] = [:]
        result.reserveCapacity(strips.count)
        for strip in strips {
            let scopeHasSolo = soloedScopes.contains(strip.scope)
            result[strip.id] = !strip.muted && (!scopeHasSolo || strip.solo)
        }
        return result
    }

    /// The engine's shape of the question: every lane scoped by its
    /// destination bus, every bus scoped by its parent (`nil` = the root set).
    public static func effectiveEnabled(
        lanes: [LaneConfig], buses: [BusConfig], graph: RoutingGraph
    ) -> (lanes: [UUID: Bool], buses: [UUID: Bool]) {
        let laneStrips = lanes.compactMap { lane -> Strip<UUID>? in
            guard let destination = graph.laneDestination[lane.id] else { return nil }
            return Strip(id: lane.id, muted: lane.muted, solo: lane.solo, scope: destination)
        }
        let busStrips = buses.map {
            Strip(id: $0.id, muted: $0.muted, solo: $0.solo, scope: graph.parent[$0.id])
        }
        return (effectiveEnabled(laneStrips), effectiveEnabled(busStrips))
    }
}
