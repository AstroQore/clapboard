import AudioToolbox
import ClapboardCore
import Foundation
import Testing

/// Session format 2 (`docs/ROUTING.md`): `buses`, a lane's `destinationBus`,
/// and migrating a version 1 file's implicit master into an explicit one.
@Suite("Session migration")
@MainActor
struct SessionMigrationTests {
    // MARK: - Version 1 -> version 2

    /// A file written before buses existed: no `buses` key at all, routing
    /// implicit in `outputDeviceUID`/`masterGainDB`, the master chain (if any)
    /// in `masterExtras`.
    private func version1JSON(masterEffects: Data? = nil) -> String {
        let extras = masterEffects.map { "\"masterExtras\": {\"effects\": \"\($0.base64EncodedString())\"}," } ?? ""
        return """
        {
          "formatVersion": 1,
          "lanes": [
            {"deviceUID": "mic-a", "deviceChannels": [0], "name": "A", "gainDB": -3, "enabled": true, "delaySamples": 480},
            {"deviceUID": "mic-b", "deviceChannels": [0], "name": "B"}
          ],
          "outputDeviceUID": "out-device",
          "masterGainDB": -6,
          "savedAt": "2024-01-01T00:00:00Z",
          \(extras.isEmpty ? "" : extras)
          "laneExtras": {}
        }
        """
    }

    @Test func aVersion1FileHasNoBusesAndIsFlaggedForMigration() throws {
        let document = try SessionDocument.decode(Data(version1JSON().utf8))
        #expect(document.formatVersion == 1)
        #expect(document.buses.isEmpty)
        #expect(document.needsBusMigration)
        #expect(document.outputDeviceUID == "out-device")
        #expect(document.masterGainDB == -6)
    }

    @Test func restoringAVersion1FileCreatesOneMasterBusAndRoutesEveryLaneToIt() throws {
        let document = try SessionDocument.decode(Data(version1JSON().utf8))
        let engine = AudioEngine()
        let report = engine.restore(document)

        #expect(report.migratedFromFormat1)
        #expect(report.restoredLanes == 2)
        #expect(engine.buses.count == 1)
        let master = try #require(engine.buses.first)
        #expect(master.name == BusConfig.masterName)
        #expect(master.outputDeviceUID == "out-device")
        #expect(master.gainDB == -6)
        #expect(master.destinationBus == nil)
        #expect(engine.outputDeviceUID == "out-device", "the legacy shim reads the migrated bus")
        #expect(engine.masterGainDB == -6)
        for lane in engine.lanes {
            #expect(lane.destinationBus == master.id, "\(lane.name) must be routed to the migrated Master bus")
        }
        // `--session-dump` after a migration shows format 2 going forward.
        #expect(engine.sessionSnapshot.formatVersion == 2)
        #expect(engine.sessionSnapshot.buses.count == 1)
    }

    @Test func aVersion1MasterChainMigratesOntoTheMasterBus() async throws {
        let ghost = EffectConfig(componentID: "aufx.zzzz.zzzz", displayName: "Nonexistent: Ghost")
        let blob = try EffectChainCodec.encode([ghost])
        let document = try SessionDocument.decode(Data(version1JSON(masterEffects: blob).utf8))

        let engine = AudioEngine()
        defer { engine.shutdown() }
        let report = engine.restore(document)
        #expect(report.pendingEffects == 1)
        await engine.waitForEffectRestore()

        // The component does not exist on this Mac, so it comes back as a
        // placeholder — but it comes back, on the Master bus, which is the
        // point: the chain is not silently dropped by the migration.
        #expect(engine.masterEffects.map(\.componentID) == ["aufx.zzzz.zzzz"])
        #expect(engine.masterEffects.first?.isAvailable == false)
    }

    @Test func aVersion2FileWithNoBusesAtAllStillMigrates() throws {
        // A hand-edited version 2 file that dropped `buses` by mistake must
        // not leave the mixer with zero buses.
        let json = """
        {"formatVersion": 2, "lanes": [{"deviceUID": "mic", "deviceChannels": [0], "name": "A"}],
         "outputDeviceUID": "out", "masterGainDB": 0}
        """
        let document = try SessionDocument.decode(Data(json.utf8))
        #expect(document.needsBusMigration)
        let engine = AudioEngine()
        let report = engine.restore(document)
        #expect(engine.buses.count == 1)
        #expect(report.migratedFromFormat1)
    }

    // MARK: - Version 2 round trip

    @Test func aVersion2DocumentRoundTripsThroughJSONExactly() throws {
        let masterID = UUID()
        let vocalsID = UUID()
        let laneID = UUID()
        let vocalsEffect = EffectConfig(
            componentID: "aufx.dely.appl", displayName: "Apple: Delay",
            fullState: Data([0x01, 0x02, 0x03]))

        let original = SessionDocument(
            formatVersion: 2,
            lanes: [
                LaneConfig(
                    id: laneID, deviceUID: "mic-a", deviceChannels: [0], name: "A",
                    gainDB: -1.5, enabled: false, polarityInverted: true, delaySamples: 240,
                    solo: true, destinationBus: vocalsID)
            ],
            buses: [
                BusConfig(
                    id: masterID, name: "Master", gainDB: -2, muted: false, solo: false,
                    destinationBus: nil, outputDeviceUID: "out-device", outputChannelOffset: 0),
                BusConfig(
                    id: vocalsID, name: "Vocals", gainDB: 1, muted: true, solo: false,
                    effects: [vocalsEffect], destinationBus: masterID)
            ]
        )

        let data = try original.jsonData()
        let decoded = try SessionDocument.decode(data)

        #expect(decoded.formatVersion == 2)
        #expect(decoded.lanes == original.lanes)
        #expect(decoded.buses == original.buses)
        #expect(!decoded.needsBusMigration)
        #expect(decoded.lanes.first?.destinationBus == vocalsID)
        #expect(decoded.buses.last?.destinationBus == masterID)
        #expect(decoded.buses.last?.effects.first?.fullState == Data([0x01, 0x02, 0x03]))
    }

    @Test func engineSessionSnapshotRoundTripsThroughRestoreForAMultiBusMix() throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        let master = engine.buses[0]
        let vocals = engine.addBus(name: "Vocals")
        #expect(engine.setBusDestination(id: vocals.id, parent: master.id).isSuccess)
        engine.setBusGainDB(vocals.id, -4.5)
        engine.setBusMuted(vocals.id, true)
        let lane = engine.addLane(deviceUID: "mic", deviceChannels: [0], name: "Mic")
        #expect(engine.setLaneDestination(lane.id, bus: vocals.id))

        let document = engine.sessionSnapshot
        #expect(document.formatVersion == 2)
        #expect(document.buses.count == 2)

        let reopened = AudioEngine()
        defer { reopened.shutdown() }
        let report = reopened.restore(document)
        #expect(!report.migratedFromFormat1)
        #expect(reopened.buses.count == 2)
        let restoredVocals = try #require(reopened.buses.first { $0.name == "Vocals" })
        #expect(restoredVocals.gainDB == -4.5)
        #expect(restoredVocals.muted)
        #expect(reopened.lanes.first?.destinationBus == restoredVocals.id)
    }

    // MARK: - Tolerant decoding

    @Test func unknownKeysAnywhereInAVersion2FileAreTolerated() throws {
        let json = """
        {
          "formatVersion": 2,
          "somethingThisBuildHasNeverHeardOf": {"a": 1},
          "lanes": [
            {"deviceUID": "mic", "deviceChannels": [0], "name": "A", "destinationBus": "\(UUID().uuidString)",
             "fromTheFuture": true}
          ],
          "buses": [
            {"id": "\(UUID().uuidString)", "name": "Master", "outputDeviceUID": "out",
             "aFieldAddedByANewerClapboard": [1, 2, 3]}
          ],
          "aTopLevelExtraField": "ignored"
        }
        """
        let document = try SessionDocument.decode(Data(json.utf8))
        #expect(document.lanes.count == 1)
        #expect(document.lanes.first?.name == "A")
        #expect(document.buses.count == 1)
        #expect(document.buses.first?.name == "Master")
        #expect(document.buses.first?.outputDeviceUID == "out")
        #expect(!document.needsBusMigration)
    }

    @Test func aBusThatFailsToDecodeIsDroppedRatherThanFailingTheWholeFile() throws {
        let json = """
        {"formatVersion": 2,
         "lanes": [],
         "buses": [ {"noIdOrName": true}, {"id": "\(UUID().uuidString)", "name": "Master"} ]}
        """
        let document = try SessionDocument.decode(Data(json.utf8))
        // The first bus entry has neither `id` nor `name`, both required —
        // it is dropped, the well-formed one after it is not.
        #expect(document.buses.count == 1)
        #expect(document.buses.first?.name == "Master")
    }
}
