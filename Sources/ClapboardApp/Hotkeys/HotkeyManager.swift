import AppKit
import Carbon.HIToolbox
import ClapboardCore
import Foundation
import Observation

/// Owns the global shortcuts: the file, the Carbon registrations, and what
/// each key does to the mixer.
///
/// Carbon's `RegisterEventHotKey` is used rather than
/// `NSEvent.addGlobalMonitorForEvents` on purpose. The monitor API needs
/// Accessibility permission — a System Settings trip, a TCC prompt, and a
/// grant that an ad-hoc-signed rebuild invalidates exactly the way the
/// microphone one does — and it only *observes* keys, so the keystroke also
/// reaches whatever app is frontmost. A Carbon hotkey needs no permission at
/// all and swallows the key, which is what you want from a mute button: press
/// ⌃⌥M in OBS and OBS must not also see it.
///
/// Everything here is main-actor. The Carbon handler is installed on the
/// application event target, which dispatches on the main run loop, so a
/// keypress never touches the render thread — it goes through
/// `AudioEngine.setLaneEnabled`, which writes an atomic the IOProc reads on
/// its next block.
@MainActor
@Observable
final class HotkeyManager {
    /// The rows as shown in settings and written to disk, bound or not.
    private(set) var entries: [HotkeyEntry] = []
    /// Registration failures, keyed by action. A hotkey already taken by macOS
    /// or by another app fails with `eventHotKeyExistsErr`, and a user whose
    /// mute key silently does nothing deserves to be told why.
    private(set) var registrationErrors: [HotkeyAction: String] = [:]
    /// The last action that fired, for the UI to flash. Also the honest answer
    /// to "did that keypress reach Clapboard?".
    private(set) var lastTriggered: (action: HotkeyAction, date: Date)?
    /// Non-nil when the hotkey file could not be read or written.
    private(set) var lastFileError: String?
    /// Rows the file contained that this build dropped.
    private(set) var skippedOnLoad: [String] = []

    /// The lanes that were live when the mixer was last muted, so one key can
    /// serve both 闭麦 and 开麦. Not persisted: it describes this run of the
    /// mixer, and restoring a stale one after a relaunch would un-mute lanes
    /// the user muted by hand yesterday.
    @ObservationIgnored private var rememberedEnabled: Set<UUID> = []

    /// `false` until a load has succeeded.
    ///
    /// A read that failed leaves `entries` empty, and the next edit would then
    /// write that emptiness over a file that was only *momentarily*
    /// unreadable — a disk hiccup, or another copy of Clapboard halfway
    /// through its atomic swap. Never save over a file you could not read.
    @ObservationIgnored private var isSafeToSave = false

    @ObservationIgnored private let store: HotkeyStore?
    @ObservationIgnored private weak var engine: AudioEngine?
    @ObservationIgnored private var registrations: [UInt32: Registration] = [:]
    @ObservationIgnored private var nextHotkeyID: UInt32 = 1
    @ObservationIgnored private var eventHandler: EventHandlerRef?

    private struct Registration {
        var action: HotkeyAction
        var ref: EventHotKeyRef?
    }

    /// Four-char code `CLBP`, so a hotkey id of ours is never confused with
    /// another framework's inside the same process.
    private static let signature = OSType(0x434C_4250)

    init(store: HotkeyStore? = nil) {
        if let store {
            self.store = store
        } else {
            do {
                self.store = try HotkeyStore()
            } catch {
                self.store = nil
                self.lastFileError = String(describing: error)
            }
        }
    }

    var fileURL: URL? { store?.fileURL }

    // MARK: - Launch

    /// Loads the file — writing the defaults if there is none — and registers
    /// what it found. Call once, from the scene.
    func start(engine: AudioEngine?) {
        self.engine = engine
        load()
        register()
    }

    /// Loads without registering. `--hotkeys-selftest` uses this to report the
    /// file before it touches Carbon.
    @discardableResult
    func load() -> HotkeyStore.LoadResult {
        guard let store else { return HotkeyStore.LoadResult() }
        let (result, error) = store.loadReportingFailure()
        if let error {
            lastFileError = String(describing: error)
            report(lastFileError!)
            isSafeToSave = false
            entries = []
            return result
        }
        isSafeToSave = true
        skippedOnLoad = result.skipped
        for skip in result.skipped { report("dropped a binding — \(skip)") }
        if result.fileWasMissing {
            entries = HotkeyStore.defaultEntries
            save()
        } else {
            entries = result.entries
        }
        return result
    }

    func save() {
        guard let store else { return }
        guard isSafeToSave else {
            report("refusing to save over a hotkey file that could not be read")
            return
        }
        do {
            try store.save(entries)
            lastFileError = nil
        } catch {
            lastFileError = String(describing: error)
            report("could not save hotkeys — \(lastFileError!)")
        }
    }

    // MARK: - Editing

    func setBinding(_ binding: KeyBinding?, for action: HotkeyAction) {
        if let index = entries.firstIndex(where: { $0.action == action }) {
            entries[index].binding = binding
        } else {
            entries.append(HotkeyEntry(action: action, binding: binding))
        }
        save()
        register()
    }

    func addAction(_ action: HotkeyAction) {
        guard !entries.contains(where: { $0.action == action }) else { return }
        entries.append(HotkeyEntry(action: action, binding: nil))
        save()
    }

    func removeAction(_ action: HotkeyAction) {
        entries.removeAll { $0.action == action }
        save()
        register()
    }

    func binding(for action: HotkeyAction) -> KeyBinding? {
        entries.first { $0.action == action }?.binding
    }

    /// Actions sharing one key. Carbon registers the first and refuses the
    /// rest, so this is what the settings sheet warns about before the user
    /// discovers it by pressing the key.
    var conflicts: [KeyBinding: [HotkeyAction]] {
        var byBinding: [KeyBinding: [HotkeyAction]] = [:]
        for entry in entries {
            guard let binding = entry.binding, entry.action.isImplemented else { continue }
            byBinding[binding, default: []].append(entry.action)
        }
        return byBinding.filter { $0.value.count > 1 }
    }

    // MARK: - Registration

    struct RegistrationOutcome {
        var action: HotkeyAction
        var binding: KeyBinding
        var status: OSStatus
        var isSuccess: Bool { status == noErr }
        var message: String {
            isSuccess ? "noErr" : "\(HotkeyManager.describe(status)) (\(status))"
        }
    }

    /// Drops every registration and puts back the current, implemented,
    /// non-conflicting ones. Cheap enough to run on every edit — Carbon
    /// registration is a handful of Mach messages, not a device rebuild.
    @discardableResult
    func register() -> [RegistrationOutcome] {
        unregisterAll()
        installEventHandlerIfNeeded()

        var outcomes: [RegistrationOutcome] = []
        var errors: [HotkeyAction: String] = [:]
        var claimed: Set<KeyBinding> = []
        for entry in entries {
            guard let binding = entry.binding else { continue }
            guard entry.action.isImplemented else {
                errors[entry.action] = "not implemented yet"
                continue
            }
            guard claimed.insert(binding).inserted else {
                errors[entry.action] = "\(binding.displayString) is already used by another Clapboard action"
                continue
            }

            let id = nextHotkeyID
            nextHotkeyID += 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: id)
            let status = RegisterEventHotKey(
                binding.keyCode,
                binding.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            let outcome = RegistrationOutcome(action: entry.action, binding: binding, status: status)
            outcomes.append(outcome)
            if status == noErr {
                registrations[id] = Registration(action: entry.action, ref: ref)
            } else {
                errors[entry.action] = "\(binding.displayString) could not be registered — \(outcome.message)"
                report("\(entry.action.title): \(errors[entry.action]!)")
            }
        }
        registrationErrors = errors
        return outcomes
    }

    /// Called on quit. A hotkey outliving its process would be a leak in the
    /// window server, not just in us.
    func unregisterAll() {
        for registration in registrations.values {
            if let ref = registration.ref { UnregisterEventHotKey(ref) }
        }
        registrations.removeAll()
    }

    func shutdown() {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventCallback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &ref
        )
        if status == noErr {
            eventHandler = ref
        } else {
            report("could not install the hotkey event handler — \(HotkeyManager.describe(status))")
        }
    }

    /// Entry point from the Carbon callback. Already on the main thread.
    fileprivate func handleHotkey(id: UInt32) {
        guard let action = registrations[id]?.action else { return }
        perform(action)
    }

    // MARK: - Doing the work

    /// Runs an action. Public because the menu-bar item and the settings sheet
    /// press the same buttons the keyboard does.
    func perform(_ action: HotkeyAction) {
        lastTriggered = (action, Date())
        guard let engine, action.isImplemented else { return }

        switch action {
        case .toggleLaneMute(let laneID):
            guard let lane = engine.lane(id: laneID) else { return }
            engine.setLaneEnabled(laneID, !lane.enabled)
            // A lane the user turned on by hand belongs to the current set,
            // not to the one being held for a restore.
            rememberedEnabled.remove(laneID)
        case .muteAllLanes:
            apply(MuteToggleLogic.muteAll(lanes: engine.lanes, remembered: rememberedEnabled))
        case .unmuteAllLanes:
            apply(MuteToggleLogic.unmuteAll(lanes: engine.lanes))
        case .toggleAllLanes:
            apply(MuteToggleLogic.toggleAll(lanes: engine.lanes, remembered: rememberedEnabled))
        case .toggleBusMute, .toggleLaneSolo:
            break
        }
    }

    private func apply(_ outcome: MuteToggleLogic.Outcome) {
        guard let engine else { return }
        // Only the lanes that actually change are written, so a second press
        // of the mute key does not dirty the session file for nothing.
        for (id, enabled) in outcome.changes(from: engine.lanes) {
            engine.setLaneEnabled(id, enabled)
        }
        rememberedEnabled = outcome.remembered
    }

    /// `true` when at least one lane is live — the menu-bar icon's state.
    var anyLaneEnabled: Bool { MuteToggleLogic.anyEnabled(engine?.lanes ?? []) }

    // MARK: - Helpers

    nonisolated static func describe(_ status: OSStatus) -> String {
        switch status {
        case noErr: return "noErr"
        case OSStatus(eventHotKeyExistsErr): return "already taken by macOS or another app"
        case OSStatus(eventHotKeyInvalidErr): return "invalid hotkey"
        case OSStatus(eventParameterNotFoundErr): return "event parameter not found"
        case OSStatus(paramErr): return "bad parameter"
        default: return "OSStatus \(status)"
        }
    }

    private func report(_ message: String) {
        FileHandle.standardError.write(Data("Clapboard hotkeys: \(message)\n".utf8))
    }
}

/// The Carbon callback. C function pointers cannot capture, so the manager
/// travels in `userData`; the handler is installed on the application event
/// target, which only ever fires on the main thread.
private let hotkeyEventCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { manager.handleHotkey(id: id) }
    return noErr
}
