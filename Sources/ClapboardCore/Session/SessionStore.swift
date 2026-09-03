import Foundation

public enum SessionStoreError: Error, CustomStringConvertible, Sendable {
    case noApplicationSupportDirectory
    case unreadable(url: URL, reason: String)
    /// The file existed but was not a session. It has been moved aside rather
    /// than deleted, so nothing a user typed is ever lost to a parse error.
    case corruptFileQuarantined(original: URL, quarantined: URL, reason: String)
    /// Worse: the file is unreadable *and* could not be moved out of the way,
    /// so the next save would have to overwrite it. Never do that silently.
    case corruptFileStuck(url: URL, reason: String)
    case writeFailed(url: URL, reason: String)

    public var description: String {
        switch self {
        case .noApplicationSupportDirectory:
            return "macOS did not report an Application Support directory for this user."
        case .unreadable(let url, let reason):
            return "Could not read \(url.lastPathComponent): \(reason)"
        case .corruptFileQuarantined(_, let quarantined, let reason):
            return "The session file was unreadable (\(reason)); it was kept as \(quarantined.lastPathComponent) and Clapboard started empty."
        case .corruptFileStuck(let url, let reason):
            return "The session file at \(url.path) is unreadable (\(reason)) and could not be moved aside."
        case .writeFailed(let url, let reason):
            return "Could not write \(url.lastPathComponent): \(reason)"
        }
    }
}

/// Reads and writes the session file.
///
/// Location is `~/Library/Application Support/Clapboard/session.json`. The
/// base directory is injectable so tests never touch the real one.
///
/// Writes go to a temporary file in the same directory and are then swapped in
/// with `replaceItemAt`, which is atomic on the same volume: a crash or a full
/// disk mid-save leaves the previous session intact rather than a truncated
/// file. Reads never destroy anything — a file that does not parse is renamed
/// to `session.json.corrupt-<timestamp>` and the failure is reported.
public struct SessionStore: Sendable {
    public static let defaultFolderName = "Clapboard"
    public static let defaultFileName = "session.json"

    public let directory: URL
    public let fileName: String

    public var fileURL: URL { directory.appendingPathComponent(fileName) }

    /// - Parameter baseDirectory: `nil` means the user's Application Support
    ///   directory. Tests pass a temporary directory.
    public init(
        baseDirectory: URL? = nil,
        folderName: String = SessionStore.defaultFolderName,
        fileName: String = SessionStore.defaultFileName
    ) throws {
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else {
            guard let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first else {
                throw SessionStoreError.noApplicationSupportDirectory
            }
            base = support
        }
        self.directory = base.appendingPathComponent(folderName, isDirectory: true)
        self.fileName = fileName
    }

    /// A store pointing at one exact file, for `--session-path`.
    public init(fileURL: URL) {
        self.directory = fileURL.deletingLastPathComponent()
        self.fileName = fileURL.lastPathComponent
    }

    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Load

    /// - Returns: `nil` when there is no session file yet.
    /// - Throws: `corruptFileQuarantined` when a file existed but did not
    ///   parse. The bad file has been moved aside by then, so a second call
    ///   returns `nil` and the app can carry on empty.
    public func load() throws -> SessionDocument? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SessionStoreError.unreadable(url: url, reason: shortReason(error))
        }
        do {
            return try SessionDocument.decode(data)
        } catch {
            let reason = shortReason(error)
            let quarantined: URL
            do {
                quarantined = try quarantine()
            } catch {
                throw SessionStoreError.corruptFileStuck(url: url, reason: "\(reason); \(shortReason(error))")
            }
            throw SessionStoreError.corruptFileQuarantined(
                original: url, quarantined: quarantined, reason: reason
            )
        }
    }

    /// Launch-time convenience: never throws, so a broken file cannot stop the
    /// app from opening. The caller shows `error` in the status line.
    public func loadReportingFailure() -> (document: SessionDocument?, error: (any Error)?) {
        do {
            return (try load(), nil)
        } catch {
            return (nil, error)
        }
    }

    /// Moves the current file to `session.json.corrupt-<timestamp>`.
    @discardableResult
    public func quarantine(now: Date = Date()) throws -> URL {
        let stamp = SessionStore.timestampFormatter.string(from: now)
        var candidate = directory.appendingPathComponent("\(fileName).corrupt-\(stamp)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(fileName).corrupt-\(stamp)-\(suffix)")
            suffix += 1
        }
        try FileManager.default.moveItem(at: fileURL, to: candidate)
        return candidate
    }

    // MARK: - Save

    /// Writes `document` atomically, creating the directory on demand.
    public func save(_ document: SessionDocument) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SessionStoreError.writeFailed(url: directory, reason: shortReason(error))
        }

        let data: Data
        do {
            data = try document.jsonData()
        } catch {
            throw SessionStoreError.writeFailed(url: fileURL, reason: shortReason(error))
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
            throw SessionStoreError.writeFailed(url: fileURL, reason: shortReason(error))
        }
    }

    // MARK: - Helpers

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private func shortReason(_ error: any Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .dataCorrupted(let context): return "not JSON — \(context.debugDescription)"
            case .keyNotFound(let key, _): return "missing key \(key.stringValue)"
            case .typeMismatch(_, let context): return "type mismatch at \(path(context))"
            case .valueNotFound(_, let context): return "missing value at \(path(context))"
            @unknown default: return "\(decoding)"
            }
        }
        return (error as? CocoaError)?.localizedDescription ?? "\(error)"
    }

    private func path(_ context: DecodingError.Context) -> String {
        context.codingPath.map(\.stringValue).joined(separator: ".")
    }
}
