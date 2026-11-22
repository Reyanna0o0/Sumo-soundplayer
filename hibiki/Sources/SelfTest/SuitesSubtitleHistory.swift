import Foundation
import HibikiCore

func runSubtitleHistorySuites(_ h: Harness) {
    func check(_ name: String, _ body: () throws -> Void) {
        h.test(name) {
            do { try body() }
            catch { h.expect(false, "意外错误：\(error)") }
        }
    }
    func seed(_ db: SQLiteDatabase, migrate: Bool = true) throws -> (SubtitleRepository, [Int64]) {
        if migrate { try db.migrate(Schema.migrations) }
        let library = LibraryRepository(database: db)
        let source = try library.saveSource(LibrarySource(name: "字幕历史测试"))
        let work = try library.upsertWork(WorkRecord(title: "保留所有原资料", folderPath: "/history", sourceID: source))
        try library.replaceTracks(workID: work, tracks: ["a.wav", "b.wav"].map {
            TrackRecord(workID: work, fileName: $0, filePath: "/history/" + $0, relativePath: $0, fileType: "wav")
        })
        return (SubtitleRepository(database: db), try library.tracks(workID: work).map(\.id))
    }
    func cues(_ name: String) -> [SubtitleCue] {
        [SubtitleCue(startMS: 105, endMS: 950, text: name + "\n原文", translatedText: "訳文🙂", speaker: "甲", status: .provisional),
         SubtitleCue(startMS: 0, endMS: 0, text: "", translatedText: nil, speaker: nil, status: .untimed)]
    }
    func source(_ repo: SubtitleRepository, _ track: Int64, _ label: String) throws -> (track: Int64, version: Int64) {
        try repo.createTrack(trackID: track, kind: .manual, language: "ja", label: label, cues: cues(label))
    }
    func edit(_ repo: SubtitleRepository, _ source: Int64, _ name: String, empty: Bool = false) throws -> Int64 {
        try repo.insertVersion(subtitleTrackID: source, note: name, isBaseline: false, cues: empty ? [] : cues(name))
    }
    let contentColumns = "cue_index, start_ms, end_ms, source_text, translated_text, speaker, status"
    func content(_ db: SQLiteDatabase, _ version: Int64) throws -> [SQLRow] {
        try db.query("SELECT \(contentColumns) FROM subtitle_cue WHERE version_id = ? ORDER BY cue_index, id", [.integer(version)])
    }
    func allState(_ db: SQLiteDatabase) throws -> [String: [SQLRow]] {
        var result: [String: [SQLRow]] = [:]
        for table in ["source", "work", "track", "subtitle_track", "subtitle_version", "subtitle_cue",
                      "subtitle_reading_position", "playlist_group", "playlist_entry", "playlist_clip_subtitle", "app_setting"] {
            result[table] = try db.query("SELECT * FROM \(table) ORDER BY rowid")
        }
        return result
    }

    h.suite("字幕固定版本与历史清理") {
        check("v24 升级默认不固定，固定/取消固定跨关闭重开，原记录不变") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-history-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("history.sqlite").path
            let old = try SQLiteDatabase(path: path)
            try old.migrate(Schema.migrations.filter { $0.version <= 24 })
            let (repo, ids) = try seed(old, migrate: false)
            let a = try source(repo, ids[0], "原始")
            let v2 = try edit(repo, a.track, "修改")
            let oldColumns = "id, subtitle_track_id, version_no, note, is_baseline, cue_count, created_at"
            let versionsBefore = try old.query("SELECT \(oldColumns) FROM subtitle_version ORDER BY id")
            let cuesBefore = try old.query("SELECT * FROM subtitle_cue ORDER BY id")
            old.close()

            let upgraded = try SQLiteDatabase(path: path)
            h.expectEqual(try upgraded.migrate(Schema.migrations), 1, "只执行新增迁移")
            let current = SubtitleRepository(database: upgraded)
            h.expectEqual(try current.versions(subtitleTrackID: a.track).map(\.isPinned), [false, false], "旧版本默认不固定")
            h.expectEqual(try upgraded.query("SELECT \(oldColumns) FROM subtitle_version ORDER BY id"), versionsBefore, "全部原版本字段保持")
            h.expectEqual(try upgraded.query("SELECT * FROM subtitle_cue ORDER BY id"), cuesBefore, "原文译文时间不变")
            h.expect(try current.setVersionPinned(v2, isPinned: true), "固定成功")
            h.expect(try current.setVersionPinned(a.version, isPinned: true), "原始也可标记固定")
            h.expect(try current.setVersionPinned(a.version, isPinned: false), "取消原始固定")
            h.expect(!(try current.setVersionPinned(Int64.max, isPinned: true)), "失效版本不伪报成功")
            upgraded.close()

            let reopened = try SQLiteDatabase(path: path)
            defer { reopened.close() }
            h.expectEqual(try reopened.migrate(Schema.migrations), 0, "重开不重复升级")
            let reopenedRepo = SubtitleRepository(database: reopened)
            h.expectEqual(try reopenedRepo.pinnedVersions(subtitleTrackID: a.track).map(\.id), [v2], "固定状态持久化")
            h.expectEqual(try reopenedRepo.versions(subtitleTrackID: a.track).map(\.id), [a.version, v2], "固定不会复制版本")
            h.expectEqual(try reopenedRepo.activeCues(trackID: ids[0]).map(\.text), cues("修改").map(\.text), "固定不切换生效内容")
            try reopenedRepo.setVersionPinned(v2, isPinned: false)
            h.expect(try reopenedRepo.pinnedVersions(subtitleTrackID: a.track).isEmpty, "取消固定可查询")
        }

        check("全库清理保留各来源原始最新固定和草稿，估算采用真实行及 UTF8 字节") {
            let db = try SQLiteDatabase.inMemory()
            let (repo, ids) = try seed(db)
            let a = try source(repo, ids[0], "A原始")
            let b = try source(repo, ids[0], "B原始")
            let c = try source(repo, ids[1], "另一音轨原始")
            let oldA = try edit(repo, a.track, "旧A🙂")
            let oldB = try edit(repo, b.track, "草稿基准")
            let oldC = try edit(repo, c.track, "空旧版", empty: true)
            var retained: [Int64] = [a.version, b.version, c.version, oldB]
            for item in [a, b, c] {
                let pinned = try edit(repo, item.track, "固定")
                try repo.setVersionPinned(pinned, isPinned: true)
                retained.append(pinned)
                retained.append(try edit(repo, item.track, "最新"))
                try db.execute("INSERT INTO subtitle_reading_position(subtitle_track_id,payload,updated_at) VALUES (?, '{}', 123)", [.integer(item.track)])
            }
            try db.execute("INSERT INTO app_setting(key,value,updated_at) VALUES ('retained','original',1)")
            let lists = PlaylistRepository(database: db)
            try lists.addClip(trackID: ids[0], title: "独立摘选", workTitle: "作品", startMS: 100, endMS: 500, filename: "retained.caf")
            try db.execute("UPDATE subtitle_version SET cue_count = 999 WHERE id = ?", [.integer(oldA)])
            let before = try allState(db)
            let draftIDs: Set<Int64> = [oldB, -1, Int64.max]
            let summary = try repo.historyCleanupSummary(protectingVersionIDs: draftIDs)
            let bytes = "旧A🙂".utf8.count + "空旧版".utf8.count + cues("旧A🙂").reduce(0) {
                $0 + $1.text.utf8.count + ($1.translatedText?.utf8.count ?? 0) + ($1.speaker?.utf8.count ?? 0)
            }
            h.expectEqual(summary.versionCount, 2, "只删除A旧版及C空旧版")
            h.expectEqual(summary.cueCount, 2, "读实际行数，不相信冗余999")
            h.expectEqual(summary.estimatedContentBytes, Int64(bytes), "包括备注原译说话人实际UTF8字节")
            h.expectEqual(try allState(db), before, "预览不写任何记录")
            h.expectEqual(try repo.cleanupUnpinnedHistory(protectingVersionIDs: draftIDs), summary, "返回本次真实清理量")
            h.expectEqual(try repo.historyCleanupSummary(protectingVersionIDs: draftIDs), SubtitleHistoryCleanupSummary(), "无候选")
            h.expectEqual(try repo.cleanupUnpinnedHistory(protectingVersionIDs: draftIDs), SubtitleHistoryCleanupSummary(), "重复清理幂等")
            let after = try allState(db)
            let retainedIDs = Set(retained)
            h.expectEqual(after["subtitle_version"], before["subtitle_version"]?.filter { retainedIDs.contains($0.int64("id")!) }, "所有保留版本原样")
            h.expectEqual(after["subtitle_cue"], before["subtitle_cue"]?.filter { retainedIDs.contains($0.int64("version_id")!) }, "所有保留句字段原样")
            for table in before.keys where !["subtitle_version", "subtitle_cue"].contains(table) {
                h.expectEqual(after[table], before[table], "\(table) 来源关联阅读位置全部保持")
            }
            h.expect(try repo.cues(versionID: oldA).isEmpty && repo.cues(versionID: oldC).isEmpty, "只级联清理目标句")
            let next = try edit(repo, a.track, "下一次编辑")
            h.expectEqual(try repo.versions(subtitleTrackID: a.track).map(\.versionNo), [1, 3, 4, 5], "不压缩或复用旧编号")
            h.expect(next > retained.max()!, "新记录ID也不复用")
            do {
                _ = try repo.insertVersion(subtitleTrackID: a.track, versionNo: 2, note: "不得复用", isBaseline: false, cues: [])
                h.expect(false, "显式旧编号必须拒绝")
            } catch { h.expect(true, "拒绝复用已清理编号") }
        }

        check("预览后固定仍保留，单版删除也保护原始当前固定与草稿") {
            let db = try SQLiteDatabase.inMemory()
            let (repo, ids) = try seed(db)
            let a = try source(repo, ids[0], "A")
            let v2 = try edit(repo, a.track, "旧版")
            let v3 = try edit(repo, a.track, "当前")
            h.expectEqual(try repo.historyCleanupSummary().versionCount, 1, "初始可清理")
            try repo.setVersionPinned(v2, isPinned: true)
            h.expectEqual(try repo.cleanupUnpinnedHistory().versionCount, 0, "清理重算不会采用旧预览")
            for version in [a.version, v2, v3] { try repo.deleteVersion(version) }
            h.expectEqual(try repo.versions(subtitleTrackID: a.track).count, 3, "保护不可绕过单版删除")
            try repo.setVersionPinned(v2, isPinned: false)
            try repo.deleteVersion(v2, protectingVersionIDs: [v2])
            h.expectEqual(try repo.versions(subtitleTrackID: a.track).count, 3, "草稿也保护")
            try repo.deleteVersion(v2)
            h.expectEqual(try repo.versions(subtitleTrackID: a.track).map(\.id), [a.version, v3], "取消固定后可删除旧版")
        }

        for failure in ["FAIL", "IGNORE"] {
            check("清理中途 \(failure) 会回滚全部版本和句子") {
                let db = try SQLiteDatabase.inMemory()
                let (repo, ids) = try seed(db)
                let a = try source(repo, ids[0], "A")
                _ = try edit(repo, a.track, "旧一")
                let old = try edit(repo, a.track, "旧二")
                _ = try edit(repo, a.track, "当前")
                let before = try allState(db)
                let action = failure == "FAIL" ? "RAISE(FAIL, 'intentional history failure')" : "RAISE(IGNORE)"
                try db.executeScript("""
                    CREATE TEMP TRIGGER interrupt_history BEFORE DELETE ON subtitle_version
                    WHEN OLD.id = \(old) BEGIN SELECT \(action); END;
                    """)
                do {
                    _ = try repo.cleanupUnpinnedHistory()
                    h.expect(false, "失败或跳过不能报告成功")
                } catch { h.expectEqual(try allState(db), before, "之前已删除的条目和级联句全部回滚") }
                try db.executeScript("DROP TRIGGER interrupt_history")
                h.expectEqual(try repo.cleanupUnpinnedHistory().versionCount, 2, "失败后可正常重试")
            }
        }

        check("空来源、只有原始及缺少baseline标记的最早版本安全保留") {
            let db = try SQLiteDatabase.inMemory()
            let (repo, ids) = try seed(db)
            let a = try repo.createTrack(trackID: ids[0], kind: .manual, language: nil, label: "空字幕", cues: [])
            h.expectEqual(try repo.cleanupUnpinnedHistory(), SubtitleHistoryCleanupSummary(), "单一空原始不删除")
            try db.execute("UPDATE subtitle_version SET is_baseline = 0 WHERE id = ?", [.integer(a.version)])
            let old = try edit(repo, a.track, "中间")
            let last = try edit(repo, a.track, "最新")
            _ = try repo.cleanupUnpinnedHistory()
            h.expectEqual(try repo.versions(subtitleTrackID: a.track).map(\.id), [a.version, last], "旧异常资料仍保最早与最新")
            h.expect(try repo.cues(versionID: old).isEmpty, "中间可清理")
            try db.execute("INSERT INTO subtitle_track(track_id,kind,label,is_active,created_at) VALUES (?, 'manual', '无版本来源', 0, 0)", [.integer(ids[1])])
            let sourceRows = try db.query("SELECT * FROM subtitle_track ORDER BY id")
            _ = try repo.cleanupUnpinnedHistory()
            h.expectEqual(try db.query("SELECT * FROM subtitle_track ORDER BY id"), sourceRows, "即使来源没有版本也不删除来源")
        }

        check("跨来源恢复固定快照原子新建最新版，保留每字段与原固定记录") {
            let db = try SQLiteDatabase.inMemory()
            let (repo, ids) = try seed(db)
            let a = try source(repo, ids[0], "来源A")
            let pinned = try edit(repo, a.track, "固定旧快照")
            try repo.setVersionPinned(pinned, isPinned: true)
            _ = try edit(repo, a.track, "A目前最新")
            let b = try source(repo, ids[0], "来源B")
            _ = try edit(repo, b.track, "B生效")
            try db.execute("UPDATE subtitle_cue SET cue_index = cue_index + 10 WHERE version_id = ?", [.integer(pinned)])
            let original = try db.query("SELECT * FROM subtitle_version WHERE id = ?", [.integer(pinned)])
            let body = try content(db, pinned)
            let bVersions = try repo.versions(subtitleTrackID: b.track)
            let restored = try repo.restoreVersion(pinned, trackID: ids[0])
            h.expectEqual(try content(db, restored), body, "原文译文说话人状态时间及非连续行序原样复制")
            h.expectEqual(try db.query("SELECT * FROM subtitle_version WHERE id = ?", [.integer(pinned)]), original, "固定旧版本不改")
            h.expectEqual(try repo.versions(subtitleTrackID: a.track).last?.versionNo, 4, "新恢复版本递增")
            h.expectEqual(try repo.versions(subtitleTrackID: a.track).last?.isPinned, false, "新版本不继承旧pin")
            h.expectEqual(try repo.versions(subtitleTrackID: b.track), bVersions, "原生效来源全部历史保留")
            h.expectEqual(try repo.tracks(forTrackID: ids[0]).filter(\.isActive).map(\.id), [a.track], "只在成功后切来源")
            h.expectEqual(try repo.activeCues(trackID: ids[0]).map(\.text), cues("固定旧快照").map(\.text), "播放读新恢复版本")
            let before = try allState(db)
            for wrong in [(pinned, ids[1]), (Int64.max, ids[0])] {
                do {
                    _ = try repo.restoreVersion(wrong.0, trackID: wrong.1)
                    h.expect(false, "跨音轨或失效版本必须拒绝")
                } catch { h.expectEqual(try allState(db), before, "错误目标不新增版本或切源") }
            }
        }

        for lateFailure in [false, true] {
            check("恢复在\(lateFailure ? "最后切源" : "复制第二句")失败时回滚，不遗留版本或切源") {
                let db = try SQLiteDatabase.inMemory()
                let (repo, ids) = try seed(db)
                let a = try source(repo, ids[0], "A")
                try repo.setVersionPinned(a.version, isPinned: true)
                let b = try source(repo, ids[0], "B")
                let before = try allState(db)
                if lateFailure {
                    try db.executeScript("""
                        CREATE TEMP TRIGGER fail_restore BEFORE UPDATE OF is_active ON subtitle_track
                        WHEN NEW.id = \(a.track) AND NEW.is_active = 1 BEGIN SELECT RAISE(FAIL, 'deny activation'); END;
                        """)
                } else {
                    try db.executeScript("""
                        CREATE TEMP TRIGGER fail_restore BEFORE INSERT ON subtitle_cue
                        WHEN NEW.cue_index = 1 BEGIN SELECT RAISE(FAIL, 'deny second cue'); END;
                        """)
                }
                do {
                    _ = try repo.restoreVersion(a.version, trackID: ids[0])
                    h.expect(false, "恢复应失败")
                } catch { h.expectEqual(try allState(db), before, "所有记录和激活来源回滚") }
                h.expectEqual(try repo.tracks(forTrackID: ids[0]).filter(\.isActive).map(\.id), [b.track], "仍读原来源B")
                try db.executeScript("DROP TRIGGER fail_restore")
                _ = try repo.restoreVersion(a.version, trackID: ids[0])
                h.expectEqual(try repo.versions(subtitleTrackID: a.track).map(\.versionNo), [1, 2], "重试没有半成品或跳号")
            }
        }

        check("固定的自动底稿重扫描不改正文与备注，取消固定后维持既有更新规则") {
            let db = try SQLiteDatabase.inMemory()
            let (repo, ids) = try seed(db)
            let original = try repo.createTrack(trackID: ids[0], kind: .script, language: nil,
                label: "测试.pdf · 第1轨", cues: cues("旧底稿"), note: "从作品 PDF 自动识别 · 尚未设置时间", prefersTimedSidecar: true)
            try repo.setVersionPinned(original.version, isPinned: true)
            let before = try allState(db)
            let track = TrackRecord(id: ids[0], workID: 1, fileName: "01.wav", filePath: "/history/a.wav", fileType: "wav")
            let sections = ScriptSectioner.split("tr01\n0:01 新底稿\n0:03 另一行")
            let plan = ScriptImportPlan.make(sections: sections, tracks: [track])
            try repo.importScriptSections(plan, fileName: "测试.pdf", automatically: true, durationsMS: [ids[0]: 10_000])
            h.expectEqual(try allState(db), before, "固定后重扫不改任何旧记录")
            try repo.setVersionPinned(original.version, isPinned: false)
            try repo.importScriptSections(plan, fileName: "测试.pdf", automatically: true, durationsMS: [ids[0]: 10_000])
            h.expectEqual(try repo.versions(subtitleTrackID: original.track).map(\.id), [original.version], "未编辑底稿继续原位更新而非多加来源")
            h.expect(try repo.cues(versionID: original.version).first?.text.contains("新底稿") == true, "取消固定后保留原自动更新语义")
        }
    }
}
