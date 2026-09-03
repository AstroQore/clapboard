import Foundation

/// One lane's pre-delay recording of an Auto Sync take.
///
/// `samples` are the raw input frames captured *before* the lane's delay line,
/// mono (one channel of the lane), at `sampleRate`. Every lane of a take must
/// share a sample rate and a common time origin: sample `n` of every lane was
/// captured in the same IOProc cycle.
public struct LaneRecording: Sendable {
    public let laneID: UUID
    public let label: String
    public let samples: [Float]
    public let sampleRate: Double
    /// Lanes fed by a virtual device (Loopback, Audio Hijack, a process tap).
    /// They are analysed like any other lane but never become the reference,
    /// because their timeline is a re-broadcast of somebody else's clock.
    public let isVirtual: Bool

    public init(
        laneID: UUID = UUID(),
        label: String,
        samples: [Float],
        sampleRate: Double,
        isVirtual: Bool = false
    ) {
        self.laneID = laneID
        self.label = label
        self.samples = samples
        self.sampleRate = sampleRate
        self.isVirtual = isVirtual
    }

    public var durationSeconds: Double {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}

/// Whether a lane's clap could be located, and how well.
public enum LaneSyncStatus: Sendable, Equatable {
    /// - Parameters:
    ///   - offsetSamples: arrival time of the clap on this lane minus the
    ///     arrival time on the reference lane, in samples, sub-sample
    ///     accurate. Positive means this lane heard the clap later.
    ///   - confidence: 0...1 heuristic combining `peakRatio` and onset SNR.
    ///   - peakRatio: main correlation peak over the strongest competing peak.
    ///   - polarityInverted: the main peak is negative, so this lane's signal
    ///     is wired (or mixed) out of phase with the reference.
    case aligned(
        offsetSamples: Double,
        confidence: Double,
        peakRatio: Double,
        polarityInverted: Bool
    )
    /// The lane's delay must not be touched. `reason` is meant to be shown to
    /// the user as-is.
    case notDetected(reason: String)

    public var isAligned: Bool {
        if case .aligned = self { return true }
        return false
    }

    public var offsetSamples: Double? {
        if case let .aligned(offset, _, _, _) = self { return offset }
        return nil
    }

    public var confidence: Double? {
        if case let .aligned(_, confidence, _, _) = self { return confidence }
        return nil
    }

    public var peakRatio: Double? {
        if case let .aligned(_, _, ratio, _) = self { return ratio }
        return nil
    }

    public var polarityInverted: Bool {
        if case let .aligned(_, _, _, inverted) = self { return inverted }
        return false
    }

    public var notDetectedReason: String? {
        if case let .notDetected(reason) = self { return reason }
        return nil
    }
}

/// What the 1 ms RMS envelope of one lane's take looked like.
///
/// The numbers behind the verdict, kept so the result page and `--sync-test`
/// can say *why* a lane was refused instead of only that it was.
public struct LaneLevels: Sendable, Equatable {
    /// Loudest 1 ms window, dBFS.
    public let peakDBFS: Double
    /// Median 1 ms window of the whole take: what the room sounds like.
    public let medianDBFS: Double
    /// Median 1 ms window of the clap-free head.
    public let noiseFloorDBFS: Double
    /// `peakDBFS - medianDBFS`. A clap clears `SyncOptions.minDominanceDB`;
    /// speech, keys and a bump do not.
    public let dominanceDB: Double
    /// Largest absolute sample value, dBFS.
    public let samplePeakDBFS: Double
    /// First sample of the loudest window.
    public let peakSample: Int
    /// Another maximum within 6 dB of the peak, more than 100 ms away: the
    /// take holds more than one bang. The loudest is the one that was used.
    public let multipleTransients: Bool

    public init(
        peakDBFS: Double,
        medianDBFS: Double,
        noiseFloorDBFS: Double,
        dominanceDB: Double,
        samplePeakDBFS: Double,
        peakSample: Int,
        multipleTransients: Bool
    ) {
        self.peakDBFS = peakDBFS
        self.medianDBFS = medianDBFS
        self.noiseFloorDBFS = noiseFloorDBFS
        self.dominanceDB = dominanceDB
        self.samplePeakDBFS = samplePeakDBFS
        self.peakSample = peakSample
        self.multipleTransients = multipleTransients
    }
}

/// Auto Sync's verdict for a single lane.
public struct LaneSyncResult: Sendable {
    public let laneID: UUID
    public let label: String
    public let status: LaneSyncStatus
    /// Coarse onset found by the RMS envelope, in samples from the start of
    /// the recording. Useful for drawing the result page's waveform overlay.
    public let onsetSample: Int?
    /// How far the onset rose above this lane's own noise floor.
    public let onsetSNRdB: Double?
    /// A sample reached `SyncOptions.clipThreshold`; the measurement may be
    /// usable anyway, but the user should turn the lane's input gain down.
    public let clipped: Bool
    /// Integer delay to write into the lane so it lines up with the latest
    /// arriving lane. Always >= 0; exactly one aligned lane (the latest) gets
    /// 0. `nil` when the lane was not detected.
    public let suggestedDelaySamples: Int?
    public let suggestedDelayMs: Double?
    /// Envelope levels behind the verdict, `nil` only when the lane could not
    /// be analysed at all (a mismatched sample rate, say).
    public let levels: LaneLevels?

    public init(
        laneID: UUID,
        label: String,
        status: LaneSyncStatus,
        onsetSample: Int?,
        onsetSNRdB: Double?,
        clipped: Bool,
        suggestedDelaySamples: Int?,
        suggestedDelayMs: Double?,
        levels: LaneLevels? = nil
    ) {
        self.laneID = laneID
        self.label = label
        self.status = status
        self.onsetSample = onsetSample
        self.onsetSNRdB = onsetSNRdB
        self.clipped = clipped
        self.suggestedDelaySamples = suggestedDelaySamples
        self.suggestedDelayMs = suggestedDelayMs
        self.levels = levels
    }
}

/// The result of analysing one take (`analyze`) or a group of takes
/// (`analyzeMultiple`).
public struct SyncResult: Sendable {
    /// Lane every `offsetSamples` is measured against, `nil` when no lane
    /// produced a usable transient.
    public let referenceLaneID: UUID?
    public let lanes: [LaneSyncResult]
    public let sampleRate: Double
    /// Why the whole take is unusable, ready to show as-is. Set exactly when
    /// `referenceLaneID` is `nil`: no two lanes heard the same clap, so there
    /// is nothing to measure anything against and no delay may be written.
    public let failureSummary: String?

    /// The one sentence that explains an Auto Sync take with no reference.
    public static let noClapFailureSummary = "No clap was found on two or more lanes."

    public init(
        referenceLaneID: UUID?,
        lanes: [LaneSyncResult],
        sampleRate: Double,
        failureSummary: String? = nil
    ) {
        self.referenceLaneID = referenceLaneID
        self.lanes = lanes
        self.sampleRate = sampleRate
        self.failureSummary = failureSummary
    }

    public subscript(laneID: UUID) -> LaneSyncResult? {
        lanes.first { $0.laneID == laneID }
    }

    public var alignedLanes: [LaneSyncResult] { lanes.filter { $0.status.isAligned } }
    public var notDetectedLanes: [LaneSyncResult] { lanes.filter { !$0.status.isAligned } }
}
