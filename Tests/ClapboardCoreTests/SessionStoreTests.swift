import ClapboardCore
import Foundation
import Testing

@Suite("SessionStore")
struct SessionStoreTests {
    /// Every test gets its own base directory, so nothing here can reach the
    /// real `~/Library/Application Support/Clapboard`.
    private func makeStore() throws -> (SessionStore, URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClapboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (try SessionStore(baseDirectory: base), base)
    }

    private func document(_ name: String = "Mic", gain: Float = -3) -> SessionDocument {
        SessionDocument(
            lanes: [LaneConfig(deviceUID: "uid-\(name)", deviceChannels: [0], name: name, gainDB: gain)],
            outputDeviceUID: "out",
            masterGainDB: gain
        )
    }

    @Test func defaultLocationIsApplicationSupport() throws {
        let store = try SessionStore()
        #expect(store.fileURL.lastPathComponent == "session.json")
        #expect(store.fileURL.deletingLastPathComponent().lastPathComponent == "Clapboard")
        #expect(store.fileURL.path.contains("Application Support"))
    }

    @Test func loadingReturnsNilWhenThereIsNoFileYet() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(!store.fileExists)
        #expect(try store.load() == nil)
    }

    @Test func savingCreatesTheDirectoryAndRoundTrips() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let original = document()
        try store.save(original)
        #expect(store.fileExists)
        #expect(try store.load() == original)
    }

    @Test func savingLeavesNoTemporaryFileAndReplacesTheOldContent() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try store.save(document("First", gain: -1))
        try store.save(document("Second", gain: -9))

        let entries = try FileManager.default.contentsOfDirectory(
            at: store.directory, includingPropertiesForKeys: nil
        )
        #expect(entries.map(\.lastPathComponent) == ["session.json"])

        let loaded = try #require(try store.load())
        #expect(loaded.lanes.map(\.name) == ["Second"])
        #expect(loaded.masterGainDB == -9)
        // Nothing of the first document is left in the file.
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("First"))
    }

    @Test func aCorruptFileIsQuarantinedAndReported() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try store.save(document())
        try Data("{ this is not a session".utf8).write(to: store.fileURL)

        var reported: (any Error)?
        #expect(throws: (any Error).self) {
            do { _ = try store.load() } catch { reported = error; throw error }
        }
        guard case .corruptFileQuarantined(_, let quarantined, _)? = reported as? SessionStoreError else {
            Issue.record("expected a quarantine error, got \(String(describing: reported))")
            return
        }
        // Moved aside, never deleted: the bytes the user had are still there.
        #expect(quarantined.lastPathComponent.hasPrefix("session.json.corrupt-"))
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
        #expect(try String(contentsOf: quarantined, encoding: .utf8) == "{ this is not a session")
        // And the app can carry on: the next load finds no session at all.
        #expect(!store.fileExists)
        #expect(try store.load() == nil)
    }

    @Test func loadReportingFailureNeverThrows() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("nonsense".utf8).write(to: store.fileURL)

        let outcome = store.loadReportingFailure()
        #expect(outcome.document == nil)
        #expect(outcome.error != nil)
        #expect(store.loadReportingFailure().document == nil)
        #expect(store.loadReportingFailure().error == nil)  // quarantined already
    }

    @Test func twoCorruptFilesInTheSameSecondBothSurvive() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        for _ in 0..<2 {
            try Data("bad".utf8).write(to: store.fileURL)
            _ = store.loadReportingFailure()
        }
        let quarantined = try FileManager.default
            .contentsOfDirectory(atPath: store.directory.path)
            .filter { $0.hasPrefix("session.json.corrupt-") }
        #expect(quarantined.count == 2)
    }

    @Test func aFileStoreTargetsOneExactPath() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClapboardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = SessionStore(fileURL: base.appendingPathComponent("elsewhere.json"))
        try store.save(document("Exact"))
        #expect(try store.load()?.lanes.first?.name == "Exact")
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("elsewhere.json").path))
    }
}
