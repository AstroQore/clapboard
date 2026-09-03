import Foundation

/// Plug-in delay compensation across the whole routing tree.
///
/// The rule is one sentence: **every input of a bus is delayed until they all
/// arrive together**, and that is applied bottom-up, so two microphones with
/// very different plug-in chains still line up after they have been through
/// two different buses and a parent.
///
/// Per bus:
///
/// ```
/// inputAlign(bus) = max( laneChain(L) for every lane L feeding it,
///                        subtree(C)   for every child bus C feeding it )
/// subtree(bus)    = busChain(bus) + inputAlign(bus)
/// lanePDC(L)      = inputAlign(bus(L)) − laneChain(L)
/// busPDC(C)       = inputAlign(parent(C)) − subtree(C)
/// ```
///
/// `docs/ROUTING.md` states the bus half as "siblings aligned to the slowest
/// subtree", which is the same number whenever a bus is fed only by buses.
/// The form above additionally aligns a bus's *lanes* against its *child
/// buses* — the case the document does not spell out — because otherwise a
/// lane plugged straight into a bus that also carries a slow sub-mix would
/// arrive early, which is exactly the misalignment Auto Sync exists to
/// prevent.
///
/// Root buses are not compensated against each other: they are different
/// destinations, and delaying one to match another would only add latency
/// nobody hears. Roots that write to the *same* device are the exception —
/// they are one destination, so they are aligned like siblings.
///
/// Pure arithmetic over a `RoutingGraph`; no engine, no plug-ins, no render
/// thread.
public struct LatencyPlan: Sendable, Equatable {
    /// Extra delay each lane needs, on top of its manual / Auto Sync delay.
    public let laneCompensation: [UUID: Int]
    /// Delay each bus applies before its own effects.
    public let busCompensation: [UUID: Int]
    /// `busChain + inputAlign`: what the whole subtree under a bus costs,
    /// measured at the bus's output and excluding its own compensation.
    public let subtreeLatency: [UUID: Int]
    /// The latency every input of a bus is lined up to.
    public let inputAlignment: [UUID: Int]
    /// End-to-end latency at each output device, in samples.
    public let outputLatency: [String: Int]
    /// Strips whose compensation had to be clipped to the delay line's
    /// capacity, and which are therefore no longer aligned.
    public let clamped: Set<UUID>

    public static let empty = LatencyPlan(
        laneCompensation: [:], busCompensation: [:], subtreeLatency: [:],
        inputAlignment: [:], outputLatency: [:], clamped: []
    )

    /// - Parameters:
    ///   - laneChainLatency: samples each lane's effect chain adds. A lane
    ///     that is missing from the map contributes nothing.
    ///   - busChainLatency: the same for each bus's chain.
    public static func compute(
        graph: RoutingGraph,
        laneChainLatency: [UUID: Int],
        busChainLatency: [UUID: Int]
    ) -> LatencyPlan {
        var inputAlignment: [UUID: Int] = [:]
        var subtree: [UUID: Int] = [:]

        // `graph.order` puts every child before its parent, so one pass is
        // enough — a bus's children are already resolved when it comes up.
        for busID in graph.order {
            var align = 0
            for laneID in graph.laneInputs[busID] ?? [] {
                align = max(align, laneChainLatency[laneID] ?? 0)
            }
            for childID in graph.busInputs[busID] ?? [] {
                align = max(align, subtree[childID] ?? 0)
            }
            inputAlignment[busID] = align
            subtree[busID] = align + max(0, busChainLatency[busID] ?? 0)
        }

        var clamped = Set<UUID>()
        func bounded(_ id: UUID, _ samples: Int) -> Int {
            let value = max(0, samples)
            if value > RTLimits.maxDelaySamples {
                clamped.insert(id)
                return RTLimits.maxDelaySamples
            }
            return value
        }

        var laneCompensation: [UUID: Int] = [:]
        for (busID, laneIDs) in graph.laneInputs {
            let align = inputAlignment[busID] ?? 0
            for laneID in laneIDs {
                laneCompensation[laneID] = bounded(laneID, align - (laneChainLatency[laneID] ?? 0))
            }
        }

        // Roots that share an output device are one destination, so they are
        // aligned to the slowest of them; roots that do not are left alone.
        var rootTargets: [String: Int] = [:]
        for busID in graph.roots {
            guard let send = graph.outputSends.first(where: { $0.busID == busID }) else { continue }
            rootTargets[send.deviceUID] = max(rootTargets[send.deviceUID] ?? 0, subtree[busID] ?? 0)
        }

        var busCompensation: [UUID: Int] = [:]
        for busID in graph.order {
            let own = subtree[busID] ?? 0
            if let parentID = graph.parent[busID] {
                busCompensation[busID] = bounded(busID, (inputAlignment[parentID] ?? 0) - own)
            } else if let send = graph.outputSends.first(where: { $0.busID == busID }),
                      let target = rootTargets[send.deviceUID] {
                busCompensation[busID] = bounded(busID, target - own)
            } else {
                busCompensation[busID] = 0
            }
        }

        var outputLatency: [String: Int] = [:]
        for send in graph.outputSends {
            let total = (busCompensation[send.busID] ?? 0) + (subtree[send.busID] ?? 0)
            outputLatency[send.deviceUID] = max(outputLatency[send.deviceUID] ?? 0, total)
        }

        return LatencyPlan(
            laneCompensation: laneCompensation,
            busCompensation: busCompensation,
            subtreeLatency: subtree,
            inputAlignment: inputAlignment,
            outputLatency: outputLatency,
            clamped: clamped
        )
    }

    /// Latency from a lane's input to the output of `bus`, following the
    /// parents. Excludes the lane's manual delay, which is alignment of the
    /// physical world rather than of the plug-ins.
    ///
    /// The point of the whole type is that this is the same number for every
    /// lane that reaches a given bus, which is what the tests assert.
    public func totalLatency(
        forLane laneID: UUID, to busID: UUID, graph: RoutingGraph, laneChainLatency: [UUID: Int]
    ) -> Int? {
        guard var current = graph.laneDestination[laneID] else { return nil }
        var total = (laneChainLatency[laneID] ?? 0) + (laneCompensation[laneID] ?? 0)
        while true {
            total += (busCompensation[current] ?? 0)
            total += (subtreeLatency[current] ?? 0) - (inputAlignment[current] ?? 0)
            if current == busID { return total }
            guard let next = graph.parent[current] else { return nil }
            current = next
        }
    }
}
