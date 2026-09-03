import ClapboardCore
import Foundation
import Observation

/// Owns the session file: loads it at launch, restores it into the engine, and
/// writes it back whenever the mixer changes.
///
/// Autosave is debounced by one second and driven by `withObservationTracking`
/// on exactly the three things the session contains — lanes, output device,
/// master gain. Meters, callback counts and run state are observable too and
/// change dozens of times a second; they are deliberately not read here, so
/// dragging a fader writes one file, not sixty.
///
/// *Which* file that is belongs to `ProjectController`: opening a project
/// retargets this controller (`retarget(to:dirty:)`) rather than starting a
/// second autosave beside it. There is one debounce, one dirty flag and one
/// writer in the app, whether or not a project is open.
@MainActor
@Observable
final class SessionController {
    /// Wait after the last edit before writing.
    static let autosaveDelay: TimeInterval = 1.0

    /// Non-nil when the last write failed; shown in the UI's status line.
    private(set) var lastSaveError: String?
    /// Non-nil when the file could not be read at launch — a corrupt file has
    /// been quarantined by then and the app started empty.
    private(set) var lastLoadError: String?
    private(set) var lastSavedAt: Date?
    private(set) var saveCount = 0
    private(set) var restoreReport: SessionRestoreReport?
    /// The file was written by a newer Clapboard. It was loaded as far as this
    /// build understands it, and saving will rewrite it in this build's format.
    private(set) var loadedNewerFormat = false

    /// The file autosave writes. `nil` only when macOS reported no Application
    /// Support directory and no explicit store was given.
    ///
    /// A `var` because a project *is* the autosave target while it is open;
    /// see `retarget(to:dirty:)`.
    private(set) var store: SessionStore?

    /// True while the live graph differs from what is on disk in `store`.
    ///
    /// Observable because the window's edited dot reads it. It is deliberately
    /// the same flag the debounce uses: a title bar that could disagree with
    /// what autosave believes would be worse than no title bar at all.
    private(set) var isDirty = false

    @ObservationIgnored private weak var engine: AudioEngine?
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    @ObservationIgnored private var isRestoring = false
    /// State a newer Clapboard wrote that this one does not model. Carried
    /// from load to save untouched so an older build cannot erase it. The
    /// effect-chain key is excluded: this build owns it, and carrying it would
    /// resurrect a chain the user has just deleted.
    @ObservationIgnored private var carriedLaneExtras: [String: [String: Data]] = [:]
    @ObservationIgnored private var carriedMasterExtras: [String: Data] = [:]

    init(store: SessionStore? = nil) {
        if let store {
            self.store = store
        } else {
            do {
                self.store = try SessionStore()
            } catch {
                self.store = nil
                self.lastSaveError = String(describing: error)
            }
        }
    }

    var fileURL: URL? { store?.fileURL }

    var statusLine: String {
        if let lastSaveError { return "Session not saved — \(lastSaveError)" }
        if let lastLoadError { return lastLoadError }
        if loadedNewerFormat {
            return "This session was written by a newer Clapboard; it will be rewritten in this version's format."
        }
        guard let lastSavedAt else { return "Session not saved yet" }
        return "Session saved \(SessionController.clock.string(from: lastSavedAt))"
    }

    // MARK: - Launch

    /// Loads the file and restores it into `engine`, then starts watching for
    /// changes. Restoring must not itself trigger a save, so tracking only
    /// begins once the engine is back in shape.
    ///
    /// `ProjectController.attach` may have pointed `store` at a project file
    /// first; this loads whatever it is aimed at, with no idea which.
    func attach(engine: AudioEngine) {
        self.engine = engine
        guard let store else {
            beginTracking()
            return
        }
        let (document, error) = store.loadReportingFailure()
        if let error {
            lastLoadError = String(describing: error)
            report(lastLoadError!)
        }
        if let document {
            adopt(document, into: engine)
        }
        beginTracking()
    }

    // MARK: - Retargeting

    /// Points autosave at another file.
    ///
    /// Any debounced write is cancelled first: it was aimed at the document the
    /// user has just left, and letting it land after the switch would write one
    /// project's mixer into another project's file.
    ///
    /// - Parameter dirty: `true` when the live graph is already known to differ
    ///   from `newStore`'s contents — `New`, which empties the mixer and then
    ///   expects that empty mixer to reach the default session file.
    func retarget(to newStore: SessionStore?, dirty: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        store = newStore
        lastSaveError = nil
        lastLoadError = nil
        loadedNewerFormat = false
        isDirty = false
        // Deliberately not `noteChange()`: that is guarded against changes
        // arriving *during* a restore, and `New` retargets immediately after
        // one. The caller saying "this graph differs from that file" is not the
        // thing the guard is there to catch.
        if dirty, store != nil { scheduleSave() }
    }

    /// Replaces the live graph with `document` without the restore counting as
    /// an edit, and adopts the extras bags that came with the file.
    @discardableResult
    func adopt(_ document: SessionDocument, into engine: AudioEngine) -> SessionRestoreReport {
        self.engine = engine
        carriedLaneExtras = document.laneExtras
        carriedMasterExtras = document.masterExtras
        loadedNewerFormat = document.isFromNewerFormat
        isRestoring = true
        let report = engine.restore(document)
        restoreReport = report
        isDirty = false
        // `onChange` fires during the restore but re-arms on the *next*
        // main-actor turn, so it reads `isRestoring` after this call has
        // returned. Clearing the flag synchronously here would let the
        // restore's own mutations arrive one turn later as a user edit and
        // dirty a project the moment it was opened.
        Task { @MainActor [weak self] in self?.isRestoring = false }
        return report
    }

    // MARK: - Saving

    /// Writes now, cancelling any debounced save. Used on quit and on sleep.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard isDirty else { return }
        saveNow()
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let store else { return }
        switch write(to: store) {
        case .success(let document):
            isDirty = false
            lastSaveError = nil
            lastSavedAt = document.savedAt
            saveCount += 1
        case .failure(let error):
            lastSaveError = String(describing: error)
            report("session save failed: \(lastSaveError!)")
        }
    }

    /// Writes the current graph to `destination` right now, without changing
    /// where autosave points. `Save As` uses this before retargeting, so a
    /// failed write leaves the app attached to the file it was already on.
    @discardableResult
    func write(to destination: SessionStore) -> Result<SessionDocument, any Error> {
        guard let engine else {
            return .failure(SessionStoreError.writeFailed(
                url: destination.fileURL, reason: "no engine is attached"))
        }
        let document = mergedSnapshot(engine)
        do {
            try destination.save(document)
            return .success(document)
        } catch {
            return .failure(error)
        }
    }

    /// The engine's snapshot with anything a newer Clapboard left in the extras
    /// bags merged back in, minus extras belonging to lanes that no longer
    /// exist. The snapshot already carries this build's effect chains.
    private func mergedSnapshot(_ engine: AudioEngine) -> SessionDocument {
        var document = engine.sessionSnapshot
        let ids = Set(engine.lanes.map(\.id.uuidString))
        for (laneID, bag) in carriedLaneExtras where ids.contains(laneID) {
            for (key, value) in bag
            where key != EffectChainCodec.extrasKey && document.laneExtras[laneID]?[key] == nil {
                document.laneExtras[laneID, default: [:]][key] = value
            }
        }
        for (key, value) in carriedMasterExtras
        where key != EffectChainCodec.extrasKey && document.masterExtras[key] == nil {
            document.masterExtras[key] = value
        }
        return document
    }

    // MARK: - Change tracking

    private func beginTracking() {
        guard let engine else { return }
        withObservationTracking {
            // Exactly the session's contents — nothing that ticks. `buses` is
            // read transitively: `masterGainDB`, `outputDeviceUID` and
            // `masterEffects` are all computed off it, so every bus edit is
            // tracked without naming it here.
            _ = engine.lanes
            _ = engine.outputDeviceUID
            _ = engine.masterGainDB
            // Chain edits are session changes too. A plug-in's *parameters*
            // are not observable — nothing here can see a knob move inside a
            // plug-in's own window — so those are picked up by the save on
            // quit and by the next edit that does fire.
            _ = engine.laneEffects
            _ = engine.masterEffects
        } onChange: { [weak self] in
            // `onChange` fires *before* the value lands, and re-arming from
            // inside it would observe the old state; hop to the next main-actor
            // turn instead.
            Task { @MainActor in
                guard let self else { return }
                self.beginTracking()
                self.noteChange()
            }
        }
    }

    private func noteChange() {
        guard !isRestoring, store != nil else { return }
        scheduleSave()
    }

    /// Marks the graph dirty and arms the debounce. `noteChange` is this plus
    /// the "not while restoring" guard.
    private func scheduleSave() {
        isDirty = true
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveDelay, execute: work)
    }

    // MARK: - Helpers

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    /// A failure the user cannot see is a failure that gets shipped. The
    /// status line is the real channel; this is for `open`-from-a-terminal and
    /// for Console.
    private func report(_ message: String) {
        FileHandle.standardError.write(Data("Clapboard session: \(message)\n".utf8))
    }
}
