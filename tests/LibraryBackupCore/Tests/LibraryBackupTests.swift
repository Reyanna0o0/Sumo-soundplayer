import XCTest
import Foundation
import SQLite3
import HibikiCore
import ZIPFoundation
@testable import BackupCore

final class LibraryBackupTests: XCTestCase {
    final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func run(_ body: () -> Void) { lock.lock(); defer { lock.unlock() }; guard !done else { return }; done = true; body() }
    }
    struct Fixture {
        let base: URL; let roots: LibraryBackupRoots; let defaults: UserDefaults; let suite: String
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("simo-backup-synthetic-" + UUID().uuidString)
            roots = LibraryBackupRoots(documents: base.appendingPathComponent("Documents"),
                applicationSupport: base.appendingPathComponent("Library/Application Support"),
                state: base.appendingPathComponent("Library/BackupState"))
            suite = "simo.backup.synthetic." + UUID().uuidString; defaults = UserDefaults(suiteName: suite)!
            try LibraryBackupCore.ensureDirectory(roots.documents)
            try LibraryBackupCore.ensureDirectory(roots.applicationSupport)
        }
        func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: base) }
        func file(_ path: String, _ data: String) throws {
            let url = base.appendingPathComponent(path)
            try LibraryBackupCore.ensureDirectory(url.deletingLastPathComponent()); try Data(data.utf8).write(to: url)
        }
        func db(_ value: String = "original", keepOpen: Bool = false) throws -> OpaquePointer? {
            let path = roots.documents.appendingPathComponent("hibiki.db").path
            var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
            let source = roots.documents.appendingPathComponent("ImportedArchives/test").path.replacingOccurrences(of: "'", with: "''")
            let call = String(data: try JSONEncoder().encode(CallProfile(avatarMode: .none, backgroundMode: .custom,
                backgroundAssetPath: "Covers/call.jpg")), encoding: .utf8)!
            for migration in Schema.migrations { XCTAssertEqual(sqlite3_exec(db, migration.sql, nil, nil, nil), SQLITE_OK) }
            let sql = """
            PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA user_version=26;
            INSERT INTO source(id,name,type,root_path,bookmark,created_at) VALUES(1,'owned','local','\(source)',X'01',0),(2,'personal','local',NULL,NULL,0),(3,'NAS','smb','/external/NAS',NULL,0);
            INSERT INTO work(id,title,cover_asset_path,folder_path,source_id,created_at,updated_at) VALUES(1,'\(value)','Covers/cover.jpg','.',1,0,0);
            INSERT INTO track(id,work_id,file_name,file_path,file_type,asset_relative_path,relative_path,created_at) VALUES
            (1,1,'test.wav','\(roots.applicationSupport.path)/WorkAssets/Audio/test.wav','wav','Audio/test.wav','test.wav',0),
            (2,1,'local.wav','\(source)/local.wav','wav',NULL,'local.wav',0);
            INSERT INTO creator(id,name,avatar_asset_path,created_at,updated_at) VALUES(1,'Synthetic creator','Covers/avatar.jpg',0,0);
            INSERT INTO call_profile(owner_kind,owner_id,profile_json,updated_at) VALUES('localUser',0,'\(call)',0);
            INSERT INTO playlist_entry(group_id,track_id,title,work_title,start_ms,end_ms,clip_filename,created_at) VALUES(2,1,'Synthetic clip','Synthetic work',0,1000,'clip.caf',0);
            INSERT INTO app_setting(key,value,updated_at) VALUES('nas.source','{"credentialReference":"ref-only"}',0);
            """
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            try file("Documents/ImportedArchives/test/local.wav", "owned-folder-audio")
            try file("Documents/user-file.txt", "user-document")
            try file("Documents/debug.log", "excluded log")
            try file("Library/Application Support/WorkAssets/Audio/test.wav", "owned-audio")
            try file("Library/Application Support/WorkAssets/Covers/cover.jpg", "owned-cover")
            try file("Library/Application Support/WorkAssets/Covers/avatar.jpg", "creator-avatar")
            try file("Library/Application Support/WorkAssets/Covers/call.jpg", "call-background")
            try file("Library/Application Support/PlaylistClips/clip.caf", "saved-clip")
            try file("Library/Application Support/UpgradeBackups/old.db", "excluded old database")
            try file("Library/Caches/cache.bin", "excluded cache")
            defaults.set("graphite", forKey: "appAppearancePalette")
            defaults.set("never-export", forKey: "nas.password")
            if keepOpen { return db }; sqlite3_close(db); return nil
        }
        func backup(_ progress: (@Sendable (Int64,Int64)->Void)? = nil) throws -> URL {
            let target = roots.state.appendingPathComponent(UUID().uuidString + ".simobackup")
            _ = try LibraryBackupCore.export(roots: roots,
                preferences: LibraryBackupPreferences.data(from: defaults.dictionaryRepresentation()),
                destination: target, appVersion: "synthetic", progress: progress)
            return target
        }
        func value(_ sql: String) throws -> String {
            try LibraryBackupCore.withDatabase(roots.documents.appendingPathComponent("hibiki.db")) { try LibraryBackupCore.query($0,sql).first?.first ?? "" }
        }
    }

    func testWALSnapshotFreshRootRestoreReanchorsOwnedSourcesAndPreservesAssets() throws {
        let source = try Fixture(), target = try Fixture(); defer { source.cleanup(); target.cleanup() }
        let open = try source.db("wal-committed", keepOpen: true); defer { sqlite3_close(open) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.roots.documents.appendingPathComponent("hibiki.db-wal").path))
        let backup = try source.backup()
        let prepared = try LibraryBackupCore.prepareRestore(archiveURL: backup, roots: target.roots)
        XCTAssertEqual(prepared.manifest.externalSources.map(\.name), ["NAS"])
        XCTAssertEqual(prepared.manifest.ownedSources.count, 1)
        XCTAssertFalse(prepared.manifest.files.contains { $0.path.contains("UpgradeBackups") || $0.path.contains("Caches") || $0.path == "Documents/debug.log" })
        XCTAssertTrue(prepared.manifest.files.contains { $0.path == "ApplicationSupport/WorkAssets/Covers/call.jpg" })
        try LibraryBackupLaunchGate.confirm(prepared, roots: target.roots)
        XCTAssertEqual(try LibraryBackupLaunchGate.apply(roots: target.roots, defaults: target.defaults), .restored)
        XCTAssertEqual(try target.value("SELECT title FROM work WHERE id=1"), "wal-committed")
        XCTAssertEqual(try target.value("SELECT root_path FROM source WHERE id=1"), target.roots.documents.appendingPathComponent("ImportedArchives/test").path)
        XCTAssertEqual(try target.value("SELECT length(bookmark) FROM source WHERE id=1"), "")
        XCTAssertEqual(try target.value("SELECT root_path FROM source WHERE id=3"), "/external/NAS")
        XCTAssertEqual(target.defaults.string(forKey: "appAppearancePalette"), "graphite")
        XCTAssertNil(target.defaults.string(forKey: "nas.password"))
        for file in prepared.manifest.files where file.path != "Documents/hibiki.db" && file.path != "preferences.plist" {
            let url = file.path.hasPrefix("Documents/") ? target.roots.documents.appendingPathComponent(String(file.path.dropFirst(10))) : target.roots.applicationSupport.appendingPathComponent(String(file.path.dropFirst(19)))
            XCTAssertEqual(try LibraryBackupLaunchGate.hashFile(url), file.sha256)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.roots.state.appendingPathComponent("last-successful-restore.json").path))
    }

    func testEachTransactionFailureRollsBackOriginalDatabaseAssetsAndPreferences() throws {
        enum Injected: Error { case failure }
        for checkpoint in ["journalPersisted", "oldDocumentsMoved", "newDocumentsMoved", "oldSupportMoved", "newSupportMoved", "preferencesApplied"] {
            let source = try Fixture(), target = try Fixture(); defer { source.cleanup(); target.cleanup() }
            _ = try source.db("incoming"); _ = try target.db("original")
            target.defaults.set("original-theme", forKey: "appAppearancePalette")
            try target.file("Library/Application Support/WorkAssets/Audio/test.wav", "original bytes")
            let prepared = try LibraryBackupCore.prepareRestore(archiveURL: source.backup(), roots: target.roots)
            try LibraryBackupLaunchGate.confirm(prepared, roots: target.roots)
            XCTAssertThrowsError(try LibraryBackupLaunchGate.apply(roots: target.roots, defaults: target.defaults) { if $0 == checkpoint { throw Injected.failure } })
            XCTAssertEqual(try target.value("SELECT title FROM work"), "original", checkpoint)
            XCTAssertEqual(target.defaults.string(forKey: "appAppearancePalette"), "original-theme", checkpoint)
            XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.directory.path), checkpoint)
            XCTAssertEqual(try String(contentsOf: target.roots.applicationSupport.appendingPathComponent("WorkAssets/Audio/test.wav"), encoding: .utf8), "original bytes", checkpoint)
            XCTAssertEqual(try LibraryBackupLaunchGate.apply(roots: target.roots, defaults: target.defaults), .none)
        }
    }

    func testInterruptedDirectorySwapIsRecoveredOnNextColdStart() throws {
        let source = try Fixture(), target = try Fixture(); defer { source.cleanup(); target.cleanup() }
        _ = try source.db("incoming"); _ = try target.db("original")
        let prepared = try LibraryBackupCore.prepareRestore(archiveURL: source.backup(), roots: target.roots)
        try LibraryBackupLaunchGate.confirm(prepared, roots: target.roots)
        let rollbackLeaf = "rollback-" + UUID().uuidString
        let rollback = target.roots.state.appendingPathComponent(rollbackLeaf)
        try LibraryBackupCore.ensureDirectory(rollback)
        try LibraryBackupPreferences.data(from: target.defaults.dictionaryRepresentation()).write(to: rollback.appendingPathComponent("preferences.plist"))
        let journal = LibraryBackupLaunchGate.Journal(preparedLeaf: prepared.directory.lastPathComponent, rollbackLeaf: rollbackLeaf,
            hadDocuments: true, hadSupport: true, committed: false)
        try JSONEncoder().encode(journal).write(to: target.roots.state.appendingPathComponent("journal.json"))
        try FileManager.default.moveItem(at: target.roots.documents, to: rollback.appendingPathComponent("Documents"))
        try FileManager.default.moveItem(at: prepared.directory.appendingPathComponent("payload/Documents"), to: target.roots.documents)
        XCTAssertEqual(try LibraryBackupLaunchGate.apply(roots: target.roots, defaults: target.defaults), .rolledBack)
        XCTAssertEqual(try target.value("SELECT title FROM work"), "original")
        XCTAssertFalse(LibraryBackupLaunchGate.hasPending(roots: target.roots))
    }

    func testMissingOwnedMediaFailsExportInsteadOfSilentlyOmitting() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }; _ = try fixture.db()
        try FileManager.default.removeItem(at: fixture.roots.applicationSupport.appendingPathComponent("WorkAssets/Covers/avatar.jpg"))
        XCTAssertThrowsError(try fixture.backup())
        XCTAssertEqual(try fixture.value("SELECT title FROM work"), "original")
    }
    func testStaleIOSOwnedRootIsRecognizedAndReanchoredWithoutExternalMislabel() throws {
        let source = try Fixture(), target = try Fixture(); defer { source.cleanup(); target.cleanup() }
        _ = try source.db()
        let oldRoot = "/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111/Documents/ImportedArchives/test"
        var db: OpaquePointer?; sqlite3_open(source.roots.documents.appendingPathComponent("hibiki.db").path, &db)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE source SET root_path='\(oldRoot)' WHERE id=1; UPDATE track SET file_path='\(oldRoot)/local.wav' WHERE id=2", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let prepared = try LibraryBackupCore.prepareRestore(archiveURL: source.backup(), roots: target.roots)
        XCTAssertEqual(prepared.manifest.externalSources.map(\.name), ["NAS"])
        XCTAssertEqual(prepared.manifest.ownedSources.first?.originalRoot, oldRoot)
        try LibraryBackupLaunchGate.confirm(prepared, roots: target.roots)
        XCTAssertEqual(try LibraryBackupLaunchGate.apply(roots: target.roots, defaults: target.defaults), .restored)
        XCTAssertEqual(try target.value("SELECT root_path FROM source WHERE id=1"), target.roots.documents.appendingPathComponent("ImportedArchives/test").path)
    }
    func testMissingOwnedSourceCoverScriptAttachmentAndStaleAbsoluteAudioAreRejected() throws {
        for missing in ["cover", "script", "attachment", "staleAudio"] {
            let fixture = try Fixture(); defer { fixture.cleanup() }; _ = try fixture.db()
            var db: OpaquePointer?; sqlite3_open(fixture.roots.documents.appendingPathComponent("hibiki.db").path, &db)
            let sql: String
            switch missing {
            case "cover": sql = "UPDATE work SET cover_asset_path=NULL,cover_path='missing-cover.jpg'"
            case "script": sql = "UPDATE work SET script_path='missing-script.txt'"
            case "attachment": sql = "INSERT INTO work_attachment(work_id,relative_path,kind,byte_count) VALUES(1,'missing-video.mp4','video',123)"
            default:
                let old = "/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111/Documents/ImportedArchives/test"
                sql = "UPDATE source SET root_path='\(old)' WHERE id=1; UPDATE track SET file_path='\(old)/local.wav' WHERE id=2"
                try FileManager.default.removeItem(at: fixture.roots.documents.appendingPathComponent("ImportedArchives/test/local.wav"))
            }
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
            XCTAssertThrowsError(try fixture.backup(), missing)
        }
    }
    func testLegacyFormatAndFilesAsWorksReferencesMatchAppResolution() throws {
        for grouping in ["automatic", "filesAsWorks"] {
            let fixture = try Fixture(); defer { fixture.cleanup() }; _ = try fixture.db()
            let folder = grouping == "automatic" ? "wav" : "one/local.wav"
            let directory = grouping == "automatic" ? "wav" : "one"
            try fixture.file("Documents/ImportedArchives/test/\(directory)/local.wav", "relative audio")
            let attachment = grouping == "automatic" ? "Documents/ImportedArchives/test/companion.txt" : "Documents/ImportedArchives/test/one/companion.txt"
            try fixture.file(attachment, "companion")
            var db: OpaquePointer?; sqlite3_open(fixture.roots.documents.appendingPathComponent("hibiki.db").path, &db)
            XCTAssertEqual(sqlite3_exec(db, "UPDATE source SET grouping='\(grouping)' WHERE id=1; UPDATE work SET folder_path='\(folder)'; INSERT INTO work_attachment(work_id,relative_path,kind,byte_count) VALUES(1,'companion.txt','text',9)", nil, nil, nil), SQLITE_OK)
            sqlite3_close(db)
            XCTAssertNoThrow(try fixture.backup(), grouping)
            try FileManager.default.removeItem(at: fixture.base.appendingPathComponent(attachment))
            XCTAssertThrowsError(try fixture.backup(), grouping)
        }
    }
    func testAbsoluteFolderPathUsesFolderRelAndSupportsLegacyAbsoluteFallback() throws {
        for useRelative in [true, false] {
            let fixture = try Fixture(); defer { fixture.cleanup() }; _ = try fixture.db()
            let root = fixture.roots.documents.appendingPathComponent("ImportedArchives/test").path
            for file in ["local.wav", "cover.jpg", "script.txt", "companion.pdf"] {
                try fixture.file("Documents/ImportedArchives/test/album/" + file, "synthetic " + file)
            }
            var db: OpaquePointer?; sqlite3_open(fixture.roots.documents.appendingPathComponent("hibiki.db").path, &db)
            let relativeSQL = useRelative ? "'album'" : "NULL"
            let sql = """
            UPDATE work SET folder_path='\(root)/album',folder_rel=\(relativeSQL),cover_asset_path=NULL,cover_path='cover.jpg',script_path='script.txt';
            UPDATE track SET file_path='\(root)/album/local.wav',file_rel='ignored-index-only.wav' WHERE id=2;
            INSERT INTO work_attachment(work_id,relative_path,kind,byte_count) VALUES(1,'companion.pdf','pdf',1);
            """
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
            let archive = try fixture.backup()
            XCTAssertNoThrow(try LibraryBackupCore.prepareRestore(archiveURL: archive, roots: fixture.roots))
            try FileManager.default.removeItem(at: fixture.roots.documents.appendingPathComponent("ImportedArchives/test/album/script.txt"))
            XCTAssertThrowsError(try fixture.backup())
        }
    }
    func testSyntheticColdLaunchSeedContainsBothLibrariesAndValidatedPending() throws {
        let source = try Fixture(), target = try Fixture(); defer { source.cleanup(); target.cleanup() }
        _ = try source.db("SYNTHETIC RESTORED LIBRARY"); _ = try target.db("SYNTHETIC ORIGINAL LIBRARY")
        try target.file("Documents/original-library-marker.txt", "original library retained for rollback")
        let archive = try source.backup()
        let prepared = try LibraryBackupCore.prepareRestore(archiveURL: archive, roots: target.roots)
        try LibraryBackupLaunchGate.confirm(prepared, roots: target.roots)
        XCTAssertTrue(LibraryBackupLaunchGate.hasPending(roots: target.roots))
        XCTAssertEqual(try target.value("SELECT title FROM work"), "SYNTHETIC ORIGINAL LIBRARY")
        guard let destination = ProcessInfo.processInfo.environment["SIMO_BACKUP_SYNTHETIC_SEED"] else { return }
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        guard destination.hasPrefix("/private/tmp/"), !FileManager.default.fileExists(atPath: output.path) else { throw LibraryBackupError.invalid("合成测试输出目录无效") }
        try LibraryBackupCore.ensureDirectory(output.appendingPathComponent("Library"))
        try FileManager.default.copyItem(at: target.roots.documents, to: output.appendingPathComponent("Documents"))
        try FileManager.default.copyItem(at: target.roots.applicationSupport, to: output.appendingPathComponent("Library/Application Support"))
        try FileManager.default.copyItem(at: target.roots.state, to: output.appendingPathComponent("Library/SumoLibraryBackupState"))
        try FileManager.default.copyItem(at: archive, to: output.appendingPathComponent("synthetic-input.simobackup"))
        try JSONEncoder().encode(prepared.manifest).write(to: output.appendingPathComponent("expected-manifest.json"))
    }
    func testAssetsChangedAfterReadOrNewFilesInvalidateExport() throws {
        for change in ["delete", "add", "rewrite"] {
            let fixture = try Fixture(); defer { fixture.cleanup() }; _ = try fixture.db()
            let once = Once()
            XCTAssertThrowsError(try fixture.backup { completed,total in
                guard completed == total else { return }; once.run {
                if change == "delete" { try? FileManager.default.removeItem(at: fixture.roots.applicationSupport.appendingPathComponent("WorkAssets/Audio/test.wav")) }
                else { try? fixture.file(change == "add" ? "Documents/added.txt" : "Library/Application Support/WorkAssets/Audio/test.wav", "different") }
                }
            }) { error in XCTAssertTrue(error is LibraryBackupError) }
        }
    }
    func testDatabaseWriteDuringExportInvalidatesSnapshot() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }; _ = try fixture.db()
        let once = Once()
        XCTAssertThrowsError(try fixture.backup { completed,total in
            guard completed == total else { return }; once.run {
            var writer: OpaquePointer?; sqlite3_open(fixture.roots.documents.appendingPathComponent("hibiki.db").path, &writer)
            sqlite3_exec(writer,"UPDATE work SET title='changed'",nil,nil,nil); sqlite3_close(writer)
            }
        })
    }
    func testPreparedPayloadTamperCannotBeConfirmed() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }; _ = try fixture.db()
        let prepared = try LibraryBackupCore.prepareRestore(archiveURL: fixture.backup(), roots: fixture.roots)
        try Data("tampered".utf8).write(to: prepared.directory.appendingPathComponent("payload/ApplicationSupport/WorkAssets/Covers/cover.jpg"))
        XCTAssertThrowsError(try LibraryBackupLaunchGate.confirm(prepared, roots: fixture.roots))
        XCTAssertFalse(LibraryBackupLaunchGate.hasPending(roots: fixture.roots))
        XCTAssertEqual(try fixture.value("SELECT title FROM work"), "original")
    }
    func testCancelPendingDeletesOnlyItsPreparedCopyAndPreservesOriginal() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }; _ = try fixture.db()
        let prepared = try LibraryBackupCore.prepareRestore(archiveURL: fixture.backup(), roots: fixture.roots)
        try LibraryBackupLaunchGate.confirm(prepared, roots: fixture.roots)
        let unrelated = fixture.roots.state.appendingPathComponent("rollback-" + UUID().uuidString)
        try LibraryBackupCore.ensureDirectory(unrelated)
        try LibraryBackupLaunchGate.cancelPending(roots: fixture.roots)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.directory.path))
        XCTAssertFalse(LibraryBackupLaunchGate.hasPending(roots: fixture.roots))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(try fixture.value("SELECT title FROM work"), "original")
    }
    func testMaliciousArchivePathsTypesHashesAndSchemaLeaveCurrentLibraryUntouched() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }; _ = try fixture.db()
        let original = try fixture.backup()
        for attack in ["traversal", "symlink", "duplicateCase", "extraFile", "badHash", "futureSchema", "oversize", "corruptDatabase", "missingReferencedFile"] {
            let mutated = try rewriteArchive(original, attack: attack, at: fixture.base)
            XCTAssertThrowsError(try LibraryBackupCore.prepareRestore(archiveURL: mutated, roots: fixture.roots), attack)
            XCTAssertEqual(try fixture.value("SELECT title FROM work"), "original", attack)
            XCTAssertFalse(LibraryBackupLaunchGate.hasPending(roots: fixture.roots))
        }
    }
    func testSpaceLimitIsCheckedBeforeRestoreOrExportWritesTargets() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }; _ = try fixture.db()
        let archive = try fixture.backup()
        var limits = LibraryBackupLimits(); limits.freeSpaceReserve = .max
        XCTAssertThrowsError(try LibraryBackupCore.prepareRestore(archiveURL: archive, roots: fixture.roots, limits: limits))
        XCTAssertThrowsError(try LibraryBackupCore.export(roots: fixture.roots, preferences: LibraryBackupPreferences.data(from: [:]),
            destination: fixture.base.appendingPathComponent("failed.simobackup"), appVersion: "test", limits: limits))
        XCTAssertEqual(try fixture.value("SELECT title FROM work"), "original")
    }
    func testClaimedSchemaVersionCannotHideMissingTablesOrColumns() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }; _ = try fixture.db()
        var db: OpaquePointer?; sqlite3_open(fixture.roots.documents.appendingPathComponent("hibiki.db").path, &db)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE creator", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try fixture.backup())
    }
    func testSymlinkOwnedAssetRejectedAndSecretPreferencesExcluded() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }; _ = try fixture.db()
        try FileManager.default.createSymbolicLink(atPath: fixture.roots.documents.appendingPathComponent("outside").path, withDestinationPath: "/tmp")
        XCTAssertThrowsError(try fixture.backup())
        let data = try LibraryBackupPreferences.data(from: ["appAppearancePalette":"graphite", "stats.password":"secret", "credential":"secret"])
        XCTAssertEqual(try LibraryBackupPreferences.decode(data).keys.sorted(), ["appAppearancePalette"])
        let unsafe = try PropertyListSerialization.data(fromPropertyList: ["password":"x"], format: .binary, options: 0)
        XCTAssertThrowsError(try LibraryBackupPreferences.decode(unsafe))
    }
    func testCancellationRemovesOnlyFreshStaging() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }; _ = try fixture.db()
        let archive = try fixture.backup()
        let initial = Set(try FileManager.default.contentsOfDirectory(atPath: fixture.roots.state.path))
        let task = Task.detached {
            try LibraryBackupCore.prepareRestore(archiveURL: archive, roots: fixture.roots, progress: { completed, _ in
                if completed > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.roots.state.path)), initial)
        XCTAssertEqual(try fixture.value("SELECT title FROM work"), "original")
    }

    func testLargeOperationProgressIsThrottledBeforeDispatchAndResetsPerOperation() {
        let throttle = LibraryBackupProgressThrottle()
        var count = 0, last = 0.0
        for value in 0...1_000_000 {
            if let fraction = throttle.fractionIfDue(completed: Int64(value), total: 1_000_000) { count += 1; last = fraction }
        }
        XCTAssertLessThanOrEqual(count, 101); XCTAssertEqual(last, 1)
        XCTAssertNil(throttle.fractionIfDue(completed: 10, total: 100))
        XCTAssertEqual(LibraryBackupProgressThrottle().fractionIfDue(completed: 10, total: 100), 0.1)
    }

    func testInterruptedCleanupUsesOnlyCapturedUUIDDirectoriesAndRetainsBackupsAndNewWork() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try LibraryBackupCore.ensureDirectory(fixture.roots.state)
        let oldExport = fixture.roots.state.appendingPathComponent("export-" + UUID().uuidString)
        let replaced = fixture.roots.state.appendingPathComponent("prepared-" + UUID().uuidString)
        let retained = ["Exports", "rollback-" + UUID().uuidString, "export-not-a-uuid", "prepared-" + UUID().uuidString + "-extra"]
            .map { fixture.roots.state.appendingPathComponent($0) }
        for directory in [oldExport, replaced] + retained {
            try LibraryBackupCore.ensureDirectory(directory.appendingPathComponent("nested"))
            try Data("synthetic payload".utf8).write(to: directory.appendingPathComponent("nested/payload"))
        }
        let symlink = fixture.roots.state.appendingPathComponent("export-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: retained[0])
        let captured = try LibraryBackupCore.captureInterruptedWork(roots: fixture.roots)
        XCTAssertEqual(Set(captured.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path }),
                       Set([oldExport, replaced].map { $0.resolvingSymlinksInPath().standardizedFileURL.path }))
        let moved = fixture.roots.state.appendingPathComponent("RetainedOriginal")
        try FileManager.default.moveItem(at: replaced, to: moved)
        try LibraryBackupCore.ensureDirectory(replaced) // Same path, a new directory identity.
        let newWork = fixture.roots.state.appendingPathComponent("export-" + UUID().uuidString)
        try LibraryBackupCore.ensureDirectory(newWork)
        XCTAssertEqual(LibraryBackupCore.removeCapturedInterruptedWork(captured, roots: fixture.roots), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldExport.path))
        for directory in retained + [replaced, moved, newWork, symlink] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), directory.lastPathComponent)
        }
    }

    func testInterruptedCleanupSkipsEverythingWithPendingOrJournalEvenAfterCapture() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let old = fixture.roots.state.appendingPathComponent("prepared-" + UUID().uuidString)
        try LibraryBackupCore.ensureDirectory(old)
        let captured = try LibraryBackupCore.captureInterruptedWork(roots: fixture.roots)
        XCTAssertEqual(captured.count, 1)
        for name in ["pending.json", "journal.json"] {
            let marker = fixture.roots.state.appendingPathComponent(name)
            try Data("even malformed markers must retain data".utf8).write(to: marker)
            XCTAssertTrue(try LibraryBackupCore.captureInterruptedWork(roots: fixture.roots).isEmpty)
            XCTAssertEqual(LibraryBackupCore.removeCapturedInterruptedWork(captured, roots: fixture.roots), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
            try FileManager.default.removeItem(at: marker)
        }
        let danglingMarker = fixture.roots.state.appendingPathComponent("pending.json")
        try FileManager.default.createSymbolicLink(atPath: danglingMarker.path, withDestinationPath: fixture.base.appendingPathComponent("absent-marker-target").path)
        XCTAssertTrue(try LibraryBackupCore.captureInterruptedWork(roots: fixture.roots).isEmpty)
        XCTAssertEqual(LibraryBackupCore.removeCapturedInterruptedWork(captured, roots: fixture.roots), 0)
        try FileManager.default.removeItem(at: danglingMarker)
        XCTAssertEqual(LibraryBackupCore.removeCapturedInterruptedWork(captured, roots: fixture.roots), 1)
    }

    private func rewriteArchive(_ original: URL, attack: String, at root: URL) throws -> URL {
        let input = try Archive(url: original, accessMode: .read)
        var files: [(String,Data,Entry.EntryType)] = []
        for entry in input {
            var data = Data(); _ = try input.extract(entry) { data.append($0) }
            files.append((entry.path,data,.file))
        }
        let manifestIndex = files.firstIndex { $0.0 == "manifest.json" }!
        var object = try JSONSerialization.jsonObject(with: files[manifestIndex].1) as! [String:Any]
        if attack == "badHash" || attack == "oversize" {
            var items = object["files"] as! [[String:Any]]
            items[0][attack == "badHash" ? "sha256" : "bytes"] = attack == "badHash" ? String(repeating:"0",count:64) as Any : Int64.max as Any
            object["files"] = items
        }
        if attack == "futureSchema" { object["databaseSchema"] = 999 }
        if attack == "missingReferencedFile" {
            let path = "Documents/ImportedArchives/test/local.wav"
            object["files"] = (object["files"] as! [[String:Any]]).filter { $0["path"] as? String != path }
            // Keep all remaining hashes, sizes and CRCs self-consistent to reach reference validation.
            files.removeAll { $0.0 == path }
        }
        let currentManifestIndex = files.firstIndex { $0.0 == "manifest.json" }!
        files[currentManifestIndex].1 = try JSONSerialization.data(withJSONObject: object)
        if attack == "traversal" { files.append(("../escape",Data("x".utf8),.file)) }
        if attack == "symlink" { files.append(("Documents/link",Data("/tmp".utf8),.symlink)) }
        if attack == "duplicateCase" { files.append(("MANIFEST.JSON",files[manifestIndex].1,.file)) }
        if attack == "extraFile" { files.append(("Documents/extra",Data("x".utf8),.file)) }
        if attack == "corruptDatabase" { let index = files.firstIndex { $0.0 == "Documents/hibiki.db" }!; files[index].1 = Data("not sqlite".utf8) }
        let output = root.appendingPathComponent(attack+".zip"), archive = try Archive(url: output, accessMode: .create)
        for (path,data,type) in files {
            try archive.addEntry(with: path, type: type, uncompressedSize: Int64(data.count)) { offset,count in
                data.subdata(in: Int(offset)..<min(data.count,Int(offset)+count))
            }
        }
        return output
    }
}
