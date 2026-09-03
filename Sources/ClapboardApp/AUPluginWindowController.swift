import AppKit
import AudioToolbox
import ClapboardCore
import CoreAudioKit

/// The plug-in editor windows.
///
/// One window per hosted instance, kept alive once opened: asking for a
/// plug-in's view a second time is slow for an AUv3 (it is an XPC round trip)
/// and outright destructive for some AUv2 bundles, which keep editor state in
/// the view rather than in the unit. Re-opening therefore brings the existing
/// window to the front.
///
/// ## Contract
///
/// `close(_:)` must be called before an `AUEffectInstance` is released. The
/// view holds the plug-in's `AudioUnit` and will keep drawing from it; letting
/// the instance deallocate first leaves the window pointing at deallocated
/// render resources.
@MainActor
final class AUPluginWindowController: NSObject, NSWindowDelegate {
    static let shared = AUPluginWindowController()

    private struct Entry {
        weak var instance: AUEffectInstance?
        let window: NSWindow
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Open — or re-front — the editor for one plug-in.
    func show(_ instance: AUEffectInstance) {
        let key = ObjectIdentifier(instance)
        if let existing = entries[key], existing.instance === instance {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        // A stale entry means an instance was released without `close(_:)`.
        // Drop the window rather than hand it a dangling plug-in.
        if let stale = entries.removeValue(forKey: key) {
            stale.window.orderOut(nil)
        }

        // AUv3 plug-ins answer asynchronously; AUv2 bundles answer inline. The
        // completion handler is documented to run on the main queue either way.
        instance.auAudioUnit.requestViewController { [weak self, weak instance] controller in
            MainActor.assumeIsolated {
                guard let self, let instance else { return }
                self.present(controller: controller, for: instance)
            }
        }
    }

    /// Close and forget one plug-in's window. Call before releasing the
    /// instance.
    func close(_ instance: AUEffectInstance) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(instance)) else { return }
        entry.window.delegate = nil
        entry.window.contentView = nil
        entry.window.orderOut(nil)
    }

    func closeAll() {
        for entry in entries.values {
            entry.window.delegate = nil
            entry.window.contentView = nil
            entry.window.orderOut(nil)
        }
        entries.removeAll()
    }

    // MARK: - Building the window

    private func present(controller: NSViewController?, for instance: AUEffectInstance) {
        let view = controller?.view ?? Self.genericView(for: instance) ?? Self.placeholderView(for: instance)
        let size = preferredSize(of: view)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = instance.componentInfo.displayName
        window.subtitle = subtitle(for: instance)
        // The window outlives its close so `show` can bring it back without
        // rebuilding the plug-in's view.
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Holds the view controller for the lifetime of the window; an AUv3's
        // view goes blank the moment its controller is released.
        window.contentViewController = controller
        if controller == nil {
            window.contentView = view
        }
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        entries[ObjectIdentifier(instance)] = Entry(instance: instance, window: window)
    }

    /// AUv2 bundles without their own view get Core Audio's generic parameter
    /// sheet, which needs the underlying v2 `AudioUnit` — reachable only
    /// through the bridge object `AUAudioUnit.instantiate` hands back for a
    /// v2 component.
    private static func genericView(for instance: AUEffectInstance) -> NSView? {
        guard let bridge = instance.auAudioUnit as? AUAudioUnitV2Bridge else { return nil }
        return AUGenericView(audioUnit: bridge.audioUnit)
    }

    private static func placeholderView(for instance: AUEffectInstance) -> NSView {
        let label = NSTextField(labelWithString:
            "\(instance.componentInfo.displayName) has no editor.")
        label.alignment = .center
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        label.frame = container.bounds.insetBy(dx: 16, dy: 48)
        label.autoresizingMask = [.width, .height]
        container.addSubview(label)
        return container
    }

    private func preferredSize(of view: NSView) -> NSSize {
        // AUGenericView reports its size in its frame; AUv3 views usually
        // report a fitting size and start out zero-sized.
        var size = view.frame.size
        if size.width < 1 || size.height < 1 { size = view.fittingSize }
        if size.width < 1 || size.height < 1 { size = NSSize(width: 480, height: 320) }
        return size
    }

    private func subtitle(for instance: AUEffectInstance) -> String {
        var parts = ["\(instance.channels) ch"]
        if instance.dualMono { parts.append("dual mono") }
        parts.append(instance.isInProcess ? "in-process" : "out-of-process")
        if instance.latencySamples > 0 { parts.append("\(instance.latencySamples) smp latency") }
        return parts.joined(separator: " · ")
    }
}
