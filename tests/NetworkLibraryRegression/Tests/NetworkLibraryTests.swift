import XCTest
import HibikiCore

final class NetworkLibraryTests: XCTestCase {
    private func fixture() throws -> (SQLiteDatabase, LibraryRepository, Int64) {
        let db = try SQLiteDatabase(path: ":memory:")
        let repo = LibraryRepository(database: db)
        try repo.prepare()
        let source = try repo.saveSource(LibrarySource(name: "Synthetic NAS", type: .smb))
        return (db, repo, source)
    }

    private func audio(_ path: String) -> NetworkImportTrack {
        NetworkImportTrack(name: (path as NSString).lastPathComponent, relativePath: path, fileType: "mp3",
            byteCount: 1234, modifiedAt: Date(timeIntervalSince1970: 1234), resourceJSON: "{\"path\":\"\(path)\"}")
    }

    func testManualSelectionIsOneWorkWithSeparateStableLocators() throws {
        let (db, repo, source) = try fixture(); defer { db.close() }
        let work = try repo.importNetworkWork(sourceID: source, title: "Selected", library: .collection,
            tracks: [audio("A/one.mp3"), audio("B/two.mp3")])
        let tracks = try repo.tracks(workID: work)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(try repo.works().count, 1)
        XCTAssertEqual(tracks.map(\.relativePath), ["A/one.mp3", "B/two.mp3"])
        XCTAssertTrue(tracks.allSatisfy { $0.filePath.hasPrefix("network-track:") && !$0.filePath.contains("/") })
        XCTAssertEqual(Set(tracks.map(\.filePath)).count, 2)
        XCTAssertEqual(try repo.setting("networkTrack.\(tracks[0].id)"), "{\"path\":\"A/one.mp3\"}")
        XCTAssertNil(try repo.sources().first?.rootPath)
    }

    func testBothExistingLibrariesRemainIndependent() throws {
        let (db, repo, source) = try fixture(); defer { db.close() }
        let creator = try repo.saveCreator(CreatorRecord(name: "Synthetic Creator"))
        _ = try repo.importNetworkWork(sourceID: source, title: "Personal", library: .personal,
            creatorID: creator, tracks: [audio("personal.mp3")])
        _ = try repo.importNetworkWork(sourceID: source, title: "Collection", library: .collection,
            tracks: [audio("collection.mp3")])
        XCTAssertEqual(try repo.works(libraryKind: .personal).first?.creatorID, creator)
        XCTAssertEqual(try repo.works(libraryKind: .collection).map(\.title), ["Collection"])
    }

    func testDisabledConnectionKeepsCatalogueAndRejectsNewImports() throws {
        let (db, repo, source) = try fixture(); defer { db.close() }
        let work = try repo.importNetworkWork(sourceID: source, title: "Kept", library: .collection,
            tracks: [audio("one.mp3")])
        let originalTracks = try repo.tracks(workID: work)
        _ = try repo.saveSource(LibrarySource(id: source, name: "Offline", type: .smb, enabled: false))
        XCTAssertEqual(try repo.work(id: work)?.title, "Kept")
        XCTAssertEqual(try repo.tracks(workID: work), originalTracks)
        XCTAssertThrowsError(try repo.importNetworkWork(sourceID: source, title: "New", library: .collection,
            tracks: [audio("two.mp3")]))
        XCTAssertEqual(try repo.counts().works, 1)
    }

    func testBindingUpdatePreservesWorkTrackAndCatalogueMetadata() throws {
        let (db, repo, source) = try fixture(); defer { db.close() }
        let workID = try repo.importNetworkWork(sourceID: source, title: "User Title", library: .collection,
            tracks: [audio("one.mp3")])
        let before = try repo.tracks(workID: workID)
        try repo.setFavorite(true, workID: workID)
        try repo.setRating(4, workID: workID)
        try repo.savePlaybackPosition(workID: workID, trackID: before[0].id, positionMS: 42_000)
        try repo.networkTransaction {
            _ = try repo.saveSource(LibrarySource(id: source, name: "Replacement connection", type: .webdav))
            try repo.setSetting("networkTrack.\(before[0].id)", "{\"path\":\"new/one.mp3\"}")
        }
        XCTAssertEqual(try repo.tracks(workID: workID), before)
        XCTAssertEqual(try repo.work(id: workID)?.title, "User Title")
        XCTAssertEqual(try repo.work(id: workID)?.favorite, true)
        XCTAssertEqual(try repo.work(id: workID)?.rating, 4)
        XCTAssertEqual(try repo.work(id: workID)?.lastPlayedTrackID, before[0].id)
        XCTAssertEqual(try repo.work(id: workID)?.lastPlayedPositionMS, 42_000)
        XCTAssertEqual(try repo.sources().first?.id, source)
        XCTAssertEqual(try repo.setting("networkTrack.\(before[0].id)"), "{\"path\":\"new/one.mp3\"}")
    }

    func testFailureRollsBackWorkTracksAndLocatorSettings() throws {
        let (db, repo, source) = try fixture(); defer { db.close() }
        XCTAssertThrowsError(try repo.importNetworkWork(sourceID: source, title: "Rejected", library: .collection,
            coverAssetPath: "../outside.jpg", tracks: [audio("one.mp3"), audio("two.mp3")]))
        XCTAssertEqual(try repo.counts().works, 0)
        XCTAssertEqual(try repo.counts().tracks, 0)
        XCTAssertNil(try repo.setting("networkTrack.1"))
        XCTAssertNil(try repo.setting("networkTrack.2"))
    }

    func testDuplicateAndEmptySelectionsMakeNoCatalogueChanges() throws {
        let (db, repo, source) = try fixture(); defer { db.close() }
        XCTAssertThrowsError(try repo.importNetworkWork(sourceID: source, title: "Duplicate", library: .collection,
            tracks: [audio("same.mp3"), audio("same.mp3")]))
        XCTAssertThrowsError(try repo.importNetworkWork(sourceID: source, title: "Empty", library: .collection, tracks: []))
        XCTAssertEqual(try repo.counts().works, 0)
        XCTAssertEqual(try repo.counts().tracks, 0)
    }

    func testSourceAndConfigurationRollbackTogether() throws {
        let (db, repo, _) = try fixture(); defer { db.close() }
        enum Abort: Error { case expected }
        XCTAssertThrowsError(try repo.networkTransaction {
            _ = try repo.saveSource(LibrarySource(name: "Uncommitted", type: .http))
            try repo.setSetting("networkLibrary.sources.v1", "pending")
            throw Abort.expected
        })
        XCTAssertEqual(try repo.sources().count, 1)
        XCTAssertNil(try repo.setting("networkLibrary.sources.v1"))
    }
}
