import Foundation

/// What `restore` actually did, for the status line and the headless test.
public struct SessionRestoreReport: Sendable, Equatable {
    public var restoredLanes: Int = 0
    /// One human-readable line per lane that was not restored.
    public var skippedLanes: [String] = []
    /// The engine was running and has been started again.
    public var restarted: Bool = false
    /// The file came from a newer Clapboard; anything this build does not
    /// understand was dropped from the lanes but kept in the extras bag.
    public var fromNewerFormat: Bool = false

    public var summary: String {
        var parts = ["restored \(restoredLanes) lane\(restoredLanes == 1 ? "" : "s")"]
        if !skippedLanes.isEmpty { parts.append("skipped \(skippedLanes.count)") }
        if restarted { parts.append("engine restarted") }
        if fromNewerFormat { parts.append("file is from a newer Clapboard") }
        return parts.joined(separator: ", ")
    }
}

extension AudioEngine {
    /// The part of the engine's state that belongs in the session file.
    ///
    /// Meters, run state, overload counts and the aggregate device are all
    /// derived or per-run and deliberately absent.
    public var sessionSnapshot: SessionDocument {
        SessionDocument(
            lanes: lanes,
            outputDeviceUID: outputDeviceUID,
            masterGainDB: masterGainDB
        )
    }

    /// Rebuilds the mixer from `session`.
    ///
    /// Restoring is a topology edit, so it is done with the engine stopped. A
    /// running engine is stopped, restored and started again rather than being
    /// refused: "open a session" should behave the same whether or not the mix
    /// is live, and every intermediate state (no lanes, wrong output device)
    /// would otherwise be pushed to the render thread one edit at a time.
    ///
    /// Lanes whose device is not plugged in are kept, exactly as they were
    /// saved. They come back as `LaneStatus.deviceMissing` once the engine
    /// runs, and rebind by themselves when the device reappears.
    @discardableResult
    public func restore(_ session: SessionDocument) -> SessionRestoreReport {
        var report = SessionRestoreReport(fromNewerFormat: session.isFromNewerFormat)
        let wasRunning = runState.isRunning || runState.isBusy
        if wasRunning { stop() }

        for id in lanes.map(\.id) { removeLane(id: id) }
        setOutputDevice(uid: session.outputDeviceUID)
        masterGainDB = AudioEngine.clampedGainDB(session.masterGainDB)

        var usedIDs = Set<UUID>()
        for lane in session.lanes {
            // A lane on the output device would feed the mix back into itself;
            // `setOutputDevice` drops such lanes, and a hand-edited file must
            // not be able to sneak one past it.
            guard lane.deviceUID != session.outputDeviceUID else {
                report.skippedLanes.append("\(lane.name): its device is the output device")
                continue
            }
            // Duplicated ids in an edited file would make two lanes share one
            // set of runtime parameters.
            let id = usedIDs.insert(lane.id).inserted ? lane.id : UUID()
            if id != lane.id {
                report.skippedLanes.append("\(lane.name): duplicate id, restored under a new one")
            }
            addLane(AudioEngine.sanitized(lane, id: id))
            report.restoredLanes += 1
        }

        if wasRunning {
            start()
            report.restarted = true
        }
        return report
    }

    /// Values from a file are not values from the UI: clamp them to what the
    /// render thread can actually accept before they reach it.
    private static func sanitized(_ lane: LaneConfig, id: UUID) -> LaneConfig {
        LaneConfig(
            id: id,
            deviceUID: lane.deviceUID,
            deviceChannels: LaneConfig.sanitized(channels: lane.deviceChannels),
            name: lane.name,
            gainDB: clampedGainDB(lane.gainDB),
            enabled: lane.enabled,
            polarityInverted: lane.polarityInverted,
            delaySamples: min(max(0, lane.delaySamples), RTLimits.maxDelaySamples)
        )
    }

    private static func clampedGainDB(_ db: Float) -> Float {
        guard db.isFinite else { return 0 }
        return min(max(db, -120), 24)
    }
}
