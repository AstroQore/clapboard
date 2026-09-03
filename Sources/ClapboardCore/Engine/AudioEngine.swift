import AVFoundation
import CoreAudio
import Foundation
import Observation

/// The one place the app drives audio from.
///
/// Owns the private aggregate device, the IOProc, and the real-time graph.
/// Everything here is main-actor bound; the render thread only ever sees the
/// `RTState` pointer handed to `HALIOProc`.
@MainActor
@Observable
public final class AudioEngine {
    public enum RunState: Equatable, Sendable {
        case stopped
        case starting
        case running
        case failed(String)

        public var isRunning: Bool { self == .running }
        public var isBusy: Bool { self == .starting }

        public var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case .running: return "Running"
            case .failed(let message): return "Error: \(message)"
            }
        }
    }

    /// Why a lane is not contributing to the mix.
    ///
    /// `deviceMissing` covers a process-tap lane whose tap could not be built
    /// too — the app is not playing, or macOS refuses the capture. The two
    /// cases are the same thing from the mixer's point of view (this lane's
    /// source is not here right now), and the difference the user needs is the
    /// sentence, which `laneStatusReason` carries.
    public enum LaneStatus: Equatable, Sendable {
        case ok
        case deviceMissing
        case channelOutOfRange
        case idle

        public var isProblem: Bool { self == .deviceMissing || self == .channelOutOfRange }
    }

    // MARK: - Observable state

    public internal(set) var lanes: [LaneConfig] = []
    /// Every bus in the mixer, in no particular order (`RoutingGraph.order`,
    /// derived from this, is what the render thread and the topological
    /// queries use). Always has at least one entry — `removeBus` refuses to
    /// drop the last one, and the initial `Master` bus besides.
    public internal(set) var buses: [BusConfig] = []
    /// The bus `setOutputDevice`/`masterGainDB`/`masterEffects`/`masterMeter`
    /// are thin shims onto. Fixed at creation and never removable, so those
    /// APIs — and the UI built on them — always have somewhere to point.
    var masterBusID = UUID()
    /// The validated routing tree built from `lanes` and `buses`. Rebuilt by
    /// `rebuildRoutingGraph()` on every topology edit; a rebuild that would
    /// fail (an edit that was not pre-validated, or a hand-edited session)
    /// leaves this at its last good value and records `routingError` instead
    /// of publishing a broken graph.
    var graph: RoutingGraph
    /// Set by `rebuildRoutingGraph()` when `lanes`/`buses` do not form a legal
    /// graph. `nil` in ordinary operation, since every topology-editing method
    /// validates before mutating.
    public private(set) var routingError: RoutingError?
    /// The plug-in delay compensation `pushEffectiveDelays()` last computed
    /// across the whole bus tree. `outputLatencySamples(forDevice:)` and the
    /// per-lane/per-bus PDC read-outs are views onto this.
    public internal(set) var latencyPlan: LatencyPlan = .empty
    /// What `muteAllLanes()` remembers to give back on `unmuteAllLanes()`/
    /// `toggleAllLanes()` — see `MuteToggleLogic`. Buses are never part of
    /// mute-all, only lanes.
    var mutedLanesRemembered: Set<UUID> = []
    public private(set) var runState: RunState = .stopped
    public private(set) var lastError: String?
    /// Sub-device drift compensation inserts a resampler whose latency is not
    /// reported and changes when the aggregate is rebuilt, so measured delays
    /// have to be re-taken after one.
    public private(set) var delaysMayBeStale = false
    public private(set) var overloadCount = 0
    public private(set) var callbackHealthy = false
    public private(set) var secondsSinceLastCallback: Double = 0
    public private(set) var restartCount = 0
    public private(set) var aggregateSummary: String?
    public private(set) var laneStatus: [UUID: LaneStatus] = [:]
    /// One human-readable sentence for a lane whose `laneStatus` is a problem
    /// and whose reason is not obvious from the status alone — today that is
    /// every process-tap lane whose tap the HAL would not build. Absent for an
    /// ordinary unplugged device, where "device missing" already says it.
    public private(set) var laneStatusReason: [UUID: String] = [:]
    /// Per-lane effect chains, keyed by `LaneConfig.id`. An entry whose
    /// `unavailableReason` is set is a placeholder: it holds a plug-in's saved
    /// state so a session opened without that plug-in can be saved again
    /// without losing it, and it is not published to the render thread.
    public internal(set) var laneEffects: [UUID: [EffectConfig]] = [:]
    /// The master bus's chain, after the sum and before its fader. A thin
    /// shim onto `buses[masterBusID].effects` — `BusConfig` is where a bus's
    /// chain actually lives now, master included.
    public internal(set) var masterEffects: [EffectConfig] {
        get { buses.first { $0.id == masterBusID }?.effects ?? [] }
        set {
            guard let index = buses.firstIndex(where: { $0.id == masterBusID }) else { return }
            buses[index].effects = newValue
        }
    }
    /// Extra delay plug-in delay compensation is adding to each lane, in
    /// samples. Purely derived; the UI shows it next to the manual delay.
    public internal(set) var pdcSamples: [UUID: Int] = [:]
    /// Set when a lane's or a bus's compensated delay had to be clamped to
    /// `RTLimits.maxDelaySamples`, which means the mix is no longer aligned.
    public internal(set) var pdcWarning: String?
    /// True while a restored session's chains are still being instantiated.
    public internal(set) var restoringEffects = false
    /// Thin shim onto the master bus's own gain — kept so the existing UI
    /// and any code written against the pre-bus API keep working unchanged.
    public var masterGainDB: Float {
        get { buses.first { $0.id == masterBusID }?.gainDB ?? 0 }
        set { setBusGainDB(masterBusID, newValue) }
    }
    /// Thin shim onto the master bus's own output device. Several other
    /// buses may target other devices — `buses`/`RoutingGraph.outputDeviceUIDs`
    /// is the full picture — but this is what the pre-bus UI and every
    /// headless single-output flow still read and write.
    public var outputDeviceUID: String? {
        buses.first { $0.id == masterBusID }?.outputDeviceUID
    }
    public private(set) var microphoneAuthorized = false
    /// The *other* capture permission: whether macOS lets Clapboard tap other
    /// applications' audio. Separate from the microphone one in every way —
    /// different TCC service, different Info.plist key
    /// (`NSAudioCaptureUsageDescription`), and no `AVFoundation` API — see
    /// `ProcessTapPermission` and `docs/PERMISSIONS.md`.
    ///
    /// Only consulted when a lane actually wants a tap: a microphone-only mix
    /// must not be blocked by a permission it never uses.
    public private(set) var systemAudioAuthorization: SystemAudioAuthorization = .notDetermined
    /// Processes the HAL currently reports as candidates for a tap. Refreshed
    /// by `refreshTappableProcesses()` and whenever the HAL's process list
    /// changes, so the UI can read it without enumerating anything itself.
    public private(set) var tappableProcesses: [TappableProcess] = []

    /// Opening and closing a plug-in's editor window is AppKit work, and
    /// `ClapboardCore` has no AppKit. The app wires these to
    /// `AUPluginWindowController`; `onCloseEffectWindow` is called before an
    /// instance is torn down, because the window holds the plug-in's view.
    public var onShowEffectWindow: ((AUEffectInstance) -> Void)?
    public var onCloseEffectWindow: ((AUEffectInstance) -> Void)?

    /// Diagnostics only. Lets the engine run without microphone TCC so the
    /// aggregate device, IOProc cadence and output path can be exercised on a
    /// machine where the prompt has not been answered — capture is silent in
    /// that case, because the HAL substitutes zeros rather than failing. The
    /// UI never sets this.
    public var allowsUnauthorizedCapture = false

    public var sampleRate: Double { aggregate?.sampleRate ?? 48_000 }
    public var bufferFrameSize: Int { Int(aggregate?.bufferFrameSize ?? 256) }

    // MARK: - Private

    let host = RTEngineHost()
    /// Restoring a session's chains means instantiating plug-ins, which is
    /// `async`; the task is kept so a second restore cannot race the first.
    var effectRestoreTask: Task<Void, Never>?
    private var aggregate: AggregateDevice?
    private var ioProc: HALIOProc?
    private var watchdog: Timer?
    private var restartWork: DispatchWorkItem?
    private weak var registry: AudioDeviceRegistry?
    private var suspendedForSleep = false
    /// Shape of the devices the running graph depends on, captured at bring-up.
    private var dependencyFingerprint: [String] = []
    /// HAL listener on `kAudioHardwarePropertyProcessObjectList`, registered
    /// only while some lane wants an app tap. A tapped app quitting or
    /// launching changes nothing about the *device* list, so hot-plug handling
    /// would never notice it.
    private var processListListener: AudioObjectPropertyListenerBlock?
    /// Watchdog only fires once the engine has actually seen a callback, so a
    /// slow-starting device is not mistaken for a dead one.
    private var sawFirstCallback = false

    public init() {
        let master = BusConfig(name: BusConfig.masterName)
        buses = [master]
        masterBusID = master.id
        // A single bus with no destination and no lanes cannot be a cycle or
        // point anywhere invalid, so this can never actually throw.
        graph = try! RoutingGraph.build(lanes: [], buses: [master])
        host.setMeterDecay(framesPerBlock: 256, sampleRate: 48_000)
        host.runtime(forBus: master.id)
        refreshAuthorization()
        TerminationGuard.register(self)
    }

    deinit {
        // `deinit` cannot hop to the main actor; the app calls `shutdown()`
        // from `applicationWillTerminate`, and a private aggregate dies with
        // the process anyway.
    }

    // MARK: - Wiring

    /// Subscribes to hot-plug notifications, chaining any handler already set.
    public func attach(registry: AudioDeviceRegistry) {
        self.registry = registry
        let previous = registry.onHardwareChange
        registry.onHardwareChange = { [weak self] in
            previous?()
            self?.handleHardwareChange()
        }
    }

    // MARK: - Lanes

    @discardableResult
    public func addLane(deviceUID: String, deviceChannels: [Int], name: String) -> LaneConfig {
        addLane(LaneConfig(deviceUID: deviceUID, deviceChannels: deviceChannels, name: name))
    }

    /// Adds a lane fed by a process tap instead of an input device. Everything
    /// downstream — meters, delay, effects, routing — is identical; only the
    /// source differs.
    @discardableResult
    public func addTapLane(_ spec: TapSpec, name: String? = nil) -> LaneConfig {
        addLane(LaneConfig(source: .processTap(spec), name: name ?? spec.name))
    }

    /// Adds a lane whose identity is already decided — session restore, where
    /// keeping `LaneConfig.id` is what keeps per-lane data (M3 sync results,
    /// M4 plug-in state) attached to the right lane across a relaunch.
    @discardableResult
    public func addLane(_ lane: LaneConfig) -> LaneConfig {
        var lane = lane
        // A lane always has a destination bus (`docs/ROUTING.md`): assign the
        // Master bus the moment one is missing, or points at a bus that is no
        // longer here — the only way either happens is a hand-edited or
        // stale-format session file.
        if lane.destinationBus == nil || !buses.contains(where: { $0.id == lane.destinationBus }) {
            lane.destinationBus = masterBusID
        }
        lanes.append(lane)
        host.runtime(for: lane.id)
        pushParameters(lane)
        applyTopologyChange()
        pushEffectiveDelays()
        return lane
    }

    public func removeLane(id: UUID) {
        guard let index = lanes.firstIndex(where: { $0.id == id }) else { return }
        lanes.remove(at: index)
        laneStatus[id] = nil
        laneStatusReason[id] = nil
        pdcSamples[id] = nil
        // The lane's plug-ins go the same way its runtime does: detached now,
        // freed once the render thread has left the snapshot that named them.
        for effect in laneEffects.removeValue(forKey: id) ?? [] {
            host.discardEffect(id: effect.id)
        }
        // The runtime is only detached here; `RTEngineHost` frees it once the
        // render thread has moved past the snapshot that referenced it.
        host.discardRuntime(for: id)
        applyTopologyChange()
        pushEffectiveDelays()
        drainRetiredEffects()
    }

    /// Lane order is cosmetic — the mix is a plain sum — but it is also the
    /// order the aggregate's sub-devices are listed in, so a reorder republishes.
    public func moveLanes(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().compactMap { $0 < lanes.count ? lanes[$0] : nil }
        var remaining = lanes
        for index in source.sorted(by: >) where index < remaining.count {
            remaining.remove(at: index)
        }
        let insertion = min(max(0, destination - source.filter { $0 < destination }.count), remaining.count)
        remaining.insert(contentsOf: moving, at: insertion)
        lanes = remaining
        republishGraph()
    }

    public func lane(id: UUID) -> LaneConfig? {
        lanes.first { $0.id == id }
    }

    // Parameter edits never rebuild anything: they land in atomics the render
    // thread reads on its next block.

    public func setLaneGainDB(_ id: UUID, _ db: Float) {
        mutate(id) { $0.gainDB = db }
        host.setLaneGain(id, linear: Decibels.linear(db))
    }

    public func setLaneEnabled(_ id: UUID, _ enabled: Bool) {
        mutate(id) { $0.enabled = enabled }
        refreshEffectiveEnable()
    }

    public func setLanePolarity(_ id: UUID, inverted: Bool) {
        mutate(id) { $0.polarityInverted = inverted }
        host.setLanePolarity(id, inverted: inverted)
    }

    /// The manual — or Auto Sync measured — delay. What actually reaches the
    /// render thread is this plus plug-in delay compensation; see
    /// `pushEffectiveDelays()`.
    public func setLaneDelaySamples(_ id: UUID, _ samples: Int) {
        let clamped = max(0, min(RTLimits.maxDelaySamples, samples))
        mutate(id) { $0.delaySamples = clamped }
        pushEffectiveDelays()
    }

    public func setLaneName(_ id: UUID, _ name: String) {
        mutate(id) { $0.name = name }
    }

    public func setLaneSource(_ id: UUID, deviceUID: String, deviceChannels: [Int]) {
        setLaneSource(id, .device(uid: deviceUID, channels: Array(deviceChannels.prefix(2))))
    }

    /// Re-points a lane at any source, device or tap. A tap the aggregate does
    /// not already carry means a rebuild, which `applyTopologyChange` works
    /// out for itself.
    public func setLaneSource(_ id: UUID, _ source: LaneSource) {
        guard lane(id: id)?.source != source else { return }
        mutate(id) { $0.source = source }
        applyTopologyChange()
    }

    /// Thin shim onto `setBusOutput(id:deviceUID:channelOffset:)` for the
    /// master bus — what the pre-bus UI and every single-output headless flow
    /// still call.
    public func setOutputDevice(uid: String?) {
        guard outputDeviceUID != uid else { return }
        setBusOutput(id: masterBusID, deviceUID: uid, channelOffset: 0)
        if runState.isRunning || runState.isBusy {
            rebuild(reason: "output device changed")
        }
    }

    public func acknowledgeStaleDelays() {
        delaysMayBeStale = false
    }

    func mutate(_ id: UUID, _ body: (inout LaneConfig) -> Void) {
        guard let index = lanes.firstIndex(where: { $0.id == id }) else { return }
        body(&lanes[index])
    }

    /// Delay is deliberately absent: it is the one parameter the host does not
    /// take at face value, because plug-in delay compensation is added to it.
    /// `pushEffectiveDelays()` owns it.
    private func pushParameters(_ lane: LaneConfig) {
        host.setLaneGain(lane.id, linear: Decibels.linear(lane.gainDB))
        host.setLaneEnabled(lane.id, lane.enabled)
        host.setLanePolarity(lane.id, inverted: lane.polarityInverted)
    }

    // MARK: - Auto Sync capture

    public enum SyncCaptureError: Error, LocalizedError, Equatable {
        case engineNotRunning
        case noLanes
        case alreadyArmed

        public var errorDescription: String? {
            switch self {
            case .engineNotRunning:
                return "Start the engine before measuring: Auto Sync records what the IOProc is already receiving."
            case .noLanes:
                return "Pick at least one lane to record."
            case .alreadyArmed:
                return "A capture is already running."
            }
        }
    }

    /// True between `armSyncCapture` and `disarmSyncCapture`.
    public private(set) var syncCaptureArmed = false

    /// Starts recording every named lane's raw, pre-delay input into a
    /// pre-allocated buffer. All the allocation happens here, on the main
    /// thread; the render thread only appends.
    public func armSyncCapture(laneIDs: [UUID], seconds: Double) throws {
        guard runState.isRunning else { throw SyncCaptureError.engineNotRunning }
        guard !syncCaptureArmed else { throw SyncCaptureError.alreadyArmed }
        let known = lanes.map(\.id).filter { laneIDs.contains($0) }
        guard !known.isEmpty else { throw SyncCaptureError.noLanes }
        let bounded = min(max(seconds, 0.5), 20)
        let frames = max(1, Int((bounded * sampleRate).rounded()))
        let armed = host.armCapture(laneIDs: known, frames: frames)
        guard !armed.isEmpty else { throw SyncCaptureError.noLanes }
        syncCaptureArmed = true
    }

    /// 0…1, polled by the UI. Reads one atomic.
    public var syncCaptureProgress: Double {
        let requested = host.captureRequestedFrames
        guard requested > 0 else { return 0 }
        return min(1, Double(host.capturedFrameCount) / Double(requested))
    }

    /// Frames captured so far, shared by every armed lane.
    public var syncCapturedFrames: Int { host.capturedFrameCount }

    /// A slice of one lane's capture while it is still running, for the cheap
    /// main-thread transient watcher that ends a take early.
    public func syncCapturedSamples(laneID: UUID, from start: Int, count: Int) -> [Float] {
        host.capturedSamples(for: laneID, from: start, count: count)
    }

    /// Stops the capture and hands back one array of raw pre-delay samples per
    /// armed lane, all of them the same length and sharing a time origin.
    ///
    /// The render thread reads the arm flag once at the top of a block, so a
    /// block that started before the flag went down can still be writing:
    /// this waits for two further callbacks before copying anything out.
    public func disarmSyncCapture() async -> [UUID: [Float]] {
        guard syncCaptureArmed else { return [:] }
        syncCaptureArmed = false
        host.disarmCapture()
        let target = host.callbackCount + 2
        let deadline = Date().addingTimeInterval(0.5)
        while host.callbackCount < target, Date() < deadline, runState.isRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return host.drainCaptureBuffers()
    }

    /// Throws the capture away without copying it out. Same timing rule.
    public func cancelSyncCapture() async {
        guard syncCaptureArmed else { return }
        _ = await disarmSyncCapture()
    }

    // MARK: - Meters

    public func meter(laneID: UUID) -> MeterReading { host.laneMeter(laneID) }
    public var masterMeter: MeterReading { host.busMeter(masterBusID) }
    public var masterPeaks: (left: Float, right: Float) { host.busPeaks(masterBusID) }
    public var callbackCount: Int { host.callbackCount }
    public var droppedBlocks: Int { host.droppedBlocks }

    // MARK: - Permission

    public func refreshAuthorization() {
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public func requestAuthorization(_ completion: (@Sendable @MainActor (Bool) -> Void)? = nil) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor [weak self] in
                self?.refreshAuthorization()
                completion?(granted)
            }
        }
    }

    /// Checks — and, the first time, asks for — the system-audio-capture
    /// permission by building and immediately destroying a real tap. There is
    /// no query-only API for it (`ProcessTapPermission`), so this *is* the
    /// request; call it from a user action, not from a view body.
    @discardableResult
    public func refreshSystemAudioAuthorization() -> SystemAudioAuthorization {
        let result = ProcessTapPermission.probe()
        systemAudioAuthorization = result
        return result
    }

    /// True when some lane is fed by a process tap, which is the only reason
    /// the system-audio permission matters at all.
    public var usesProcessTaps: Bool { lanes.contains { $0.source.isProcessTap } }

    /// Re-reads the HAL's process list into `tappableProcesses`.
    public func refreshTappableProcesses() {
        tappableProcesses = ProcessTapCatalog.outputProducingProcesses()
    }

    // MARK: - Run / stop

    public func start() {
        guard runState != .running, runState != .starting else { return }
        refreshAuthorization()
        // Without TCC the HAL hands the IOProc zeros rather than an error, so
        // a silent mix would look like a wiring bug. Gate on it instead.
        guard microphoneAuthorized || allowsUnauthorizedCapture else {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .notDetermined {
                requestAuthorization { [weak self] granted in
                    if granted { self?.start() }
                }
                fail("Waiting for microphone permission…")
            } else {
                fail("Microphone access is \(status == .denied ? "denied" : "restricted"). Enable Clapboard in System Settings › Privacy & Security › Microphone.")
            }
            return
        }
        // The system-audio permission is gated the same way, but only when
        // something actually needs it: a microphone-only mix must not be held
        // up by a permission it never uses. Unlike the microphone, refusal
        // here is not fatal — the mix still runs and the tap lanes report why
        // they are silent, which is strictly more useful than refusing to
        // start at all when one of five lanes is a tap.
        if usesProcessTaps, !systemAudioAuthorization.isAuthorized {
            refreshSystemAudioAuthorization()
        }
        launch(context: nil)
    }

    public func stop() {
        tearDown()
        runState = .stopped
        lastError = nil
    }

    /// Full teardown and bring-up. Used by the watchdog, by hot-plug handling
    /// and by the UI's Rebuild button. A no-op when the engine is stopped.
    public func rebuild(reason: String) {
        guard runState.isRunning || runState.isBusy else { return }
        tearDown()
        restartCount += 1
        // Drift compensation's resampler latency is not reported and can land
        // differently every time the aggregate is built, so any delay measured
        // before this rebuild is now suspect.
        delaysMayBeStale = true
        launch(context: reason)
    }

    private func launch(context: String?) {
        lastError = nil
        runState = .starting
        rebuildRoutingGraph()
        let outputs = graph.outputDeviceUIDs
        guard !outputs.isEmpty else {
            fail("Pick an output device first.")
            return
        }
        do {
            try bringUp(outputDeviceUIDs: outputs)
            sawFirstCallback = false
            runState = .running
            startWatchdog()
        } catch {
            tearDown()
            fail(context.map { "\($0): \(error)" } ?? String(describing: error))
        }
    }

    /// Called from `applicationWillTerminate`.
    ///
    /// Plug-ins are torn down here rather than in `stop()`: a chain has to
    /// survive stop/start and every aggregate rebuild, because reloading a
    /// plug-in would drop its state and its editor window. By the time this
    /// runs the IOProc has stopped, so no render thread can be inside
    /// `AUEffectInstance.process`.
    public func shutdown() {
        tearDown()
        runState = .stopped
        teardownAllEffects()
    }

    // MARK: - System events

    public func handleWillSleep() {
        guard runState.isRunning || runState.isBusy else { return }
        suspendedForSleep = true
        tearDown()
        runState = .stopped
    }

    public func handleDidWake() {
        guard suspendedForSleep else { return }
        suspendedForSleep = false
        delaysMayBeStale = true
        // Devices reappear a little after the wake notification, so give the
        // HAL time to re-enumerate before starting again.
        schedule(after: 1.5) { engine in
            engine.registry?.refresh()
            engine.start()
        }
    }

    public func handleHardwareChange() {
        guard runState.isRunning || runState.isBusy else { return }
        // Creating and destroying our own aggregate device changes
        // `kAudioHardwarePropertyDevices`, so reacting to every notification
        // makes the engine rebuild itself forever. Only a change to a device
        // the graph actually depends on matters — that is also the dangerous
        // case, since a vanished sub-device silently shifts every channel
        // offset after it.
        let current = makeDependencyFingerprint()
        guard current != dependencyFingerprint else { return }
        dependencyFingerprint = current
        // Hot-plug arrives as a burst of notifications; coalesce them.
        scheduleRestart(after: 0.4, reason: "a device the mix uses changed")
    }

    private func makeDependencyFingerprint() -> [String] {
        let uids = orderedInputDeviceUIDs() + graph.outputDeviceUIDs
        let known = knownDevices()
        let parts = uids.map { uid -> String in
            guard let device = known.first(where: { $0.uid == uid }) else { return "\(uid)|gone" }
            return "\(uid)|\(device.inputStreamChannels)|\(device.outputStreamChannels)"
                + "|\(device.isAlive)|\(Int(device.nominalSampleRate))"
        }
        return parts
    }

    /// Watches the HAL's client-process list while an app tap is live, so a
    /// tapped app quitting or launching rebuilds the aggregate the same way a
    /// device being unplugged does. Registered only when it is needed: the
    /// list changes constantly on a busy Mac.
    private func startWatchingProcessList() {
        stopWatchingProcessList()
        guard orderedTapSpecs().contains(where: { $0.bundleID != nil }) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshTappableProcesses()
                self.handleProcessListChange()
            }
        }
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyProcessObjectList)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID.system, &address, DispatchQueue.main, block)
        if status == noErr { processListListener = block }
    }

    private func stopWatchingProcessList() {
        guard let block = processListListener else { return }
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID.system, &address, DispatchQueue.main, block)
        processListListener = nil
    }

    /// Rebuilds only for the one change that a rebuild actually fixes: a tap
    /// the aggregate does *not* carry (because the app was not playing when it
    /// was built) whose app is now there.
    ///
    /// Deliberately not "the process ids changed". An app that respawns a
    /// helper per sound would then rebuild the engine several times a second,
    /// and it does not need to: a tap the aggregate already carries keeps
    /// working across the tapped app quitting and coming back, because the
    /// description carries `bundleIDs` with process restore enabled.
    private func handleProcessListChange() {
        guard runState.isRunning, let aggregate else { return }
        let live = Set(aggregate.tapKeys)
        let revivable = orderedTapSpecs().contains { spec in
            guard let bundleID = spec.bundleID, !live.contains(spec.sourceKey) else { return false }
            return !ProcessTapCatalog.objectIDs(bundleID: bundleID).isEmpty
        }
        guard revivable else { return }
        scheduleRestart(after: 0.4, reason: "an app a lane taps started playing")
    }

    private func scheduleRestart(after delay: TimeInterval, reason: String) {
        schedule(after: delay) { engine in
            engine.registry?.refresh()
            engine.rebuild(reason: reason)
        }
    }

    private func schedule(after delay: TimeInterval, _ body: @escaping (AudioEngine) -> Void) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Bring-up

    private func bringUp(outputDeviceUIDs: [String]) throws {
        let inputUIDs = orderedInputDeviceUIDs()
        let device = try AggregateDevice.create(AggregateDeviceRequest(
            inputDeviceUIDs: inputUIDs,
            outputDeviceUIDs: outputDeviceUIDs,
            tapSpecs: orderedTapSpecs(),
            sampleRate: 48_000,
            bufferFrameSize: 256,
            name: "Clapboard Mix"
        ))
        aggregate = device
        aggregateSummary = device.summary
        host.setMeterDecay(framesPerBlock: Int(device.bufferFrameSize), sampleRate: device.sampleRate)
        host.resetCounters()
        overloadCount = 0
        for lane in lanes {
            host.runtime(for: lane.id)
            pushParameters(lane)
        }
        for bus in buses { host.runtime(forBus: bus.id) }
        // Chains survive a stop/start and every aggregate rebuild — reloading
        // a plug-in would drop its state and its editor window — but their
        // tails do not: a 20-second delay must not keep ringing across the
        // gap. Safe here because the IOProc has not been started yet.
        for instance in host.allEffectInstances() { instance.reset() }
        pushEffectiveDelays()
        republishGraph()

        // `align()` may have moved a sub-device to 48 kHz; re-read so the
        // fingerprint below records the shape the graph is actually built on.
        registry?.refresh()
        refreshTappableProcesses()
        dependencyFingerprint = makeDependencyFingerprint()
        startWatchingProcessList()

        let proc = HALIOProc(deviceID: device.objectID, state: host.state)
        proc.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event: event) }
        }
        try proc.start()
        ioProc = proc
    }

    private func tearDown() {
        restartWork?.cancel()
        restartWork = nil
        watchdog?.invalidate()
        watchdog = nil
        stopWatchingProcessList()
        ioProc?.stop()
        ioProc = nil
        // Safe now: `AudioDeviceStop` guarantees the block has returned, so
        // every retired snapshot — and any Auto Sync capture buffer — can be
        // reclaimed.
        host.releaseCaptureBuffers()
        syncCaptureArmed = false
        host.unpublish()
        aggregate?.destroy()
        aggregate = nil
        aggregateSummary = nil
        callbackHealthy = false
        sawFirstCallback = false
        dependencyFingerprint = []
    }

    private func fail(_ message: String) {
        lastError = message
        runState = .failed(message)
    }

    private func handle(event: HALIOProc.Event) {
        switch event {
        case .overload:
            overloadCount = host.overloadCount
        case .deviceDied:
            guard runState.isRunning else { return }
            scheduleRestart(after: 0.2, reason: "aggregate device died")
        case .sampleRateChanged, .bufferSizeChanged:
            guard runState.isRunning, let aggregate else { return }
            let rate = (try? aggregate.objectID.property(.init(kAudioDevicePropertyNominalSampleRate), as: Double.self)) ?? 0
            let frames = (try? aggregate.objectID.property(.init(kAudioDevicePropertyBufferFrameSize), as: UInt32.self)) ?? 0
            if abs(rate - 48_000) > 0.5 || frames == 0 {
                scheduleRestart(after: 0.2, reason: "aggregate format changed")
            } else {
                host.setMeterDecay(framesPerBlock: Int(frames), sampleRate: rate)
            }
        }
    }

    // MARK: - Graph

    /// A topology edit only needs a full restart when the aggregate does not
    /// already carry every device the lanes and the buses want. Adding or
    /// removing a lane on a device that is already a sub-device, or
    /// re-routing a lane or a bus to a different bus, is a snapshot swap,
    /// which is click-free; only the *set* of input or output devices
    /// changing needs the aggregate itself rebuilt.
    func applyTopologyChange() {
        rebuildRoutingGraph()
        guard runState.isRunning || runState.isBusy else {
            republishGraph()
            return
        }
        let wantedInputs = Set(orderedInputDeviceUIDs())
        let presentInputs = Set(aggregate?.inputDeviceUIDs ?? [])
        let wantedOutputs = Set(graph.outputDeviceUIDs)
        let presentOutputs = Set(aggregate?.outputDeviceUIDs ?? [])
        // A tap lives inside the aggregate, so wanting one the aggregate does
        // not carry needs the same rebuild adding a sub-device does. A tap the
        // aggregate carries but nothing wants any more is left alone until the
        // next rebuild — it costs one silent stream, not a click.
        let wantedTaps = Set(orderedTapSpecs().map(\.sourceKey))
        let presentTaps = Set(aggregate.map { $0.tapKeys + Array($0.tapFailures.keys) } ?? [])
        if wantedInputs.isSubset(of: presentInputs), wantedOutputs.isSubset(of: presentOutputs),
           wantedTaps.isSubset(of: presentTaps) {
            republishGraph()
            dependencyFingerprint = makeDependencyFingerprint()
        } else {
            rebuild(reason: "routing needs a source the aggregate does not have")
        }
    }

    /// Rebuilds `graph` from the current `lanes`/`buses`. Every topology-
    /// editing method validates its own edit before mutating (an unknown bus,
    /// a cycle), so this should never actually fail in ordinary operation —
    /// the guard exists for a hand-edited or stale-format session file, which
    /// gets `routingError` instead of a crash or a silently wrong mix. On
    /// failure the previous (still legal) graph is kept, so the render thread
    /// keeps running whatever it was last correctly told to.
    func rebuildRoutingGraph() {
        do {
            graph = try RoutingGraph.build(lanes: lanes, buses: buses)
            routingError = nil
        } catch let error as RoutingError {
            routingError = error
        } catch {
            routingError = nil
        }
    }

    /// Recomputes `!muted && (no solo in scope || solo)` for every lane and
    /// bus and pushes the result straight to the render thread's atomics.
    /// Cheap — `SoloLogic` is pure arithmetic over what is already in memory —
    /// so every mute/solo edit calls this directly rather than going through
    /// a full `republishGraph()`.
    func refreshEffectiveEnable() {
        let effective = SoloLogic.effectiveEnabled(lanes: lanes, buses: buses, graph: graph)
        for lane in lanes {
            host.setLaneEnabled(lane.id, effective.lanes[lane.id] ?? lane.enabled)
        }
        for bus in buses {
            host.setBusEnabled(bus.id, effective.buses[bus.id] ?? !bus.muted)
        }
    }

    func mutateBus(_ id: UUID, _ body: (inout BusConfig) -> Void) {
        guard let index = buses.firstIndex(where: { $0.id == id }) else { return }
        body(&buses[index])
    }

    /// A lane whose device just became (one of) the mix's output devices
    /// would feed the mix back into itself; `AggregateDevice.create` refuses
    /// that outright, so it is dropped here first rather than surfacing as a
    /// bring-up failure the next time the engine starts.
    func dropLanesConflictingWithOutputs() {
        let outputs = Set(buses.compactMap(\.outputDeviceUID))
        for id in lanes.filter({ !$0.source.isProcessTap && outputs.contains($0.deviceUID) }).map(\.id) {
            removeLane(id: id)
        }
    }

    /// The taps the lanes want, in lane order, without duplicates. Two lanes
    /// on the same app share one tap — the aggregate carries it once and both
    /// lanes read the same channels out of it.
    ///
    /// Nothing is filtered on "is that app running": `ProcessTapFactory`
    /// decides that, and a tap that cannot be built comes back as a reason on
    /// the lane rather than as a silently dropped source.
    public func orderedTapSpecs() -> [TapSpec] {
        var seen = Set<String>()
        var result: [TapSpec] = []
        for spec in lanes.compactMap(\.source.tap) where !seen.contains(spec.sourceKey) {
            seen.insert(spec.sourceKey)
            result.append(spec)
        }
        return result
    }

    /// Lane source devices, in lane order, without duplicates.
    ///
    /// Lanes whose device is not plugged in right now are skipped: the
    /// aggregate cannot carry a device that is not there, and refusing to
    /// build one would take the whole mix down because a single microphone is
    /// missing — the case a restored session hits every time. Such a lane
    /// stays in `lanes`, reports `.deviceMissing`, and rebinds by itself when
    /// the device comes back: this list changes shape, so the dependency
    /// fingerprint changes and `handleHardwareChange` rebuilds.
    private func orderedInputDeviceUIDs() -> [String] {
        let present = Set(knownDevices().map(\.uid))
        let outputs = Set(graph.outputDeviceUIDs)
        var seen = Set<String>()
        var result: [String] = []
        // A tap lane's `deviceUID` is `tap:…`, which is never a device UID, so
        // `present` filters it out here without a special case. Its channels
        // come from `orderedTapSpecs()` instead.
        for lane in lanes
        where !seen.contains(lane.deviceUID)
            && !outputs.contains(lane.deviceUID)
            && present.contains(lane.deviceUID) {
            seen.insert(lane.deviceUID)
            result.append(lane.deviceUID)
        }
        return result
    }

    private func knownDevices() -> [AudioDeviceInfo] {
        registry?.devices ?? ((try? AudioDeviceInfo.enumerateAll()) ?? [])
    }

    /// Publishes a fresh `RTGraph` snapshot from the current `lanes`/`buses`
    /// and `graph` (the validated routing tree). Every bus is published, in
    /// `graph.order` — children before parents, exactly what the render
    /// kernel needs — with its parent resolved to an index, its output
    /// resolved to a buffer via `AggregateDevice.outputSlot(forDeviceUID:)`,
    /// and its chain patched in.
    func republishGraph() {
        guard let aggregate else {
            host.unpublish()
            laneStatus = lanes.reduce(into: [:]) { $0[$1.id] = .idle }
            laneStatusReason = [:]
            return
        }
        var nodes: [RTLaneNode] = []
        var status: [UUID: LaneStatus] = [:]
        var reasons: [UUID: String] = [:]
        nodes.reserveCapacity(lanes.count)
        for lane in lanes {
            let runtime = host.runtime(for: lane.id)
            guard aggregate.inputLayout.globalChannels(forDeviceUID: lane.deviceUID) != nil else {
                status[lane.id] = .deviceMissing
                // A tap that would not build is the one case where "missing"
                // needs a sentence: nothing is unplugged, macOS or the tapped
                // app simply said no, and the lane must say which rather than
                // sitting at the noise floor looking like a wiring mistake.
                if let tap = lane.source.tap {
                    reasons[lane.id] = aggregate.tapFailures[tap.sourceKey]
                        ?? "The tap on \(tap.name) is not in the aggregate device."
                }
                nodes.append(RTLaneNode(
                    runtime: runtime, channelCount: max(1, lane.deviceChannels.count),
                    bufferIndex0: -1, channelInBuffer0: 0, channelsInBuffer0: 0
                ))
                continue
            }
            var located: [(buffer: Int, channel: Int, stride: Int)] = []
            var resolved = true
            for deviceChannel in lane.deviceChannels {
                guard
                    let global = aggregate.inputLayout.globalChannel(deviceUID: lane.deviceUID, deviceChannel: deviceChannel),
                    let position = aggregate.inputLayout.locate(globalChannel: global)
                else {
                    resolved = false
                    break
                }
                let stride = aggregate.inputLayout.slots[position.bufferIndex].channelCount
                located.append((position.bufferIndex, position.channel, stride))
            }
            guard resolved, let first = located.first else {
                status[lane.id] = .channelOutOfRange
                nodes.append(RTLaneNode(
                    runtime: runtime, channelCount: max(1, lane.deviceChannels.count),
                    bufferIndex0: -1, channelInBuffer0: 0, channelsInBuffer0: 0
                ))
                continue
            }
            status[lane.id] = .ok
            let second = located.count > 1 ? located[1] : nil
            nodes.append(RTLaneNode(
                runtime: runtime,
                channelCount: located.count,
                bufferIndex0: first.buffer,
                channelInBuffer0: first.channel,
                channelsInBuffer0: first.stride,
                bufferIndex1: second?.buffer ?? -1,
                channelInBuffer1: second?.channel ?? 0,
                channelsInBuffer1: second?.stride ?? 0
            ))
        }
        laneStatus = status
        laneStatusReason = reasons

        // Gain and effective enable (mute + solo scope) are parameter-only —
        // no snapshot needed — but this is the one place guaranteed to run
        // after every topology edit, so it is the simplest place to make sure
        // they are never stale.
        refreshEffectiveEnable()
        for bus in buses {
            host.setBusGain(bus.id, linear: Decibels.linear(bus.gainDB))
        }

        var busInfos: [RTEngineHost.BusPublishInfo] = []
        busInfos.reserveCapacity(graph.order.count)
        for busID in graph.order {
            guard let bus = buses.first(where: { $0.id == busID }) else { continue }
            let slot = bus.outputDeviceUID.flatMap(aggregate.outputSlot(forDeviceUID:))
            busInfos.append(RTEngineHost.BusPublishInfo(
                id: busID,
                parentID: graph.parent[busID],
                outputBufferIndex: slot?.bufferIndex ?? -1,
                outputChannelOffset: min(bus.outputChannelOffset, max(0, (slot?.channelCount ?? 1) - 1)),
                outputChannelsInBuffer: slot?.channelCount ?? 0,
                effectIDs: publishableEffectIDs(bus.effects)
            ))
        }

        host.publish(
            laneNodes: nodes,
            laneBusIDs: lanes.map(\.destinationBus),
            laneEffectIDs: lanes.map { publishableEffectIDs(laneEffects[$0.id]) },
            buses: busInfos
        )
    }

    /// Placeholders — a plug-in that is not installed, or one macOS refused to
    /// load — have no instance and are simply not in the chain the render
    /// thread sees. The mix runs without them rather than stopping.
    private func publishableEffectIDs(_ chain: [EffectConfig]?) -> [UUID] {
        (chain ?? []).filter { $0.isAvailable }.map(\.id)
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickWatchdog() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func tickWatchdog() {
        host.collectGarbage()
        drainRetiredEffects()
        overloadCount = host.overloadCount
        guard runState.isRunning else { return }
        let hostTime = host.lastCallbackHostTime
        if hostTime != 0 { sawFirstCallback = true }
        let age = HostClock.seconds(since: hostTime)
        secondsSinceLastCallback = age
        callbackHealthy = sawFirstCallback && age < 1.0
        if sawFirstCallback && age > 1.0 {
            scheduleRestart(after: 0, reason: "no IOProc callback for \(String(format: "%.1f", age)) s")
        }
    }
}
