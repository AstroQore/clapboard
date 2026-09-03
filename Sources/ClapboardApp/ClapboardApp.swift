import ClapboardCore
import SwiftUI

@main
struct ClapboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var registry = AudioDeviceRegistry()
    @State private var permission = MicrophonePermission()
    @State private var engine = AudioEngine()

    var body: some Scene {
        WindowGroup("Clapboard") {
            MainView(engine: engine, registry: registry, permission: permission)
                .frame(minWidth: 900, minHeight: 520)
                .onAppear {
                    registry.start()
                    permission.refresh()
                    engine.refreshAuthorization()
                    engine.attach(registry: registry)
                    if engine.outputDeviceUID == nil {
                        engine.setOutputDevice(uid: registry.defaultOutputUID)
                    }
                    // The aggregate device and IOProc must be torn down before
                    // the process exits; a private aggregate normally dies with
                    // the process, but not if the HAL outlives us by a beat.
                    appDelegate.engine = engine
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
