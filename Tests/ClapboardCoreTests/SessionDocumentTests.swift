import ClapboardCore
import Foundation
import Testing

@Suite("SessionDocument")
struct SessionDocumentTests {
    private func sample() -> SessionDocument {
        SessionDocument(
            lanes: [
                LaneConfig(
                    deviceUID: "AppleUSBAudioEngine:DJI:Mic:1", deviceChannels: [0],
                    name: "DJI TX1", gainDB: -3.5, enabled: true,
                    polarityInverted: false, delaySamples: 3_360
                ),
                LaneConfig(
                    deviceUID: "AppleUSBAudioEngine:DJI:Mic:1", deviceChannels: [1],
                    name: "DJI TX2", gainDB: 2, enabled: false,
                    polarityInverted: true, delaySamples: 0
                ),
                LaneConfig(
                    deviceUID: "com.rogueamoeba.Loopback:1", deviceChannels: [0, 1],
                    name: "Loopback L/R", gainDB: 0, enabled: true,
                    polarityInverted: false, delaySamples: 480
                )
            ],
            outputDeviceUID: "com.rogueamoeba.Loopback:2",
            masterGainDB: -6,
            savedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    @Test func roundTripsEveryField() throws {
        let original = sample()
        let restored = try SessionDocument.decode(original.jsonData())
        #expect(restored == original)
        #expect(restored.savedAt == original.savedAt)
    }

    @Test func laneControlsSurviveTheRoundTrip() throws {
        let restored = try SessionDocument.decode(sample().jsonData())
        #expect(restored.lanes[0].delaySamples == 3_360)
        #expect(restored.lanes[0].gainDB == -3.5)
        #expect(restored.lanes[1].enabled == false)
        #expect(restored.lanes[1].polarityInverted == true)
        #expect(restored.lanes[2].deviceChannels == [0, 1])
        #expect(restored.lanes[2].isStereo)
    }

    @Test func laneIdentityAndOrderArePreserved() throws {
        let original = sample()
        let restored = try SessionDocument.decode(original.jsonData())
        // Order is the session: it is what the UI shows and the order the
        // aggregate device lists its sub-devices in.
        #expect(restored.lanes.map(\.name) == ["DJI TX1", "DJI TX2", "Loopback L/R"])
        #expect(restored.lanes.map(\.id) == original.lanes.map(\.id))
    }

    @Test func fileIsPrettyPrintedWithSortedKeys() throws {
        let json = try String(decoding: sample().jsonData(), as: UTF8.self)
        #expect(json.contains("\n"))
        #expect(json.hasSuffix("\n"))
        let keys = ["formatVersion", "lanes", "masterGainDB", "outputDeviceUID", "savedAt"]
        let positions = keys.map { json.range(of: "\"\($0)\"")!.lowerBound }
        #expect(positions == positions.sorted())
        // ISO-8601, not a float, so the file reads like a document.
        #expect(json.contains("\"savedAt\" : \"20"))
    }

    @Test func unknownKeysAreIgnored() throws {
        let json = """
        {
          "formatVersion": 1,
          "masterGainDB": -6,
          "outputDeviceUID": "out",
          "somethingFromTheFuture": {"a": [1, 2, 3]},
          "lanes": [
            {"deviceUID": "mic", "name": "Mic", "auChain": "AAAA", "wetness": 0.5}
          ]
        }
        """
        let document = try SessionDocument.decode(Data(json.utf8))
        #expect(document.lanes.count == 1)
        #expect(document.lanes[0].name == "Mic")
        #expect(document.outputDeviceUID == "out")
    }

    @Test func missingFieldsFallBackToDefaults() throws {
        let document = try SessionDocument.decode(Data("""
        {"lanes": [{"deviceUID": "mic"}]}
        """.utf8))
        #expect(document.formatVersion == SessionDocument.currentFormatVersion)
        #expect(document.outputDeviceUID == nil)
        #expect(document.masterGainDB == 0)
        #expect(document.laneExtras.isEmpty)
        let lane = try #require(document.lanes.first)
        #expect(lane.deviceChannels == [0])
        #expect(lane.name == "mic")
        #expect(lane.gainDB == 0)
        #expect(lane.enabled)
        #expect(!lane.polarityInverted)
        #expect(lane.delaySamples == 0)
    }

    @Test func wrongTypesFallBackInsteadOfFailing() throws {
        let document = try SessionDocument.decode(Data("""
        {"formatVersion": "one", "masterGainDB": null, "outputDeviceUID": 17,
         "lanes": [{"deviceUID": "mic", "gainDB": "loud", "deviceChannels": "stereo"}]}
        """.utf8))
        #expect(document.formatVersion == SessionDocument.currentFormatVersion)
        #expect(document.masterGainDB == 0)
        #expect(document.outputDeviceUID == nil)
        #expect(document.lanes.count == 1)
        #expect(document.lanes[0].gainDB == 0)
        #expect(document.lanes[0].deviceChannels == [0])
    }

    @Test func aNewerFormatVersionStillLoadsItsLanes() throws {
        let document = try SessionDocument.decode(Data("""
        {
          "formatVersion": 99,
          "outputDeviceUID": "out",
          "masterGainDB": -2,
          "lanes": [
            {"deviceUID": "mic-a", "name": "A", "delaySamples": 4800},
            {"deviceUID": "mic-b", "name": "B", "sidechain": {"source": "mic-a"}}
          ]
        }
        """.utf8))
        #expect(document.formatVersion == 99)
        #expect(document.isFromNewerFormat)
        #expect(document.lanes.map(\.name) == ["A", "B"])
        #expect(document.lanes[0].delaySamples == 4_800)
        #expect(document.masterGainDB == -2)
    }

    @Test func aBrokenLaneIsDroppedAndTheRestSurvive() throws {
        // The middle entry has no `deviceUID`, so it is not a lane at all.
        let document = try SessionDocument.decode(Data("""
        {"lanes": [
          {"deviceUID": "a", "name": "A"},
          {"name": "no device"},
          {"deviceUID": "c", "name": "C"}
        ]}
        """.utf8))
        #expect(document.lanes.map(\.name) == ["A", "C"])
    }

    @Test func negativeAndExtraChannelsAreRejected() throws {
        let document = try SessionDocument.decode(Data("""
        {"lanes": [
          {"deviceUID": "a", "deviceChannels": [-1, 3, 4, 5]},
          {"deviceUID": "b", "deviceChannels": []}
        ]}
        """.utf8))
        #expect(document.lanes[0].deviceChannels == [3, 4])
        #expect(document.lanes[1].deviceChannels == [0])
    }

    @Test func extrasBagRoundTripsForFutureEffectState() throws {
        var document = sample()
        let laneID = document.lanes[0].id.uuidString
        document.laneExtras = [laneID: ["auChain": Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74])]]
        document.masterExtras = ["auChain": Data([0x00, 0xFF])]
        let restored = try SessionDocument.decode(document.jsonData())
        #expect(restored.laneExtras[laneID]?["auChain"] == Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]))
        #expect(restored.masterExtras["auChain"] == Data([0x00, 0xFF]))
    }

    @Test func garbageIsRejected() {
        #expect(throws: (any Error).self) {
            try SessionDocument.decode(Data("not json at all".utf8))
        }
        #expect(throws: (any Error).self) {
            try SessionDocument.decode(Data())
        }
    }
}
