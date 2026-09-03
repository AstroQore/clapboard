import ClapboardCore
import SwiftUI

/// Window shell: the console, the row-based mixer it replaces, and the M0
/// device list kept one tab away, over a project bar that says which document
/// the mixer belongs to.
///
/// The console is the default and the row mixer is kept beside it — the
/// existing view still works, still drives the Master bus through the engine's
/// shims, and stays reachable "until the console view has been used for a
/// while" (`docs/ROUTING.md`). The choice rides in `UserDefaults` rather than
/// in the session file: it is a preference about this Mac's window, not part of
/// the mix, and the session document has no field for it.
struct MainView: View {
    let engine: AudioEngine
    let registry: AudioDeviceRegistry
    let permission: MicrophonePermission
    let project: ProjectController
    let session: SessionController

    enum Pane: String, Hashable {
        case console
        case rows
        case devices
    }

    @AppStorage("mainPane") private var pane: Pane = .console

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $pane) {
                Tab("Console", systemImage: "slider.vertical.3", value: Pane.console) {
                    ConsoleView(engine: engine, registry: registry, permission: permission)
                }
                Tab("Rows", systemImage: "slider.horizontal.3", value: Pane.rows) {
                    MixerView(engine: engine, registry: registry, permission: permission)
                }
                Tab("Devices", systemImage: "list.bullet", value: Pane.devices) {
                    DeviceListView(registry: registry, permission: permission)
                }
            }
            Divider()
            ProjectBar(project: project, session: session)
        }
        .background(
            WindowDocumentBinder(
                title: project.windowTitle,
                isEdited: project.isDirty,
                representedURL: project.projectURL
            )
        )
    }
}
