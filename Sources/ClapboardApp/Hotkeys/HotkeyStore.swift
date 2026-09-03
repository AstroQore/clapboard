import Foundation

/// The hotkey file: `~/Library/Application Support/Clapboard/hotkeys.json`.
///
/// Deliberately *not* part of `session.json`. A session is the mixer — lanes,
/// devices, gains — and gets copied between machines or reset when a rig
/// changes; a mute key is muscle memory and should outlive that. Keeping them
/// apart also means a corrupt session cannot cost the user their mute key, and
/// the other way round.
///
/// Writes use the same temp-file-plus-`replaceItemAt` swap as `SessionStore`:
/// atomic on the same volume, so a crash mid-save leaves the old bindings
/// rather than a truncated file. Decoding is tolerant per row — one binding
/// this build cannot read (an action from a newer Clapboard, a hand-edited key
/// code) is dropped and reported, never taken as a reason to lose the rest.
struct HotkeyStore: Sendable {
    static let defaultFolderName = "Clapboard"
    static let defaultFileName = "hotkeys.json"
    static let formatVersion = 1

    let directory: URL
    let fileName: String

    var fileURL: URL { directory.appendingPathComponent(fileName) }
    var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// - Parameter baseDirectory: `nil` means Application Support. Tests and
    ///   `--hotkeys-selftest --hotkeys-path` pass their own.
    init(
        baseDirectory: URL? = nil,
        folderName: String = HotkeyStore.defaultFolderName,
        fileName: String = HotkeyStore.defaultFileName
    ) throws {
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else {
            guard let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first else {
                throw HotkeyStoreError.noApplicationSupportDirectory
            }
            base = support
        }
        self.directory = base.appendingPathComponent(folderName, isDirectory: true)
        self.fileName = fileName
    }

    /// A store pointing at one exact file.
    init(fileURL: URL) {
        self.directory = fileURL.deletingLastPathComponent()
        self.fileName = fileURL.lastPathComponent
    }

    // MARK: - Load

    struct LoadResult: Sendable {
        var entries: [HotkeyEntry] = []
        /// Rows that did not decode, described for the status line. Empty is
        /// the normal case.
        var skipped: [String] = []
        /// `true` when there was no file at all — first launch.
        var fileWasMissing: Bool = false
        /// A file written by a newer Clapboard. It is still loaded as far as
        /// this build understands it; saving rewrites it in this format.
        var isFromNewerFormat: Bool = false
    }

    func load() throws -> LoadResult {
        guard fileExists else { return LoadResult(fileWasMissing: true) }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw HotkeyStoreError.unreadable(url: fileURL, reason: error.localizedDescription)
        }

        // Split the array by hand rather than decoding it in one go: a single
        // unreadable row must not take its neighbours with it, and `Codable`
        // has no way to skip an element.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HotkeyStoreError.unreadable(url: fileURL, reason: "not a JSON object")
        }
        var result = LoadResult()
        if let version = root["formatVersion"] as? Int, version > HotkeyStore.formatVersion {
            result.isFromNewerFormat = true
        }
        let rows = root["bindings"] as? [Any] ?? []
        let decoder = JSONDecoder()
        var seen: Set<HotkeyAction> = []
        for (index, row) in rows.enumerated() {
            guard let object = row as? [String: Any],
                  let rowData = try? JSONSerialization.data(withJSONObject: object) else {
                result.skipped.append("binding \(index + 1) is not an object")
                continue
            }
            do {
                let entry = try decoder.decode(HotkeyEntry.self, from: rowData)
                // A hand-edited file can name the same action twice; the first
                // row wins, so the outcome never depends on ordering somewhere
                // downstream.
                guard seen.insert(entry.action).inserted else {
                    result.skipped.append("binding \(index + 1): duplicate \(entry.action.title)")
                    continue
                }
                result.entries.append(entry)
            } catch let error as HotkeyAction.UnknownKind {
                result.skipped.append("binding \(index + 1): \(error.description)")
            } catch {
                result.skipped.append("binding \(index + 1) is unreadable")
            }
        }
        return result
    }

    /// Launch-time convenience: a broken hotkey file must not stop the app.
    func loadReportingFailure() -> (result: LoadResult, error: (any Error)?) {
        do {
            return (try load(), nil)
        } catch {
            return (LoadResult(), error)
        }
    }

    // MARK: - Save

    func save(_ entries: [HotkeyEntry]) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw HotkeyStoreError.writeFailed(url: directory, reason: error.localizedDescription)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(
                Document(formatVersion: HotkeyStore.formatVersion, bindings: entries)
            )
        } catch {
            throw HotkeyStoreError.writeFailed(url: fileURL, reason: "\(error)")
        }

        // Same directory, therefore the same volume, therefore a real rename.
        let temporary = directory.appendingPathComponent(".\(fileName).tmp-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: .atomic)
            if manager.fileExists(atPath: fileURL.path) {
                _ = try manager.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            throw HotkeyStoreError.writeFailed(url: fileURL, reason: error.localizedDescription)
        }
    }

    /// What a machine with no hotkey file gets: one key for 闭麦 / 开麦, plus
    /// the two one-way actions listed unbound, so they are discoverable in the
    /// settings sheet without silently claiming a second system-wide shortcut.
    static var defaultEntries: [HotkeyEntry] {
        [
            HotkeyEntry(action: .toggleAllLanes, binding: .defaultToggleAll),
            HotkeyEntry(action: .muteAllLanes, binding: nil),
            HotkeyEntry(action: .unmuteAllLanes, binding: nil)
        ]
    }

    private struct Document: Encodable {
        var formatVersion: Int
        var bindings: [HotkeyEntry]
    }
}

enum HotkeyStoreError: Error, CustomStringConvertible, Sendable {
    case noApplicationSupportDirectory
    case unreadable(url: URL, reason: String)
    case writeFailed(url: URL, reason: String)

    var description: String {
        switch self {
        case .noApplicationSupportDirectory:
            return "macOS did not report an Application Support directory for this user."
        case .unreadable(let url, let reason):
            return "Could not read \(url.lastPathComponent): \(reason)"
        case .writeFailed(let url, let reason):
            return "Could not write \(url.lastPathComponent): \(reason)"
        }
    }
}
