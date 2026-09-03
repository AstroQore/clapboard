import AppKit
import ClapboardCore
import Foundation

/// Headless check for the global-shortcut path, the sibling of
/// `--engine-test` and `--session-dump`.
///
///     Clapboard --hotkeys-selftest [--hotkeys-path <file>] [--reset]
///
/// It loads the hotkey file — writing the default set when there is none —
/// registers every binding with Carbon and prints `noErr` or the failure per
/// binding, then unregisters and exits. That is the only way to find out
/// whether a shortcut is actually free without a human pressing it: a key
/// macOS has already claimed fails at *registration* with
/// `eventHotKeyExistsErr`, silently, and a mute key that never fires is worse
/// than one that was refused out loud.
///
/// Exit status is 0 when every binding registered, 1 when any did not, 2 when
/// the file itself could not be read or written.
enum HotkeySelfTest {
    @MainActor
    static func run(arguments: [String]) -> Never {
        var path: String?
        var reset = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--hotkeys-path":
                index += 1
                path = index < arguments.count ? arguments[index] : nil
            case "--reset":
                reset = true
            default:
                break
            }
            index += 1
        }

        // Carbon hotkeys hang off the *application* event target, so the
        // process needs an NSApplication even though no window is ever shown.
        // `.accessory` keeps it out of the Dock and the ⌘-Tab switcher.
        NSApplication.shared.setActivationPolicy(.accessory)

        let store: HotkeyStore?
        if let path {
            store = HotkeyStore(fileURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } else {
            store = try? HotkeyStore()
        }
        guard let store else {
            fail("no Application Support directory, and no --hotkeys-path given")
        }
        print("file: \(store.fileURL.path)")

        if reset, store.fileExists {
            do {
                try FileManager.default.removeItem(at: store.fileURL)
                print("reset: removed the existing file")
            } catch {
                fail("could not remove \(store.fileURL.path): \(error.localizedDescription)")
            }
        }

        let existed = store.fileExists
        let manager = HotkeyManager(store: store)
        let load = manager.load()
        if let error = manager.lastFileError {
            fail(error)
        }
        if !existed || load.fileWasMissing {
            print("no file yet — wrote the default bindings")
        }
        if load.isFromNewerFormat {
            print("note: written by a newer Clapboard; loaded as far as this build understands it")
        }
        for skipped in load.skipped {
            print("skipped: \(skipped)")
        }
        print("bindings: \(manager.entries.count)")
        for entry in manager.entries {
            let key = entry.binding?.displayString ?? "—"
            let note = entry.action.isImplemented ? "" : "  [\(entry.action.unavailableNote ?? "reserved")]"
            print("  \(entry.action.title.padded(to: 26)) \(key)\(note)")
        }

        let outcomes = manager.register()
        print("registration:")
        if outcomes.isEmpty {
            print("  (nothing bound)")
        }
        for outcome in outcomes {
            let mark = outcome.isSuccess ? "ok  " : "FAIL"
            print("  \(mark) \(outcome.binding.displayString.padded(to: 10)) \(outcome.action.title.padded(to: 26)) \(outcome.message)")
        }
        // Actions that never reached Carbon — reserved, or fighting over one key.
        for (action, message) in manager.registrationErrors
        where !outcomes.contains(where: { $0.action == action }) {
            print("  skip \(action.title.padded(to: 37)) \(message)")
        }

        manager.shutdown()
        let failures = outcomes.filter { !$0.isSuccess }.count
        print(failures == 0
              ? "all \(outcomes.count) binding(s) registered and released"
              : "\(failures) of \(outcomes.count) binding(s) could not be registered")
        exit(failures == 0 ? 0 : 1)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("hotkeys selftest: \(message)\n".utf8))
        exit(2)
    }
}

private extension String {
    /// Column alignment for the report; long names are left long rather than
    /// truncated, because a clipped lane name is a lie.
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
