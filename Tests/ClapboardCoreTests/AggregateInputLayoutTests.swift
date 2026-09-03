import ClapboardCore
import Testing

@Suite("AggregateInputLayout")
struct AggregateInputLayoutTests {
    // DJI receiver (stereo, one stream), a mono USB mic, a Loopback device
    // exposing two stereo streams, and an output-only device contributing no
    // input streams.
    private let layout = AggregateInputLayout(subDevices: [
        SubDeviceInputLayout(deviceUID: "dji", streamChannelCounts: [2]),
        SubDeviceInputLayout(deviceUID: "mono", streamChannelCounts: [1]),
        SubDeviceInputLayout(deviceUID: "loopback", streamChannelCounts: [2, 2]),
        SubDeviceInputLayout(deviceUID: "speakers", streamChannelCounts: [])
    ])

    @Test func concatenatesStreamsInSubDeviceOrder() {
        #expect(layout.totalChannels == 7)
        #expect(layout.bufferCount == 4)
        #expect(layout.slots.map(\.bufferIndex) == [0, 1, 2, 3])
        #expect(layout.slots.map(\.firstGlobalChannel) == [0, 2, 3, 5])
        #expect(layout.slots.map(\.deviceUID) == ["dji", "mono", "loopback", "loopback"])
    }

    @Test func deviceRangesSpanAllOfItsStreams() {
        #expect(layout.globalChannels(forDeviceUID: "dji") == 0..<2)
        #expect(layout.globalChannels(forDeviceUID: "mono") == 2..<3)
        #expect(layout.globalChannels(forDeviceUID: "loopback") == 3..<7)
        #expect(layout.globalChannels(forDeviceUID: "speakers") == nil)
        #expect(layout.globalChannels(forDeviceUID: "missing") == nil)
    }

    @Test func mapsDeviceLocalChannelsToGlobalIndices() {
        #expect(layout.globalChannel(deviceUID: "dji", deviceChannel: 1) == 1)
        #expect(layout.globalChannel(deviceUID: "loopback", deviceChannel: 3) == 6)
        #expect(layout.globalChannel(deviceUID: "loopback", deviceChannel: 4) == nil)
        #expect(layout.globalChannel(deviceUID: "mono", deviceChannel: -1) == nil)
    }

    @Test func locatesGlobalChannelsInsideIOProcBuffers() {
        #expect(layout.locate(globalChannel: 0)! == (0, 0))
        #expect(layout.locate(globalChannel: 1)! == (0, 1))
        #expect(layout.locate(globalChannel: 2)! == (1, 0))
        #expect(layout.locate(globalChannel: 4)! == (2, 1))
        #expect(layout.locate(globalChannel: 6)! == (3, 1))
        #expect(layout.locate(globalChannel: 7) == nil)
        #expect(layout.locate(globalChannel: -1) == nil)
    }

    @Test func emptyLayoutHasNoChannels() {
        let empty = AggregateInputLayout(subDevices: [])
        #expect(empty.totalChannels == 0)
        #expect(empty.bufferCount == 0)
        #expect(empty.locate(globalChannel: 0) == nil)
    }
}
