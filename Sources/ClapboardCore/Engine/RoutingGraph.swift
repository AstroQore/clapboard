import Foundation

/// Why a set of lanes and buses is not a graph the engine can run.
public enum RoutingError: Error, CustomStringConvertible, Equatable, Sendable {
    /// A strip points at a bus that is not in the mixer.
    case unknownDestination(strip: String, busID: UUID)
    /// Following `destinationBus` came back to where it started. The path is
    /// spelled out with names, in the order it was walked.
    case cycle(path: [String])
    /// A lane with no destination at all — only possible from a hand-edited
    /// file, since the engine assigns one when the lane is added.
    case unrouted(strip: String)
    case noBuses

    public var description: String {
        switch self {
        case .unknownDestination(let strip, let busID):
            return "\(strip) is routed to a bus that no longer exists (\(busID.uuidString))."
        case .cycle(let path):
            return "Routing loop: \(path.joined(separator: " → "))."
        case .unrouted(let strip):
            return "\(strip) is not routed to a bus."
        case .noBuses:
            return "There are no buses; every mixer has at least one."
        }
    }
}

/// The validated routing tree: which lanes feed which bus, which buses feed
/// which parent, the order the render thread must process them in, and where
/// the whole thing comes out.
///
/// Pure and value-typed on purpose — no engine, no Core Audio, no render
/// thread — so the rules that decide whether a mix is even legal can be tested
/// on their own. `AudioEngine` rebuilds one on every topology edit and refuses
/// the edit if it does not build.
public struct RoutingGraph: Sendable, Equatable {
    /// Bus ids in processing order: every bus appears before the bus it feeds.
    public let order: [UUID]
    /// Position of a bus inside `order`, which is also the index the render
    /// graph uses.
    public let index: [UUID: Int]
    /// Parent of each bus. A bus missing from this map is a root.
    public let parent: [UUID: UUID]
    /// Lanes feeding each bus, in lane order.
    public let laneInputs: [UUID: [UUID]]
    /// Child buses feeding each bus, in bus order.
    public let busInputs: [UUID: [UUID]]
    /// The bus each lane sums into.
    public let laneDestination: [UUID: UUID]
    /// Output devices the mix actually reaches, in bus order and deduplicated.
    /// The first one becomes the aggregate device's clock main.
    public let outputDeviceUIDs: [String]
    /// Every device send: which bus writes to which device, at what offset.
    public let outputSends: [OutputSend]

    public struct OutputSend: Hashable, Sendable {
        public let busID: UUID
        public let deviceUID: String
        public let channelOffset: Int
    }

    // MARK: - Building

    /// - Throws: `RoutingError` when a strip points at a bus that is not
    ///   there, or when the bus graph contains a loop.
    public static func build(lanes: [LaneConfig], buses: [BusConfig]) throws -> RoutingGraph {
        guard !buses.isEmpty else { throw RoutingError.noBuses }
        let known = Set(buses.map(\.id))
        var names: [UUID: String] = [:]
        for bus in buses { names[bus.id] = bus.name }

        var parent: [UUID: UUID] = [:]
        var busInputs: [UUID: [UUID]] = [:]
        for bus in buses {
            guard let destination = bus.destinationBus else { continue }
            guard known.contains(destination) else {
                throw RoutingError.unknownDestination(strip: bus.name, busID: destination)
            }
            parent[bus.id] = destination
            busInputs[destination, default: []].append(bus.id)
        }

        var laneDestination: [UUID: UUID] = [:]
        var laneInputs: [UUID: [UUID]] = [:]
        for lane in lanes {
            guard let destination = lane.destinationBus else {
                throw RoutingError.unrouted(strip: lane.name)
            }
            guard known.contains(destination) else {
                throw RoutingError.unknownDestination(strip: lane.name, busID: destination)
            }
            laneDestination[lane.id] = destination
            laneInputs[destination, default: []].append(lane.id)
        }

        let order = try topologicalOrder(buses: buses, parent: parent, busInputs: busInputs, names: names)
        var index: [UUID: Int] = [:]
        for (position, id) in order.enumerated() { index[id] = position }

        var seenDevices = Set<String>()
        var deviceUIDs: [String] = []
        var sends: [OutputSend] = []
        for bus in buses {
            guard let uid = bus.outputDeviceUID else { continue }
            sends.append(OutputSend(busID: bus.id, deviceUID: uid, channelOffset: bus.outputChannelOffset))
            if seenDevices.insert(uid).inserted { deviceUIDs.append(uid) }
        }

        return RoutingGraph(
            order: order,
            index: index,
            parent: parent,
            laneInputs: laneInputs,
            busInputs: busInputs,
            laneDestination: laneDestination,
            outputDeviceUIDs: deviceUIDs,
            outputSends: sends
        )
    }

    /// Children before parents, by depth-first search over the *input* edges.
    ///
    /// A cycle is not reachable from any root, so anything left unvisited at
    /// the end is either in a loop or feeding one; walking `destinationBus`
    /// from such a bus is guaranteed to come back to a bus already on the
    /// path, and that is the path the error names.
    private static func topologicalOrder(
        buses: [BusConfig],
        parent: [UUID: UUID],
        busInputs: [UUID: [UUID]],
        names: [UUID: String]
    ) throws -> [UUID] {
        var order: [UUID] = []
        order.reserveCapacity(buses.count)
        var visited = Set<UUID>()
        // Explicit stack: a deep chain of buses must not be able to blow the
        // main thread's stack from a hand-edited session file.
        for bus in buses where parent[bus.id] == nil {
            var stack: [(id: UUID, childIndex: Int)] = [(bus.id, 0)]
            visited.insert(bus.id)
            while var frame = stack.popLast() {
                let children = busInputs[frame.id] ?? []
                if frame.childIndex < children.count {
                    let child = children[frame.childIndex]
                    frame.childIndex += 1
                    stack.append(frame)
                    if visited.insert(child).inserted {
                        stack.append((child, 0))
                    }
                } else {
                    order.append(frame.id)
                }
            }
        }
        guard order.count == buses.count else {
            let stranded = buses.first { !visited.contains($0.id) }!
            throw RoutingError.cycle(path: cyclePath(from: stranded.id, parent: parent, names: names))
        }
        return order
    }

    /// Walks `destinationBus` until a bus repeats, then returns the loop
    /// itself — closed, so it reads `A → B → A`.
    private static func cyclePath(
        from start: UUID, parent: [UUID: UUID], names: [UUID: String]
    ) -> [String] {
        var walked: [UUID] = []
        var seen = Set<UUID>()
        var current = start
        while seen.insert(current).inserted {
            walked.append(current)
            guard let next = parent[current] else { break }
            current = next
        }
        let loopStart = walked.firstIndex(of: current) ?? 0
        let loop = Array(walked[loopStart...]) + [current]
        return loop.map { names[$0] ?? $0.uuidString }
    }

    // MARK: - Queries

    public var busCount: Int { order.count }

    public func isRoot(_ busID: UUID) -> Bool { parent[busID] == nil }

    /// The buses a solo on `busID` is scoped to: everything sharing its
    /// parent, or every root bus when it has none. Includes `busID` itself.
    public func siblings(of busID: UUID) -> [UUID] {
        guard let parentID = parent[busID] else { return roots }
        return busInputs[parentID] ?? [busID]
    }

    public var roots: [UUID] {
        order.filter { parent[$0] == nil }
    }

    /// Sibling sets, each in bus order: one per parent plus the root set.
    /// Every bus appears in exactly one of them.
    public var siblingSets: [[UUID]] {
        var sets: [[UUID]] = []
        let rootSet = roots
        if !rootSet.isEmpty { sets.append(rootSet) }
        for busID in order {
            if let children = busInputs[busID], !children.isEmpty { sets.append(children) }
        }
        return sets
    }

    /// Would pointing `busID` at `newParent` close a loop? Used by
    /// `AudioEngine.setBusDestination` to refuse the edit before it is made.
    public static func wouldCreateCycle(
        busID: UUID, newParent: UUID?, buses: [BusConfig]
    ) -> Bool {
        guard let newParent else { return false }
        if newParent == busID { return true }
        var parent: [UUID: UUID] = [:]
        for bus in buses where bus.id != busID {
            parent[bus.id] = bus.destinationBus
        }
        var current: UUID? = newParent
        var seen = Set<UUID>([busID])
        while let node = current {
            guard seen.insert(node).inserted else { return true }
            current = parent[node]
        }
        return false
    }
}
