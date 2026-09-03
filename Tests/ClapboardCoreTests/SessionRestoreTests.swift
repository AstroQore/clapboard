import ClapboardCore
import Foundation
import Testing

/// `restore` on a stopped engine. No aggregate device is built here, so these
/// run anywhere: the engine only publishes an empty graph while stopped.
@Suite("Session restore")
@MainActor
struct SessionRestoreTests {
    private func document() -> SessionDocument {
        SessionDocument(
            lanes: [
                LaneConfig(deviceUID: "mic-a", deviceChannels: [0], name: "A", gainDB: -4, delaySamples: 2_400),
                LaneConfig(deviceUID: "mic-b", deviceChannels: [1], name: "B", enabled: false, polarityInverted: true),
                LaneConfig(deviceUID: "mic-a", deviceChannels: [1], name: "C", gainDB: 1.5)
            ],
            outputDeviceUID: "the-output",
            masterGainDB: -6
        )
    }

    @Test func snapshotAndRestoreAreInverses() {
        let original = document()
        let engine = AudioEngine()
        engine.restore(original)
        let snapshot = engine.sessionSnapshot
        #expect(snapshot.lanes == original.lanes)
        #expect(snapshot.outputDeviceUID == "the-output")
        #expect(snapshot.masterGainDB == -6)
    }

    @Test func laneIdsAndOrderSurviveARestore() {
        let original = document()
        let engine = AudioEngine()
        engine.restore(original)
        // Per-lane data added later (M3 sync results, M4 plug-in state) is
        // keyed on these ids, so a relaunch must not renumber them.
        #expect(engine.lanes.map(\.id) == original.lanes.map(\.id))
        #expect(engine.lanes.map(\.name) == ["A", "B", "C"])
    }

    @Test func restoringTwiceReplacesRatherThanAppends() {
        let engine = AudioEngine()
        engine.restore(document())
        engine.restore(document())
        #expect(engine.lanes.count == 3)
    }

    @Test func aLaneWhoseDeviceIsNotHereIsKept() {
        let engine = AudioEngine()
        engine.restore(SessionDocument(
            lanes: [LaneConfig(deviceUID: "device-that-does-not-exist", deviceChannels: [0], name: "Gone")],
            outputDeviceUID: "the-output"
        ))
        // Kept, not dropped: the microphone is only unplugged, and the lane has
        // to come back with its gain and delay when it returns.
        #expect(engine.lanes.map(\.name) == ["Gone"])
        // Stopped, so every lane is idle; `deviceMissing` is a running verdict.
        #expect(engine.laneStatus[engine.lanes[0].id] == .idle)
        #expect(engine.sessionSnapshot.lanes[0].deviceUID == "device-that-does-not-exist")
    }

    @Test func aLaneOnTheOutputDeviceIsRefused() {
        let engine = AudioEngine()
        let report = engine.restore(SessionDocument(
            lanes: [
                LaneConfig(deviceUID: "the-output", deviceChannels: [0], name: "Feedback"),
                LaneConfig(deviceUID: "mic-a", deviceChannels: [0], name: "Fine")
            ],
            outputDeviceUID: "the-output"
        ))
        #expect(engine.lanes.map(\.name) == ["Fine"])
        #expect(report.restoredLanes == 1)
        #expect(report.skippedLanes.count == 1)
    }

    @Test func hostileValuesAreClampedBeforeTheyReachTheRenderThread() {
        let engine = AudioEngine()
        engine.restore(SessionDocument(
            lanes: [LaneConfig(
                deviceUID: "mic-a", deviceChannels: [0], name: "Edited by hand",
                gainDB: .infinity, delaySamples: 10_000_000
            )],
            outputDeviceUID: "out"
        ))
        let lane = engine.lanes[0]
        #expect(lane.delaySamples == RTLimits.maxDelaySamples)
        #expect(lane.gainDB.isFinite)
    }

    @Test func duplicateLaneIdsAreSeparated() {
        let shared = UUID()
        let engine = AudioEngine()
        let report = engine.restore(SessionDocument(
            lanes: [
                LaneConfig(id: shared, deviceUID: "mic-a", deviceChannels: [0], name: "One"),
                LaneConfig(id: shared, deviceUID: "mic-b", deviceChannels: [0], name: "Two")
            ],
            outputDeviceUID: "out"
        ))
        #expect(engine.lanes.count == 2)
        #expect(Set(engine.lanes.map(\.id)).count == 2)
        #expect(report.skippedLanes.count == 1)
    }

    @Test func anEmptySessionClearsTheMixer() {
        let engine = AudioEngine()
        engine.restore(document())
        engine.restore(SessionDocument())
        #expect(engine.lanes.isEmpty)
        #expect(engine.outputDeviceUID == nil)
        #expect(engine.masterGainDB == 0)
    }

    @Test func aFileFromTheFutureIsFlaggedNotRefused() throws {
        let document = try SessionDocument.decode(Data("""
        {"formatVersion": 42, "outputDeviceUID": "out",
         "lanes": [{"deviceUID": "mic-a", "name": "Still works"}]}
        """.utf8))
        let engine = AudioEngine()
        let report = engine.restore(document)
        #expect(report.fromNewerFormat)
        #expect(engine.lanes.map(\.name) == ["Still works"])
    }
}
