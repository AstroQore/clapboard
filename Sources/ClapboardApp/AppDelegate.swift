import AppKit
import ClapboardCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the scene once the engine exists, so termination and sleep can
    /// reach it. `AudioEngine` itself stays free of AppKit.
    var engine: AudioEngine? {
        didSet { installWorkspaceObservers() }
    }

    /// Set by the scene alongside `engine`. Autosave is debounced, so quit and
    /// sleep have to flush it explicitly.
    var session: SessionController?

    /// Set by the scene. Carbon hotkeys are process-wide and have to be handed
    /// back before the process goes away.
    var hotkeys: HotkeyManager?

    private var observersInstalled = false
    /// Owned here rather than by the scene: an `NSStatusItem` disappears when
    /// its owner is released, and scene state does not outlive the window.
    private let statusItemController = StatusItemController()

    func installStatusItem(engine: AudioEngine, hotkeys: HotkeyManager) {
        statusItemController.install(engine: engine, hotkeys: hotkeys)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Last chance to destroy the private aggregate device. Leaving one behind
    /// would keep every sub-device open.
    func applicationWillTerminate(_ notification: Notification) {
        // The session is written first: `shutdown()` tears the plug-ins down,
        // and a torn-down plug-in has no state left to save.
        session?.flush()
        AUPluginWindowController.shared.closeAll()
        // Carbon hotkeys are registered against the window server, not against
        // this object graph, so they are given back explicitly.
        hotkeys?.shutdown()
        statusItemController.remove()
        engine?.shutdown()
    }

    /// Devices are torn down across sleep and come back with different object
    /// ids, so the engine stops on the way down and rebuilds on the way up.
    private func installWorkspaceObservers() {
        guard !observersInstalled, engine != nil else { return }
        observersInstalled = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Write before the machine goes down: a sleep that turns into a
                // power loss must not cost the session.
                self?.session?.flush()
                self?.engine?.handleWillSleep()
            }
        }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine?.handleDidWake() }
        }
    }
}
