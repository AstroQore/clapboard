import ClapboardCore
import CoreAudio
import Foundation
import Testing

/// The lane-source model and the tap description Clapboard builds from it.
///
/// Nothing here creates a real HAL tap: `AudioHardwareCreateProcessTap` needs
/// the system-audio-capture permission and a running target, neither of which
/// belongs in a unit test. What *is* checked here is everything that decides
/// how such a tap would behave — mute behaviour above all — plus the session
/// round trip, which is where a mistake would silently cost a user their lane.
@Suite("Process tap lanes")
struct ProcessTapLaneTests {
    private let musicSpec = TapSpec(target: .app(bundleID: "com.apple.Music"), name: "Music")

    // MARK: - Source keys

    @Test func tapKeysCannotCollideWithDeviceUIDs() {
        #expect(musicSpec.sourceKey == "tap:com.apple.Music")
        #expect(TapSpec(target: .systemAudio, name: "System audio").sourceKey == "tap:system")
        // Two lanes on the same app share one tap; two different apps do not.
        #expect(TapSpec(target: .app(bundleID: "com.apple.Music"), name: "Other").sourceKey
                == musicSpec.sourceKey)
    }

    @Test func tapLaneReportsItsKeyAsTheDeviceUID() {
        let lane = LaneConfig(source: .processTap(musicSpec), name: "Music")
        #expect(lane.deviceUID == "tap:com.apple.Music")
        #expect(lane.deviceChannels == [0, 1])
        #expect(lane.isStereo)
        #expect(lane.channelLabel == "tap · stereo")
    }

    @Test func monoTapIsOneChannel() {
        let lane = LaneConfig(
            source: .processTap(TapSpec(target: .systemAudio, name: "System audio", mono: true)),
            name: "System")
        #expect(lane.deviceChannels == [0])
        #expect(!lane.isStereo)
        #expect(lane.channelLabel == "tap · mono")
    }

    @Test func assigningChannelsFlipsATapBetweenMonoAndStereo() {
        var lane = LaneConfig(source: .processTap(musicSpec), name: "Music")
        lane.deviceChannels = [0]
        #expect(lane.source.tap?.mono == true)
        lane.deviceChannels = [0, 1]
        #expect(lane.source.tap?.mono == false)
        // The source is still a tap: changing channels must not quietly turn
        // it back into a device lane.
        #expect(lane.source.isProcessTap)
    }

    @Test func assigningADeviceUIDTurnsATapLaneIntoADeviceLane() {
        var lane = LaneConfig(source: .processTap(musicSpec), name: "Music")
        lane.deviceUID = "BuiltInMicrophoneDevice"
        #expect(!lane.source.isProcessTap)
        #expect(lane.deviceUID == "BuiltInMicrophoneDevice")
        #expect(lane.deviceChannels == [0, 1])
    }

    // MARK: - Persistence

    @Test func tapLaneSurvivesAJSONRoundTrip() throws {
        let lane = LaneConfig(
            source: .processTap(TapSpec(target: .app(bundleID: "com.apple.Music"), name: "Music", mono: true)),
            name: "Music", gainDB: -3, delaySamples: 480)
        let data = try SessionDocument.makeEncoder().encode(SessionDocument(lanes: [lane]))
        let restored = try SessionDocument.decode(data)
        #expect(restored.lanes.count == 1)
        #expect(restored.lanes[0].source == lane.source)
        #expect(restored.lanes[0].id == lane.id)
        #expect(restored.lanes[0].delaySamples == 480)
    }

    /// A tap lane still writes the pre-tap `deviceUID`/`deviceChannels` pair,
    /// so a Clapboard that predates `source` reads a lane on an unknown device
    /// — missing, not absent — instead of dropping it and everything keyed on
    /// its id.
    @Test func tapLaneAlsoWritesTheOldDeviceSpelling() throws {
        let lane = LaneConfig(source: .processTap(musicSpec), name: "Music")
        let data = try SessionDocument.makeEncoder().encode(SessionDocument(lanes: [lane]))
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lanes = try #require(json["lanes"] as? [[String: Any]])
        #expect(lanes[0]["deviceUID"] as? String == "tap:com.apple.Music")
        #expect(lanes[0]["deviceChannels"] as? [Int] == [0, 1])
    }

    /// The acceptance case for tolerant decoding: a version 2 file written
    /// before process taps existed has no `source` key at all.
    @Test func versionTwoFileWithoutASourceKeyLoadsAsADeviceLane() throws {
        let json = """
        {"formatVersion": 2,
         "lanes": [{"deviceUID": "mic-a", "deviceChannels": [0, 1], "name": "A", "gainDB": -2}],
         "buses": [{"id": "\(UUID().uuidString)", "name": "Master"}]}
        """
        let document = try SessionDocument.decode(Data(json.utf8))
        #expect(document.lanes.count == 1)
        #expect(document.lanes[0].source == .device(uid: "mic-a", channels: [0, 1]))
        #expect(document.lanes[0].gainDB == -2)
    }

    @Test func aTapSourceMissingItsSpecFallsBackToTheDeviceKeys() throws {
        // A hand-edited or truncated file: `kind` says tap but there is no
        // tap object. The lane must still load rather than vanish.
        let json = """
        {"formatVersion": 2,
         "lanes": [{"deviceUID": "mic-a", "deviceChannels": [0],
                    "source": {"kind": "processTap"}, "name": "A"}]}
        """
        let document = try SessionDocument.decode(Data(json.utf8))
        #expect(document.lanes.count == 1)
        #expect(document.lanes[0].source == .device(uid: "mic-a", channels: [0]))
    }

    @Test func aTapTargetWithoutABundleIDDecodesAsSystemAudio() throws {
        let json = """
        {"target": {"kind": "app"}, "name": "Broken", "mono": true}
        """
        let spec = try JSONDecoder().decode(TapSpec.self, from: Data(json.utf8))
        #expect(spec.target == .systemAudio)
        #expect(spec.mono)
    }

    // MARK: - Aggregate layout

    /// The HAL appends tap streams after every sub-device stream, which is
    /// what `AggregateDevice.create` builds and then re-checks against the
    /// aggregate's real stream configuration. This pins the arithmetic that
    /// turns that order into buffer indices.
    @Test func tapChannelsFollowEverySubDeviceStream() {
        let layout = AggregateInputLayout(subDevices: [
            SubDeviceInputLayout(deviceUID: "BuiltInMicrophoneDevice", streamChannelCounts: [1]),
            SubDeviceInputLayout(deviceUID: "loopback", streamChannelCounts: [2]),
            SubDeviceInputLayout(deviceUID: "tap:system", streamChannelCounts: [2])
        ])
        #expect(layout.totalChannels == 5)
        #expect(layout.globalChannels(forDeviceUID: "tap:system") == 3..<5)
        #expect(layout.globalChannel(deviceUID: "tap:system", deviceChannel: 0) == 3)
        #expect(layout.globalChannel(deviceUID: "tap:system", deviceChannel: 1) == 4)
        // Its own buffer, its own channels inside it — the same shape a
        // sub-device stream gets.
        #expect(layout.locate(globalChannel: 3).map { [$0.bufferIndex, $0.channel] } == [2, 0])
        #expect(layout.locate(globalChannel: 4).map { [$0.bufferIndex, $0.channel] } == [2, 1])
    }

    // MARK: - Tap description

    /// Mute behaviour is the decision this feature turns on: capturing an app
    /// must not stop it being heard. `CATapMuted`/`CATapMutedWhenTapped` would
    /// silence the tapped app for as long as Clapboard reads the tap.
    @Test func theTapDescriptionNeverMutesTheAppItCaptures() throws {
        let (description, processes) = try ProcessTapFactory.makeDescription(
            TapSpec(target: .systemAudio, name: "System audio"))
        #expect(description.muteBehavior == .unmuted)
        #expect(description.isPrivate)
        #expect(description.isExclusive)
        #expect(!description.isMono)
        // A system-wide tap names what to leave out, and Clapboard's own
        // output is the one thing that must be left out.
        #expect(processes.isEmpty)
        #expect(description.processes == (ProcessTapCatalog.ownProcessObjectID().map { [$0] } ?? []))
    }

    @Test func aMonoSystemTapAsksForOneChannel() throws {
        let (description, _) = try ProcessTapFactory.makeDescription(
            TapSpec(target: .systemAudio, name: "System audio", mono: true))
        #expect(description.isMono)
        #expect(description.muteBehavior == .unmuted)
    }

    @Test func anAppThatIsNotPlayingIsRefusedWithAReasonRatherThanASilentTap() {
        #expect(throws: ProcessTapError.processNotRunning(bundleID: "com.example.definitely.not.running")) {
            _ = try ProcessTapFactory.makeDescription(
                TapSpec(target: .app(bundleID: "com.example.definitely.not.running"), name: "Nope"))
        }
    }

    @Test func creatingNoTapLeavesNoneBehind() {
        #expect(ProcessTapFactory.leakedTapUIDs().isEmpty)
    }
}

/// The engine side: which taps a set of lanes asks the aggregate device for,
/// and that a tap lane survives being saved and restored.
@Suite("Process tap lanes in the engine")
@MainActor
struct ProcessTapEngineTests {
    @Test func lanesOnTheSameAppShareOneTap() {
        let engine = AudioEngine()
        engine.addTapLane(TapSpec(target: .app(bundleID: "com.apple.Music"), name: "Music"))
        engine.addTapLane(TapSpec(target: .app(bundleID: "com.apple.Music"), name: "Music again"))
        engine.addTapLane(TapSpec(target: .systemAudio, name: "System audio"))
        engine.addLane(deviceUID: "mic-a", deviceChannels: [0], name: "Mic")
        #expect(engine.orderedTapSpecs().map(\.sourceKey) == ["tap:com.apple.Music", "tap:system"])
        #expect(engine.usesProcessTaps)
    }

    @Test func aMixWithoutTapsAsksForNone() {
        let engine = AudioEngine()
        engine.addLane(deviceUID: "mic-a", deviceChannels: [0], name: "Mic")
        #expect(engine.orderedTapSpecs().isEmpty)
        #expect(!engine.usesProcessTaps)
    }

    @Test func aTapLaneSurvivesSaveAndRestore() {
        let engine = AudioEngine()
        let spec = TapSpec(target: .app(bundleID: "com.apple.Music"), name: "Music", mono: true)
        let lane = engine.addTapLane(spec)
        engine.setLaneGainDB(lane.id, -7)
        engine.setLaneDelaySamples(lane.id, 240)

        let snapshot = engine.sessionSnapshot
        let reopened = AudioEngine()
        reopened.restore(snapshot)

        #expect(reopened.lanes.count == 1)
        #expect(reopened.lanes[0].id == lane.id)
        #expect(reopened.lanes[0].source == .processTap(spec))
        #expect(reopened.lanes[0].gainDB == -7)
        #expect(reopened.lanes[0].delaySamples == 240)
        #expect(reopened.orderedTapSpecs().map(\.sourceKey) == ["tap:com.apple.Music"])
    }

    /// A tap lane's key can never equal an output device's UID, so the
    /// feedback guard that drops a lane sitting on an output device must not
    /// touch it.
    @Test func aTapLaneIsNeverMistakenForFeedback() {
        let engine = AudioEngine()
        engine.setOutputDevice(uid: "the-output")
        let restored = engine.restore(SessionDocument(
            lanes: [
                LaneConfig(source: .processTap(TapSpec(target: .systemAudio, name: "System audio")),
                           name: "System"),
                LaneConfig(deviceUID: "the-output", deviceChannels: [0], name: "Feedback")
            ],
            outputDeviceUID: "the-output"
        ))
        #expect(restored.restoredLanes == 1)
        #expect(engine.lanes.map(\.name) == ["System"])
    }

    @Test func retargetingALaneFromADeviceToATapKeepsItsIdentity() {
        let engine = AudioEngine()
        let lane = engine.addLane(deviceUID: "mic-a", deviceChannels: [0], name: "Mic")
        engine.setLaneGainDB(lane.id, -4)
        let spec = TapSpec(target: .systemAudio, name: "System audio")
        engine.setLaneSource(lane.id, .processTap(spec))
        #expect(engine.lanes[0].id == lane.id)
        #expect(engine.lanes[0].source == .processTap(spec))
        #expect(engine.lanes[0].gainDB == -4)
        engine.setLaneSource(lane.id, deviceUID: "mic-b", deviceChannels: [0, 1])
        #expect(engine.lanes[0].source == .device(uid: "mic-b", channels: [0, 1]))
    }
}
