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

    var body: some Scene {
        WindowGroup("Clapboard") {
            MainView(engine: engine, registry: registry, permission: permission)
                .frame(minWidth: 900, minHeight: 520)
                .onAppear {
                    registry.start()
                    permission.refresh()
                    engine.refreshAuthorization()
                    engine.attach(registry: registry)
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
                }
        }
        .defaultSize(width: 1080, height: 660)
        .commands {
            CommandGroup(after: .toolbar) {
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
    }
}
