import AppKit
import ClapboardCore
import Observation

/// The menu-bar microphone.
///
/// A global mute key is only half the feature: the other half is being able to
/// see, from any app, whether you are live. The icon is the answer to "am I
/// muted?" and the menu is the mouse-driven version of every hotkey, so a user
/// who never opens the settings sheet still gets one-click 闭麦 / 开麦.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var engine: AudioEngine?
    private weak var hotkeys: HotkeyManager?
    /// Cancelled by dropping the controller; `withObservationTracking` re-arms
    /// itself after every change, exactly like `SessionController`'s autosave.
    private var trackingArmed = false

    func install(engine: AudioEngine, hotkeys: HotkeyManager) {
        self.engine = engine
        self.hotkeys = hotkeys
        guard statusItem == nil else { return }

        // Not `.removalAllowed`: this icon is the only mute indicator a user
        // has while another app is full-screen, and a stray ⌘-drag must not be
        // able to take it away with no way back.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        // `menuNeedsUpdate` decides what is enabled; automatic enabling would
        // second-guess it through the responder chain.
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        updateIcon()
        beginTracking()
    }

    func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - Icon

    /// `mic.fill` while something is live, `mic.slash.fill` when everything is
    /// muted; dimmed while the engine is stopped, because a stopped engine is
    /// not passing audio no matter what the lane switches say.
    private func updateIcon() {
        guard let button = statusItem?.button, let engine else { return }
        let live = MuteToggleLogic.anyEnabled(engine.lanes)
        let name = live ? "mic.fill" : "mic.slash.fill"
        let state = live ? "microphones live" : "microphones muted"
        // A stopped engine passes no audio whatever the lane switches say, so
        // VoiceOver and the tooltip both say so rather than only the dimming.
        let description = engine.runState.isRunning
            ? "Clapboard — \(state)"
            : "Clapboard — engine stopped, \(state)"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        button.image?.isTemplate = true
        button.appearsDisabled = !engine.runState.isRunning
        button.toolTip = description
    }

    /// Observes exactly what the icon draws. Lane *meters* tick dozens of times
    /// a second and are deliberately not read here.
    private func beginTracking() {
        guard let engine else { return }
        trackingArmed = true
        withObservationTracking {
            _ = engine.lanes
            _ = engine.runState
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.trackingArmed else { return }
                self.beginTracking()
                self.updateIcon()
            }
        }
    }

    // MARK: - Menu

    /// Built on every open rather than kept in sync: lanes come and go, and a
    /// menu that is only ever seen for a second is not worth an observer.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let engine else { return }

        for action in HotkeyAction.globalActions {
            let item = NSMenuItem(
                title: action.title,
                action: #selector(performAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action
            item.isEnabled = !engine.lanes.isEmpty
            // Shown as a tooltip rather than as a key equivalent: a status-item
            // key equivalent would fire alongside the Carbon hotkey while the
            // menu is open, toggling the mixer twice on one press.
            if let binding = hotkeys?.binding(for: action) {
                item.toolTip = "Shortcut: \(binding.displayString)"
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if engine.lanes.isEmpty {
            let empty = NSMenuItem(title: "No lanes yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for lane in engine.lanes {
            let item = NSMenuItem(
                title: lane.name,
                action: #selector(toggleLane(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = lane.id
            item.state = lane.enabled ? .on : .off
            if engine.laneStatus[lane.id]?.isProblem == true {
                item.title = "\(lane.name) — device missing"
            }
            if let binding = hotkeys?.binding(for: .toggleLaneMute(laneID: lane.id)) {
                item.toolTip = "Shortcut: \(binding.displayString)"
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let engineItem = NSMenuItem(
            title: engine.runState.isRunning ? "Stop Engine" : "Run Engine",
            action: #selector(toggleEngine(_:)),
            keyEquivalent: ""
        )
        engineItem.target = self
        engineItem.isEnabled = !engine.runState.isBusy && engine.outputDeviceUID != nil
        menu.addItem(engineItem)

        let open = NSMenuItem(title: "Open Clapboard", action: #selector(openMainWindow(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let settings = NSMenuItem(title: "Shortcuts…", action: #selector(openSettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Clapboard", action: #selector(quit(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? HotkeyAction else { return }
        hotkeys?.perform(action)
        updateIcon()
    }

    @objc private func toggleLane(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        hotkeys?.perform(.toggleLaneMute(laneID: id))
        updateIcon()
    }

    @objc private func toggleEngine(_ sender: NSMenuItem) {
        guard let engine else { return }
        engine.runState.isRunning ? engine.stop() : engine.start()
    }

    @objc private func openMainWindow(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        // The window may only be hidden behind another app, or it may be gone
        // entirely; ask AppKit to reopen in the second case.
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isMiniaturized }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(#selector(NSApplication.unhide(_:)), to: NSApp, from: nil)
        }
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        // The selector moved between macOS releases; try the current one first.
        let modern = Selector(("showSettingsWindow:"))
        let legacy = Selector(("showPreferencesWindow:"))
        if NSApp.responds(to: modern) || NSApp.target(forAction: modern) != nil {
            NSApp.sendAction(modern, to: nil, from: nil)
        } else {
            NSApp.sendAction(legacy, to: nil, from: nil)
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
