import ClapboardCore
import SwiftUI

/// The one-line project read-out at the foot of the window: which project the
/// mixer belongs to, whether it has unsaved changes, and what the last project
/// or autosave operation did.
///
/// It sits in `MainView` rather than in `EngineStatusBar` on purpose. The
/// engine bar is shared by the console and the row mixer and is about the
/// *engine*; which document you are in is a property of the window, and putting
/// it here keeps both mixer views out of it.
struct ProjectBar: View {
    let project: ProjectController
    let session: SessionController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.hasProject ? "doc.fill" : "waveform.circle")
                .foregroundStyle(.secondary)
                .imageScale(.small)

            Text(project.projectName)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            if project.isDirty {
                // The same meaning as the title bar's edited dot, for anyone
                // whose eye is on the mixer rather than the window frame.
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }

            if let error = project.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            } else {
                Text(project.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(project.statusLine)
            }

            Spacer()

            Text(session.statusLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(session.lastSaveError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                .lineLimit(1)
                .help(session.fileURL?.path ?? "No session file")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// Puts the project's name, the standard edited dot and the proxy icon on the
/// window itself.
///
/// SwiftUI's `WindowGroup` title is fixed at the scene, and there is no
/// SwiftUI spelling of `isDocumentEdited`, so this reaches the `NSWindow`
/// directly. The work is deferred by one turn because the view is not in a
/// window yet during the first update pass, and because SwiftUI applies its own
/// title during layout — running after it is what makes the project name stick.
struct WindowDocumentBinder: NSViewRepresentable {
    let title: String
    let isEdited: Bool
    let representedURL: URL?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let title = title
        let isEdited = isEdited
        let url = representedURL
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.title != title { window.title = title }
            if window.isDocumentEdited != isEdited { window.isDocumentEdited = isEdited }
            if window.representedURL != url { window.representedURL = url }
        }
    }
}
