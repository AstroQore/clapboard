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

    @ObservationIgnored private let store: SessionStore?
    @ObservationIgnored private weak var engine: AudioEngine?
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    @ObservationIgnored private var isRestoring = false
    @ObservationIgnored private var isDirty = false
    /// State a newer Clapboard wrote that this one does not model. Carried
    /// from load to save untouched so an older build cannot erase it.
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
            carriedLaneExtras = document.laneExtras
            carriedMasterExtras = document.masterExtras
            loadedNewerFormat = document.isFromNewerFormat
            isRestoring = true
            restoreReport = engine.restore(document)
            isRestoring = false
        }
        beginTracking()
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
        guard let store, let engine else { return }
        var document = engine.sessionSnapshot
        // Extras belonging to lanes that no longer exist go with them.
        let ids = Set(engine.lanes.map(\.id.uuidString))
        document.laneExtras = carriedLaneExtras.filter { ids.contains($0.key) }
        document.masterExtras = carriedMasterExtras
        do {
            try store.save(document)
            isDirty = false
            lastSaveError = nil
            lastSavedAt = document.savedAt
            saveCount += 1
        } catch {
            lastSaveError = String(describing: error)
            report("session save failed: \(lastSaveError!)")
        }
    }

    // MARK: - Change tracking

    private func beginTracking() {
        guard let engine else { return }
        withObservationTracking {
            // Exactly the session's contents — nothing that ticks.
            _ = engine.lanes
            _ = engine.outputDeviceUID
            _ = engine.masterGainDB
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
