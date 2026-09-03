import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The "press the key you want" field.
///
/// It has to be an `NSView` rather than SwiftUI's `onKeyPress`: recording a
/// shortcut means seeing ⌘, ⌥ and ⎋ *before* the responder chain gets its
/// hands on them — a menu would swallow ⌘Q, a sheet would swallow ⎋ — which
/// only `performKeyEquivalent(with:)` on a first-responder view can do.
struct KeyRecorderView: NSViewRepresentable {
    var binding: KeyBinding?
    var isEnabled: Bool = true
    /// `nil` means the user cleared the shortcut.
    var onChange: (KeyBinding?) -> Void

    func makeNSView(context: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.binding = binding
        view.isEnabledForRecording = isEnabled
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: KeyRecorderNSView, context: Context) {
        view.binding = binding
        view.isEnabledForRecording = isEnabled
        view.onChange = onChange
        view.needsDisplay = true
    }
}

/// Draws itself, because a bordered `NSButton` would fight the first-responder
/// handling and a SwiftUI overlay would sit above the click target.
final class KeyRecorderNSView: NSView {
    var binding: KeyBinding? {
        didSet { needsDisplay = true }
    }
    var isEnabledForRecording = true {
        didSet {
            if !isEnabledForRecording { stopRecording() }
            needsDisplay = true
        }
    }
    var onChange: ((KeyBinding?) -> Void)?

    private(set) var isRecording = false {
        didSet { needsDisplay = true }
    }
    /// Modifiers held right now, so the field shows ⌃⌥ while the user is still
    /// reaching for the letter.
    private var liveModifiers: UInt32 = 0 {
        didSet { needsDisplay = true }
    }
    /// Why the last keypress was not accepted. Shown in the field for a beat,
    /// because a recorder that only beeps leaves the user guessing.
    private var rejection: String? {
        didSet { needsDisplay = true }
    }

    /// Refuse a combination and stay in recording mode.
    private func reject(_ reason: String) {
        NSSound.beep()
        rejection = reason
        let generation = UUID()
        rejectionGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.rejectionGeneration == generation else { return }
            self.rejection = nil
        }
    }

    private var rejectionGeneration = UUID()

    override var acceptsFirstResponder: Bool { isEnabledForRecording }
    override var intrinsicContentSize: NSSize { NSSize(width: 116, height: 22) }
    override var isFlipped: Bool { true }

    /// Set by `mouseDown` just before asking for first responder.
    ///
    /// Without it the settings window opens *in* recording mode: AppKit hands
    /// the initial first responder to the first view that accepts it, which is
    /// the topmost recorder, and the user's existing shortcut would be hidden
    /// behind "Press a key…" — with the next thing they typed captured.
    private var wantsRecording = false

    override func mouseDown(with event: NSEvent) {
        guard isEnabledForRecording else { return }
        if isRecording {
            window?.makeFirstResponder(nil)
        } else {
            wantsRecording = true
            window?.makeFirstResponder(self)
            wantsRecording = false
        }
    }

    override func becomeFirstResponder() -> Bool {
        // Refuse focus that the user did not ask for, so AppKit moves on to
        // the next candidate instead of arming this field.
        guard isEnabledForRecording, wantsRecording else { return false }
        isRecording = true
        liveModifiers = 0
        rejection = nil
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return true
    }

    private func stopRecording() {
        isRecording = false
        liveModifiers = 0
    }

    // MARK: - Capture

    /// Runs before menu key equivalents, which is the whole point: ⌘Q has to
    /// be recordable as a mute key without quitting the app on the way.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        return handle(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording, handle(event) else {
            super.keyDown(with: event)
            return
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        liveModifiers = KeyBinding.carbonModifiers(from: event.modifierFlags)
    }

    /// - Returns: `true` when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:
            // Cancel: keep whatever was bound before.
            window?.makeFirstResponder(nil)
            return true
        case kVK_Delete, kVK_ForwardDelete:
            binding = nil
            onChange?(nil)
            window?.makeFirstResponder(nil)
            return true
        default:
            break
        }
        guard let recorded = KeyBinding(event: event) else {
            // A bare letter would be swallowed system-wide; say so and stay in
            // recording mode rather than binding something the user would have
            // to hunt down in System Settings later.
            reject("Add ⌃, ⌥ or ⌘")
            return true
        }
        if let reason = recorded.systemReservedReason {
            reject(reason)
            return true
        }
        binding = recorded
        onChange?(recorded)
        window?.makeFirstResponder(nil)
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)

        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let colour: NSColor
        if let rejection {
            text = rejection
            colour = .systemOrange
        } else if isRecording {
            let held = KeyBinding.modifierSymbols(liveModifiers)
            text = held.isEmpty ? "Press a key…" : held
            colour = .controlAccentColor
        } else if let binding {
            text = binding.displayString
            colour = isEnabledForRecording ? .labelColor : .disabledControlTextColor
        } else {
            text = "Not set"
            colour = .tertiaryLabelColor
        }

        // A reason like "⌘Space opens Spotlight" does not fit at 12pt; it is
        // worth more than the shortcut it replaced for the second it is up.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(
                ofSize: rejection == nil ? 12 : 10,
                weight: isRecording ? .medium : .regular
            ),
            .foregroundColor: colour
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}
