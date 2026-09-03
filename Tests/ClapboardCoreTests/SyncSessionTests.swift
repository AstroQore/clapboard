import ClapboardCore
import Foundation
import Testing

private typealias LaneSpec = SyncTestSignals.LaneSpec

/// The glue between the capture buffers and `ClapAligner`: assembling
/// recordings, mapping a result onto lane delays, the early-stop transient
/// watcher, and the envelopes the result page draws.
@Suite("Sync session")
struct SyncSessionTests {
    private static let sampleRate: Double = 48_000

    private func option(
        _ label: String,
        id: UUID = UUID(),
        virtual: Bool = false
    ) -> SyncLaneOption {
        SyncLaneOption(
            id: id, label: label, deviceName: "\(label) device",
            isVirtual: virtual, currentDelaySamples: 0
        )
    }

    // MARK: - Recording assembly

    @Test func recordingsKeepTheCommonTimeOriginByTrimmingToTheShortestLane() {
        let a = option("A")
        let b = option("B", virtual: true)
        let recordings = SyncSessionMath.makeRecordings(
            lanes: [a, b],
            captures: [a.id: [Float](repeating: 0.5, count: 900),
                       b.id: [Float](repeating: 0.25, count: 700)],
            sampleRate: Self.sampleRate
        )
        #expect(recordings.count == 2)
        #expect(recordings.allSatisfy { $0.samples.count == 700 })
        #expect(recordings[0].laneID == a.id)
        #expect(recordings[0].label == "A")
        #expect(recordings[0].isVirtual == false)
        // A virtual lane is measured but must be marked, or it could become
        // the reference and hand everyone else Loopback's timeline.
        #expect(recordings[1].isVirtual)
        #expect(recordings[1].sampleRate == Self.sampleRate)
        // Trimming keeps the head, which is where the noise floor is measured.
        #expect(recordings[0].samples.allSatisfy { $0 == 0.5 })
    }

    @Test func aLaneThatRecordedNothingIsDroppedRatherThanAnalysedAsSilence() {
        let a = option("A")
        let b = option("B")
        let c = option("C")
        let recordings = SyncSessionMath.makeRecordings(
            lanes: [a, b, c],
            captures: [a.id: [Float](repeating: 0.1, count: 500), b.id: []],
            sampleRate: Self.sampleRate
        )
        #expect(recordings.map(\.laneID) == [a.id])
    }

    @Test func recordingsAreEmptyWhenNothingWasCaptured() {
        #expect(SyncSessionMath.makeRecordings(
            lanes: [option("A")], captures: [:], sampleRate: Self.sampleRate
        ).isEmpty)
    }

    // MARK: - Apply mapping

    @Test func applyOnlyTouchesTheLanesThatWereActuallyMeasured() {
        let take = SyncTestSignals.makeTake(
            [
                LaneSpec("near"),
                { var spec = LaneSpec("far"); spec.delaySamples = -1400; return spec }(),
                { var spec = LaneSpec("mute"); spec.content = .silence; return spec }()
            ],
            seed: 4242
        )
        let result = ClapAligner().analyze(take.lanes)
        let assignments = SyncSessionMath.delayAssignments(from: result)

        let silent = take.lanes[2].laneID
        #expect(assignments[silent] == nil)
        #expect(assignments.count == 2)
        #expect(assignments.values.allSatisfy { $0 >= 0 })
        // The lane that arrived last anchors the mix at zero.
        #expect(assignments.values.contains(0))
        // "near" is 1400 samples later than "far", so "far" waits for it.
        #expect(assignments[take.lanes[0].laneID] == 0)
        #expect(abs((assignments[take.lanes[1].laneID] ?? 0) - 1400) <= 1)
    }

    @Test func verifyMeasuresAgainstTheLaneThatWasGivenNoDelay() {
        let take = SyncTestSignals.makeTake(
            [
                LaneSpec("late"),
                { var spec = LaneSpec("early"); spec.delaySamples = -900; return spec }()
            ],
            seed: 77
        )
        let result = ClapAligner().analyze(take.lanes)
        let assignments = SyncSessionMath.delayAssignments(from: result)
        let reference = SyncSessionMath.verificationReference(result: result, assignments: assignments)
        #expect(reference == take.lanes[0].laneID)

        let verifications = SyncSessionMath.verify(
            result: result,
            recordings: take.lanes,
            appliedDelays: assignments,
            options: SyncOptions(),
            sampleRate: Self.sampleRate
        )
        // The reference is not verified against itself.
        #expect(verifications.count == 1)
        #expect(verifications[0].laneID == take.lanes[1].laneID)
        let residual = try? #require(verifications[0].residualSamples)
        #expect(abs(residual ?? 99) <= 1)
        #expect(abs(verifications[0].residualMilliseconds ?? 99) < 0.03)
    }

    // MARK: - Envelopes

    @Test func envelopeDownsamplesToTheRequestedNumberOfPoints() {
        var samples = [Float](repeating: 0, count: 10_000)
        samples[5_000] = 1
        samples[5_001] = -0.5
        let points = SyncSessionMath.envelope(samples: samples, from: 0, count: 10_000, points: 100)
        #expect(points.count == 100)
        #expect(points[50] == 1)                     // normalised to its own peak
        #expect(points.filter { $0 > 0 }.count == 1)
        #expect(points.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func envelopeReadsOutsideTheRecordingAsSilenceInsteadOfClamping() {
        let samples = [Float](repeating: 0.5, count: 1_000)
        let points = SyncSessionMath.envelope(samples: samples, from: -500, count: 2_000, points: 100)
        #expect(points.count == 100)
        // First quarter is before the recording, last half is past its end.
        #expect(points[0] == 0)
        #expect(points[99] == 0)
        #expect(points[30] == 1)
    }

    @Test func theDrawnWindowHoldsBothTheRawAndTheShiftedArrival() {
        let take = SyncTestSignals.makeTake(
            [
                LaneSpec("late"),
                { var spec = LaneSpec("early"); spec.delaySamples = -2000; return spec }()
            ],
            seed: 9
        )
        let result = ClapAligner().analyze(take.lanes)
        let set = SyncSessionMath.makeEnvelopes(
            result: result, recordings: take.lanes, sampleRate: Self.sampleRate, points: 500
        )
        let envelopes = try? #require(set)
        #expect(envelopes?.lanes.count == 2)
        #expect(envelopes?.pointCount == 500)
        for lane in envelopes?.lanes ?? [] {
            let onset = lane.onsetPoint ?? -1
            #expect(onset >= 0 && onset < 500)
            #expect(onset + lane.shiftPoints <= 500)
            #expect(lane.points.count == 500)
        }
        // 2000 samples of correction plus two 50 ms margins.
        #expect((envelopes?.spanMilliseconds ?? 0) > 100)
    }

    @Test func adviceNamesTheLanesThatNeedTheUsersAttention() {
        // Two lanes heard the clap, so there is a measurement; the third did
        // not, and that is what the advice line is for.
        let take = SyncTestSignals.makeTake(
            [
                LaneSpec("clean"),
                { var spec = LaneSpec("clean 2"); spec.delaySamples = 320.5; return spec }(),
                { var spec = LaneSpec("quiet"); spec.content = .silence; return spec }()
            ],
            seed: 5
        )
        let result = ClapAligner().analyze(take.lanes)
        #expect(result.failureSummary == nil)
        let advice = SyncSessionMath.advice(for: result)
        #expect(advice?.contains("not detected") == true)

        // A take with no reference leads with the failure summary instead.
        let nothing = SyncResult(
            referenceLaneID: nil, lanes: [], sampleRate: Self.sampleRate,
            failureSummary: SyncResult.noClapFailureSummary
        )
        let failure = SyncSessionMath.advice(for: nothing)
        #expect(failure?.hasPrefix(SyncResult.noClapFailureSummary) == true)
        #expect(failure?.contains("CLAP NOW") == true)
        // Even without a summary the advice must not pretend anything worked.
        let bare = SyncResult(referenceLaneID: nil, lanes: [], sampleRate: Self.sampleRate)
        #expect(SyncSessionMath.advice(for: bare)?.contains("No clap") == true)
    }

    @Test func theWholeTakeIsDrawnWithItsOnsetAndPeakMarkers() {
        var near = SyncTestSignals.RoomLaneSpec("near")
        var far = SyncTestSignals.RoomLaneSpec("far")
        far.delaySamples = 260.5
        let take = SyncTestSignals.makeRoomTake([near, far], seed: 21, seconds: 4)
        let result = ClapAligner().analyze(take.lanes)

        let set = try! #require(SyncSessionMath.makeTakeEnvelopes(
            result: result, recordings: take.lanes,
            sampleRate: Self.sampleRate, endedEarly: true, points: 2000
        ))
        #expect(set.lanes.count == 2)
        #expect(set.pointCount == 2000)
        #expect(abs(set.durationSeconds - 4) < 0.01)
        #expect(set.endedEarly)
        for lane in set.lanes {
            #expect(lane.points.count == 2000)
            #expect(lane.points.allSatisfy { $0 >= 0 && $0 <= 1 })
            let onset = try! #require(lane.onsetPoint)
            let peak = try! #require(lane.peakPoint)
            // Both markers sit on the clap, which is somewhere past 1.5 s.
            let expected = take.clapPosition / (4 * Self.sampleRate) * 2000
            #expect(abs(onset - expected) < 4, "onset point \(onset) vs \(expected)")
            #expect(abs(peak - expected) < 4, "peak point \(peak) vs \(expected)")
            #expect(lane.isAligned)
            #expect((lane.dominanceDB ?? 0) >= 20)
            #expect(lane.notDetectedReason == nil)
        }
        _ = near
    }

    // MARK: - Early-stop transient watcher

    @Test func theProbeFindsTheClapAfterTheQuietHead() {
        var samples = [Float](repeating: 0, count: Int(2.0 * Self.sampleRate))
        for index in samples.indices {           // −60 dBFS room tone
            samples[index] = Float(sin(Double(index) * 0.31)) * 0.001
        }
        let clap = SyncTestSignals.makeClap(seed: 3)
        let arrival = Int(1.2 * Self.sampleRate)
        for (offset, value) in clap.enumerated() { samples[arrival + offset] += value * 0.5 }

        var probe = SyncOnsetProbe(sampleRate: Self.sampleRate)
        probe.append(samples)
        let onset = try? #require(probe.onsetSample)
        #expect(abs((onset ?? 0) - arrival) < Int(0.002 * Self.sampleRate))
        #expect(probe.scanned >= samples.count - probe.windowSamples)
    }

    @Test func feedingTheProbeInChunksMatchesFeedingItAllAtOnce() {
        var samples = [Float](repeating: 0, count: Int(2.5 * Self.sampleRate))
        for index in samples.indices { samples[index] = Float(sin(Double(index) * 0.11)) * 0.002 }
        // Past the one second of lead the probe insists on before anything can
        // count as a clap.
        let arrival = Int(1.9 * Self.sampleRate)
        for (offset, value) in SyncTestSignals.makeClap(seed: 11).enumerated() {
            samples[arrival + offset] += value * 0.4
        }

        var whole = SyncOnsetProbe(sampleRate: Self.sampleRate)
        whole.append(samples)

        // The live probe is fed whatever the render thread has published, in
        // lumps that do not divide by the window size.
        var chunked = SyncOnsetProbe(sampleRate: Self.sampleRate)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + 1913)
            chunked.append(Array(samples[index..<end]))
            index = end
        }
        #expect(whole.onsetSample != nil)
        #expect(chunked.onsetSample == whole.onsetSample)
        #expect(chunked.scanned == whole.scanned)
    }

    @Test func theProbeIgnoresARoomFullOfBurstsForTheWholeListenWindow() {
        var spec = SyncTestSignals.RoomLaneSpec("mic")
        spec.hasClap = false
        let room = SyncTestSignals.makeRoomTake([spec], seed: 606, seconds: 4)

        // Fed the way the session feeds it: whatever the render thread has
        // published since the last 40 ms poll.
        var probe = SyncOnsetProbe(sampleRate: Self.sampleRate)
        var index = 0
        while index < room.lanes[0].samples.count {
            let end = min(room.lanes[0].samples.count, index + 1913)
            probe.append(Array(room.lanes[0].samples[index..<end]))
            #expect(probe.onsetSample == nil, "fired at \(probe.onsetSample ?? -1)")
            index = end
        }
        #expect(probe.onsetSample == nil)
        #expect(probe.medianLevel > 0)
    }

    @Test func theProbeFiresOnTheClapAndNotBefore() {
        let room = SyncTestSignals.makeRoomTake(
            [SyncTestSignals.RoomLaneSpec("mic")], seed: 707, seconds: 5
        )
        let samples = room.lanes[0].samples
        let arrival = Int(room.clapPosition)

        var probe = SyncOnsetProbe(sampleRate: Self.sampleRate)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + 1913)
            probe.append(Array(samples[index..<end]))
            // Nothing in the room before the clap may end the take.
            if end < arrival { #expect(probe.onsetSample == nil, "fired at \(probe.onsetSample ?? -1)") }
            index = end
        }
        let onset = try! #require(probe.onsetSample)
        #expect(abs(onset - arrival) < Int(0.003 * Self.sampleRate),
                "onset \(onset) vs clap \(arrival)")
    }

    @Test func steadyRoomToneNeverLooksLikeAClap() {
        var samples = [Float](repeating: 0, count: Int(3.0 * Self.sampleRate))
        var seed: UInt64 = 12345
        for index in samples.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            samples[index] = Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max) * 0.01
        }
        var probe = SyncOnsetProbe(sampleRate: Self.sampleRate)
        probe.append(samples)
        #expect(probe.onsetSample == nil)
        #expect(probe.noiseFloor > 0)
    }

    @Test func roomToneAtTheLevelTheRigActuallyMeasuresIsNotAClap() {
        // The rig reads about −40 dBFS RMS of room tone on the DJI receiver.
        // A *mean* noise floor plus a bare 12 dB test fires on the first window
        // past the head and cuts the take before the user has clapped; the
        // median floor and the steepness test are what stop that.
        var seed: UInt64 = 99
        func noise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
        }
        var samples = [Float](repeating: 0, count: Int(3.0 * Self.sampleRate))
        for index in samples.indices { samples[index] = noise() * 0.017 }
        #expect(abs(20 * log10(SyncTestSignals.rms(samples)) + 40) < 2)

        var probe = SyncOnsetProbe(sampleRate: Self.sampleRate)
        probe.append(samples)
        #expect(probe.onsetSample == nil)
        #expect(abs(20 * log10(probe.noiseFloor) + 40) < 3)

        // The clap on top of that same tone still lands, in the right place.
        let arrival = Int(2.0 * Self.sampleRate)
        for (offset, value) in SyncTestSignals.makeClap(seed: 2).enumerated() {
            samples[arrival + offset] += value * 0.6
        }
        var second = SyncOnsetProbe(sampleRate: Self.sampleRate)
        second.append(samples)
        let onset = try? #require(second.onsetSample)
        #expect(abs((onset ?? 0) - arrival) < Int(0.003 * Self.sampleRate))
    }

    @Test func theLoudestTransientWinsSoAnEarlyBumpDoesNotEndTheTake() {
        var samples = [Float](repeating: 0, count: Int(3.0 * Self.sampleRate))
        for index in samples.indices { samples[index] = Float(sin(Double(index) * 0.37)) * 0.001 }
        let bump = Int(0.7 * Self.sampleRate)
        for (offset, value) in SyncTestSignals.makeClap(seed: 21).enumerated() {
            samples[bump + offset] += value * 0.02
        }
        let clap = Int(2.2 * Self.sampleRate)
        for (offset, value) in SyncTestSignals.makeClap(seed: 22).enumerated() {
            samples[clap + offset] += value * 0.7
        }
        var probe = SyncOnsetProbe(sampleRate: Self.sampleRate)
        probe.append(samples)
        // The bump is a transient too, but the clap supersedes it, so the take
        // keeps running until a second after the real thing.
        #expect(abs((probe.onsetSample ?? 0) - clap) < Int(0.003 * Self.sampleRate))
    }

    @Test func aDigitallySilentLaneDoesNotTriggerOnItsOwnFloor() {
        // Median of zero would make 12 dB above the floor trivially reachable.
        var samples = [Float](repeating: 0, count: Int(1.0 * Self.sampleRate))
        for index in Int(0.6 * Self.sampleRate)..<samples.count {
            samples[index] = 1e-6      // far below anything audible
        }
        var probe = SyncOnsetProbe(sampleRate: Self.sampleRate)
        probe.append(samples)
        #expect(probe.onsetSample == nil)
    }
}
