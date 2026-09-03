import AppKit
import ClapboardCore
import Foundation
import Observation
import UniformTypeIdentifiers

/// The Open Recent list.
///
/// A protocol only so the headless self-test can run against an in-memory list:
/// a diagnostic must never rewrite the user's real Open Recent menu, and
/// `NSDocumentController` is process-wide state shared with the Dock.
@MainActor
protocol RecentProjects {
    var urls: [URL] { get }
    func note(_ url: URL)
    func remove(_ url: URL)
    func clear()
}

/// macOS's own list, so Clapboard's File menu, the Dock menu and the Finder
/// cannot disagree about what was opened recently.
@MainActor
struct SystemRecentProjects: RecentProjects {
    var urls: [URL] { NSDocumentController.shared.recentDocumentURLs }

    func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// AppKit has no "forget this one". The list is rebuilt instead, oldest
    /// first, so the survivors come back in the order they were already in.
    func remove(_ url: URL) {
        let target = url.standardizedFileURL
        let survivors = urls.filter { $0.standardizedFileURL != target }
        guard survivors.count != urls.count else { return }
        NSDocumentController.shared.clearRecentDocuments(nil)
        for survivor in survivors.reversed() {
            NSDocumentController.shared.noteNewRecentDocumentURL(survivor)
        }
    }

    func clear() { NSDocumentController.shared.clearRecentDocuments(nil) }
}

/// In-memory recents for `--project-selftest` and `--open-project`.
@MainActor
final class MemoryRecentProjects: RecentProjects {
    private(set) var urls: [URL] = []

    func note(_ url: URL) {
        remove(url)
        urls.insert(url.standardizedFileURL, at: 0)
    }

    func remove(_ url: URL) {
        let target = url.standardizedFileURL
        urls.removeAll { $0.standardizedFileURL == target }
    }

    func clear() { urls.removeAll() }
}

/// Where the "reopen this on next launch" pointer lives.
///
/// Injectable for the same reason the recents are: a self-test must not leave
/// anything behind in the user's preferences.
@MainActor
protocol LastProjectMemory: AnyObject {
    var lastProjectPath: String? { get set }
}

@MainActor
final class UserDefaultsLastProject: LastProjectMemory {
    static let key = "lastProjectPath"

    var lastProjectPath: String? {
        get { UserDefaults.standard.string(forKey: Self.key) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.key)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.key)
            }
        }
    }
}

@MainActor
final class MemoryLastProject: LastProjectMemory {
    var lastProjectPath: String?
}

/// Named projects: New, Open, Open Recent, Save, Save As, and the window title
/// that says which one you are in.
///
/// This owns *identity* — which file the mix belongs to, what it is called,
/// what was opened lately — and nothing else. Every byte written to disk, the
/// one-second debounce and the dirty flag all still belong to
/// `SessionController`; a project is simply that controller's autosave target
/// while it is open. The seam between the two is three calls (`retarget`,
/// `adopt`, `write`), which is what keeps this from becoming a second,
/// competing change-tracking mechanism.
@MainActor
@Observable
final class ProjectController {
    static let fileExtension = "clapboard"
    static let contentTypeIdentifier = "com.astroqore.clapboard.project"
    /// "Open Recent keeps the last ten paths" (`docs/ROUTING.md`).
    static let recentLimit = 10
    /// What the title bar says when no project file is open — the autosaved
    /// session is a session, not a document, and has no name of its own.
    static let defaultSessionName = "Untitled Session"

    /// `nil` means the default autosaved session
    /// (`~/Library/Application Support/Clapboard/session.json`).
    private(set) var projectURL: URL?
    private(set) var recentURLs: [URL] = []
    /// What just happened to the *project* — opened, saved, gone missing.
    /// Autosave has its own line (`SessionController.statusLine`); this one
    /// never repeats it.
    private(set) var statusLine = "No project — autosaving the default session"
    /// Non-nil when the last project operation failed. Shown in red.
    private(set) var lastError: String?

    @ObservationIgnored private weak var engine: AudioEngine?
    @ObservationIgnored private weak var registry: AudioDeviceRegistry?
    @ObservationIgnored private var session: SessionController?
    @ObservationIgnored private let recents: any RecentProjects
    @ObservationIgnored private let memory: any LastProjectMemory
    /// The store the app falls back to with no project open. `nil` only when
    /// macOS reports no Application Support directory.
    @ObservationIgnored private let defaultStore: SessionStore?
    /// Files handed to us by the Finder before the scene existed.
    @ObservationIgnored private var pendingOpen: [URL] = []
    @ObservationIgnored private var isAttached = false

    /// The dependencies are optional rather than defaulted in place because a
    /// default argument is evaluated in a nonisolated context, and all three of
    /// these are main-actor state.
    init(
        recents: (any RecentProjects)? = nil,
        memory: (any LastProjectMemory)? = nil,
        defaultStore: SessionStore? = nil
    ) {
        self.recents = recents ?? SystemRecentProjects()
        self.memory = memory ?? UserDefaultsLastProject()
        self.defaultStore = defaultStore ?? (try? SessionStore())
    }

    // MARK: - Derived state

    var projectName: String {
        guard let projectURL else { return Self.defaultSessionName }
        return projectURL.deletingPathExtension().lastPathComponent
    }

    /// The live graph differs from the file on disk. Straight through to
    /// `SessionController`: the window's edited dot and the autosave debounce
    /// must never be able to disagree.
    var isDirty: Bool { session?.isDirty ?? false }

    var hasProject: Bool { projectURL != nil }

    /// `<project name> — Clapboard`, per `docs/ROUTING.md`.
    var windowTitle: String { "\(projectName) — Clapboard" }

    // MARK: - Launch

    /// Decides which file the session comes from, then hands it to
    /// `SessionController` to load and restore.
    ///
    /// The target is chosen *before* the session is attached so launch restores
    /// exactly once: loading the default session and then immediately replacing
    /// it with the last project would tear down and rebuild the whole graph for
    /// nothing.
    func attach(engine: AudioEngine, session: SessionController, registry: AudioDeviceRegistry?) {
        self.engine = engine
        self.session = session
        self.registry = registry

        var launchNote: String?
        if let path = memory.lastProjectPath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                session.retarget(to: SessionStore(fileURL: url), dirty: false)
                projectURL = url
                // Reopening on launch *is* opening it, so it belongs at the top
                // of Open Recent like any other open. Without this the project
                // you are looking at is the one entry the menu does not list.
                recents.note(url)
                launchNote = "Reopened \(url.lastPathComponent)"
            } else {
                // "otherwise fall back to the default session and say so"
                // (`docs/ROUTING.md`). Silently starting somewhere else is the
                // one thing a project file must never do.
                launchNote = "\(url.lastPathComponent) is no longer at \(url.deletingLastPathComponent().path)"
                    + " — opened the default session instead"
                memory.lastProjectPath = nil
                recents.remove(url)
            }
        }

        session.attach(engine: engine)

        if let error = session.lastLoadError {
            // A corrupt project has been quarantined by now; say which file it
            // was rather than letting the app look empty for no reason.
            lastError = error
            statusLine = hasProject ? "\(projectName) could not be read" : "The session could not be read"
        } else if let launchNote {
            statusLine = launchNote
        } else {
            statusLine = defaultStatusLine
        }

        isAttached = true
        refreshRecents()
        drainPendingOpen()
    }

    /// A double-clicked `.clapboard` file can arrive before the scene exists.
    func handleExternalOpen(_ urls: [URL]) {
        pendingOpen.append(contentsOf: urls)
        guard isAttached else { return }
        drainPendingOpen()
    }

    private func drainPendingOpen() {
        let urls = pendingOpen
        pendingOpen = []
        // Opening replaces the whole graph, so only the last one can win;
        // opening four files in sequence would just be three wasted restores.
        guard let url = urls.last else { return }
        _ = open(url)
    }

    // MARK: - New

    /// Stops the engine, empties the mixer back to one `Master`, detaches from
    /// any project file and goes back to autosaving the default session.
    ///
    /// That last step is why the confirmation is wider than "when dirty": with
    /// a project open the document can be perfectly clean and New will still,
    /// one debounce later, write an empty graph over the default session file —
    /// which is where a user's real device setup and Auto Sync delays live.
    /// Losing that to an unprompted menu click is not a trade worth making.
    @discardableResult
    func newProject(confirmed: Bool = false) -> Bool {
        guard let engine, let session else { return false }
        if !confirmed, needsDiscardConfirmation, !confirmDiscard() { return false }

        engine.stop()
        // An empty document has no buses, so `restore` synthesizes exactly one
        // `Master` — the same path a brand-new install takes.
        session.adopt(SessionDocument(), into: engine)
        if engine.outputDeviceUID == nil, let registry {
            // Otherwise Run is disabled and the new session looks broken.
            engine.setOutputDevice(uid: registry.defaultOutputUID)
        }

        projectURL = nil
        memory.lastProjectPath = nil
        lastError = nil
        // Dirty on purpose: the empty graph is a change against whatever the
        // default session file currently holds, and New's contract is that the
        // app is autosaving that file again.
        session.retarget(to: defaultStore, dirty: true)
        statusLine = "New session — autosaving the default session"
        return true
    }

    /// True when New would throw away something the user cannot get back from
    /// a file: unsaved edits, or a mixer that is about to be replaced by an
    /// empty one while autosave swings back to the default session.
    var needsDiscardConfirmation: Bool {
        guard let engine else { return false }
        return isDirty || !engine.lanes.isEmpty || engine.buses.count > 1
    }

    private func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isDirty
            ? "Discard unsaved changes to \(projectName)?"
            : "Start a new session?"
        alert.informativeText = """
            The mixer will be emptied back to a single Master bus, and Clapboard \
            will go back to autosaving the default session at \
            \(defaultStore?.fileURL.path ?? "the default location") — overwriting \
            whatever that file holds now.
            """
        alert.addButton(withTitle: "New Session")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Open

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose a Clapboard project."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = open(url)
    }

    /// Loads `url`, replaces the live graph, and makes it the autosave target.
    ///
    /// The engine stop/restart is `AudioEngine.restore`'s: it stops a running
    /// engine, rebuilds the topology and starts it again, so every intermediate
    /// state (no lanes, wrong output device) is kept off the render thread.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let engine, let session else { return false }
        let store = SessionStore(fileURL: url)

        guard FileManager.default.fileExists(atPath: url.path) else {
            // A recent entry whose file has been moved or deleted reports it
            // and drops out of the list rather than failing quietly.
            forget(url, because: "\(url.lastPathComponent) is no longer at "
                + url.deletingLastPathComponent().path)
            return false
        }

        let document: SessionDocument
        do {
            guard let loaded = try store.load() else {
                forget(url, because: "\(url.lastPathComponent) is no longer readable")
                return false
            }
            document = loaded
        } catch {
            // `SessionStoreError` already says the file was quarantined and
            // under what name; surfacing it verbatim is the point.
            lastError = String(describing: error)
            statusLine = "Could not open \(url.deletingPathExtension().lastPathComponent)"
            return false
        }

        // Retarget before restoring: a debounced write still aimed at the file
        // being left would land in the wrong document.
        session.retarget(to: store, dirty: false)
        let report = session.adopt(document, into: engine)

        projectURL = url
        memory.lastProjectPath = url.path
        lastError = nil
        recents.note(url)
        refreshRecents()
        statusLine = "Opened \(projectName) — \(report.summary)"
        return true
    }

    private func forget(_ url: URL, because reason: String) {
        recents.remove(url)
        refreshRecents()
        if memory.lastProjectPath == url.path { memory.lastProjectPath = nil }
        lastError = reason
        statusLine = "Removed \(url.lastPathComponent) from Open Recent"
    }

    // MARK: - Save

    /// ⌘S. Autosave is debounced, so this is the flush.
    func save() {
        guard let session else { return }
        guard session.isDirty else {
            statusLine = "No changes to save"
            return
        }
        session.flush()
        if let error = session.lastSaveError {
            lastError = error
        } else {
            lastError = nil
            statusLine = "Saved \(projectName)"
        }
    }

    func showSaveAsPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = hasProject ? projectName : "Clapboard Project"
        panel.prompt = "Save"
        panel.message = "Save this mixer — lanes, buses, routing, delays and effects — as a project."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = saveAs(to: url)
    }

    /// Writes the current graph to `url` and makes it the autosave target.
    @discardableResult
    func saveAs(to url: URL) -> Bool {
        guard let session else { return false }
        // The panel appends the extension when the user leaves it off, but a
        // path from a script or a test has not been through the panel.
        let destination = url.pathExtension == Self.fileExtension
            ? url
            : url.appendingPathExtension(Self.fileExtension)
        let store = SessionStore(fileURL: destination)

        switch session.write(to: store) {
        case .failure(let error):
            lastError = String(describing: error)
            statusLine = "Could not save \(destination.lastPathComponent)"
            return false
        case .success:
            session.retarget(to: store, dirty: false)
            projectURL = destination
            memory.lastProjectPath = destination.path
            lastError = nil
            recents.note(destination)
            refreshRecents()
            statusLine = "Saved \(projectName)"
            return true
        }
    }

    // MARK: - Recents

    /// Re-reads macOS's list rather than keeping a second one on disk, so the
    /// File menu and the Dock menu are the same list.
    func refreshRecents() {
        recentURLs = Array(recents.urls.prefix(Self.recentLimit))
    }

    func clearRecents() {
        recents.clear()
        refreshRecents()
        statusLine = "Cleared the Open Recent menu"
    }

    // MARK: - Helpers

    private var defaultStatusLine: String {
        "No project — autosaving \(defaultStore?.fileURL.lastPathComponent ?? "the default session")"
    }

    /// Declared in `Info.plist` as an exported type; `exportedAs` picks that
    /// declaration up rather than inventing a second, conflicting one.
    private static let contentType = UTType(
        exportedAs: ProjectController.contentTypeIdentifier, conformingTo: .json
    )
}
