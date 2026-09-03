import ClapboardCore
import SwiftUI

@main
struct ClapboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var registry = AudioDeviceRegistry()
    @State private var permission = MicrophonePermission()

    var body: some Scene {
        WindowGroup("Clapboard") {
            DeviceListView(registry: registry, permission: permission)
                .frame(minWidth: 760, minHeight: 440)
                .onAppear {
                    registry.start()
                    permission.refresh()
                }
        }
        .defaultSize(width: 900, height: 520)
    }
}
