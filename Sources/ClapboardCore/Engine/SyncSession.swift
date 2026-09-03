import Foundation
import Observation

/// One lane as the Auto Sync sheet offers it.
public struct SyncLaneOption: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let label: String
    public let deviceName: String
    /// Loopback / Audio Hijack and friends. They are measured when the user
    /// insists, but never lead and are off by default: they cannot hear a clap,
    /// they replay somebody else's clock.
    public let isVirtual: Bool
    public let currentDelaySamples: Int

    public init(
        id: UUID,
        label: String,
        deviceName: String,
        isVirtual: Bool,
        currentDelaySamples: Int
    ) {
        self.id = id
        self.label = label
        self.deviceName = deviceName
        self.isVirtual = isVirtual
        self.currentDelaySamples = currentDelaySamples
    }
}

/// One lane's downsampled envelope, drawn twice by the result page: at its own
/// arrival time, and shifted right by the delay Auto Sync suggests.
public struct SyncEnvelope: Identifiable, Sendable {
    public var id: UUID { laneID }
    public let laneID: UUID
    public let label: String
    /// Peak magnitude per bucket, normalised to this lane's own maximum.
    public let points: [Float]
    /// Coarse onset, in points, or `nil` when the lane heard nothing.
    public let onsetPoint: Double?
    /// Points the "after" trace is shifted right by.
    public let shiftPoints: Double
    public let isAligned: Bool

    public init(
        laneID: UUID,
        label: String,
        points: [Float],
        onsetPoint: Double?,
        shiftPoints: Double,
        isAligned: Bool
    ) {
        self.laneID = laneID
        self.label = label
        self.points = points
        self.onsetPoint = onsetPoint
        self.shiftPoints = shiftPoints
        self.isAligned = isAligned
    }
}

/// Everything the result page needs to draw the overlay, on one shared time
/// axis. Computed once, in the session — never in a SwiftUI `body`.
public struct SyncEnvelopeSet: Sendable {
    public let lanes: [SyncEnvelope]
    public let samplesPerPoint: Double
    public let sampleRate: Double
    public var pointCount: Int { lanes.first?.points.count ?? 0 }
    /// Width of the drawn window in milliseconds.
    public var spanMilliseconds: Double {
        sampleRate > 0 ? Double(pointCount) * samplesPerPoint / sampleRate * 1000 : 0
    }

    public init(lanes: [SyncEnvelope], samplesPerPoint: Double, sampleRate: Double) {
        self.lanes = lanes
        self.samplesPerPoint = samplesPerPoint
        self.sampleRate = sampleRate
    }
}

/// One lane's envelope over the *whole* take, at the top of the result page.
///
/// The zoomed overlay below it only shows the few hundred milliseconds around
/// the clap; this is what proves the analysed window *was* a clap — one spike
/// out of a flat room — or shows at a glance that it was not.
public struct SyncTakeEnvelope: Identifiable, Sendable {
    public var id: UUID { laneID }
    public let laneID: UUID
    public let label: String
    /// Peak magnitude per bucket, normalised to this lane's own maximum.
    public let points: [Float]
    /// Where the attack was found, in points, or `nil` when nothing was.
    public let onsetPoint: Double?
    /// The loudest 1 ms window, in points. Marked even on a refused lane: it
    /// is the thing that was measured and rejected.
    public let peakPoint: Double?
    public let isAligned: Bool
    /// How far the peak stood above the room, for the caption.
    public let dominanceDB: Double?
    public let multipleTransients: Bool
    /// Why the lane was refused, `nil` when it was not.
    public let notDetectedReason: String?

    public init(
        laneID: UUID,
        label: String,
        points: [Float],
        onsetPoint: Double?,
        peakPoint: Double?,
        isAligned: Bool,
        dominanceDB: Double?,
        multipleTransients: Bool,
        notDetectedReason: String?
    ) {
        self.laneID = laneID
        self.label = label
        self.points = points
        self.onsetPoint = onsetPoint
        self.peakPoint = peakPoint
        self.isAligned = isAligned
        self.dominanceDB = dominanceDB
        self.multipleTransients = multipleTransients
        self.notDetectedReason = notDetectedReason
    }
}

/// Every lane's whole take on one axis. Computed in the session, never in a
/// SwiftUI `body`.
public struct SyncTakeEnvelopeSet: Sendable {
    public let lanes: [SyncTakeEnvelope]
    public let sampleRate: Double
    public let samplesPerPoint: Double
    public let durationSeconds: Double
    /// The take stopped as soon as the clap had its tail.
    public let endedEarly: Bool
    public var pointCount: Int { lanes.first?.points.count ?? 0 }

    public init(
        lanes: [SyncTakeEnvelope],
        sampleRate: Double,
        samplesPerPoint: Double,
        durationSeconds: Double,
        endedEarly: Bool
    ) {
        self.lanes = lanes
        self.sampleRate = sampleRate
        self.samplesPerPoint = samplesPerPoint
        self.durationSeconds = durationSeconds
        self.endedEarly = endedEarly
    }
}

/// What "Verify" found for one lane after the delays were applied.
public struct SyncVerification: Sendable {
    public let laneID: UUID
    public let label: String
    /// Residual misalignment in samples; `nil` when the clap could not be
    /// re-measured on this lane.
    public let residualSamples: Double?
    public let sampleRate: Double

    public var residualMilliseconds: Double? {
        guard let residualSamples, sampleRate > 0 else { return nil }
        return residualSamples / sampleRate * 1000
    }

    public init(laneID: UUID, label: String, residualSamples: Double?, sampleRate: Double) {
        self.laneID = laneID
        self.label = label
        self.residualSamples = residualSamples
        self.sampleRate = sampleRate
    }
}

/// The Auto Sync flow: arm, listen for the clap, analyse, show, apply, verify.
///
/// The DSP is `ClapAligner`'s and the capture is the render kernel's; this is
/// the state machine that joins them and the only place the UI talks to.
@MainActor
@Observable
public final class SyncSession {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Room tone is already being recorded — the noise floor needs a
        /// clap-free head — and the user is being told to get ready.
        case armed(secondsRemaining: Double)
        case listening(take: Int, of: Int)
        case analysing
        case results
        case verifying
        case done
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .armed, .listening, .analysing, .verifying: return true
            default: return false
            }
        }

        public var showsResults: Bool {
            switch self {
            case .results, .verifying, .done: return true
            default: return false
            }
        }
    }

    // MARK: - Options

    /// Lanes to record. Defaults to every lane whose device is not virtual.
    public var includedLaneIDs: Set<UUID> = []
    /// Claps to average. 1…3; two takes have to agree before a lane is green.
    ///
    /// Clamped where it is read, not in a `didSet`: `@Observable` turns stored
    /// properties into accessors, and assigning to one inside its own observer
    /// re-enters the setter for ever.
    public var takeCount: Int = 1
    public var boundedTakeCount: Int { min(3, max(1, takeCount)) }
    /// `SyncOptions.maxLagSeconds`: how far apart two lanes may arrive.
    public var maxLagSeconds: Double = 0.25
    /// Drops `minPeakRatio` from 3 to 2 — for a hard room where lanes get
    /// refused rather than mismeasured.
    public var relaxed: Bool = false
    /// `SyncOptions.analysisWindowSeconds`.
    public var analysisWindowSeconds: Double = 0.02

    /// How long CLAP NOW stays up. The whole point is that it is a *fixed*
    /// window a human can react inside: the take is not cut short the moment
    /// something bangs, only when a genuinely dominant transient has been
    /// heard and its tail recorded.
    public var listenSeconds: Double = 4
    public var boundedListenSeconds: Double { min(8, max(3, listenSeconds)) }

    /// Hard ceiling on one take, room tone included. The capture buffer is
    /// armed for this, so a clap near the end of the listen window can still
    /// have its tail recorded.
    public static let maxTakeSeconds: Double = 8
    /// Room tone recorded before the user is told to clap. `SyncOptions`
    /// wants at least 0.3 s of clap-free head for the noise floor.
    public static let readySeconds: Double = 1.0
    /// Audio kept after the clap, so the analysis window and its tail fit.
    public static let tailSeconds: Double = 1.0

    public var syncOptions: SyncOptions {
        SyncOptions(
            maxLagSeconds: min(max(maxLagSeconds, 0.01), 1.0),
            minPeakRatio: relaxed ? 2.0 : 3.0,
            analysisWindowSeconds: min(max(analysisWindowSeconds, 0.008), 0.06)
        )
    }

    // MARK: - Observable state

    public private(set) var phase: Phase = .idle
    public private(set) var laneOptions: [SyncLaneOption] = []
    public private(set) var captureProgress: Double = 0
    public private(set) var lastResult: SyncResult?
    public private(set) var envelopes: SyncEnvelopeSet?
    /// Every lane's whole take, for the panel above the zoomed overlay.
    public private(set) var takeEnvelopes: SyncTakeEnvelopeSet?
    /// Seconds left of the CLAP NOW window, counted down for the sheet.
    public private(set) var listenSecondsRemaining: Double = 0
    /// How long the take that was kept actually ran.
    public private(set) var takeDuration: Double = 0
    /// The take stopped before the listen window was up, because a dominant
    /// transient had already been heard and its tail recorded.
    public private(set) var takeEndedEarly = false
    /// Why the take stopped, in words, for `--sync-test` and the sheet.
    public private(set) var takeEndReason: String = ""
    public private(set) var verifications: [SyncVerification] = []
    public private(set) var appliedDelays: [UUID: Int] = [:]
    /// Set when a lane's level reached `SyncOptions.clipThreshold` — the
    /// measurement may still be fine, but the input gain wants turning down.
    public private(set) var message: String?

    // MARK: - Private

    private let engine: AudioEngine
    private weak var registry: AudioDeviceRegistry?
    private var task: Task<Void, Never>?
    /// The last take, kept whole so Verify can re-measure without a new clap.
    /// Earlier takes are dropped as soon as the analysis has run.
    private var verificationTake: [LaneRecording] = []

    public init(engine: AudioEngine, registry: AudioDeviceRegistry?) {
        self.engine = engine
        self.registry = registry
        refreshLanes()
    }

    // MARK: - Lanes

    /// Re-reads the engine's lanes. Selection defaults to every physical lane
    /// and is otherwise preserved across refreshes.
    public func refreshLanes() {
        let previous = laneOptions.isEmpty ? nil : includedLaneIDs
        laneOptions = engine.lanes.map { lane in
            let device = registry?.device(uid: lane.deviceUID)
            return SyncLaneOption(
                id: lane.id,
                label: lane.name,
                deviceName: device?.name ?? lane.deviceUID,
                isVirtual: device?.transport.isVirtual ?? false,
                currentDelaySamples: lane.delaySamples
            )
        }
        let live = Set(laneOptions.map(\.id))
        if let previous {
            includedLaneIDs = previous.intersection(live)
        } else {
            includedLaneIDs = Set(laneOptions.filter { !$0.isVirtual }.map(\.id))
        }
        if includedLaneIDs.isEmpty {
            includedLaneIDs = live
        }
    }

    public func setIncluded(_ laneID: UUID, _ included: Bool) {
        if included { includedLaneIDs.insert(laneID) } else { includedLaneIDs.remove(laneID) }
    }

    /// Lanes to record, in mixer order.
    public var selectedLanes: [SyncLaneOption] {
        laneOptions.filter { includedLaneIDs.contains($0.id) }
    }

    public var canStart: Bool {
        engine.runState.isRunning && selectedLanes.count >= 2 && !phase.isBusy
    }

    // MARK: - Running

    public func start() {
        guard task == nil else { return }
        guard engine.runState.isRunning else {
            phase = .failed(AudioEngine.SyncCaptureError.engineNotRunning.errorDescription ?? "")
            return
        }
        let lanes = selectedLanes
        guard lanes.count >= 2 else {
            phase = .failed("Pick at least two lanes — Auto Sync measures lanes against each other.")
            return
        }
        message = nil
        lastResult = nil
        envelopes = nil
        takeEnvelopes = nil
        takeDuration = 0
        takeEndedEarly = false
        takeEndReason = ""
        verifications = []
        appliedDelays = [:]
        verificationTake = []
        task = Task { [weak self] in
            await self?.runAllTakes(lanes: lanes)
            self?.task = nil
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        Task { [engine] in
            await engine.cancelSyncCapture()
        }
        phase = .idle
        captureProgress = 0
    }

    /// Back to the options page, keeping the lane selection.
    public func retake() {
        guard !phase.isBusy else { return }
        lastResult = nil
        envelopes = nil
        takeEnvelopes = nil
        verifications = []
        verificationTake = []
        message = nil
        phase = .idle
    }

    private func runAllTakes(lanes: [SyncLaneOption]) async {
        var takes: [[LaneRecording]] = []
        let total = boundedTakeCount
        for index in 1...total {
            guard !Task.isCancelled else { phase = .idle; return }
            do {
                let recordings = try await runOneTake(index: index, of: total, lanes: lanes)
                // A cancelled take is short by construction; do not report it
                // as a failure the user has to read.
                guard !Task.isCancelled else { phase = .idle; return }
                guard recordings.count >= 2 else {
                    phase = .failed("Take \(index) recorded fewer than two lanes — is the engine still running?")
                    return
                }
                takes.append(recordings)
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
                return
            }
            if index < total {
                await pause(seconds: 0.6)
            }
        }
        guard !Task.isCancelled else { phase = .idle; return }

        phase = .analysing
        verificationTake = takes.last ?? []
        let options = syncOptions
        let result = await Task.detached(priority: .userInitiated) {
            ClapAligner(options: options).analyzeMultiple(takes)
        }.value
        takes = []

        lastResult = result
        envelopes = SyncSessionMath.makeEnvelopes(
            result: result,
            recordings: verificationTake,
            sampleRate: engine.sampleRate
        )
        takeEnvelopes = SyncSessionMath.makeTakeEnvelopes(
            result: result,
            recordings: verificationTake,
            sampleRate: engine.sampleRate,
            endedEarly: takeEndedEarly
        )
        message = SyncSessionMath.advice(for: result)
        phase = .results
    }

    private func runOneTake(index: Int, of total: Int, lanes: [SyncLaneOption]) async throws -> [LaneRecording] {
        let sampleRate = engine.sampleRate
        try engine.armSyncCapture(laneIDs: lanes.map(\.id), seconds: Self.maxTakeSeconds)

        // A clap-free head first: `SyncOptions.noiseFloorSeconds` is measured
        // from the very start of the recording, so telling the user to clap
        // before any room tone exists would poison the noise floor.
        let readyUntil = Date().addingTimeInterval(Self.readySeconds)
        while !Task.isCancelled {
            let remaining = readyUntil.timeIntervalSinceNow
            if remaining <= 0 { break }
            phase = .armed(secondsRemaining: remaining)
            captureProgress = engine.syncCaptureProgress
            await pause(seconds: 0.05)
        }

        phase = .listening(take: index, of: total)
        let options = syncOptions
        var probe = SyncOnsetProbe(
            sampleRate: sampleRate,
            noiseFloorSeconds: options.noiseFloorSeconds,
            thresholdDB: options.minOnsetSNRdB,
            dominanceDB: options.minDominanceDB,
            minimumLeadSeconds: Self.readySeconds
        )
        var probes: [UUID: SyncOnsetProbe] = [:]
        // Virtual lanes replay somebody else's clock and often carry no clap
        // at all, so they never end a take; if every lane is virtual the user
        // clearly meant them to.
        for lane in lanes where !lane.isVirtual { probes[lane.id] = probe }
        if probes.isEmpty { probes = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, probe) }) }

        let tailFrames = Int(Self.tailSeconds * sampleRate)
        let ceilingFrames = Int(Self.maxTakeSeconds * sampleRate)
        let listenStart = engine.syncCapturedFrames
        let listenEnd = listenStart + Int(boundedListenSeconds * sampleRate)
        var endedEarly = false
        var reason = "the listen window ran out"

        while !Task.isCancelled {
            captureProgress = engine.syncCaptureProgress
            let published = engine.syncCapturedFrames
            listenSecondsRemaining = max(0, Double(listenEnd - published) / sampleRate)

            // The probe follows the loudest transient, so an onset can move
            // later while the take runs; the latest one across the lanes is
            // the one whose tail has to fit.
            var latestOnset: Int?
            for laneID in probes.keys {
                probe = probes[laneID]!
                let fresh = engine.syncCapturedSamples(
                    laneID: laneID, from: probe.scanned, count: published - probe.scanned
                )
                probe.append(fresh)
                probes[laneID] = probe
                if let onset = probe.onsetSample { latestOnset = max(latestOnset ?? onset, onset) }
            }

            if let onset = latestOnset, published - onset >= tailFrames {
                endedEarly = published < listenEnd
                reason = String(
                    format: "a clap at %.2f s had its %.0f s of tail",
                    Double(onset) / sampleRate, Self.tailSeconds
                )
                break
            }
            if published >= ceilingFrames || captureProgress >= 1 {
                reason = latestOnset == nil
                    ? "the take hit its ceiling with no dominant transient"
                    : "the take hit its ceiling while recording the tail"
                break
            }
            // Past the listen window with a transient in hand, the take runs on
            // until that transient has its tail — a clap on the last second is
            // still worth keeping.
            if published >= listenEnd, latestOnset == nil { break }
            await pause(seconds: 0.04)
        }

        let captures = await engine.disarmSyncCapture()
        captureProgress = 0
        listenSecondsRemaining = 0
        let recordings = SyncSessionMath.makeRecordings(
            lanes: lanes, captures: captures, sampleRate: sampleRate
        )
        takeDuration = recordings.first?.durationSeconds ?? 0
        takeEndedEarly = endedEarly
        takeEndReason = reason
        return recordings
    }

    /// Sleeps without being short-circuited by cancellation: the capture
    /// hand-off has to run to completion even when the user hit Cancel, or the
    /// render thread would be left writing into a freed buffer.
    private func pause(seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }

    /// The take Verify re-measures — also what `--sync-test` prints its
    /// per-lane levels from. Empty until an analysis has run.
    public var lastTakeRecordings: [LaneRecording] { verificationTake }

    // MARK: - Apply and verify

    /// Writes the suggested delay into every aligned lane and clears the stale
    /// badge. Lanes Auto Sync could not measure are left exactly as they were.
    @discardableResult
    public func apply() -> [UUID: Int] {
        guard let lastResult else { return [:] }
        let assignments = SyncSessionMath.delayAssignments(from: lastResult)
        for (laneID, samples) in assignments {
            engine.setLaneDelaySamples(laneID, samples)
        }
        appliedDelays = assignments
        engine.acknowledgeStaleDelays()
        refreshLanes()
        if case .results = phase { phase = .done }
        return assignments
    }

    /// Re-measures the last take through the delays that were just applied.
    /// No new clap is needed: the recordings are still here and the delay is
    /// an integer shift.
    public func verify() async {
        guard let lastResult, !verificationTake.isEmpty else { return }
        let applied = appliedDelays.isEmpty
            ? SyncSessionMath.delayAssignments(from: lastResult)
            : appliedDelays
        phase = .verifying
        let recordings = verificationTake
        let options = syncOptions
        let sampleRate = engine.sampleRate
        let computed = await Task.detached(priority: .userInitiated) {
            SyncSessionMath.verify(
                result: lastResult,
                recordings: recordings,
                appliedDelays: applied,
                options: options,
                sampleRate: sampleRate
            )
        }.value
        verifications = computed
        phase = .done
    }

    public func applyAndVerify() async {
        apply()
        await verify()
    }
}

// MARK: - Pure helpers

/// The parts of `SyncSession` worth testing on their own: nothing here touches
/// the engine, the registry or the main actor.
public enum SyncSessionMath {

    /// Turns the raw capture buffers into `LaneRecording`s.
    ///
    /// Every lane is trimmed to the shortest capture so the common time origin
    /// the aligner assumes still holds; empty lanes are dropped rather than
    /// analysed as silence, because "the engine never recorded you" and "you
    /// heard nothing" are different failures.
    public static func makeRecordings(
        lanes: [SyncLaneOption],
        captures: [UUID: [Float]],
        sampleRate: Double
    ) -> [LaneRecording] {
        let present = lanes.compactMap { lane -> (SyncLaneOption, [Float])? in
            guard let samples = captures[lane.id], !samples.isEmpty else { return nil }
            return (lane, samples)
        }
        guard let shortest = present.map({ $0.1.count }).min(), shortest > 0 else { return [] }
        return present.map { lane, samples in
            LaneRecording(
                laneID: lane.id,
                label: lane.label,
                samples: samples.count == shortest ? samples : Array(samples.prefix(shortest)),
                sampleRate: sampleRate,
                isVirtual: lane.isVirtual
            )
        }
    }

    /// The delays Apply writes: aligned lanes only, everyone else untouched.
    public static func delayAssignments(from result: SyncResult) -> [UUID: Int] {
        var assignments: [UUID: Int] = [:]
        for lane in result.lanes where lane.status.isAligned {
            guard let samples = lane.suggestedDelaySamples else { continue }
            assignments[lane.laneID] = max(0, samples)
        }
        return assignments
    }

    /// The lane Verify measures everyone else against: the latest arrival, the
    /// one Auto Sync gave a delay of 0.
    public static func verificationReference(
        result: SyncResult,
        assignments: [UUID: Int]
    ) -> UUID? {
        let zeroed = result.alignedLanes.filter { assignments[$0.laneID] == 0 }
        if let best = zeroed.max(by: { ($0.status.confidence ?? 0) < ($1.status.confidence ?? 0) }) {
            return best.laneID
        }
        return result.referenceLaneID
    }

    public static func verify(
        result: SyncResult,
        recordings: [LaneRecording],
        appliedDelays: [UUID: Int],
        options: SyncOptions,
        sampleRate: Double
    ) -> [SyncVerification] {
        guard let referenceID = verificationReference(result: result, assignments: appliedDelays),
              let reference = recordings.first(where: { $0.laneID == referenceID })
        else { return [] }
        return result.alignedLanes.compactMap { lane -> SyncVerification? in
            guard lane.laneID != referenceID,
                  let recording = recordings.first(where: { $0.laneID == lane.laneID })
            else { return nil }
            let residual = SyncVerifier.residual(
                reference: reference,
                lane: recording,
                appliedDelaySamples: appliedDelays[lane.laneID] ?? 0,
                options: options
            )
            return SyncVerification(
                laneID: lane.laneID,
                label: lane.label,
                residualSamples: residual,
                sampleRate: sampleRate
            )
        }
    }

    /// Peak magnitude per bucket over `count` samples from `start`, normalised
    /// to the window's own maximum so a quiet lane is still readable.
    ///
    /// Reading outside the recording yields zeros rather than clamping, so a
    /// lane whose clap sits near an edge is drawn in the right place.
    public static func envelope(
        samples: [Float],
        from start: Int,
        count: Int,
        points: Int
    ) -> [Float] {
        guard points > 0, count > 0 else { return [] }
        var result = [Float](repeating: 0, count: points)
        let perPoint = Double(count) / Double(points)
        var maximum: Float = 0
        for point in 0..<points {
            let low = start + Int((Double(point) * perPoint).rounded(.down))
            let high = start + Int((Double(point + 1) * perPoint).rounded(.down))
            var peak: Float = 0
            var index = max(0, low)
            let end = min(samples.count, max(high, low + 1))
            while index < end {
                let magnitude = abs(samples[index])
                if magnitude > peak { peak = magnitude }
                index += 1
            }
            result[point] = peak
            if peak > maximum { maximum = peak }
        }
        if maximum > 0 {
            for index in 0..<points { result[index] /= maximum }
        }
        return result
    }

    /// The window the result page draws: from a little before the earliest
    /// arrival to a little after the latest lane's *shifted* arrival, so the
    /// "before" and "after" traces both fit on one axis.
    public static func envelopeWindow(
        result: SyncResult,
        recordings: [LaneRecording],
        sampleRate: Double
    ) -> (start: Int, length: Int) {
        let margin = Int(0.05 * sampleRate)
        let longest = recordings.map(\.samples.count).max() ?? 0
        var earliest = Int.max
        var latest = Int.min
        for lane in result.lanes {
            guard let onset = lane.onsetSample else { continue }
            earliest = min(earliest, onset)
            latest = max(latest, onset + (lane.suggestedDelaySamples ?? 0))
        }
        guard earliest != .max, latest != .min else {
            let fallback = min(longest, Int(0.2 * sampleRate))
            return (0, max(1, fallback))
        }
        let start = earliest - margin
        let end = latest + margin
        return (start, max(1, end - start))
    }

    public static func makeEnvelopes(
        result: SyncResult,
        recordings: [LaneRecording],
        sampleRate: Double,
        points: Int = 2000
    ) -> SyncEnvelopeSet? {
        guard !recordings.isEmpty else { return nil }
        let window = envelopeWindow(result: result, recordings: recordings, sampleRate: sampleRate)
        let perPoint = Double(window.length) / Double(points)
        let lanes = result.lanes.compactMap { lane -> SyncEnvelope? in
            guard let recording = recordings.first(where: { $0.laneID == lane.laneID }) else { return nil }
            return SyncEnvelope(
                laneID: lane.laneID,
                label: lane.label,
                points: envelope(
                    samples: recording.samples,
                    from: window.start,
                    count: window.length,
                    points: points
                ),
                onsetPoint: lane.onsetSample.map { Double($0 - window.start) / perPoint },
                shiftPoints: Double(lane.suggestedDelaySamples ?? 0) / perPoint,
                isAligned: lane.status.isAligned
            )
        }
        guard !lanes.isEmpty else { return nil }
        return SyncEnvelopeSet(lanes: lanes, samplesPerPoint: perPoint, sampleRate: sampleRate)
    }

    /// The whole take, one 2000-point envelope per lane, with the onset and
    /// the peak the detector actually used.
    public static func makeTakeEnvelopes(
        result: SyncResult,
        recordings: [LaneRecording],
        sampleRate: Double,
        endedEarly: Bool,
        points: Int = 2000
    ) -> SyncTakeEnvelopeSet? {
        guard !recordings.isEmpty else { return nil }
        let length = recordings.map(\.samples.count).max() ?? 0
        guard length > 0 else { return nil }
        let perPoint = Double(length) / Double(points)
        let lanes = result.lanes.compactMap { lane -> SyncTakeEnvelope? in
            guard let recording = recordings.first(where: { $0.laneID == lane.laneID })
            else { return nil }
            return SyncTakeEnvelope(
                laneID: lane.laneID,
                label: lane.label,
                points: envelope(
                    samples: recording.samples, from: 0, count: length, points: points
                ),
                onsetPoint: lane.onsetSample.map { Double($0) / perPoint },
                peakPoint: lane.levels.map { Double($0.peakSample) / perPoint },
                isAligned: lane.status.isAligned,
                dominanceDB: lane.levels?.dominanceDB,
                multipleTransients: lane.levels?.multipleTransients ?? false,
                notDetectedReason: lane.status.notDetectedReason
            )
        }
        guard !lanes.isEmpty else { return nil }
        return SyncTakeEnvelopeSet(
            lanes: lanes,
            sampleRate: sampleRate,
            samplesPerPoint: perPoint,
            durationSeconds: sampleRate > 0 ? Double(length) / sampleRate : 0,
            endedEarly: endedEarly
        )
    }

    /// One line of plain advice under the results table, or `nil`.
    public static func advice(for result: SyncResult) -> String? {
        if result.referenceLaneID == nil {
            let summary = result.failureSummary ?? SyncResult.noClapFailureSummary
            return summary
                + " Check that the lanes are unmuted and that the levels move,"
                + " then clap once, hard, while the sheet says CLAP NOW."
        }
        var notes: [String] = []
        let clipped = result.lanes.filter(\.clipped).map(\.label)
        if !clipped.isEmpty {
            notes.append("Clipped: \(clipped.joined(separator: ", ")) — turn the input gain down and re-measure.")
        }
        let inverted = result.alignedLanes.filter { $0.status.polarityInverted }.map(\.label)
        if !inverted.isEmpty {
            notes.append("Out of phase: \(inverted.joined(separator: ", ")) — consider the Ø button.")
        }
        let missed = result.notDetectedLanes.count
        if missed > 0 {
            notes.append("\(missed) lane\(missed == 1 ? "" : "s") not detected; their delays were left alone.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}

/// A cheap, incremental transient watcher used only to end a take early.
///
/// It is deliberately not `OnsetDetector`: this runs on the main thread every
/// 40 ms over the samples that arrived since the last poll, and all it has to
/// decide is "the clap has happened, we can stop recording". The measurement
/// itself is `ClapAligner`'s job.
///
/// The rule is `OnsetDetector`'s, made incremental: a window counts only when
/// it is `dominanceDB` above the *median* of every window seen so far — what
/// the room sounds like — as well as `thresholdDB` above the noise floor of
/// the clap-free head. A busy room's 1 ms windows swing 20 dB above their own
/// floor on their own, so the floor test alone ends the take on the first
/// syllable or chair; only a clap is 20 dB above everything else.
///
/// The running median is kept as a 0.25 dB histogram — a full sort of every
/// window would be quadratic over a take — and refreshed every
/// `medianRefreshWindows` windows, which is far finer than the level moves.
/// Nothing here depends on where a chunk boundary falls.
///
/// Two more rules keep it honest: nothing counts until `minimumLeadSeconds` of
/// audio exists (the user has only just been told to clap), and it keeps
/// tracking afterwards and follows the *loudest* transient, so a door closing
/// early in the take cannot end it before the clap.
public struct SyncOnsetProbe: Sendable {
    /// 1 ms windows, as in `SyncOptions.envelopeWindowSeconds`.
    public let windowSamples: Int
    /// Windows of the head averaged into the noise floor.
    public let noiseWindows: Int
    /// How far above the head noise floor a window has to sit.
    public let thresholdDB: Double
    /// How far above the running median a window has to sit.
    public let dominanceDB: Double
    /// Audio that must exist before any window may be called a clap.
    public let minimumLeadSamples: Int
    /// How much louder a later transient has to be before it takes over.
    public static let supersedeFactor = 1.5
    /// Roughly −100 dBFS: keeps a digitally silent head from making every
    /// sample an onset.
    public static let floorEpsilon = 1e-5
    /// Windows between two refreshes of the running median.
    public static let medianRefreshWindows = 32

    /// Samples consumed so far.
    public private(set) var scanned = 0
    /// Start of the loudest qualifying window so far, or `nil`.
    public private(set) var onsetSample: Int?
    /// Median 1 ms RMS of the clap-free head.
    public private(set) var noiseFloor: Double = 0
    /// Median 1 ms RMS of everything seen so far: the room, not the clap.
    public private(set) var medianLevel: Double = 0

    private var head: [Double] = []
    private var carry: [Float] = []
    private var onsetLevel: Double = 0
    private var floorSettled = false

    // MARK: - Level histogram

    /// 0.25 dB bins from −140 dBFS to +6 dBFS.
    private static let binsPerDecibel = 4.0
    private static let lowestDecibel = -140.0
    private static let binCount = 585
    private var histogram = [Int32](repeating: 0, count: SyncOnsetProbe.binCount)
    private var windowsSeen = 0
    /// Starts at the refresh interval so the very first window computes a
    /// median rather than running against zero.
    private var windowsSinceMedian = SyncOnsetProbe.medianRefreshWindows

    public init(
        sampleRate: Double,
        noiseFloorSeconds: Double = 0.3,
        thresholdDB: Double = 12,
        dominanceDB: Double = 20,
        minimumLeadSeconds: Double = 1.0
    ) {
        windowSamples = max(4, Int((0.001 * sampleRate).rounded()))
        noiseWindows = max(1, Int(noiseFloorSeconds * sampleRate) / windowSamples)
        minimumLeadSamples = max(0, Int(minimumLeadSeconds * sampleRate))
        self.thresholdDB = thresholdDB
        self.dominanceDB = dominanceDB
    }

    /// Feeds the samples that arrived since the last call. Chunk boundaries do
    /// not change the answer: whatever does not fill a window is carried over.
    public mutating func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        carry.append(contentsOf: samples)
        let snrRatio = pow(10, thresholdDB / 20)
        let dominanceRatio = pow(10, dominanceDB / 20)
        var offset = 0
        while carry.count - offset >= windowSamples {
            var sum = 0.0
            for index in offset..<(offset + windowSamples) {
                let value = Double(carry[index])
                sum += value * value
            }
            let rms = (sum / Double(windowSamples)).squareRoot()
            let windowStart = scanned + offset
            record(rms)

            if !floorSettled {
                head.append(rms)
                if head.count >= noiseWindows {
                    // Digitally silent frames say nothing about the floor.
                    let voiced = head.filter { $0 > 0 }
                    noiseFloor = Self.median(voiced.isEmpty ? head : voiced)
                    floorSettled = true
                }
            } else if windowStart + windowSamples >= minimumLeadSamples {
                let floor = max(noiseFloor, Self.floorEpsilon) * snrRatio
                let room = max(medianLevel, Self.floorEpsilon) * dominanceRatio
                if rms >= floor, rms >= room,
                   onsetSample == nil || rms > onsetLevel * Self.supersedeFactor {
                    onsetSample = windowStart
                    onsetLevel = rms
                }
            }

            offset += windowSamples
        }
        scanned += offset
        if offset > 0 { carry.removeFirst(offset) }
    }

    /// Adds one window to the histogram and refreshes `medianLevel` on the
    /// cadence. O(1) per window, O(bins) per refresh.
    private mutating func record(_ rms: Double) {
        let decibels = rms > 1e-12 ? 20 * log10(rms) : Self.lowestDecibel
        let raw = Int(((decibels - Self.lowestDecibel) * Self.binsPerDecibel).rounded(.down))
        histogram[min(max(raw, 0), Self.binCount - 1)] += 1
        windowsSeen += 1
        windowsSinceMedian += 1
        guard windowsSinceMedian >= Self.medianRefreshWindows else { return }
        windowsSinceMedian = 0
        medianLevel = medianFromHistogram()
    }

    private func medianFromHistogram() -> Double {
        guard windowsSeen > 0 else { return 0 }
        let target = windowsSeen / 2
        var seen = 0
        for bin in 0..<Self.binCount {
            seen += Int(histogram[bin])
            if seen > target {
                if bin == 0 { return 0 }
                let decibels = Self.lowestDecibel + (Double(bin) + 0.5) / Self.binsPerDecibel
                return pow(10, decibels / 20)
            }
        }
        return 0
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
