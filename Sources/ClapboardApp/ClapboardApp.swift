import ClapboardCore
import SwiftUI

/// Entry point is `main.swift`, which dispatches headless flags before
/// AppKit starts and otherwise calls `ClapboardApp.main()`.
struct ClapboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var registry = AudioDeviceRegistry()
    @State private var permission = MicrophonePermission()
    @State private var engine = AudioEngine()
    @State private var session = SessionController()
    @State private var hotkeys = HotkeyManager()

    var body: some Scene {
        WindowGroup("Clapboard") {
            MainView(engine: engine, registry: registry, permission: permission)
                // A console strip is a fixed 120 pt column of stacked controls
                // with a fader under them; below about 600 pt of window the
                // fader has nothing left to give.
                .frame(minWidth: 940, minHeight: 600)
                .onAppear {
                    registry.start()
                    permission.refresh()
                    engine.refreshAuthorization()
                    engine.attach(registry: registry)
                    // Plug-in editor windows are AppKit, and `ClapboardCore`
                    // has none. Closing before teardown is a hard requirement:
                    // the view keeps drawing from the plug-in's render
                    // resources, which `teardown()` releases.
                    engine.onShowEffectWindow = { AUPluginWindowController.shared.show($0) }
                    engine.onCloseEffectWindow = { AUPluginWindowController.shared.close($0) }
                    // Restore before falling back to the default output, so a
                    // saved output device wins over whatever macOS is pointing
                    // at today. Autosave starts once this returns.
                    session.attach(engine: engine)
                    if engine.outputDeviceUID == nil {
                        engine.setOutputDevice(uid: registry.defaultOutputUID)
                    }
                    // The aggregate device and IOProc must be torn down before
                    // the process exits; a private aggregate normally dies with
                    // the process, but not if the HAL outlives us by a beat.
                    appDelegate.engine = engine
                    appDelegate.session = session
                    // Restore first: a per-lane shortcut is keyed on a lane id,
                    // so the lanes have to exist before the bindings are read.
                    hotkeys.start(engine: engine)
                    appDelegate.hotkeys = hotkeys
                    appDelegate.installStatusItem(engine: engine, hotkeys: hotkeys)
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Mute All Microphones") { hotkeys.perform(.muteAllLanes) }
                    .disabled(engine.lanes.isEmpty)
                Button("Unmute All Microphones") { hotkeys.perform(.unmuteAllLanes) }
                    .disabled(engine.lanes.isEmpty)
                Divider()
                Button(engine.runState.isRunning ? "Stop Engine" : "Run Engine") {
                    engine.runState.isRunning ? engine.stop() : engine.start()
                }
                .keyboardShortcut("r", modifiers: [.command])
                Button("Rebuild Aggregate Device") {
                    engine.rebuild(reason: "manual rebuild")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!engine.runState.isRunning)
            }
        }

        // ⌘, comes free with a `Settings` scene.
        Settings {
            HotkeysSettingsView(hotkeys: hotkeys, engine: engine)
        }
    }
}
