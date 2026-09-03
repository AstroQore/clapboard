import Foundation

/// The input streams one sub-device contributes to an aggregate device, in
/// stream order. Built from `AudioDeviceInfo.inputStreamChannels`.
public struct SubDeviceInputLayout: Hashable, Sendable {
    public let deviceUID: String
    public let streamChannelCounts: [Int]

    public init(deviceUID: String, streamChannelCounts: [Int]) {
        self.deviceUID = deviceUID
        self.streamChannelCounts = streamChannelCounts
    }

    public var totalChannels: Int { streamChannelCounts.reduce(0, +) }
}

/// Where each sub-device's input channels land in the aggregate device's
/// input `AudioBufferList`.
///
/// The HAL lays out an aggregate's input as the concatenation of every
/// sub-device's input streams, in sub-device order, one `AudioBuffer` per
/// stream with the stream's channels interleaved inside that buffer. This
/// type does that arithmetic once so the real-time path can index buffers
/// with plain integers.
public struct AggregateInputLayout: Hashable, Sendable {
    public struct Slot: Hashable, Sendable {
        public let deviceUID: String
        /// Index of this stream's buffer inside the IOProc input list.
        public let bufferIndex: Int
        public let channelCount: Int
        /// Aggregate-wide index of this stream's first channel.
        public let firstGlobalChannel: Int

        public var globalChannels: Range<Int> {
            firstGlobalChannel..<(firstGlobalChannel + channelCount)
        }
    }

    public let slots: [Slot]
    public let totalChannels: Int

    public init(subDevices: [SubDeviceInputLayout]) {
        var slots: [Slot] = []
        var bufferIndex = 0
        var globalChannel = 0
        for device in subDevices {
            for count in device.streamChannelCounts where count > 0 {
                slots.append(Slot(
                    deviceUID: device.deviceUID,
                    bufferIndex: bufferIndex,
                    channelCount: count,
                    firstGlobalChannel: globalChannel
                ))
                bufferIndex += 1
                globalChannel += count
            }
        }
        self.slots = slots
        self.totalChannels = globalChannel
    }

    public var bufferCount: Int { slots.count }

    /// Aggregate-wide channel range owned by a sub-device, or nil if the
    /// device contributes no input.
    public func globalChannels(forDeviceUID uid: String) -> Range<Int>? {
        let owned = slots.filter { $0.deviceUID == uid }
        guard let first = owned.first, let last = owned.last else { return nil }
        return first.firstGlobalChannel..<(last.firstGlobalChannel + last.channelCount)
    }

    /// Maps a channel index local to a sub-device (0-based, across all of its
    /// input streams) to the aggregate-wide channel index.
    public func globalChannel(deviceUID uid: String, deviceChannel: Int) -> Int? {
        guard deviceChannel >= 0, let range = globalChannels(forDeviceUID: uid) else { return nil }
        let candidate = range.lowerBound + deviceChannel
        return range.contains(candidate) ? candidate : nil
    }

    /// Locates an aggregate-wide channel in the IOProc input list.
    public func locate(globalChannel: Int) -> (bufferIndex: Int, channel: Int)? {
        guard globalChannel >= 0, globalChannel < totalChannels else { return nil }
        guard let slot = slots.last(where: { $0.firstGlobalChannel <= globalChannel }) else { return nil }
        return (slot.bufferIndex, globalChannel - slot.firstGlobalChannel)
    }
}

// The arithmetic above is scope-agnostic: an aggregate's *output* buffer list
// is laid out the same way, one buffer per sub-device output stream in
// sub-device order. `AggregateDevice` builds both scopes from these types, so
// these aliases give the output side a name that is not a lie.
public typealias SubDeviceStreamLayout = SubDeviceInputLayout
public typealias AggregateStreamLayout = AggregateInputLayout
