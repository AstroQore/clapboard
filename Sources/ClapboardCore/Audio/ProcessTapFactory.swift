import CoreAudio
import Darwin
import Foundation

/// One client process the HAL currently knows about — a candidate for a
/// process tap.
///
/// `objectID` is a HAL object id and is *not* stable: it disappears when the
/// process stops doing audio and comes back as a different number. Everything
/// persisted about a tap is keyed by `bundleID` instead (`TapSpec`), and the
/// object ids are resolved again every time a tap is built.
public struct TappableProcess: Identifiable, Hashable, Sendable {
    public var id: AudioObjectID { objectID }
    public let objectID: AudioObjectID
    public let pid: pid_t
    /// `nil` for a process macOS does not report a bundle id for — a plain
    /// command-line tool such as `afplay`. Such a process can still be tapped
    /// in this run, but nothing about it can be persisted.
    public let bundleID: String?
    /// Best-effort human name: the enclosing `.app`'s display name, else the
    /// executable's file name, else the bundle id.
    public let name: String
    public let isRunning: Bool
    public let isRunningOutput: Bool

    public init(
        objectID: AudioObjectID,
        pid: pid_t,
        bundleID: String?,
        name: String,
        isRunning: Bool,
        isRunningOutput: Bool
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRunning = isRunning
        self.isRunningOutput = isRunningOutput
    }
}

/// Reads `kAudioHardwarePropertyProcessObjectList` and the per-process
/// properties around it.
///
/// Deliberately free of AppKit: `ClapboardCore` never links it (see
/// `AudioEngine`'s note about plug-in windows), so the display name comes from
/// `proc_pidpath` plus `Bundle`, not from `NSRunningApplication`.
public enum ProcessTapCatalog {
    /// Every process object the HAL reports, in HAL order.
    public static func processes() -> [TappableProcess] {
        let ids = (try? AudioObjectID.system.propertyArray(
            .init(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self
        )) ?? []
        return ids.compactMap(describe(processObject:))
    }

    /// Processes worth offering as a lane source: the ones that are actually
    /// producing output, plus anything with a bundle id that has audio running
    /// at all. Sorted by name so the picker is stable between refreshes.
    public static func outputProducingProcesses() -> [TappableProcess] {
        let own = ownPID()
        return processes()
            .filter { $0.pid != own && ($0.isRunningOutput || $0.isRunning) }
            .sorted { ($0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending) }
    }

    public static func describe(processObject id: AudioObjectID) -> TappableProcess? {
        let pid = (try? id.property(.init(kAudioProcessPropertyPID), as: pid_t.self)) ?? -1
        let bundleID = try? id.propertyString(.init(kAudioProcessPropertyBundleID))
        let running = (try? id.property(.init(kAudioProcessPropertyIsRunning), as: UInt32.self)) ?? 0
        let runningOutput = (try? id.property(.init(kAudioProcessPropertyIsRunningOutput), as: UInt32.self)) ?? 0
        let cleanBundleID = (bundleID?.isEmpty ?? true) ? nil : bundleID
        return TappableProcess(
            objectID: id,
            pid: pid,
            bundleID: cleanBundleID,
            name: displayName(pid: pid, bundleID: cleanBundleID),
            isRunning: running != 0,
            isRunningOutput: runningOutput != 0
        )
    }

    /// Every HAL process object belonging to `bundleID`. An app can have more
    /// than one (helper processes share the bundle id), and taps take a list,
    /// so all of them are returned.
    public static func objectIDs(bundleID: String) -> [AudioObjectID] {
        processes().filter { $0.bundleID == bundleID }.map(\.objectID)
    }

    /// Clapboard's own process object, so a system-wide tap can exclude it.
    /// Without this the mix Clapboard writes to its output device is captured
    /// straight back into a lane — a feedback loop that builds on every block.
    public static func ownProcessObjectID() -> AudioObjectID? {
        let own = ownPID()
        return processes().first { $0.pid == own }?.objectID
    }

    private static func ownPID() -> pid_t { getpid() }

    // MARK: - Naming

    private static func displayName(pid: pid_t, bundleID: String?) -> String {
        if let path = executablePath(pid: pid) {
            if let bundleName = appBundleName(executablePath: path) { return bundleName }
            let file = (path as NSString).lastPathComponent
            if !file.isEmpty { return file }
        }
        if let bundleID { return bundleID }
        return "PID \(pid)"
    }

    private static func executablePath(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Walks up from `/Applications/Music.app/Contents/MacOS/Music` to the
    /// `.app` and asks the bundle for its localized display name.
    private static func appBundleName(executablePath: String) -> String? {
        var url = URL(fileURLWithPath: executablePath)
        for _ in 0..<4 {
            url = url.deletingLastPathComponent()
            guard url.path != "/" else { return nil }
            if url.pathExtension == "app" {
                let bundle = Bundle(url: url)
                let name = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                return name ?? url.deletingPathExtension().lastPathComponent
            }
        }
        return nil
    }
}

// MARK: - Errors

public enum ProcessTapError: Error, CustomStringConvertible, Sendable, Equatable {
    /// `AudioHardwareCreateProcessTap` refused because this app has not been
    /// granted system-audio capture. See `docs/PERMISSIONS.md`.
    case notPermitted(status: OSStatus)
    /// The app the lane names is not running, or is running but has no audio
    /// client, so there is no process object to tap.
    case processNotRunning(bundleID: String)
    case creationFailed(status: OSStatus)
    /// The tap object exists but reports no usable stream format, which means
    /// nothing would arrive in the aggregate device.
    case noFormat(status: OSStatus)

    public var description: String {
        switch self {
        case .notPermitted:
            return "macOS refused the audio tap: Clapboard is not allowed to record this Mac's audio. "
                + "Enable it in System Settings › Privacy & Security › " + ProcessTapPermission.settingsPaneName + "."
        case .processNotRunning(let bundleID):
            return "\(bundleID) is not playing any audio right now, so there is nothing to tap."
        case .creationFailed(let status):
            return "AudioHardwareCreateProcessTap failed with \(fourCharCode(status)) (\(status))."
        case .noFormat(let status):
            return "The tap reports no stream format (\(fourCharCode(status)))."
        }
    }

    /// The one-line reason a lane shows instead of capturing silence.
    public var laneReason: String { description }
}

// MARK: - Tap object

/// One live Core Audio process tap.
///
/// Owns the HAL object: `destroy()` is idempotent and is called on stop, on
/// every aggregate rebuild, from `deinit`, and from `TerminationGuard` by way
/// of `AudioEngine.shutdown()`. A leaked tap keeps capturing (and, with a
/// muting description, keeps the tapped app quiet), so this is not optional
/// tidiness the way a private aggregate almost is.
public final class ProcessTap {
    public let objectID: AudioObjectID
    /// `kAudioTapPropertyUID` — the string the aggregate device's tap list
    /// refers to this tap by (`kAudioSubTapUIDKey`).
    public let uid: String
    public let spec: TapSpec
    /// The format the tap publishes, and therefore the shape of the stream it
    /// contributes to an aggregate device.
    public let format: AudioStreamBasicDescription
    /// Process objects the tap was created against. Empty for a system-wide
    /// tap (which is exclusive: it names what to *leave out*).
    public let processObjectIDs: [AudioObjectID]

    private var destroyed = false

    init(
        objectID: AudioObjectID,
        uid: String,
        spec: TapSpec,
        format: AudioStreamBasicDescription,
        processObjectIDs: [AudioObjectID]
    ) {
        self.objectID = objectID
        self.uid = uid
        self.spec = spec
        self.format = format
        self.processObjectIDs = processObjectIDs
    }

    deinit { destroy() }

    public var channelCount: Int { Int(format.mChannelsPerFrame) }
    public var sampleRate: Double { format.mSampleRate }
    public var isDestroyed: Bool { destroyed }

    public func destroy() {
        guard !destroyed else { return }
        destroyed = true
        AudioHardwareDestroyProcessTap(objectID)
        ProcessTapFactory.forget(uid: uid)
    }

    public var summary: String {
        "\(spec.sourceKey)[\(channelCount)ch @\(Int(sampleRate))Hz uid=\(uid)]"
    }
}

// MARK: - Factory

/// Builds `ProcessTap`s from the persisted `TapSpec`s a lane carries.
public enum ProcessTapFactory {
    /// Every tap UID this process has ever created, minus the ones it has
    /// destroyed. `leakedTapUIDs()` turns it into a real leak check against the
    /// HAL's own list rather than a bookkeeping claim.
    private static let live = Mutex(Set<String>())

    /// Creates the tap `spec` describes.
    ///
    /// **Mute behaviour is always `.unmuted`.** `CATapMuteBehavior` also offers
    /// `.muted` and `.mutedWhenTapped`, either of which would stop the tapped
    /// app's audio from reaching the speakers for as long as Clapboard is
    /// reading the tap. Clapboard is a mixer, not a recorder that replaces
    /// playback: taking a lane from Music must not silence Music, and the user
    /// mutes what they do not want to hear with the lane's own `M` button.
    public static func make(_ spec: TapSpec) throws -> ProcessTap {
        let (description, processObjectIDs) = try makeDescription(spec)

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            if isPermissionFailure(status) { throw ProcessTapError.notPermitted(status: status) }
            // A short-lived process can exit between being resolved above and
            // the tap being built, and the HAL answers that with `noErr` and
            // no object rather than an error. Re-resolving says which of the
            // two it was, so the lane gets "not playing" instead of
            // "failed with 0".
            if case .app(let bundleID) = spec.target,
               ProcessTapCatalog.objectIDs(bundleID: bundleID).isEmpty {
                throw ProcessTapError.processNotRunning(bundleID: bundleID)
            }
            throw ProcessTapError.creationFailed(status: status)
        }

        var created = false
        defer { if !created { AudioHardwareDestroyProcessTap(tapID) } }

        let uid = (try? tapID.propertyString(.init(kAudioTapPropertyUID)))
            ?? description.uuid.uuidString
        do {
            let format = try tapID.property(
                .init(kAudioTapPropertyFormat), as: AudioStreamBasicDescription.self)
            guard format.mChannelsPerFrame > 0 else { throw ProcessTapError.noFormat(status: noErr) }
            created = true
            live.withLock { _ = $0.insert(uid) }
            return ProcessTap(
                objectID: tapID, uid: uid, spec: spec,
                format: format, processObjectIDs: processObjectIDs)
        } catch let error as ProcessTapError {
            throw error
        } catch let error as CoreAudioError {
            throw ProcessTapError.noFormat(status: error.status)
        }
    }

    /// The `CATapDescription` `make` would build, and the process objects it
    /// resolved. Separate so the description's flags — above all the mute
    /// behaviour — can be asserted in a unit test without a live HAL tap.
    public static func makeDescription(_ spec: TapSpec) throws -> (CATapDescription, [AudioObjectID]) {
        let description: CATapDescription
        var processObjectIDs: [AudioObjectID] = []
        switch spec.target {
        case .systemAudio:
            // Exclusive: tap everything *except* Clapboard. Excluding
            // ourselves is not politeness — the mix Clapboard writes to its
            // output device is audio produced by this process, so a truly
            // global tap would feed the master straight back into a lane and
            // build a loop one block at a time.
            let excluded = ProcessTapCatalog.ownProcessObjectID().map { [$0] } ?? []
            description = spec.mono
                ? CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
                : CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        case .app(let bundleID):
            processObjectIDs = ProcessTapCatalog.objectIDs(bundleID: bundleID)
            guard !processObjectIDs.isEmpty else {
                throw ProcessTapError.processNotRunning(bundleID: bundleID)
            }
            description = spec.mono
                ? CATapDescription(monoMixdownOfProcesses: processObjectIDs)
                : CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        }
        description.name = "Clapboard \(spec.name)"
        // Private for the same reason the aggregate device is: nothing
        // Clapboard creates should show up in another app's device list, and a
        // private tap dies with the process if we ever fail to.
        description.isPrivate = true
        // The whole point (see the doc comment above): capturing an app must
        // not stop it being heard.
        description.muteBehavior = .unmuted
        if #available(macOS 26.0, *), case .app(let bundleID) = spec.target {
            // Lets the HAL re-attach the tap by bundle id when the tapped app
            // quits and comes back — including an app that spawns a fresh
            // helper process per sound — instead of the lane going quiet until
            // the next aggregate rebuild.
            description.bundleIDs = [bundleID]
            description.isProcessRestoreEnabled = true
        }
        return (description, processObjectIDs)
    }

    /// UIDs this process created and never destroyed that the HAL still lists.
    /// Empty is the only acceptable answer after a clean shutdown.
    public static func leakedTapUIDs() -> [String] {
        let ours = live.withLock { $0 }
        guard !ours.isEmpty else { return [] }
        let ids = (try? AudioObjectID.system.propertyArray(
            .init(kAudioHardwarePropertyTapList), of: AudioObjectID.self)) ?? []
        let present = Set(ids.compactMap { try? $0.propertyString(.init(kAudioTapPropertyUID)) })
        return ours.filter(present.contains).sorted()
    }

    /// Tap UIDs this process believes it still owns, leaked or not.
    public static func liveTapUIDs() -> [String] { live.withLock { $0 }.sorted() }

    static func forget(uid: String) {
        live.withLock { _ = $0.remove(uid) }
    }

    /// macOS reports a missing system-audio-capture authorization as a plain
    /// HAL error rather than a distinct one, so the classification is by
    /// status code. `'!pri'` is what a denied tap returns on the systems this
    /// has been tried on; the two generic HAL refusals are treated the same
    /// way because there is nothing else about a well-formed description that
    /// makes the HAL say no.
    static func isPermissionFailure(_ status: OSStatus) -> Bool {
        status == kAudioHardwareIllegalOperationError
            || status == kAudioHardwareUnspecifiedError
            || status == OSStatus(bitPattern: 0x21707269)  // '!pri'
    }
}

/// Tiny lock, so `ProcessTapFactory`'s bookkeeping can be touched from any
/// thread without importing `Synchronization` into a type that also has to be
/// usable from Swift 5 mode call sites.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
