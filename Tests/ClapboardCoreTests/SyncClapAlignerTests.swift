import ClapboardCore
import Foundation
import Testing

private typealias LaneSpec = SyncTestSignals.LaneSpec

@Suite("ClapAligner")
struct SyncClapAlignerTests {
    let aligner = ClapAligner()

    // MARK: - Clean signals

    // 15 dB of clap-to-noise is where a 1 ms clap peak still stands the
    // required 20 dB above the median of the take; below that the clap is no
    // longer dominant and is refused on purpose — see
    // `refusesAClapThatDoesNotStandOutFromTheRoom`.
    @Test("clean lanes at 40, 20 and 15 dB SNR land within half a sample",
          arguments: [40.0, 20.0, 15.0])
    func alignsCleanLanes(snrdB: Double) {
        var near = LaneSpec("near")
        near.snrdB = snrdB
        var middle = LaneSpec("middle")
        middle.delaySamples = 137.3
        middle.snrdB = snrdB
        var far = LaneSpec("far")
        far.delaySamples = 641.9
        far.snrdB = snrdB

        let take = SyncTestSignals.makeTake([near, middle, far], seed: UInt64(snrdB) &+ 11)
        let result = aligner.analyze(take.lanes)

        #expect(result.referenceLaneID != nil)
        for lane in take.lanes {
            let laneResult = result[lane.laneID]
            #expect(
                laneResult?.status.isAligned == true,
                "\(lane.label): \(String(describing: laneResult?.status))"
            )
            let error = result.offsetError(laneID: lane.laneID, truth: take.truth) ?? .infinity
            #expect(abs(error) <= 0.5, "\(lane.label) off by \(error) samples at \(snrdB) dB")
        }
    }

    @Test("a clap that does not stand out from the room is refused, not guessed")
    func refusesAClapThatDoesNotStandOutFromTheRoom() {
        var near = LaneSpec("near")
        near.snrdB = 5
        var far = LaneSpec("far")
        far.delaySamples = 137.3
        far.snrdB = 5

        let take = SyncTestSignals.makeTake([near, far], seed: 555)
        let result = aligner.analyze(take.lanes)

        #expect(result.referenceLaneID == nil)
        #expect(result.failureSummary == SyncResult.noClapFailureSummary)
        for lane in result.lanes {
            #expect(lane.status.isAligned == false)
            #expect(lane.suggestedDelaySamples == nil)
            #expect((lane.levels?.dominanceDB ?? 99) < 20)
        }
        #expect(result.lanes.contains {
            $0.status.notDetectedReason?.contains("no dominant transient") == true
        })
    }

    // MARK: - Rooms

    @Test("discrete echoes and a diffuse tail stay inside one sample")
    func alignsThroughReverberation() {
        var direct = LaneSpec("stage")
        direct.snrdB = 30
        direct.echoes = [(11, 0.35)]
        direct.reverbTailDB = -18

        var reflective = LaneSpec("corner")
        reflective.delaySamples = 402.4
        reflective.snrdB = 30
        reflective.echoes = [(5, 0.7), (17, 0.5), (34, 0.4)]
        reflective.reverbTailDB = -12

        var boomy = LaneSpec("ceiling")
        boomy.delaySamples = -213.6
        boomy.snrdB = 26
        boomy.echoes = [(8, 0.6), (23, 0.45)]
        boomy.reverbTailDB = -12

        let take = SyncTestSignals.makeTake([direct, reflective, boomy], seed: 4242)
        let result = aligner.analyze(take.lanes)

        for lane in take.lanes {
            #expect(result[lane.laneID]?.status.isAligned == true, "\(lane.label)")
            let error = result.offsetError(laneID: lane.laneID, truth: take.truth) ?? .infinity
            #expect(abs(error) <= 1.0, "\(lane.label) off by \(error) samples")
        }
    }

    // MARK: - Awkward lanes

    @Test("a lane 30 dB quieter than the rest still aligns")
    func alignsQuietLane() {
        var loud = LaneSpec("loud")
        loud.snrdB = 35
        var quiet = LaneSpec("quiet")
        quiet.delaySamples = 318.7
        quiet.snrdB = 30
        quiet.gain = 0.0316
        quiet.noiseFloorRMS = 3e-5

        let take = SyncTestSignals.makeTake([loud, quiet], seed: 77)
        let result = aligner.analyze(take.lanes)

        #expect(result.referenceLaneID == take.lanes[0].laneID)
        #expect(result[take.lanes[1].laneID]?.status.isAligned == true)
        let error = result.offsetError(laneID: take.lanes[1].laneID, truth: take.truth) ?? .infinity
        #expect(abs(error) <= 1.0, "quiet lane off by \(error) samples")
    }

    @Test("a hard clipped lane aligns and is flagged")
    func flagsClippedLane() {
        var clean = LaneSpec("clean")
        clean.snrdB = 35
        var hot = LaneSpec("hot")
        hot.delaySamples = 96.4
        hot.snrdB = 35
        hot.clipGain = 6

        let take = SyncTestSignals.makeTake([clean, hot], seed: 909)
        let result = aligner.analyze(take.lanes)

        let hotResult = result[take.lanes[1].laneID]
        #expect(hotResult?.clipped == true)
        #expect(result[take.lanes[0].laneID]?.clipped == false)
        #expect(hotResult?.status.isAligned == true, "\(String(describing: hotResult?.status))")
        let error = result.offsetError(laneID: take.lanes[1].laneID, truth: take.truth) ?? .infinity
        #expect(abs(error) <= 1.0, "clipped lane off by \(error) samples")
    }

    @Test("silent, musical and unrelated lanes are reported, not aligned")
    func reportsLanesThatNeverHeardTheClap() {
        var good = LaneSpec("mic")
        good.snrdB = 35
        var second = LaneSpec("mic 2")
        second.delaySamples = 240.5
        second.snrdB = 35
        var silent = LaneSpec("unplugged")
        silent.content = .silence
        var music = LaneSpec("music bed")
        music.content = .music
        var foreign = LaneSpec("other room")
        foreign.content = .foreignTransient(offsetSeconds: 0.08)
        foreign.snrdB = 25

        let take = SyncTestSignals.makeTake([good, second, silent, music, foreign], seed: 31337)
        let result = aligner.analyze(take.lanes)

        #expect(result[take.lanes[0].laneID]?.status.isAligned == true)
        #expect(result[take.lanes[1].laneID]?.status.isAligned == true)

        let silentStatus = result[take.lanes[2].laneID]?.status
        #expect(silentStatus?.isAligned == false)
        #expect(silentStatus?.notDetectedReason?.contains("silent") == true)
        #expect(result[take.lanes[2].laneID]?.suggestedDelaySamples == nil)

        let musicStatus = result[take.lanes[3].laneID]?.status
        #expect(musicStatus?.isAligned == false, "\(String(describing: musicStatus))")
        #expect(musicStatus?.notDetectedReason?.contains("transient") == true)

        let foreignStatus = result[take.lanes[4].laneID]?.status
        #expect(foreignStatus?.isAligned == false, "\(String(describing: foreignStatus))")
        #expect(foreignStatus?.notDetectedReason?.contains("ambiguous") == true)
    }

    @Test("a virtual lane is measured but never becomes the reference")
    func neverPicksVirtualLaneAsReference() {
        var virtualLane = LaneSpec("Loopback")
        virtualLane.snrdB = 60
        virtualLane.isVirtual = true
        var mic = LaneSpec("mic")
        mic.delaySamples = 512.25
        mic.snrdB = 30
        var otherMic = LaneSpec("mic 2")
        otherMic.delaySamples = 128.5
        otherMic.snrdB = 28

        let take = SyncTestSignals.makeTake([virtualLane, mic, otherMic], seed: 5150)
        let result = aligner.analyze(take.lanes)

        #expect(result.referenceLaneID != take.lanes[0].laneID)
        #expect(result.referenceLaneID != nil)
        #expect(result[take.lanes[0].laneID]?.status.isAligned == true)
        let error = result.offsetError(laneID: take.lanes[0].laneID, truth: take.truth) ?? .infinity
        #expect(abs(error) <= 1.0, "virtual lane off by \(error) samples")
    }

    @Test("a virtual lane that heard nothing is reported, not aligned")
    func reportsSilentVirtualLane() {
        var mic = LaneSpec("mic")
        mic.snrdB = 35
        var other = LaneSpec("mic 2")
        other.delaySamples = 200
        other.snrdB = 35
        var virtualLane = LaneSpec("Loopback")
        virtualLane.content = .silence
        virtualLane.isVirtual = true

        let take = SyncTestSignals.makeTake([mic, other, virtualLane], seed: 606)
        let result = aligner.analyze(take.lanes)
        #expect(result[take.lanes[2].laneID]?.status.isAligned == false)
        #expect(result[take.lanes[2].laneID]?.suggestedDelaySamples == nil)
    }

    // MARK: - Search window

    @Test("an arrival just inside the search window is still measured")
    func alignsAtSearchWindowEdge() {
        var early = LaneSpec("early")
        early.snrdB = 35
        var late = LaneSpec("late")
        late.delaySamples = 0.24 * SyncTestSignals.sampleRate
        late.snrdB = 35

        let take = SyncTestSignals.makeTake([early, late], seed: 240, clapPosition: 0.5 * 48_000)
        let result = aligner.analyze(take.lanes)

        #expect(result[take.lanes[1].laneID]?.status.isAligned == true)
        let error = result.offsetError(laneID: take.lanes[1].laneID, truth: take.truth) ?? .infinity
        #expect(abs(error) <= 1.0, "edge lane off by \(error) samples")
    }

    @Test("an arrival past the search window is refused instead of guessed")
    func refusesArrivalBeyondSearchWindow() {
        var early = LaneSpec("early")
        early.snrdB = 35
        var tooLate = LaneSpec("too late")
        tooLate.delaySamples = 0.30 * SyncTestSignals.sampleRate
        tooLate.snrdB = 35

        let take = SyncTestSignals.makeTake([early, tooLate], seed: 300, clapPosition: 0.5 * 48_000)
        let result = aligner.analyze(take.lanes)

        // Neither lane can explain the other, so the take has no reference at
        // all: one lane says why it was out of range, the other says nobody
        // matched it. Nothing is written either way.
        #expect(result.referenceLaneID == nil)
        #expect(result.failureSummary == SyncResult.noClapFailureSummary)
        #expect(result.lanes.allSatisfy { $0.status.isAligned == false })
        #expect(result.lanes.allSatisfy { $0.suggestedDelaySamples == nil })
        #expect(
            result.lanes.contains {
                $0.status.notDetectedReason?.contains("search window") == true
            },
            "\(result.lanes.map { $0.status.notDetectedReason ?? "aligned" })"
        )
    }

    @Test("a reference nobody matched is not a reference")
    func refusesATakeOnlyOneLaneHeard() {
        var heard = LaneSpec("heard it")
        heard.snrdB = 35
        var missed = LaneSpec("missed it")
        missed.content = .silence

        let take = SyncTestSignals.makeTake([heard, missed], seed: 4004)
        let result = aligner.analyze(take.lanes)

        #expect(result.referenceLaneID == nil)
        #expect(result.failureSummary == SyncResult.noClapFailureSummary)
        #expect(result.alignedLanes.isEmpty)
        #expect(
            result[take.lanes[0].laneID]?.status.notDetectedReason
                == "no other lane matched this clap"
        )
        #expect(result[take.lanes[1].laneID]?.status.notDetectedReason?.contains("silent") == true)
        // The lane still reports the levels that explain the verdict.
        #expect((result[take.lanes[0].laneID]?.levels?.dominanceDB ?? 0) > 20)
    }

    @Test("two claps in one take still align on the loudest of them")
    func alignsOnTheLoudestOfTwoClaps() {
        var near = LaneSpec("near")
        near.snrdB = 30
        var far = LaneSpec("far")
        far.delaySamples = 421.5
        far.snrdB = 30

        let take = SyncTestSignals.makeTake([near, far], seed: 1_357, clapPosition: 0.6 * 48_000)
        let second = SyncTestSignals.makeClap(seed: 2_468)
        let gap = 1.5 * 48_000
        let delays = [0.0, 421.5]
        let lanes = zip(take.lanes, delays).map { lane, delay -> LaneRecording in
            var samples = lane.samples
            SyncTestSignals.add(
                clap: second, to: &samples,
                at: take.clapPosition + gap + delay,
                amplitude: SyncTestSignals.clapLevel * 1.5
            )
            return LaneRecording(
                laneID: lane.laneID, label: lane.label, samples: samples,
                sampleRate: lane.sampleRate, isVirtual: lane.isVirtual
            )
        }

        let result = aligner.analyze(lanes)
        #expect(result.referenceLaneID != nil)
        #expect(result.failureSummary == nil)
        for lane in lanes {
            #expect(result[lane.laneID]?.status.isAligned == true, "\(lane.label)")
            #expect(result[lane.laneID]?.levels?.multipleTransients == true, "\(lane.label)")
            let error = result.offsetError(laneID: lane.laneID, truth: take.truth) ?? .infinity
            #expect(abs(error) <= 1.0, "\(lane.label) off by \(error) samples")
        }
    }

    // MARK: - A real room

    @Test("a room with one clap on two lanes is measured; the same room without one is refused",
          arguments: [UInt64(11), 12, 13, 14])
    func measuresARoomTakeAndRefusesAClaplessOne(seed: UInt64) {
        var near = SyncTestSignals.RoomLaneSpec("near")
        var far = SyncTestSignals.RoomLaneSpec("far")
        far.delaySamples = 317.4

        let heard = SyncTestSignals.makeRoomTake([near, far], seed: seed)
        let result = aligner.analyze(heard.lanes)
        #expect(result.failureSummary == nil)
        #expect(result.referenceLaneID != nil)
        for lane in heard.lanes {
            #expect(result[lane.laneID]?.status.isAligned == true, "\(lane.label)")
            let error = result.offsetError(laneID: lane.laneID, truth: heard.truth) ?? .infinity
            #expect(abs(error) <= 1.0, "\(lane.label) off by \(error) samples")
            #expect((result[lane.laneID]?.levels?.dominanceDB ?? 0) >= 20)
        }

        // The same room, nobody clapped: nothing may be measured or applied.
        near.hasClap = false
        far.hasClap = false
        let missed = SyncTestSignals.makeRoomTake([near, far], seed: seed)
        let empty = aligner.analyze(missed.lanes)
        #expect(empty.referenceLaneID == nil)
        #expect(empty.failureSummary == SyncResult.noClapFailureSummary)
        #expect(empty.alignedLanes.isEmpty)
        #expect(empty.lanes.allSatisfy { $0.suggestedDelaySamples == nil })
        #expect(empty.lanes.allSatisfy {
            $0.status.notDetectedReason?.contains("no dominant transient") == true
        })
        #expect(SyncSessionMath.delayAssignments(from: empty).isEmpty)
    }

    @Test("a room where only one lane heard the clap fails instead of aligning one lane")
    func refusesARoomOnlyOneLaneHeard() {
        var heard = SyncTestSignals.RoomLaneSpec("heard it")
        var missed = SyncTestSignals.RoomLaneSpec("missed it")
        missed.hasClap = false
        missed.delaySamples = 200

        let take = SyncTestSignals.makeRoomTake([heard, missed], seed: 4_242)
        let result = aligner.analyze(take.lanes)

        #expect(result.referenceLaneID == nil)
        #expect(result.failureSummary == SyncResult.noClapFailureSummary)
        #expect(result.alignedLanes.isEmpty)
        #expect(result.notDetectedLanes.count == 2)
        #expect(
            result[take.lanes[0].laneID]?.status.notDetectedReason
                == "no other lane matched this clap"
        )
        // The lane that did hear it still reports a healthy dominance, so the
        // sheet can say "one lane heard a clap and nobody else did".
        #expect((result[take.lanes[0].laneID]?.levels?.dominanceDB ?? 0) >= 20)
        #expect((result[take.lanes[1].laneID]?.levels?.dominanceDB ?? 99) < 20)
        _ = heard
    }

    // MARK: - Delays

    @Test("suggested delays are non-negative and only the latest lane gets zero")
    func suggestedDelaysCatchUpToTheLatestLane() {
        var near = LaneSpec("near")
        near.snrdB = 35
        var middle = LaneSpec("middle")
        middle.delaySamples = 137.3
        middle.snrdB = 35
        var far = LaneSpec("far")
        far.delaySamples = 641.9
        far.snrdB = 35

        let take = SyncTestSignals.makeTake([near, middle, far], seed: 8080)
        let result = aligner.analyze(take.lanes)

        let delays = take.lanes.compactMap { result[$0.laneID]?.suggestedDelaySamples }
        #expect(delays.count == 3)
        #expect(delays.allSatisfy { $0 >= 0 })
        #expect(delays.filter { $0 == 0 }.count == 1)
        #expect(result[take.lanes[2].laneID]?.suggestedDelaySamples == 0)
        #expect(abs((delays[0]) - 642) <= 1, "near delay \(delays[0])")
        #expect(abs((delays[1]) - 505) <= 1, "middle delay \(delays[1])")

        let milliseconds = result[take.lanes[0].laneID]?.suggestedDelayMs ?? 0
        #expect(abs(milliseconds - 642.0 / 48.0) < 0.05)
    }

    // MARK: - Several takes

    @Test("three takes agree and produce one combined answer")
    func combinesSeveralTakes() {
        var near = LaneSpec("near")
        near.snrdB = 28
        var far = LaneSpec("far")
        far.delaySamples = 903.4
        far.snrdB = 28

        let takes = (0..<3).map { index in
            SyncTestSignals.makeTake([near, far], seed: 900 &+ UInt64(index) &* 17)
        }
        // The same lanes across takes: reuse take 0's identities.
        let laneIDs = takes[0].lanes.map(\.laneID)
        let aligned = takes.map { take in
            zip(take.lanes, laneIDs).map { lane, laneID in
                LaneRecording(
                    laneID: laneID, label: lane.label, samples: lane.samples,
                    sampleRate: lane.sampleRate, isVirtual: lane.isVirtual
                )
            }
        }

        let result = aligner.analyzeMultiple(aligned)
        #expect(result.referenceLaneID != nil)
        for laneResult in result.lanes {
            #expect(laneResult.status.isAligned == true, "\(laneResult.label)")
            #expect((laneResult.status.confidence ?? 0) > 0.5)
        }
        let measured = result[laneIDs[1]]?.status.offsetSamples ?? .infinity
        let reference = result[laneIDs[0]]?.status.offsetSamples ?? 0
        #expect(abs((measured - reference) - 903.4) <= 24, "spread \(measured - reference)")
        #expect(abs((measured - reference) - 903.4) <= 1)
    }

    @Test("one bad take is outvoted by the two that agree")
    func rejectsOutlierTake() {
        var near = LaneSpec("near")
        near.snrdB = 30
        var far = LaneSpec("far")
        far.delaySamples = 400.5
        far.snrdB = 30
        var displaced = far
        displaced.delaySamples = 400.5 + 2000

        let goodTakes = (0..<2).map { index in
            SyncTestSignals.makeTake([near, far], seed: 1500 &+ UInt64(index) &* 23)
        }
        let badTake = SyncTestSignals.makeTake([near, displaced], seed: 1600)

        let laneIDs = goodTakes[0].lanes.map(\.laneID)
        func rekey(_ take: SyncTestSignals.Take) -> [LaneRecording] {
            zip(take.lanes, laneIDs).map { lane, laneID in
                LaneRecording(
                    laneID: laneID, label: lane.label, samples: lane.samples,
                    sampleRate: lane.sampleRate, isVirtual: lane.isVirtual
                )
            }
        }

        // The bad take on its own really does measure the wrong thing.
        let soloBad = aligner.analyze(rekey(badTake))
        let soloOffset = (soloBad[laneIDs[1]]?.status.offsetSamples ?? 0)
            - (soloBad[laneIDs[0]]?.status.offsetSamples ?? 0)
        #expect(abs(soloOffset - 2400.5) <= 1)

        let result = aligner.analyzeMultiple(goodTakes.map(rekey) + [rekey(badTake)])
        let measured = (result[laneIDs[1]]?.status.offsetSamples ?? .infinity)
            - (result[laneIDs[0]]?.status.offsetSamples ?? 0)
        #expect(result[laneIDs[1]]?.status.isAligned == true)
        #expect(abs(measured - 400.5) <= 1, "combined offset \(measured)")
    }

    @Test("a single take through analyzeMultiple matches analyze")
    func singleTakeMatchesAnalyze() {
        var near = LaneSpec("near")
        near.snrdB = 30
        var far = LaneSpec("far")
        far.delaySamples = 250.5
        far.snrdB = 30
        let take = SyncTestSignals.makeTake([near, far], seed: 2024)

        let single = aligner.analyze(take.lanes)
        let multiple = aligner.analyzeMultiple([take.lanes])
        #expect(single.referenceLaneID == multiple.referenceLaneID)
        for lane in take.lanes {
            #expect(
                single[lane.laneID]?.status.offsetSamples
                    == multiple[lane.laneID]?.status.offsetSamples
            )
        }
    }

    // MARK: - Verify

    @Test("the residual after applying the suggested delay is under a sample")
    func verifierConfirmsAppliedDelay() {
        var near = LaneSpec("near")
        near.snrdB = 32
        var far = LaneSpec("far")
        far.delaySamples = 733.6
        far.snrdB = 32

        let take = SyncTestSignals.makeTake([near, far], seed: 6161)
        let result = aligner.analyze(take.lanes)

        let latest = take.lanes[1]
        let catchingUp = take.lanes[0]
        #expect(result[latest.laneID]?.suggestedDelaySamples == 0)
        let delay = try! #require(result[catchingUp.laneID]?.suggestedDelaySamples)

        let residual = SyncVerifier.residual(
            reference: latest, lane: catchingUp, appliedDelaySamples: delay
        )
        let value = try! #require(residual)
        #expect(abs(value) <= 1.0, "residual \(value) samples")

        // A wrong delay must show up as a residual, otherwise the check is
        // not measuring anything.
        let wrong = SyncVerifier.residual(
            reference: latest, lane: catchingUp, appliedDelaySamples: delay + 24
        )
        #expect(abs(try! #require(wrong) - 24) <= 1)
    }

    @Test("the lane wired out of phase is the one that gets flagged")
    func flagsInvertedPolarity() {
        var upright = LaneSpec("upright")
        upright.snrdB = 32
        var second = LaneSpec("upright 2")
        second.delaySamples = 88.2
        second.snrdB = 32
        var flipped = LaneSpec("flipped")
        flipped.delaySamples = 220.4
        flipped.snrdB = 32
        flipped.gain = -1

        let take = SyncTestSignals.makeTake([upright, second, flipped], seed: 1212)
        let result = aligner.analyze(take.lanes)

        // Two upright lanes outvote the flipped one, whichever became the
        // reference.
        #expect(result[take.lanes[0].laneID]?.status.polarityInverted == false)
        #expect(result[take.lanes[1].laneID]?.status.polarityInverted == false)
        #expect(result[take.lanes[2].laneID]?.status.polarityInverted == true)
        let error = result.offsetError(laneID: take.lanes[2].laneID, truth: take.truth) ?? .infinity
        #expect(abs(error) <= 1.0, "inverted lane off by \(error) samples")
    }

    @Test("takes that never agree leave the lane alone")
    func refusesWhenTakesDisagree() {
        var near = LaneSpec("near")
        near.snrdB = 30
        let displacements = [400.5, 3000.5, 6000.5]
        let takes = displacements.enumerated().map { index, delay -> SyncTestSignals.Take in
            var far = LaneSpec("far")
            far.delaySamples = delay
            far.snrdB = 30
            return SyncTestSignals.makeTake([near, far], seed: 700 &+ UInt64(index) &* 13)
        }
        let laneIDs = takes[0].lanes.map(\.laneID)
        let rekeyed = takes.map { take in
            zip(take.lanes, laneIDs).map { lane, laneID in
                LaneRecording(
                    laneID: laneID, label: lane.label, samples: lane.samples,
                    sampleRate: lane.sampleRate, isVirtual: lane.isVirtual
                )
            }
        }

        // Whichever lane anchors the takes, the other one moved every time and
        // must be refused — which leaves the anchor with nobody to be measured
        // against, so the whole take fails rather than pretending to be half
        // aligned.
        let result = aligner.analyzeMultiple(rekeyed)
        #expect(result.referenceLaneID == nil)
        #expect(result.failureSummary == SyncResult.noClapFailureSummary)
        #expect(result.alignedLanes.isEmpty)
        #expect(result.lanes.allSatisfy { $0.suggestedDelaySamples == nil })
        let reasons = result.lanes.compactMap { $0.status.notDetectedReason }
        #expect(reasons.contains { $0.contains("disagree") }, "\(reasons)")
        #expect(reasons.contains { $0.contains("no other lane matched") }, "\(reasons)")
    }

    @Test("accuracy holds across many random claps, not just one lucky seed")
    func staysAccurateAcrossSeeds() {
        var worstClean = 0.0
        var worstRoom = 0.0
        var rejected = 0

        for seed in 0..<8 {
            var near = LaneSpec("near")
            near.snrdB = 15
            var middle = LaneSpec("middle")
            middle.delaySamples = 137.3
            middle.snrdB = 15
            var far = LaneSpec("far")
            far.delaySamples = 641.9
            far.snrdB = 15
            let clean = SyncTestSignals.makeTake(
                [near, middle, far], seed: UInt64(seed) &* 7 &+ 3
            )
            let cleanResult = aligner.analyze(clean.lanes)
            for lane in clean.lanes {
                guard cleanResult[lane.laneID]?.status.isAligned == true else {
                    rejected += 1
                    continue
                }
                let error = cleanResult.offsetError(laneID: lane.laneID, truth: clean.truth) ?? 99
                worstClean = max(worstClean, abs(error))
            }

            var stage = LaneSpec("stage")
            stage.snrdB = 30
            stage.echoes = [(11, 0.35)]
            stage.reverbTailDB = -18
            var corner = LaneSpec("corner")
            corner.delaySamples = 402.4
            corner.snrdB = 30
            corner.echoes = [(5, 0.7), (17, 0.5), (34, 0.4)]
            corner.reverbTailDB = -12
            let room = SyncTestSignals.makeTake([stage, corner], seed: UInt64(seed) &* 13 &+ 5)
            let roomResult = aligner.analyze(room.lanes)
            for lane in room.lanes {
                guard roomResult[lane.laneID]?.status.isAligned == true else {
                    rejected += 1
                    continue
                }
                let error = roomResult.offsetError(laneID: lane.laneID, truth: room.truth) ?? 99
                worstRoom = max(worstRoom, abs(error))
            }
        }

        #expect(rejected == 0)
        #expect(worstClean <= 0.5, "worst clean error \(worstClean) samples")
        #expect(worstRoom <= 1.0, "worst reverberant error \(worstRoom) samples")
    }

    @Test("the same take analysed twice gives the same answer")
    func isDeterministic() {
        var near = LaneSpec("near")
        near.snrdB = 30
        var far = LaneSpec("far")
        far.delaySamples = 333.3
        far.snrdB = 30
        var twin = LaneSpec("twin")
        twin.delaySamples = 333.3
        twin.snrdB = 30
        let take = SyncTestSignals.makeTake([near, far, twin], seed: 4)

        let first = aligner.analyze(take.lanes)
        let second = aligner.analyze(take.lanes)
        #expect(first.referenceLaneID == second.referenceLaneID)
        for lane in take.lanes {
            #expect(first[lane.laneID]?.status == second[lane.laneID]?.status)
            #expect(
                first[lane.laneID]?.suggestedDelaySamples
                    == second[lane.laneID]?.suggestedDelaySamples
            )
        }
    }

    // MARK: - Degenerate input

    @Test("no lanes, one lane and mismatched rates do not crash")
    func handlesDegenerateInput() {
        #expect(aligner.analyze([]).lanes.isEmpty)
        #expect(aligner.analyzeMultiple([]).lanes.isEmpty)

        // One lane cannot be measured against anything, however good its clap
        // is: Auto Sync needs two lanes that heard the same thing.
        var solo = LaneSpec("solo")
        solo.snrdB = 30
        let take = SyncTestSignals.makeTake([solo], seed: 1)
        let single = aligner.analyze(take.lanes)
        #expect(single.referenceLaneID == nil)
        #expect(single.failureSummary == SyncResult.noClapFailureSummary)
        #expect(single[take.lanes[0].laneID]?.suggestedDelaySamples == nil)

        let odd = LaneRecording(
            label: "44.1k", samples: take.lanes[0].samples, sampleRate: 44_100
        )
        let mixed = aligner.analyze([take.lanes[0], odd])
        #expect(mixed[odd.laneID]?.status.isAligned == false)
        #expect(mixed[odd.laneID]?.status.notDetectedReason?.contains("sample rate") == true)
    }
}
