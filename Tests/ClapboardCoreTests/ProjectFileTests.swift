import ClapboardCore
import Foundation
import Testing

/// The document layer under a named project.
///
/// A `.clapboard` project is the same JSON as the autosaved session, written
/// through `SessionStore(fileURL:)` to a path the user chose, so what needs
/// covering here is that an arbitrary path behaves exactly like the default
/// one: the whole graph round-trips, a directory is created on demand, a
/// missing file is `nil` rather than an error, and a damaged project surfaces
/// the quarantine failure instead of coming back empty in silence.
///
/// `ProjectController` itself lives in the `ClapboardApp` executable target,
/// which SwiftPM cannot host tests for; its behaviour is asserted end to end by
/// `Clapboard --project-selftest`.
@Suite("Project files")
struct ProjectFileTests {
    private func scratch() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClapboardProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Two lanes and two buses beyond Master, routed to each other — the shape
    /// a project is worth saving for.
    private func mixer() -> SessionDocument {
        let master = BusConfig(name: BusConfig.masterName, gainDB: -1, outputDeviceUID: "out-uid")
        let vocals = BusConfig(name: "Vocals", gainDB: -3, destinationBus: master.id)
        let room = BusConfig(name: "Room", gainDB: -6, destinationBus: vocals.id)
        return SessionDocument(
            lanes: [
                LaneConfig(
                    deviceUID: "mic-a", deviceChannels: [0], name: "Mic A",
                    gainDB: -4.5, delaySamples: 881, destinationBus: vocals.id),
                LaneConfig(
                    deviceUID: "mic-b", deviceChannels: [0, 1], name: "Mic B",
                    gainDB: 0, polarityInverted: true, delaySamples: 812,
                    destinationBus: room.id)
            ],
            buses: [master, vocals, room]
        )
    }

    @Test func aProjectPathRoundTripsTheWholeGraph() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("Take One.clapboard")
        let store = SessionStore(fileURL: url)

        let written = mixer()
        try store.save(written)

        #expect(store.fileURL == url)
        #expect(store.fileExists)
        #expect(try store.load() == written)
    }

    @Test func aProjectIsPlainJSONWhateverItIsCalled() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("Take One.clapboard")
        try SessionStore(fileURL: url).save(mixer())

        // The exported UTI conforms to `public.json`, so this has to be true.
        let data = try Data(contentsOf: url)
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
        #expect(data.last == 0x0A)
    }

    @Test func savingCreatesTheChosenDirectory() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent("Live.clapboard")
        let store = SessionStore(fileURL: url)

        try store.save(mixer())
        #expect(store.fileExists)
    }

    /// What `Open Recent` runs into when an entry has been moved or deleted:
    /// nothing to load, and nothing thrown either.
    @Test func aMissingProjectLoadsAsNothing() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = SessionStore(fileURL: base.appendingPathComponent("Gone.clapboard"))

        #expect(store.fileExists == false)
        #expect(try store.load() == nil)
    }

    /// A damaged project must surface the quarantine error rather than opening
    /// an empty mixer without saying so. The file is moved aside, never
    /// deleted — a project is something a user may have spent an evening on.
    @Test func aDamagedProjectIsQuarantinedAndReported() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("Broken.clapboard")
        try Data("{ this is not a session".utf8).write(to: url)
        let store = SessionStore(fileURL: url)

        #expect(throws: SessionStoreError.self) { try store.load() }

        let quarantined = try FileManager.default
            .contentsOfDirectory(atPath: base.path)
            .filter { $0.hasPrefix("Broken.clapboard.corrupt-") }
        #expect(quarantined.count == 1)
        // Moved aside, so the app can carry on and the next save is not an
        // overwrite of something unreadable.
        #expect(store.fileExists == false)
        #expect(try store.load() == nil)
    }

    /// Save As over a project that already exists replaces it atomically.
    @Test func savingOverAnExistingProjectReplacesIt() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("Take One.clapboard")
        let store = SessionStore(fileURL: url)

        try store.save(mixer())
        var second = mixer()
        second.lanes[0].gainDB = -9.5
        try store.save(second)

        let loaded = try #require(try store.load())
        #expect(loaded.lanes[0].gainDB == -9.5)
        #expect(loaded == second)
        // One file, not a pile of temporaries.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.path)
        #expect(leftovers == ["Take One.clapboard"])
    }

    /// Two projects are two files: writing one must not touch the other, which
    /// is the whole premise of "configure it once, open it again next time".
    @Test func twoProjectsAreIndependent() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let liveURL = base.appendingPathComponent("Live.clapboard")
        let podcastURL = base.appendingPathComponent("Podcast.clapboard")

        try SessionStore(fileURL: liveURL).save(mixer())
        let liveBytes = try Data(contentsOf: liveURL)

        var podcast = mixer()
        podcast.lanes = [podcast.lanes[0]]
        try SessionStore(fileURL: podcastURL).save(podcast)

        #expect(try Data(contentsOf: liveURL) == liveBytes)
        #expect(try SessionStore(fileURL: podcastURL).load()?.lanes.count == 1)
        #expect(try SessionStore(fileURL: liveURL).load()?.lanes.count == 2)
    }
}
