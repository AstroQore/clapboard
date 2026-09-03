import ClapboardCore
import Foundation
import Testing

@Suite("MuteToggleLogic")
struct MuteToggleLogicTests {
    private func lane(_ name: String, enabled: Bool) -> LaneConfig {
        LaneConfig(deviceUID: "uid-\(name)", deviceChannels: [0], name: name, enabled: enabled)
    }

    @Test func muteAllSilencesEveryLaneAndRemembersTheLiveOnes() {
        let lanes = [lane("A", enabled: true), lane("B", enabled: false), lane("C", enabled: true)]
        let outcome = MuteToggleLogic.muteAll(lanes: lanes, remembered: [])

        #expect(outcome.didMute)
        #expect(outcome.enabled == [lanes[0].id: false, lanes[1].id: false, lanes[2].id: false])
        #expect(outcome.remembered == [lanes[0].id, lanes[2].id])
        // B was already off, so it is not a change to write.
        #expect(outcome.changes(from: lanes) == [lanes[0].id: false, lanes[2].id: false])
    }

    @Test func mutingTwiceKeepsTheFirstMemory() {
        let lanes = [lane("A", enabled: true), lane("B", enabled: false)]
        let first = MuteToggleLogic.muteAll(lanes: lanes, remembered: [])
        let muted = lanes.map { var copy = $0; copy.enabled = false; return copy }

        let second = MuteToggleLogic.muteAll(lanes: muted, remembered: first.remembered)
        #expect(second.remembered == [lanes[0].id])
        #expect(second.changes(from: muted).isEmpty)
    }

    @Test func restorePutsBackTheRememberedSet() {
        let lanes = [lane("A", enabled: false), lane("B", enabled: false), lane("C", enabled: false)]
        let outcome = MuteToggleLogic.restore(lanes: lanes, remembered: [lanes[0].id, lanes[2].id])

        #expect(!outcome.didMute)
        #expect(outcome.enabled == [lanes[0].id: true, lanes[1].id: false, lanes[2].id: true])
        #expect(outcome.remembered.isEmpty)
    }

    @Test func restoreWithNothingRememberedEnablesEveryLane() {
        let lanes = [lane("A", enabled: false), lane("B", enabled: false)]
        let outcome = MuteToggleLogic.restore(lanes: lanes, remembered: [])

        #expect(outcome.enabled == [lanes[0].id: true, lanes[1].id: true])
        #expect(outcome.remembered.isEmpty)
    }

    @Test func restoreEnablesEveryLaneWhenTheRememberedLanesAreAllGone() {
        let lanes = [lane("A", enabled: false), lane("B", enabled: false)]
        let outcome = MuteToggleLogic.restore(lanes: lanes, remembered: [UUID(), UUID()])

        #expect(outcome.enabled == [lanes[0].id: true, lanes[1].id: true])
    }

    /// "Unmute all" says all, so it must not quietly honour the memory the way
    /// the toggle key does — it is the escape hatch out of a confusing state.
    @Test func unmuteAllIgnoresTheRememberedSetAndEnablesEveryLane() {
        let lanes = [lane("A", enabled: false), lane("B", enabled: false), lane("C", enabled: false)]
        let outcome = MuteToggleLogic.unmuteAll(lanes: lanes)

        #expect(!outcome.didMute)
        #expect(outcome.enabled == [lanes[0].id: true, lanes[1].id: true, lanes[2].id: true])
        #expect(outcome.remembered.isEmpty)
    }

    @Test func toggleAllMutesRemembersAndRestoresAcrossPresses() {
        var lanes = [lane("A", enabled: true), lane("B", enabled: false), lane("C", enabled: true)]
        var remembered: Set<UUID> = []

        func press() {
            let outcome = MuteToggleLogic.toggleAll(lanes: lanes, remembered: remembered)
            remembered = outcome.remembered
            lanes = lanes.map { var copy = $0; copy.enabled = outcome.enabled[$0.id] ?? $0.enabled; return copy }
        }

        press()
        #expect(lanes.allSatisfy { !$0.enabled })
        #expect(remembered.count == 2)

        press()
        #expect(lanes.map(\.enabled) == [true, false, true])
        #expect(remembered.isEmpty)

        press()
        #expect(lanes.allSatisfy { !$0.enabled })
    }

    @Test func toggleAllWithNothingRememberedEnablesEveryLane() {
        let lanes = [lane("A", enabled: false), lane("B", enabled: false)]
        let outcome = MuteToggleLogic.toggleAll(lanes: lanes, remembered: [])

        #expect(!outcome.didMute)
        #expect(outcome.enabled == [lanes[0].id: true, lanes[1].id: true])
    }

    @Test func toggleAllMutesWhileAnySingleLaneIsStillLive() {
        let lanes = [lane("A", enabled: false), lane("B", enabled: true)]
        let outcome = MuteToggleLogic.toggleAll(lanes: lanes, remembered: [lanes[0].id])

        #expect(outcome.didMute)
        // The live lane replaces the stale memory rather than merging into it.
        #expect(outcome.remembered == [lanes[1].id])
    }

    @Test func anEmptyMixerIsNeverMuted() {
        #expect(!MuteToggleLogic.anyEnabled([]))
        let outcome = MuteToggleLogic.toggleAll(lanes: [], remembered: [])
        #expect(outcome.enabled.isEmpty)
        #expect(!outcome.didMute)
    }
}
