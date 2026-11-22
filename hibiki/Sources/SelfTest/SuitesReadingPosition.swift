import Foundation
import HibikiCore

func runReadingPositionSuites(_ h: Harness) {
    func cues(_ text: [String]) -> [SubtitleCue] {
        text.enumerated().map { SubtitleCue(index: $0.offset, startMS: 0, endMS: 0, text: $0.element, status: .untimed) }
    }
    let script = cues(["开头", "第一段", "读到这里", "下一段", "结尾"])

    func seed(_ db: SQLiteDatabase) throws -> (library: LibraryRepository, work: Int64, tracks: [Int64], sources: [Int64], files: [Int64]) {
        let library = LibraryRepository(database: db)
        let sourceID = try library.saveSource(LibrarySource(name: "阅读测试"))
        let workID = try library.upsertWork(WorkRecord(title: "作品", folderPath: "/reading", folderRelativePath: ".", sourceID: sourceID))
        let tracks = ["一.wav", "二.wav"].map {
            TrackRecord(workID: workID, fileName: $0, filePath: "/reading/" + $0, relativePath: $0, fileType: "wav")
        }
        try library.replaceTracks(workID: workID, tracks: tracks)
        let ids = try library.tracks(workID: workID).map(\.id)
        let subtitles = SubtitleRepository(database: db)
        let sources = try [ids[0], ids[0], ids[1]].enumerated().map { offset, trackID in
            try subtitles.createTrack(trackID: trackID, kind: .script, language: nil, label: "台本 \(offset)", cues: script).track
        }
        try library.replaceScannedAttachments(workID: workID, files: [
            WorkAttachment(relativePath: "台本.pdf", kind: .pdf, byteCount: 100),
            WorkAttachment(relativePath: "译本.pdf", kind: .pdf, byteCount: 100),
            WorkAttachment(relativePath: "台本.txt", kind: .text, byteCount: 100)
        ])
        return (library, workID, ids, sources, try library.attachmentRecords(workID: workID).map(\.id))
    }

    h.suite("阅读位置的文字锚点与边界") {
        h.test("重新读库产生新 UUID，仍找到同一行；越界与空台本安全返回") {
            let saved = ScriptReadingPosition(cues: script, index: 2, fraction: 0.4)!
            let reloaded = cues(script.map(\.text))
            h.expect(script[2].id != reloaded[2].id, "重读模拟生成新标识")
            h.expectEqual(saved.resolvedIndex(in: reloaded), 2, "根据文字恢复")
            h.expectEqual(saved.fraction, 0.4, "保留行内位置")
            h.expectNil(saved.resolvedIndex(in: []), "没有条目")
            h.expectNil(ScriptReadingPosition(cues: script, index: -1), "负行号")
            h.expectNil(ScriptReadingPosition(cues: script, index: script.count), "尾部越界")
            h.expectNil(ScriptReadingPosition(cues: [], index: 0), "空数组")
        }
        h.test("增删前文、编辑原句、删除原句与版本回滚") {
            let saved = ScriptReadingPosition(cues: script, index: 2)!
            h.expectEqual(saved.resolvedIndex(in: cues(["新增"] + script.map(\.text))), 3, "前面插入不串行")
            h.expectEqual(saved.resolvedIndex(in: Array(script.dropFirst())), 1, "前面删除仍找到原句")
            h.expectEqual(saved.resolvedIndex(in: cues(["新增", "开头", "第一段", "读到这里（已修改）", "下一段", "结尾"])),
                          3, "原句改字后依靠前后文")
            h.expectEqual(saved.resolvedIndex(in: cues(["开头", "第一段", "下一段", "结尾"])), 2, "原句删除后返回紧接的下一句")
            h.expectEqual(saved.resolvedIndex(in: cues(["全新稿"])), 0, "全部替换至少不越界")
            h.expectEqual(saved.resolvedIndex(in: script), 2, "回滚后恢复原句")
        }
        h.test("重复台词用邻句区分，无上下文时优先就近") {
            let original = cues(["甲", "嗯", "乙", "丙", "嗯", "丁", "戊"])
            let saved = ScriptReadingPosition(cues: original, index: 4)!
            let changed = cues(["甲", "嗯", "乙", "新增一", "新增二", "丙", "嗯", "丁", "戊"])
            h.expectEqual(saved.resolvedIndex(in: changed), 6, "重复文字取前后文一致的那处")
            let simple = ScriptReadingPosition(cues: cues(["a", "b", "嗯", "c"]), index: 2)!
            h.expectEqual(simple.resolvedIndex(in: cues(["嗯", "x", "嗯", "z", "嗯"])), 2, "歧义时就近")
            var bilingual = cues(["嗯", "嗯"])
            bilingual[0].translatedText = "回答"
            bilingual[1].translatedText = "应声"
            let both = ScriptReadingPosition(cues: bilingual, index: 1)!
            h.expectEqual(both.resolvedIndex(in: Array(bilingual.reversed())), 0, "同原文不同译文优先完整匹配")
            bilingual[1].translatedText = "改过译文"
            h.expectEqual(both.resolvedIndex(in: bilingual), 1, "仅修改译文不会丢失阅读句")
        }
        h.test("比例、PDF页数、空页和文字UTF16位置有边界保护") {
            h.expectEqual(ScriptReadingPosition(cues: script, index: 1, fraction: -.infinity)?.fraction, 0, "无穷比例")
            h.expectEqual(ScriptReadingPosition(cues: script, index: 1, fraction: .nan)?.fraction, 0, "NaN比例")
            h.expectEqual(ScriptReadingPosition(cues: script, index: 1, fraction: -0.1)?.fraction, 0, "负比例")
            h.expectEqual(ScriptReadingPosition(cues: script, index: 1, fraction: 2)?.fraction, 1, "超过行尾")
            let pdf = PDFReadingPosition(pageIndex: -2, x: .nan, y: 2)
            h.expectEqual(pdf.pageIndex, 0, "负页码")
            h.expectEqual(pdf.x, 0, "无效横位置")
            h.expectEqual(pdf.y, 1, "纵位置钳住")
            h.expectNil(pdf.resolvedPageIndex(pageCount: 0), "空PDF")
            h.expectNil(pdf.resolvedPageIndex(pageCount: -1), "不合法页数")
            h.expectEqual(PDFReadingPosition(pageIndex: Int.max, x: 0.5, y: 0.5).resolvedPageIndex(pageCount: 5), 4, "文件缩短回到末页")
            h.expectEqual(TextReadingPosition(utf16Offset: -1).utf16Offset, 0, "负文字位置")
            h.expectEqual(TextReadingPosition(utf16Offset: 2).clampedUTF16Offset(in: "A😀B"), 1, "不落在emoji代理对中间")
            h.expectEqual(TextReadingPosition(utf16Offset: 2).clampedUTF16Offset(in: "Ae\u{301}B"), 1, "不拆组合字符")
            h.expectEqual(TextReadingPosition(utf16Offset: Int.max).clampedUTF16Offset(in: "中文"), 1, "缩短文件不越界")
            h.expectEqual(TextReadingPosition(utf16Offset: 7).clampedUTF16Offset(in: ""), 0, "空文字")
        }
    }

    h.suite("阅读位置存取与旧库升级") {
        h.test("v15原库升级保留作品、台本、附件和设置，重复升级不清空位置") {
            do {
                let db = try SQLiteDatabase.inMemory()
                try db.migrate(Schema.migrations.filter { $0.version <= 15 })
                let fixture = try seed(db)
                try fixture.library.setSetting("previous-setting", "keep")
                try fixture.library.savePlaybackPosition(workID: fixture.work, trackID: fixture.tracks[0], positionMS: 3456)
                let before = try ["source", "work", "track", "subtitle_track", "subtitle_version", "subtitle_cue", "work_attachment", "app_setting"]
                    .map { try db.query("SELECT * FROM \($0) ORDER BY id".replacingOccurrences(of: "app_setting ORDER BY id", with: "app_setting ORDER BY key")) }
                h.expectEqual(try db.migrate(Schema.migrations.filter { $0.version <= 16 }), 1, "只增加v16")
                h.expectEqual(db.userVersion, 16, "升级到v16")
                let after = try ["source", "work", "track", "subtitle_track", "subtitle_version", "subtitle_cue", "work_attachment", "app_setting"]
                    .map { try db.query("SELECT * FROM \($0) ORDER BY id".replacingOccurrences(of: "app_setting ORDER BY id", with: "app_setting ORDER BY key")) }
                h.expectEqual(after, before, "所有原记录保持不变")
                let reading = ReadingPositionRepository(database: db)
                h.expectNil(try reading.scriptPosition(subtitleTrackID: fixture.sources[0]), "旧库不会猜测位置")
                let position = ScriptReadingPosition(cues: script, index: 3, fraction: 0.2)!
                try reading.saveScriptPosition(position, subtitleTrackID: fixture.sources[0])
                h.expectEqual(try db.migrate(Schema.migrations.filter { $0.version <= 16 }), 0, "重复升级跳过")
                h.expectEqual(try reading.scriptPosition(subtitleTrackID: fixture.sources[0]), position, "重复启动不清空位置")
                h.expect(try db.query("PRAGMA foreign_key_check").isEmpty, "外键一致")
            } catch { h.expect(false, "迁移失败：\(error)") }
        }
        h.test("跨关闭重开保存，切音轨与同音轨不同来源互不覆盖") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let path = folder.appendingPathComponent("reading.db").path
                let db = try SQLiteDatabase(path: path)
                try db.migrate(Schema.migrations)
                let fixture = try seed(db)
                let reading = ReadingPositionRepository(database: db)
                for (index, id) in fixture.sources.enumerated() {
                    try reading.saveScriptPosition(ScriptReadingPosition(cues: script, index: index + 1)!, subtitleTrackID: id)
                }
                let a = PDFReadingPosition(pageIndex: 4, x: 0.2, y: 0.7)
                let b = PDFReadingPosition(pageIndex: 8, x: 0.1, y: 0.4)
                let text = TextReadingPosition(utf16Offset: 1200)
                try reading.savePDFPosition(a, attachmentID: fixture.files[0])
                try reading.savePDFPosition(b, attachmentID: fixture.files[1])
                try reading.saveTextPosition(text, attachmentID: fixture.files[2])
                db.close()
                let reopened = try SQLiteDatabase(path: path)
                let restored = ReadingPositionRepository(database: reopened)
                for (index, id) in fixture.sources.enumerated() {
                    let saved = try restored.scriptPosition(subtitleTrackID: id)
                    h.expectEqual(saved?.resolvedIndex(in: script), index + 1, "来源\(index)各自恢复")
                }
                h.expectEqual(try restored.pdfPosition(attachmentID: fixture.files[0]), a, "第一份PDF")
                h.expectEqual(try restored.pdfPosition(attachmentID: fixture.files[1]), b, "第二份PDF")
                h.expectEqual(try restored.textPosition(attachmentID: fixture.files[2]), text, "TXT位置")
                try restored.savePDFPosition(b, attachmentID: fixture.files[0])
                h.expectEqual(try reopened.queryInt("SELECT COUNT(*) FROM attachment_reading_position"), 3, "更新位置不堆积历史")
                h.expectNil(try restored.textPosition(attachmentID: fixture.files[0]), "PDF不会误读为文字位置")
                reopened.close()
            } catch { h.expect(false, "重开保存失败：\(error)") }
        }
        h.test("重扫与字幕版本变化保留身份，删除资料清理附属位置") {
            do {
                let db = try SQLiteDatabase.inMemory()
                try db.migrate(Schema.migrations)
                let f = try seed(db), reading = ReadingPositionRepository(database: db)
                let saved = ScriptReadingPosition(cues: script, index: 2)!
                for id in f.sources { try reading.saveScriptPosition(saved, subtitleTrackID: id) }
                for id in f.files { try reading.savePDFPosition(PDFReadingPosition(pageIndex: 2, x: 0.1, y: 0.9), attachmentID: id) }
                let tracks = try f.library.tracks(workID: f.work)
                let files = try f.library.attachmentRecords(workID: f.work).map(\.attachment)
                try f.library.replaceTracks(workID: f.work, tracks: tracks)
                try f.library.replaceScannedAttachments(workID: f.work, files: files)
                h.expectEqual(try reading.scriptPosition(subtitleTrackID: f.sources[0]), saved, "重扫保留台本位置")
                h.expectEqual(try reading.pdfPosition(attachmentID: f.files[0])?.pageIndex, 2, "重扫保留PDF位置")
                let subtitles = SubtitleRepository(database: db)
                let edited = cues(["前面新增"] + script.map(\.text))
                _ = try subtitles.insertVersion(subtitleTrackID: f.sources[0], note: "增加前文", isBaseline: false, cues: edited)
                h.expectEqual(try reading.scriptPosition(subtitleTrackID: f.sources[0])?.resolvedIndex(in: edited), 3, "新版本仍寻找原句")
                try subtitles.deleteTrack(f.sources[0])
                h.expectNil(try reading.scriptPosition(subtitleTrackID: f.sources[0]), "删除来源清位置")
                h.expectNotNil(try reading.scriptPosition(subtitleTrackID: f.sources[1]), "同首其他来源保留")
                _ = try f.library.removeMedia(workID: f.work, id: .attachment(f.files[0]))
                h.expectNil(try reading.pdfPosition(attachmentID: f.files[0]), "删除附件清位置")
                h.expectNotNil(try reading.pdfPosition(attachmentID: f.files[1]), "其他PDF保留")
                _ = try f.library.removeWorkFromLibrary(workID: f.work)
                h.expectEqual(try db.queryInt("SELECT COUNT(*) FROM subtitle_reading_position"), 0, "删除作品清其全部台本位置")
                h.expectEqual(try db.queryInt("SELECT COUNT(*) FROM attachment_reading_position"), 0, "删除作品清其全部附件位置")
            } catch { h.expect(false, "资料生命周期失败：\(error)") }
        }
        h.test("缺失对象拒绝写入，失败保留旧位置，损坏内容不阻碍阅读") {
            do {
                let db = try SQLiteDatabase.inMemory()
                try db.migrate(Schema.migrations)
                let f = try seed(db), reading = ReadingPositionRepository(database: db)
                let old = ScriptReadingPosition(cues: script, index: 1)!
                try reading.saveScriptPosition(old, subtitleTrackID: f.sources[0])
                for id: Int64 in [0, -1, 999_999] {
                    do { try reading.saveScriptPosition(old, subtitleTrackID: id); h.expect(false, "应拒绝不存在的来源") }
                    catch { h.expect(true, "缺失来源拒绝写入") }
                    do { try reading.saveTextPosition(TextReadingPosition(utf16Offset: 4), attachmentID: id); h.expect(false, "应拒绝不存在的附件") }
                    catch { h.expect(true, "缺失附件拒绝写入") }
                }
                try db.executeScript("""
                    CREATE TRIGGER reject_reading_update BEFORE UPDATE ON subtitle_reading_position
                    BEGIN SELECT RAISE(ABORT, 'write failure'); END;
                    """)
                do { try reading.saveScriptPosition(ScriptReadingPosition(cues: script, index: 4)!, subtitleTrackID: f.sources[0]); h.expect(false, "故障应向上抛出") }
                catch { h.expectEqual(try reading.scriptPosition(subtitleTrackID: f.sources[0]), old, "写失败时旧位置仍在") }
                try db.execute("DROP TRIGGER reject_reading_update")
                try db.execute("UPDATE subtitle_reading_position SET payload = '{broken' WHERE subtitle_track_id = ?", [.integer(f.sources[0])])
                h.expectNil(try reading.scriptPosition(subtitleTrackID: f.sources[0]), "坏JSON被忽略")
                try reading.savePDFPosition(PDFReadingPosition(pageIndex: 1, x: 0, y: 1), attachmentID: f.files[0])
                try db.execute("UPDATE attachment_reading_position SET payload = ? WHERE attachment_id = ?",
                               [.text("{\"pageIndex\":-1,\"x\":0.2,\"y\":0.5}"), .integer(f.files[0])])
                h.expectNil(try reading.pdfPosition(attachmentID: f.files[0]), "坏页码不误跳")
                try reading.saveTextPosition(TextReadingPosition(utf16Offset: 1), attachmentID: f.files[2])
                try db.execute("UPDATE attachment_reading_position SET payload = ? WHERE attachment_id = ?",
                               [.text("{\"utf16Offset\":-7}"), .integer(f.files[2])])
                h.expectNil(try reading.textPosition(attachmentID: f.files[2]), "坏文字位置不误跳")
                h.expectEqual(try SubtitleRepository(database: db).activeCues(trackID: f.tracks[0]).map(\.text), script.map(\.text), "损坏位置不影响台本原文")
            } catch { h.expect(false, "错误恢复失败：\(error)") }
        }
    }
}
