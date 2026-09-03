import ClapboardCore
import SwiftUI

/// Window shell: the mixer, plus the M0 device list kept one tab away.
struct MainView: View {
    let engine: AudioEngine
    let registry: AudioDeviceRegistry
    let permission: MicrophonePermission

    private enum Pane: Hashable {
        case mixer
        case devices
    }

    @State private var pane: Pane = .mixer

    var body: some View {
        TabView(selection: $pane) {
            Tab("Mixer", systemImage: "slider.horizontal.3", value: Pane.mixer) {
                MixerView(engine: engine, registry: registry, permission: permission)
            }
            Tab("Devices", systemImage: "list.bullet", value: Pane.devices) {
                DeviceListView(registry: registry, permission: permission)
            }
        }
    }
}
