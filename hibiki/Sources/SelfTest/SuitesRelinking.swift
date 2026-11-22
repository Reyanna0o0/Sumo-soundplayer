import Foundation
import HibikiCore

/// Relinking must preserve database identities, not reconstruct equivalent-looking records.
final class RelinkingFixture {
    let db: SQLiteDatabase
    let library: LibraryRepository
    let sourceID: Int64
    let workID: Int64
    private(set) var tracks: [TrackRecord] = []
    private(set) var attachments: [WorkAttachmentRecord] = []
    let originalRoot = "/relink-fixture-old"
    let originalFolder = "WorkA"

    init(version: Int = Schema.currentVersion) throws {
        db = try SQLiteDatabase.inMemory()
        library = LibraryRepository(database: db)
        try db.migrate(Schema.migrations.filter { $0.version <= version })
        sourceID = try library.saveSource(LibrarySource(name: "原授权目录", rootPath: originalRoot,
            bookmark: Data("original-bookmark".utf8), grouping: .childrenAsWorks))
        let root = originalRoot + "/" + originalFolder
        workID = try library.upsertWork(WorkRecord(title: "扫描原名", rjCode: "RJ123456", circleName: "扫描社团",
            coverPath: "cover.png", folderPath: root, folderRelativePath: originalFolder,
            sourceID: sourceID, scriptPath: "A.pdf"))
        try library.replaceTracks(workID: workID, tracks: ["A.wav", "B.wav"].enumerated().map { index, name in
            TrackRecord(workID: workID, fileName: name, filePath: root + "/" + name,
                relativePath: name, fileType: "wav", title: "手工标题\(index)", durationMS: 120_000 + index,
                fileSize: 2_000_000 + Int64(index), fileMtime: Date(timeIntervalSince1970: 1_700_000_000),
                category: index == 0 ? .main : .bonus)
        })
        try library.replaceScannedAttachments(workID: workID, files: [
            WorkAttachment(relativePath: "A.pdf", kind: .pdf, byteCount: 111),
            WorkAttachment(relativePath: "B.pdf", kind: .pdf, byteCount: 222),
            WorkAttachment(relativePath: "Notes.txt", kind: .text, byteCount: 333),
            WorkAttachment(relativePath: "cover.png", kind: .image, byteCount: 444)
        ])
        tracks = try library.tracks(workID: workID).sorted { $0.id < $1.id }
        attachments = try library.attachmentRecords(workID: workID).sorted { $0.id < $1.id }
        try library.appendOwnedMedia(workID: workID, tracks: [
            TrackRecord(workID: workID, fileName: "独立.wav", filePath: "/owned/audio.wav", fileType: "wav",
                title: "独立标题", durationMS: 12_345, assetRelativePath: "Audio/owned.wav")
        ], attachments: [WorkAttachmentRecord(workID: workID,
            attachment: WorkAttachment(relativePath: "独立.pdf", kind: .pdf, byteCount: 555),
            assetRelativePath: "Attachments/owned.pdf")])
        try library.updateWorkMetadata(workID: workID, title: "用户作品名", rjCode: "RJ654321",
            circleName: "用户社团", seiyuuNames: ["甲", "乙"], cover: .replace(assetRelativePath: "Covers/owned.jpg"))
        try library.setFavorite(true, workID: workID)
        try library.setListened(true, workID: workID)
        try library.setRating(5, workID: workID)
        try library.savePlaybackPosition(workID: workID, trackID: tracks[0].id, positionMS: 12_345)
        let category = try library.addCustomCategory(workID: workID, title: "人工分组")
        try library.setCategoryOverride(workID: workID, trackIDs: [tracks[0].id], key: category.key)
        try library.renameCategory(workID: workID, key: "main", title: "改过的正篇")
        try library.setTrackOrder(workID: workID, orderedTrackIDs: library.tracks(workID: workID).reversed().map(\.id))
        try db.execute("UPDATE work_attachment SET category_key = ?, sort_order = 42 WHERE id = ?",
                       [.text(category.key), .integer(attachments[0].id)])
        try db.execute("UPDATE work SET category_order = ? WHERE id = ?",
                       [.text("[\"attachments\",\"main\",\"bonus\"]"), .integer(workID)])
        try library.setSetting("relink-user-setting", "must-survive")

        let subtitles = SubtitleRepository(database: db), reading = ReadingPositionRepository(database: db)
        for (index, track) in tracks.enumerated() {
            let cues = [SubtitleCue(index: 0, startMS: 0, endMS: 1000, text: "原稿\(index)"),
                        SubtitleCue(index: 1, startMS: 2000, endMS: 3000, text: "读到这里\(index)")]
            let original = try subtitles.createTrack(trackID: track.id, kind: .script, language: "ja",
                label: "原台本\(index)", cues: cues, prefersTimedSidecar: true)
            try subtitles.insertVersion(subtitleTrackID: original.track, note: "人工修改", isBaseline: false,
                cues: [SubtitleCue(startMS: 100, endMS: 900, text: "改过的台词\(index)",
                    translatedText: "改过的译文\(index)", speaker: "手工角色", status: .provisional)])
            _ = try subtitles.createTrack(trackID: track.id, kind: .manual, language: "zh",
                label: "另一个来源", cues: cues, activate: false)
            try reading.saveScriptPosition(ScriptReadingPosition(cues: cues, index: 1, fraction: 0.35)!,
                                           subtitleTrackID: original.track)
        }
        for (index, record) in attachments.enumerated() where record.attachment.kind == .pdf {
            try reading.savePDFPosition(PDFReadingPosition(pageIndex: index + 3, x: 0.2, y: 0.7), attachmentID: record.id)
        }
        try reading.saveTextPosition(TextReadingPosition(utf16Offset: 135), attachmentID: attachments[2].id)
        let ownedPDF = try library.attachmentRecords(workID: workID).first { $0.assetRelativePath != nil }!
        try reading.savePDFPosition(PDFReadingPosition(pageIndex: 8, x: 0.4, y: 0.9), attachmentID: ownedPDF.id)
        let playlist = PlaylistRepository(database: db)
        try playlist.addWholeTrack(trackID: tracks[0].id, title: "列表自定名", workTitle: "保留作品名")
        try playlist.addClip(trackID: tracks[1].id, title: "摘选", workTitle: "保留作品名",
                             startMS: 100, endMS: 900, filename: "saved-clip.caf")
        try db.execute("INSERT INTO favorite_group(id, name, sort_order) VALUES (2, '另一收藏组', 7)")
        try db.execute("INSERT INTO favorite_membership(work_id, group_id) VALUES (?, 2)", [.integer(workID)])
        try db.execute("INSERT INTO excluded_work_file(work_id, kind, relative_path) VALUES (?, 'track', 'Removed.wav')", [.integer(workID)])
        try db.execute("INSERT INTO excluded_work_file(work_id, kind, relative_path) VALUES (?, 'attachment', 'Removed.pdf')", [.integer(workID)])
        try db.execute("INSERT INTO play_statistic(date_key, hour_slot, work_id, seconds, title) VALUES ('2026-11-11', 8, ?, 75, '历史名')", [.integer(workID)])
        try db.execute("""
            INSERT INTO play_history(session_id, started_at, start_date_key, start_time_zone_id,
                work_id, track_id, work_title, track_title, is_saved_clip, seconds)
            VALUES ('relink-session', 1700000000, '2026-11-11', 'Pacific/Auckland', ?, ?, '历史作品', '历史曲目', 0, 75)
            """, [.integer(workID), .integer(tracks[0].id)])
    }

    func source() throws -> LibrarySource { try library.sources(includeDisabled: true).first { $0.id == sourceID }! }
    func trackMappings(_ paths: [String] = ["A.wav", "B.wav"]) -> [TrackRelinkMapping] {
        zip(tracks, paths).map { TrackRelinkMapping(trackID: $0.0.id, relativePath: $0.1) }
    }
    func attachmentMappings(_ paths: [String] = ["A.pdf", "B.pdf", "Notes.txt", "cover.png"]) -> [AttachmentRelinkMapping] {
        zip(attachments, paths).map { AttachmentRelinkMapping(attachmentID: $0.0.id, relativePath: $0.1) }
    }
    func snapshot() throws -> [String: [SQLRow]] {
        var result = [String: [SQLRow]]()
        // Include sqlite_sequence: rejected relinks must not consume IDs either.
        for row in try db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") {
            let name = row.string("name")!
            result[name] = try db.query("SELECT * FROM \"\(name)\" ORDER BY rowid")
        }
        return result
    }
    func scan(folder: String = "WorkA", trackNames: [String] = ["A.wav", "B.wav"]) -> [ScannedWork] {
        let files = trackNames.map { ScannedFile(relativePath: folder + "/" + $0,
            absolutePath: originalRoot + "/" + folder + "/" + $0,
            size: 2_000_000, modified: Date(timeIntervalSince1970: 1_700_000_000)) }
        return LibraryScanner.plan(files: files, sourceRoot: originalRoot,
            options: ScanOptions(separateAudioFormats: true, grouping: .childrenAsWorks))
    }
    func addNeighbour() throws -> Int64 {
        let id = try library.upsertWork(WorkRecord(title: "同源另一作品", folderPath: originalRoot + "/Other",
            folderRelativePath: "Other", sourceID: sourceID))
        try library.replaceTracks(workID: id, tracks: [TrackRecord(workID: id, fileName: "Other.wav",
            filePath: originalRoot + "/Other/Other.wav", relativePath: "Other.wav", fileType: "wav")])
        return id
    }
}

func runRelinkingSuites(_ h: Harness) {
    func test(_ name: String, _ body: () throws -> Void) {
        h.test(name) { do { try body() } catch { h.expect(false, "测试抛出错误：\(error)") } }
    }
    func rejectsWithoutChanges(_ f: RelinkingFixture, _ label: String, _ operation: () throws -> Void) throws {
        let before = try f.snapshot()
        do { try operation(); h.expect(false, "\(label) 应拒绝") }
        catch { h.expect(true, "\(label) 已拒绝") }
        h.expectEqual(try f.snapshot(), before, "\(label)：所有表逐字段不变")
        h.expect(try f.db.query("PRAGMA foreign_key_check").isEmpty, "\(label)：外键一致")
    }
    func expectPreserved(_ f: RelinkingFixture, before: [String: [SQLRow]]) throws {
        let after = try f.snapshot()
        let allowed: [String: Set<String>] = [
            "work": ["source_id", "folder_path", "folder_rel", "cover_path", "script_path"],
            "track": ["file_path", "relative_path", "file_rel"],
            "work_attachment": ["relative_path"]
        ]
        let preservationLabels = [
            "work": "作品整行除5个位置字段全不变：已编辑资料、category_title_overrides、custom_categories、category_order",
            "track": "音轨ID、标题、category_override、sort_order及所有非路径字段不变",
            "subtitle_track": "字幕/台本来源ID、活跃来源、语言、标签和偏好完整保留",
            "subtitle_version": "全部字幕/台本修改版本、基线、备注和版本编号完整保留",
            "subtitle_cue": "所有版本已编辑原文、译文、时间和状态逐字段保留",
            "work_category": "独立作品分类表所有记录与字段完整保留"
        ]
        for (table, rows) in before where !["source", "excluded_source_work", "sqlite_sequence"].contains(table) {
            func retained(_ values: [SQLRow]) -> [SQLRow] {
                values.map { row in SQLRow(row.values.filter { !(allowed[table] ?? []).contains($0.key) }) }
            }
            h.expectEqual(retained(after[table] ?? []), retained(rows),
                preservationLabels[table] ?? "\(table) 身份及非路径字段保留")
        }
        for table in ["track", "work_attachment"] {
            let ownedBefore = (before[table] ?? []).filter { !$0["asset_relative_path"].isNull }
            let ownedAfter = (after[table] ?? []).filter { !$0["asset_relative_path"].isNull }
            h.expectEqual(ownedAfter, ownedBefore, "\(table) owned 副本所有字段保持原样")
        }
        h.expectEqual(f.db.userVersion, Schema.currentVersion, "重关联不增加迁移版本")
        h.expect(try f.db.query("PRAGMA foreign_key_check").isEmpty, "重关联后外键一致")
    }

    h.suite("失联重扫与手动重关联") {
        func singleFileFixture() throws -> RelinkingFixture {
            let f = try RelinkingFixture()
            try f.db.execute("DELETE FROM track WHERE id = ?", [.integer(f.tracks[1].id)])
            try f.db.execute("UPDATE source SET grouping = 'filesAsWorks' WHERE id = ?", [.integer(f.sourceID)])
            try f.db.execute("UPDATE work SET folder_rel = 'WorkA/A.wav', folder_path = ? WHERE id = ?",
                             [.text(f.originalRoot + "/WorkA/A.wav"), .integer(f.workID)])
            return f
        }
        test("每文件作品同目录手动改名保留共享源和已编辑资料，旧命名台本可继续重扫") {
            let f = try singleFileFixture()
            let neighbour = try f.library.upsertWork(WorkRecord(title: "邻居", folderPath: f.originalRoot + "/WorkA/Other.wav",
                folderRelativePath: "WorkA/Other.wav", sourceID: f.sourceID))
            try f.library.replaceTracks(workID: neighbour, tracks: [TrackRecord(workID: neighbour, fileName: "Other.wav",
                filePath: f.originalRoot + "/WorkA/Other.wav", relativePath: "Other.wav", fileType: "wav")])
            let before = try f.snapshot(), originalSource = try f.source()
            let newKey = "WorkA/Renamed.wav"
            let sourceID = try f.library.relinkWork(existingID: f.workID, source: originalSource,
                folderPath: f.originalRoot + "/" + newKey, folderRelativePath: newKey,
                tracks: [TrackRelinkMapping(trackID: f.tracks[0].id, relativePath: "Renamed.wav")], attachments: f.attachmentMappings())
            h.expectEqual(sourceID, f.sourceID, "复用原共享sourceID")
            h.expectEqual(try f.source(), originalSource, "共享源所有字段不变")
            h.expectEqual(try f.library.sources(includeDisabled: true).count, 1, "没有另建同根源")
            try expectPreserved(f, before: before)
            h.expectEqual(try f.library.tracks(workID: f.workID).first { $0.id == f.tracks[0].id }?.filePath,
                          f.originalRoot + "/WorkA/Renamed.wav", "按真实父目录而非媒体identity拼路径")
            h.expect(try f.library.excludedWorkPaths(sourceID: f.sourceID).contains("WorkA/A.wav"), "旧媒体identity不会重新出现")
            let media = ["Renamed.wav", "Other.wav"].map { ScannedFile(relativePath: "WorkA/" + $0,
                absolutePath: f.originalRoot + "/WorkA/" + $0, size: 2_000_000, modified: Date()) }
            let documentFiles = f.attachments.map { record in ScannedFile(relativePath: "WorkA/" + record.attachment.relativePath,
                absolutePath: f.originalRoot + "/WorkA/" + record.attachment.relativePath, size: record.attachment.byteCount, modified: Date()) }
            let files = media + documentFiles
            let companions = LibraryScanner.files(forIndividualMedia: media[0], in: files,
                retainingCompanions: f.attachments.map { $0.attachment.relativePath })
            h.expect(companions.contains { $0.fileName == "A.pdf" }, "用户原台本不必随音频改名")
            h.expect(!companions.contains { $0.fileName == "Other.wav" }, "保留附件不会吞入邻居媒体")
            let attachments = companions.compactMap { file in WorkAttachmentFinder.kind(forExtension: file.fileExtension).map {
                WorkAttachment(relativePath: file.fileName, kind: $0, byteCount: file.size)
            } }
            let after = try f.snapshot()
            try f.library.validateSourceRescan(sourceID: f.sourceID,
                works: LibraryScanner.plan(files: files, sourceRoot: f.originalRoot, options: ScanOptions(grouping: .filesAsWorks)),
                attachments: [newKey: attachments, "WorkA/Other.wav": []])
            h.expectEqual(try f.snapshot(), after, "重新配对后整源预检通过且只读")
        }
        test("每文件共享源目标归别作或试图改根书签父目录均拒绝且原表不变") {
            let f = try singleFileFixture()
            let neighbour = try f.library.upsertWork(WorkRecord(title: "占用目标", folderPath: f.originalRoot + "/WorkA/Taken.wav",
                folderRelativePath: "WorkA/Taken.wav", sourceID: f.sourceID))
            try f.library.replaceTracks(workID: neighbour, tracks: [TrackRecord(workID: neighbour, fileName: "Taken.wav",
                filePath: f.originalRoot + "/WorkA/Taken.wav", relativePath: "Taken.wav", fileType: "wav")])
            let source = try f.source()
            try rejectsWithoutChanges(f, "同目录目标归另一作品") {
                _ = try f.library.relinkWork(existingID: f.workID, source: source,
                    folderPath: f.originalRoot + "/WorkA/Taken.wav", folderRelativePath: "WorkA/Taken.wav",
                    tracks: [TrackRelinkMapping(trackID: f.tracks[0].id, relativePath: "Taken.wav")], attachments: f.attachmentMappings())
            }
            var moved = source; moved.rootPath = "/changed-root"
            try rejectsWithoutChanges(f, "每文件模式不放宽共享根改动") {
                _ = try f.library.relinkWork(existingID: f.workID, source: moved,
                    folderPath: "/changed-root/WorkA/A.wav", folderRelativePath: "WorkA/A.wav",
                    tracks: [TrackRelinkMapping(trackID: f.tracks[0].id, relativePath: "A.wav")], attachments: f.attachmentMappings())
            }
            var rebookmarked = source; rebookmarked.bookmark = Data("different-permission".utf8)
            try rejectsWithoutChanges(f, "每文件模式不改共享书签") {
                _ = try f.library.relinkWork(existingID: f.workID, source: rebookmarked,
                    folderPath: f.originalRoot + "/WorkA/A.wav", folderRelativePath: "WorkA/A.wav",
                    tracks: [TrackRelinkMapping(trackID: f.tracks[0].id, relativePath: "A.wav")], attachments: f.attachmentMappings())
            }
            try rejectsWithoutChanges(f, "每文件模式不任意跨父目录") {
                _ = try f.library.relinkWork(existingID: f.workID, source: source,
                    folderPath: f.originalRoot + "/Else/A.wav", folderRelativePath: "Else/A.wav",
                    tracks: [TrackRelinkMapping(trackID: f.tracks[0].id, relativePath: "A.wav")], attachments: f.attachmentMappings())
            }
        }
        test("每文件视频同目录配对保留附件编号与资料，禁止identity与所选视频不一致") {
            let f = try singleFileFixture()
            try f.db.execute("DELETE FROM track WHERE id = ?", [.integer(f.tracks[0].id)])
            try f.db.execute("UPDATE work SET folder_rel = 'WorkA/Original.mp4', folder_path = ? WHERE id = ?",
                [.text(f.originalRoot + "/WorkA/Original.mp4"), .integer(f.workID)])
            try f.library.replaceScannedAttachments(workID: f.workID,
                files: f.attachments.map(\.attachment) + [WorkAttachment(relativePath: "Original.mp4", kind: .video, byteCount: 999)])
            let video = try f.library.attachmentRecords(workID: f.workID).first { $0.attachment.kind == .video }!
            let before = try f.snapshot(), source = try f.source()
            let mappings = f.attachmentMappings() + [AttachmentRelinkMapping(attachmentID: video.id, relativePath: "Renamed.mp4")]
            try rejectsWithoutChanges(f, "错误媒体identity") {
                _ = try f.library.relinkWork(existingID: f.workID, source: source,
                    folderPath: f.originalRoot + "/WorkA/Different.mp4", folderRelativePath: "WorkA/Different.mp4", tracks: [], attachments: mappings)
            }
            _ = try f.library.relinkWork(existingID: f.workID, source: source,
                folderPath: f.originalRoot + "/WorkA/Renamed.mp4", folderRelativePath: "WorkA/Renamed.mp4", tracks: [], attachments: mappings)
            h.expectEqual(try f.library.attachmentRecords(workID: f.workID).first { $0.id == video.id }?.attachment.relativePath,
                          "Renamed.mp4", "视频附件ID不变，只换路径")
            try expectPreserved(f, before: before)
        }
        test("旧目录库选择每文件一作会整源拒绝，不拆已有作品") {
            let f = try RelinkingFixture()
            let files = ["A.wav", "B.wav"].map { ScannedFile(relativePath: "WorkA/" + $0,
                absolutePath: f.originalRoot + "/WorkA/" + $0, size: 2_000_000, modified: Date()) }
            let perFile = LibraryScanner.plan(files: files, sourceRoot: f.originalRoot, options: ScanOptions(grouping: .filesAsWorks))
            try rejectsWithoutChanges(f, "更换为每文件一作") {
                try f.library.validateSourceRescan(sourceID: f.sourceID, works: perFile, attachments: [:])
            }
        }
        test("每文件身份预览取消与重扫预检只读，改名必须显式重新关联") {
            let f = try RelinkingFixture()
            // Keep one source audio plus existing independently-owned media;
            // metadata, edited subtitles, attachment positions and categories stay populated.
            try f.db.execute("DELETE FROM track WHERE id = ?", [.integer(f.tracks[1].id)])
            try f.db.execute("UPDATE source SET grouping = 'filesAsWorks' WHERE id = ?", [.integer(f.sourceID)])
            try f.db.execute("UPDATE work SET folder_rel = 'WorkA/A.wav', folder_path = ? WHERE id = ?", [.text(f.originalRoot + "/WorkA/A.wav"), .integer(f.workID)])
            h.expectEqual(try f.source().grouping, .filesAsWorks, "分组持久化不需要数据库迁移")
            let before = try f.snapshot()
            let files = [ScannedFile(relativePath: "WorkA/A.wav", absolutePath: f.originalRoot + "/WorkA/A.wav", size: 2_000_000, modified: Date())]
            let scans = LibraryScanner.plan(files: files, sourceRoot: f.originalRoot, options: ScanOptions(grouping: .filesAsWorks))
            h.expectEqual(try f.snapshot(), before, "预览后取消：所有表不变")
            try f.library.validateSourceRescan(sourceID: f.sourceID, works: scans, attachments: ["WorkA/A.wav": f.attachments.map(\.attachment)])
            h.expectEqual(try f.snapshot(), before, "同路径重扫预检只读且兼容独立媒体")
            let renamed = [ScannedFile(relativePath: "WorkA/New.wav", absolutePath: f.originalRoot + "/WorkA/New.wav", size: 2_000_000, modified: Date())]
            try rejectsWithoutChanges(f, "每文件作品改名") {
                try f.library.validateSourceRescan(sourceID: f.sourceID,
                    works: LibraryScanner.plan(files: renamed, sourceRoot: f.originalRoot, options: ScanOptions(grouping: .filesAsWorks)), attachments: [:])
            }
            try rejectsWithoutChanges(f, "每文件作品重新聚合") {
                try f.library.validateSourceRescan(sourceID: f.sourceID,
                    works: LibraryScanner.plan(files: files, sourceRoot: f.originalRoot, options: ScanOptions(grouping: .singleWork)), attachments: [:])
            }
            let oldTrack = try f.library.tracks(workID: f.workID).first { $0.id == f.tracks[0].id }!
            _ = try f.library.relinkWork(existingID: f.workID,
                source: LibrarySource(name: "明确重新配对", rootPath: "/new-work", grouping: .singleWork),
                folderPath: "/new-work", folderRelativePath: ".",
                tracks: [TrackRelinkMapping(trackID: oldTrack.id, relativePath: "Renamed.wav")], attachments: f.attachmentMappings())
            try expectPreserved(f, before: before)
            h.expectEqual(try f.library.tracks(workID: f.workID).first { $0.id == oldTrack.id }?.filePath, "/new-work/Renamed.wav", "音轨原ID只换路径")
            h.expect(try f.library.excludedWorkPaths(sourceID: f.sourceID).contains("WorkA/A.wav"), "原每文件身份不会在旧源重扫复活")
        }
        test("未改名扫描与新增文件可以预检，owned和已排除文件不要求出现") {
            let f = try RelinkingFixture(), before = try f.snapshot()
            try f.library.validateSourceRescan(sourceID: f.sourceID,
                works: f.scan(trackNames: ["A.wav", "B.wav", "New.wav"]),
                attachments: ["WorkA": f.attachments.map(\.attachment)])
            h.expectEqual(try f.snapshot(), before, "成功预检也是只读")
        }
        test("音频改名、附件改名、作品目录改名和空扫描均拒绝整源写入") {
            let f = try RelinkingFixture()
            let files = f.attachments.map(\.attachment)
            try rejectsWithoutChanges(f, "音频改名") {
                try f.library.validateSourceRescan(sourceID: f.sourceID, works: f.scan(trackNames: ["Renamed.wav", "B.wav"]), attachments: ["WorkA": files])
            }
            try rejectsWithoutChanges(f, "PDF改名") {
                var renamed = files
                renamed[0] = WorkAttachment(relativePath: "Renamed.pdf", kind: .pdf, byteCount: 111)
                try f.library.validateSourceRescan(sourceID: f.sourceID, works: f.scan(), attachments: ["WorkA": renamed])
            }
            try rejectsWithoutChanges(f, "作品目录改名") {
                try f.library.validateSourceRescan(sourceID: f.sourceID, works: f.scan(folder: "RenamedWork"), attachments: ["RenamedWork": files])
            }
            try rejectsWithoutChanges(f, "整个源失联") {
                try f.library.validateSourceRescan(sourceID: f.sourceID, works: [], attachments: [:])
            }
            try rejectsWithoutChanges(f, "原路径被其他音频类型占用") {
                var changed = f.scan()
                changed[0].tracks[0].fileType = "mp3"
                try f.library.validateSourceRescan(sourceID: f.sourceID, works: changed, attachments: ["WorkA": files])
            }
        }
        test("同源一部作品失联时，另一部正常作品与新增发现也不部分保存") {
            let f = try RelinkingFixture()
            _ = try f.addNeighbour()
            try rejectsWithoutChanges(f, "混合正常、失联、新发现") {
                let discovered = f.scan(trackNames: ["A.wav", "B.wav", "New.wav"]) + f.scan(folder: "NewWork", trackNames: ["New.wav"])
                try f.library.validateSourceRescan(sourceID: f.sourceID, works: discovered,
                    attachments: ["WorkA": f.attachments.map(\.attachment)])
            }
        }
        test("作品页附件刷新不能因PDF改名清除身份和阅读位置") {
            let f = try RelinkingFixture(), before = try f.snapshot()
            try f.library.validateAttachmentRescan(workID: f.workID, files: f.attachments.map(\.attachment))
            h.expectEqual(try f.snapshot(), before, "附件预检不写入")
            try rejectsWithoutChanges(f, "作品页缺失PDF") {
                try f.library.validateAttachmentRescan(workID: f.workID, files: f.attachments.dropFirst().map(\.attachment))
            }
            try rejectsWithoutChanges(f, "作品页重复PDF路径") {
                try f.library.validateAttachmentRescan(workID: f.workID,
                    files: f.attachments.map(\.attachment) + [f.attachments[0].attachment])
            }
        }
        test("独占存储源整目录重关联保留所有身份、字幕、阅读、收藏、列表和排序") {
            let f = try RelinkingFixture(), before = try f.snapshot()
            h.expectEqual(try f.library.work(id: f.workID)?.scriptPath, "A.pdf", "前置：原台本入口已实际入库")
            h.expectEqual(try f.library.work(id: f.workID)?.coverPath, "cover.png", "前置：原封面入口已实际入库")
            let schema = try f.db.query("SELECT * FROM sqlite_master ORDER BY type, name")
            var source = try f.source()
            source.rootPath = "/relink-fixture-new"
            source.bookmark = Data("renewed-bookmark".utf8)
            let sid = try f.library.relinkWork(existingID: f.workID, source: source,
                folderPath: "/relink-fixture-new/RenamedWork", folderRelativePath: "RenamedWork",
                tracks: f.trackMappings(["Audio/甲.wav", "Audio/乙.wav"]),
                attachments: f.attachmentMappings(["Scripts/甲.pdf", "Scripts/乙.pdf", "Notes/文字.txt", "Images/封面.png"]))
            h.expectEqual(sid, f.sourceID, "独占源复用原sourceID")
            h.expectEqual(try f.source(), source, "存储源仅按请求更新根路径和授权书签")
            let work = try f.library.work(id: f.workID)!
            h.expectEqual(work.folderPath, "/relink-fixture-new/RenamedWork", "新的作品绝对路径")
            h.expectEqual(work.folderRelativePath, "RenamedWork", "新的作品相对路径")
            h.expectEqual(work.scriptPath, "Scripts/甲.pdf", "原台本入口跟随映射")
            h.expectEqual(work.coverPath, "Images/封面.png", "原封面入口跟随映射")
            h.expectEqual(try f.library.track(id: f.tracks[0].id)?.filePath,
                "/relink-fixture-new/RenamedWork/Audio/甲.wav", "原trackID打开新路径")
            h.expectEqual(try ReadingPositionRepository(database: f.db).pdfPosition(attachmentID: f.attachments[0].id)?.pageIndex, 3, "PDF改名保留页码")
            try expectPreserved(f, before: before)
            h.expectEqual(try f.db.query("SELECT * FROM sqlite_master ORDER BY type, name"), schema, "表、索引和触发器不变")
        }
        test("两条同类型音频与两份PDF对调路径，不交换身份或读取进度") {
            let f = try RelinkingFixture(), before = try f.snapshot()
            _ = try f.library.relinkWork(existingID: f.workID, source: f.source(),
                folderPath: f.originalRoot + "/WorkA", folderRelativePath: "WorkA",
                tracks: f.trackMappings(["B.wav", "A.wav"]),
                attachments: f.attachmentMappings(["B.pdf", "A.pdf", "Notes.txt", "cover.png"]))
            h.expectEqual(try f.library.track(id: f.tracks[0].id)?.relativePath, "B.wav", "第一条身份迁到B")
            h.expectEqual(try f.library.track(id: f.tracks[1].id)?.relativePath, "A.wav", "第二条身份迁到A")
            let files = try f.library.attachmentRecords(workID: f.workID)
            h.expectEqual(files.first { $0.id == f.attachments[0].id }?.attachment.relativePath, "B.pdf", "第一份PDF迁到B")
            h.expectEqual(files.first { $0.id == f.attachments[1].id }?.attachment.relativePath, "A.pdf", "第二份PDF迁到A")
            try expectPreserved(f, before: before)
        }
        test("旧wav格式目录的附件以源根存路径时，封面与台本入口仍跟随重关联") {
            let f = try RelinkingFixture()
            try f.db.execute("UPDATE source SET grouping = 'automatic' WHERE id = ?", [.integer(f.sourceID)])
            try f.db.execute("UPDATE work SET folder_path = ?, folder_rel = 'wav', cover_path = 'cover.jpg', script_path = 'script.pdf' WHERE id = ?",
                [.text(f.originalRoot + "/wav"), .integer(f.workID)])
            for track in f.tracks {
                try f.db.execute("UPDATE track SET file_path = ? WHERE id = ?",
                    [.text(f.originalRoot + "/wav/" + track.fileName), .integer(track.id)])
            }
            let oldPaths = ["wav/script.pdf", "wav/B.pdf", "wav/Notes.txt", "wav/cover.jpg"]
            for (record, path) in zip(f.attachments, oldPaths) {
                try f.db.execute("UPDATE work_attachment SET relative_path = ? WHERE id = ?", [.text(path), .integer(record.id)])
            }
            let before = try f.snapshot()
            h.expectEqual(try f.library.work(id: f.workID)?.scriptPath, "script.pdf", "旧入口相对作品目录")
            h.expectEqual(try f.library.attachmentRecords(workID: f.workID).first { $0.id == f.attachments[0].id }?.attachment.relativePath,
                "wav/script.pdf", "旧附件相对存储源根")
            var source = try f.source()
            source.rootPath = "/legacy-relinked-work"
            source.grouping = .singleWork
            _ = try f.library.relinkWork(existingID: f.workID, source: source,
                folderPath: "/legacy-relinked-work", folderRelativePath: ".", tracks: f.trackMappings(),
                attachments: f.attachmentMappings(["docs/new.pdf", "docs/B.pdf", "notes/new.txt", "images/new.jpg"]))
            let work = try f.library.work(id: f.workID)!
            h.expectEqual(work.coverPath, "images/new.jpg", "legacy封面入口跟随对应附件")
            h.expectEqual(work.scriptPath, "docs/new.pdf", "legacy台本入口跟随对应附件")
            try expectPreserved(f, before: before)
        }
        test("明确映射到旧排除目标仅恢复该文件，随后重扫不删除刚修复的身份") {
            let f = try RelinkingFixture()
            try f.db.execute("INSERT INTO excluded_work_file(work_id, kind, relative_path) VALUES (?, 'track', 'StillHidden.wav')", [.integer(f.workID)])
            try f.db.execute("INSERT INTO excluded_work_file(work_id, kind, relative_path) VALUES (?, 'attachment', 'StillHidden.pdf')", [.integer(f.workID)])
            let before = try f.snapshot()
            _ = try f.library.relinkWork(existingID: f.workID, source: f.source(),
                folderPath: f.originalRoot + "/WorkA", folderRelativePath: "WorkA",
                tracks: f.trackMappings(["Removed.wav", "B.wav"]),
                attachments: f.attachmentMappings(["Removed.pdf", "B.pdf", "Notes.txt", "cover.png"]))
            let exclusions = try f.db.query("SELECT kind, relative_path FROM excluded_work_file WHERE work_id = ? ORDER BY kind, relative_path", [.integer(f.workID)])
            h.expectEqual(exclusions, [
                SQLRow(["kind": .text("attachment"), "relative_path": .text("StillHidden.pdf")]),
                SQLRow(["kind": .text("track"), "relative_path": .text("StillHidden.wav")])
            ], "仅本次明确恢复的两个目标退出排除清单")
            let tracks = try f.library.tracks(workID: f.workID)
            let attachments = try f.library.attachmentRecords(workID: f.workID)
            let sourceFiles = attachments.filter { $0.assetRelativePath == nil }.map(\.attachment)
            try f.library.validateSourceRescan(sourceID: f.sourceID,
                works: f.scan(trackNames: ["Removed.wav", "B.wav"]), attachments: ["WorkA": sourceFiles])
            try f.library.replaceTracks(workID: f.workID, tracks: tracks.filter { $0.assetRelativePath == nil })
            try f.library.replaceScannedAttachments(workID: f.workID, files: sourceFiles)
            h.expectEqual(try f.library.tracks(workID: f.workID).map(\.id), tracks.map(\.id), "重扫后原音轨ID及人工顺序保留")
            h.expectEqual(try f.library.attachmentRecords(workID: f.workID).map(\.id), attachments.map(\.id), "重扫后PDF和owned附件ID保留")
            let after = try f.snapshot()
            for table in ["subtitle_track", "subtitle_version", "subtitle_cue", "subtitle_reading_position",
                          "attachment_reading_position", "playlist_entry", "favorite_membership"] {
                h.expectEqual(after[table], before[table], "再次重扫仍保留\(table)的原记录")
            }
        }
        test("漏映射、重复编号、重复目标、越界和类型错误均无任何数据库副作用") {
            let f = try RelinkingFixture()
            let invalidTracks: [[TrackRelinkMapping]] = [
                Array(f.trackMappings().dropLast()),
                [TrackRelinkMapping(trackID: f.tracks[0].id, relativePath: "A.wav"), TrackRelinkMapping(trackID: f.tracks[0].id, relativePath: "B.wav")],
                f.trackMappings(["same.wav", "same.wav"]), f.trackMappings(["../A.wav", "B.wav"]),
                f.trackMappings(["/A.wav", "B.wav"]), f.trackMappings(["A//A.wav", "B.wav"]),
                f.trackMappings(["A.mp3", "B.wav"]), f.trackMappings(["", "B.wav"]),
                f.trackMappings(["./A.wav", "B.wav"]), f.trackMappings(["\u{00E9}.wav", "e\u{0301}.wav"]),
                [TrackRelinkMapping(trackID: 999_999, relativePath: "A.wav"), f.trackMappings()[1]]
            ]
            for (index, mappings) in invalidTracks.enumerated() {
                try rejectsWithoutChanges(f, "音轨无效映射\(index)") {
                    _ = try f.library.relinkWork(existingID: f.workID,
                        source: LibrarySource(name: "不能残留的新源", rootPath: "/new"),
                        folderPath: "/new", folderRelativePath: ".", tracks: mappings, attachments: f.attachmentMappings())
                }
            }
            let invalidFiles: [[AttachmentRelinkMapping]] = [
                Array(f.attachmentMappings().dropLast()),
                f.attachmentMappings(["same.pdf", "same.pdf", "Notes.txt", "cover.png"]),
                f.attachmentMappings(["A.txt", "B.pdf", "Notes.txt", "cover.png"]),
                f.attachmentMappings(["../A.pdf", "B.pdf", "Notes.txt", "cover.png"]),
                [f.attachmentMappings()[0], f.attachmentMappings()[0], f.attachmentMappings()[2], f.attachmentMappings()[3]]
            ]
            for (index, mappings) in invalidFiles.enumerated() {
                try rejectsWithoutChanges(f, "附件无效映射\(index)") {
                    _ = try f.library.relinkWork(existingID: f.workID, source: f.source(),
                        folderPath: f.originalRoot + "/WorkA", folderRelativePath: "WorkA",
                        tracks: f.trackMappings(), attachments: mappings)
                }
            }
        }
        test("不能映射owned副本或其他作品编号，目录根必须与源相符") {
            let f = try RelinkingFixture()
            let ownedTrack = try f.library.tracks(workID: f.workID).first { $0.assetRelativePath != nil }!
            let ownedFile = try f.library.attachmentRecords(workID: f.workID).first { $0.assetRelativePath != nil }!
            try rejectsWithoutChanges(f, "owned音轨不参与重关联") {
                _ = try f.library.relinkWork(existingID: f.workID, source: f.source(), folderPath: f.originalRoot + "/WorkA", folderRelativePath: "WorkA",
                    tracks: f.trackMappings() + [TrackRelinkMapping(trackID: ownedTrack.id, relativePath: "owned.wav")], attachments: f.attachmentMappings())
            }
            try rejectsWithoutChanges(f, "owned附件不参与重关联") {
                _ = try f.library.relinkWork(existingID: f.workID, source: f.source(), folderPath: f.originalRoot + "/WorkA", folderRelativePath: "WorkA",
                    tracks: f.trackMappings(), attachments: f.attachmentMappings() + [AttachmentRelinkMapping(attachmentID: ownedFile.id, relativePath: "owned.pdf")])
            }
            for (absolute, relative) in [("/outside", "WorkA"), (f.originalRoot + "/WorkA", "../WorkA")] {
                try rejectsWithoutChanges(f, "不一致或越界作品目录") {
                    _ = try f.library.relinkWork(existingID: f.workID, source: f.source(), folderPath: absolute,
                        folderRelativePath: relative, tracks: f.trackMappings(), attachments: f.attachmentMappings())
                }
            }
            let neighbour = try f.addNeighbour(), otherTrack = try f.library.tracks(workID: neighbour)[0]
            try rejectsWithoutChanges(f, "其他作品音轨编号") {
                _ = try f.library.relinkWork(existingID: f.workID, source: LibrarySource(name: "新源", rootPath: "/new"),
                    folderPath: "/new", folderRelativePath: ".",
                    tracks: [TrackRelinkMapping(trackID: otherTrack.id, relativePath: "A.wav"), f.trackMappings()[1]], attachments: f.attachmentMappings())
            }
            try rejectsWithoutChanges(f, "目标文件已归另一作品") {
                _ = try f.library.relinkWork(existingID: f.workID,
                    source: LibrarySource(name: "另建源不能绕过占用检查", rootPath: f.originalRoot + "/Other"),
                    folderPath: f.originalRoot + "/Other", folderRelativePath: ".",
                    tracks: f.trackMappings(["Other.wav", "B.wav"]), attachments: f.attachmentMappings())
            }
        }
        test("共享源不可改根；另建源仅迁移选中作品并保留其他作品与旧源") {
            let f = try RelinkingFixture(), neighbour = try f.addNeighbour()
            var shared = try f.source()
            shared.rootPath = "/changed-shared-root"
            try rejectsWithoutChanges(f, "共享源改根") {
                _ = try f.library.relinkWork(existingID: f.workID, source: shared,
                    folderPath: "/changed-shared-root/WorkA", folderRelativePath: "WorkA",
                    tracks: f.trackMappings(), attachments: f.attachmentMappings())
            }
            let before = try f.snapshot(), oldSource = try f.source()
            let otherBefore = try f.library.work(id: neighbour), otherTracks = try f.library.tracks(workID: neighbour)
            let sid = try f.library.relinkWork(existingID: f.workID,
                source: LibrarySource(name: "独立新授权", rootPath: "/isolated-work", bookmark: Data("new".utf8), grouping: .singleWork),
                folderPath: "/isolated-work", folderRelativePath: ".", tracks: f.trackMappings(), attachments: f.attachmentMappings())
            h.expect(sid != f.sourceID, "新授权独立sourceID")
            h.expectEqual(try f.source(), oldSource, "旧源的根、书签、设置完整保留")
            h.expectEqual(try f.library.work(id: neighbour), otherBefore, "其他作品原样保留")
            h.expectEqual(try f.library.tracks(workID: neighbour), otherTracks, "其他作品音轨原样保留")
            h.expectEqual(try f.library.work(id: f.workID)?.sourceID, sid, "仅目标作品关联新源")
            h.expectEqual(try f.library.sources(includeDisabled: true).count, 2, "只新增一个源")
            h.expect(try f.library.excludedWorkPaths(sourceID: f.sourceID).contains("WorkA"), "旧目录重扫不复活为重复作品")
            try expectPreserved(f, before: before)
        }
        test("实际SQL写入途中失败会撤销新源、临时路径和所有已完成更新") {
            let f = try RelinkingFixture()
            try f.db.executeScript("""
                CREATE TRIGGER reject_relink_attachment BEFORE UPDATE OF relative_path ON work_attachment
                WHEN NEW.relative_path = 'Rejected.pdf'
                BEGIN SELECT RAISE(ABORT, 'forced relink failure'); END;
                """)
            try rejectsWithoutChanges(f, "事务中途失败") {
                _ = try f.library.relinkWork(existingID: f.workID,
                    source: LibrarySource(name: "必须回滚的新源", rootPath: "/transaction-new"),
                    folderPath: "/transaction-new", folderRelativePath: ".",
                    tracks: f.trackMappings(["RenamedA.wav", "RenamedB.wav"]),
                    attachments: f.attachmentMappings(["RenamedA.pdf", "Rejected.pdf", "Notes.txt", "cover.png"]))
            }
        }
    }

    h.suite("重关联后的播放队列") {
        test("重复音轨全部更新路径，独立摘选、条目UUID、播放顺序和游标保留") {
            let items = [
                PlaybackQueueItem(workID: 10, trackID: 100, workTitle: "作品", trackTitle: "第一次",
                    subtitle: "备注甲", filePath: "/old/A.wav", fileType: "wav", durationMS: 12_345),
                PlaybackQueueItem(workID: 10, trackID: 200, workTitle: "作品", trackTitle: "另一个音轨",
                    filePath: "/old/B.wav", fileType: "wav"),
                PlaybackQueueItem(workID: 10, trackID: 100, workTitle: "作品", trackTitle: "第二次",
                    subtitle: "备注乙", filePath: "/old/A.wav", fileType: "wav", category: .bonus),
                PlaybackQueueItem(workID: 10, trackID: -100, workTitle: "摘选作品", trackTitle: "独立摘选",
                    filePath: "/clips/keep.caf", fileType: "caf", durationMS: 800)
            ]
            for shuffled in [false, true] {
                var queue = PlaybackQueue.make(items: items, startingAt: 1, shuffled: shuffled, seed: 42)
                queue.repeatMode = .one
                _ = queue.jump(toItemIndex: 2)
                let before = queue
                queue.updateFilePaths([100: "/new/A.wav", -100: "/must-not-change.caf", 999: "/not-in-queue.wav"])
                var expected = items
                expected[0].filePath = "/new/A.wav"
                expected[2].filePath = "/new/A.wav"
                h.expectEqual(queue.items, expected, "仅同trackID的两个路径改变；其他字段逐项保留")
                h.expectEqual(queue.items.map(\.id), before.items.map(\.id), "UUID和原始排序不变")
                h.expectEqual(queue.order, before.order, "实际播放顺序不变")
                h.expectEqual(queue.cursor, before.cursor, "当前游标不变")
                h.expectEqual(queue.current?.id, before.current?.id, "当前播放条目不变")
                h.expectEqual(queue.current?.filePath, "/new/A.wav", "当前重复条目也取得新路径")
                h.expectEqual(queue.repeatMode, .one, "循环设置不变")
                h.expectEqual(queue.isShuffled, shuffled, "随机设置不变")
                let updated = queue
                queue.updateFilePaths([:])
                h.expectEqual(queue, updated, "空更新不重建队列")
            }
            var empty = PlaybackQueue()
            let before = empty
            empty.updateFilePaths([100: "/new/A.wav"])
            h.expectEqual(empty, before, "空队列保持为空")
        }
    }
}
