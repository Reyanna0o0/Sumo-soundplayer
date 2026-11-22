import Foundation
import HibikiCore

func runDualLibrarySuites(_ h: Harness) {
    func test(_ name: String, _ body: () throws -> Void) {
        h.test(name) { do { try body() } catch { h.expect(false, "测试抛出错误：\(error)") } }
    }
    func makeLibrary() throws -> (SQLiteDatabase, LibraryRepository, Int64) {
        let db = try SQLiteDatabase.inMemory(), library = LibraryRepository(database: db)
        try library.prepare()
        let source = try library.saveSource(LibrarySource(name: "双库源", rootPath: "/dual-library"))
        return (db, library, source)
    }
    func addWork(_ library: LibraryRepository, source: Int64, key: String,
                 kind: MediaLibraryKind = .collection, creator: Int64? = nil) throws -> Int64 {
        try library.upsertWork(WorkRecord(title: key, folderPath: "/dual-library/" + key,
            folderRelativePath: key, sourceID: source, libraryKind: kind, creatorID: creator))
    }
    func snapshot(_ db: SQLiteDatabase) throws -> [String: [SQLRow]] {
        var result: [String: [SQLRow]] = [:]
        for row in try db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") {
            let name = row.string("name")!
            result[name] = try db.query("SELECT * FROM \"\(name)\" ORDER BY rowid")
        }
        return result
    }
    func rejects(_ db: SQLiteDatabase, _ operation: () throws -> Void) throws {
        let before = try snapshot(db)
        do { try operation(); h.expect(false, "无效操作应被拒绝") }
        catch { h.expect(true, "拒绝无效操作") }
        h.expectEqual(try snapshot(db), before, "失败后所有表及编号序列完全不变")
    }

    h.suite("双媒体库与创作者") {
        test("v23 升级后两库逐作品保存封面显示，重新扫描及打开仍保留") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("library.sqlite").path
            let db = try SQLiteDatabase(path: path), library = LibraryRepository(database: db)
            try db.migrate(Schema.migrations.filter { $0.version <= 23 })
            let source = try library.saveSource(LibrarySource(name: "封面测试"))
            let collection = try addWork(library, source: source, key: "合集")
            let personal = try addWork(library, source: source, key: "个人", kind: .personal)
            let oldState = try snapshot(db)
            try library.prepare()
            var restoredState = try snapshot(db)
            restoredState["work"] = restoredState["work"]?.map { SQLRow($0.values.filter { $0.key != "player_cover_mode" }) }
            h.expectEqual(restoredState, oldState, "升级保留所有旧字段和表内容")
            h.expectEqual(try library.work(id: collection)?.playerCoverMode, .original, "旧作品沿用原图比例")
            try library.updateWorkMetadata(workID: collection, circleName: "", seiyuuNames: [], playerCoverMode: .fit4x3)
            h.expectEqual(try library.work(id: personal)?.playerCoverMode, .original, "不会改变其他作品")
            try library.savePersonalWorkMetadata(workID: personal, title: "个人", creatorID: nil, playerCoverMode: .fill4x3)
            try rejects(db) {
                try library.updateWorkMetadata(workID: collection, circleName: "", seiyuuNames: [],
                    cover: .replace(assetRelativePath: "../invalid"), playerCoverMode: .original)
            }
            _ = try addWork(library, source: source, key: "合集")
            try library.savePersonalWorkMetadata(workID: personal, title: "新名称", creatorID: nil)
            db.close()
            let reopened = try SQLiteDatabase(path: path)
            defer { reopened.close() }
            let saved = LibraryRepository(database: reopened)
            h.expectEqual(try saved.prepare(), 0, "再次启动不重复迁移")
            h.expectEqual(try saved.work(id: collection)?.playerCoverMode, .fit4x3, "重扫及重启保留完整显示")
            h.expectEqual(try saved.work(id: personal)?.playerCoverMode, .fill4x3, "单独改名及重启保留居中裁切")
            try saved.savePersonalWorkMetadata(workID: personal, title: "新名称", creatorID: nil, playerCoverMode: .original)
            h.expectEqual(try saved.work(id: personal)?.playerCoverMode, .original, "可切回原比例")
        }

        test("个人单音频取真实曲名，旧版改名、搜索与扫描均保留") {
            let db = try SQLiteDatabase.inMemory(), library = LibraryRepository(database: db)
            try db.migrate(Schema.migrations.filter { $0.version <= 20 })
            let source = try library.saveSource(LibrarySource(name: "本地", rootPath: "/audio"))
            let work = try addWork(library, source: source, key: "原目录", kind: .personal)
            let oldEdit = try addWork(library, source: source, key: "早期作品", kind: .personal)
            let audio = TrackRecord(workID: work, fileName: "A.part.one.wav", filePath: "/audio/A.part.one.wav",
                                    fileType: "wav", title: nil)
            try library.replaceTracks(workID: work, tracks: [audio])
            var olderAudio = audio
            olderAudio.workID = oldEdit
            olderAudio.filePath = "/early/A.part.one.wav"
            try library.replaceTracks(workID: oldEdit, tracks: [olderAudio])
            try library.savePersonalWorkMetadata(workID: oldEdit, title: "旧版手工名", creatorID: nil)
            try library.prepare()
            let id = try library.tracks(workID: work)[0].id
            h.expectEqual(try library.work(id: oldEdit)?.title, "旧版手工名", "手工改名胜过扫描值")
            h.expectEqual(try library.tracks(workID: oldEdit)[0].displayTitle, "旧版手工名", "旧改名同步到曲目")
            h.expectEqual(try library.work(id: work)?.title, "A.part.one", "未自定名时用最后一段扩展名前的文件名")
            h.expectEqual(try library.works(sort: .title, limit: 1, libraryKind: .personal).first?.id, work, "排序使用显示名")
            h.expectEqual(try library.works(searchText: "part.one", libraryKind: .personal).map(\.id), [work], "搜索与卡片相同")
            h.expectEqual(try library.works(searchText: "原目录").count, 0, "旧目录不是当前名称")
            let playlist = PlaylistRepository(database: db)
            try playlist.addWholeTrack(trackID: id, title: "A.part.one", workTitle: "原目录")
            let oldPath = try library.track(id: id)?.filePath
            try rejects(db) { try library.savePersonalWorkMetadata(workID: work, title: "无效编辑", creatorID: -10) }
            let linked = try library.savePersonalWorkMetadata(workID: work, title: " 重新命名 ", creatorID: nil)
            h.expectEqual(linked, id, "返回改名的音轨身份")
            let saved = try playlist.entries()[0]
            h.expectEqual(saved.title, "重新命名", "已有整曲收藏显示新音频名")
            h.expectEqual(saved.workTitle, "重新命名", "已有整曲收藏同步作品名")
            h.expectEqual(try library.track(id: id)?.filePath, oldPath, "改名不会更改文件路径")
            var scanned = audio; scanned.title = "重新扫描的名称"
            try library.replaceTracks(workID: work, tracks: [scanned])
            h.expectEqual(try library.work(id: work)?.title, "重新命名", "重扫后卡片保留")
            let track = try library.tracks(workID: work)[0]
            h.expectEqual(track.displayTitle, "重新命名", "播放使用相同曲目显示名")
            h.expectEqual(track.id, id, "身份保留")
            h.expectEqual(track.fileName, audio.fileName, "文件名保留")
            h.expectEqual(track.filePath, audio.filePath, "原路径保留")
            let second = TrackRecord(workID: work, fileName: "two.wav", filePath: "/audio/two.wav", fileType: "wav", title: "第二轨")
            try library.replaceTracks(workID: work, tracks: [scanned, second])
            h.expectNil(try library.savePersonalWorkMetadata(workID: work, title: "多音轨作品", creatorID: nil), "多音轨只改作品名")
            h.expectEqual(try library.tracks(workID: work).map(\.displayTitle), ["重新命名", "第二轨"], "曲目改名保留且互不影响")
            var video = second; video.isVideo = true; video.title = "视频"
            try library.replaceTracks(workID: work, tracks: [scanned, video])
            h.expectEqual(try library.work(id: work)?.title, "重新命名", "视频不计入音频数")
            try library.replaceTracks(workID: work, tracks: [video])
            h.expectEqual(try library.work(id: work)?.title, "多音轨作品", "纯视频使用作品名")
            try library.replaceTracks(workID: work, tracks: [])
            h.expectEqual(try library.work(id: work)?.title, "多音轨作品", "空作品使用作品名")
        }

        test("正在播放与排队的重复音轨同步名称，收藏摘选保留独立标题") {
            let audio = PlaybackQueueItem(workID: 8, trackID: 3, workTitle: "旧作品", trackTitle: "旧曲目", filePath: "/a.wav", fileType: "wav")
            let clip = PlaybackQueueItem(workID: 8, trackID: -3, workTitle: "旧摘选作品", trackTitle: "独立摘选", filePath: "/clip.caf", fileType: "caf")
            let video = PlaybackQueueItem(workID: 8, trackID: 0, workTitle: "旧作品", trackTitle: "视频", filePath: "/b.mp4", fileType: "mp4", attachmentID: 3)
            var queue = PlaybackQueue(items: [audio, clip, video, audio])
            queue.setShuffle(true, seed: 11, keepingCurrent: 0)
            let order = queue.order, cursor = queue.cursor
            queue.renamePersonalAudio(workID: 8, trackID: 3, title: "新曲名")
            h.expectEqual(queue.items.map(\.trackTitle), ["新曲名", "独立摘选", "视频", "新曲名"], "仅对应音频")
            h.expectEqual(queue.items[2].workTitle, "新曲名", "视频归属作品保持最新")
            h.expectEqual(queue.items[1], clip, "独立摘选元数据保留")
            h.expectEqual(queue.order, order, "随机顺序保留")
            h.expectEqual(queue.cursor, cursor, "游标保留")
        }

        test("缓存查询在迁移后的首次读取即包含新列，聚合列名不错位") {
            let f = try RelinkingFixture(version: 16)
            let query = "SELECT w.*, 123 AS marker FROM work w WHERE id = ?"
            let args: [SQLValue] = [.integer(f.workID)]
            let before = try f.db.query(query, args)[0]
            h.expectNil(before.string("library_kind"), "旧表确实无新列")
            h.expectEqual(before.int("marker"), 123, "迁移前尾部聚合值")
            try f.library.prepare()
            let first = try f.db.query(query, args)[0]
            h.expectEqual(first.string("library_kind"), "collection", "第一次就读到新库归属")
            h.expect(first.values.keys.contains("creator_id"), "第一次就包含新增可空作者列")
            h.expectEqual(first.int("marker"), 123, "新增列不会把旧聚合列映射到错误名称")
            h.expectEqual(try f.db.query(query, args)[0], first, "第二次与第一次一致")
        }

        test("首次导入保存台本位置，重扫仍可更新扫描引用") {
            let (_, library, source) = try makeLibrary()
            var scanned = WorkRecord(title: "压缩包作品", folderPath: "/dual-library/archive", folderRelativePath: "archive",
                sourceID: source, scriptPath: "台本/script.pdf")
            let id = try library.upsertWork(scanned)
            h.expectEqual(try library.work(id: id)?.scriptPath, "台本/script.pdf", "初次INSERT保留台本入口")
            scanned.scriptPath = "台本/revised.pdf"
            h.expectEqual(try library.upsertWork(scanned), id, "重扫保留ID")
            h.expectEqual(try library.work(id: id)?.scriptPath, "台本/revised.pdf", "重扫延续已有引用更新行为")
        }

        test("完整v16库升级只增加字段，旧身份、字幕、阅读、分类、收藏、列表和统计逐字段保留") {
            let fixture = try RelinkingFixture(version: 16)
            try fixture.db.execute("INSERT INTO play_statistic(date_key,hour_slot,work_id,seconds) VALUES ('2026-11-10',2,0,8)")
            let before = try snapshot(fixture.db)
            var columns: [String: Set<String>] = [:]
            for table in before.keys {
                columns[table] = Set(try fixture.db.query("PRAGMA table_info(\"\(table)\")").compactMap { $0.string("name") })
            }
            h.expectEqual(try fixture.library.prepare(), Schema.currentVersion - 16, "只执行新增迁移")
            h.expectEqual(fixture.db.userVersion, Schema.currentVersion, "升级到当前版本")
            let after = try snapshot(fixture.db)
            for (table, records) in before {
                let originalColumns = after[table, default: []].map { row in
                    SQLRow(row.values.filter { columns[table, default: []].contains($0.key) })
                }
                h.expectEqual(originalColumns, records, "\(table) 所有原字段与记录保留")
            }
            h.expectEqual(try fixture.library.work(id: fixture.workID)?.libraryKind, .collection, "旧作品默认为社团合集")
            h.expectNil(try fixture.library.work(id: fixture.workID)?.creatorID, "不猜测旧作品作者")
            h.expect(try fixture.library.creators().isEmpty, "不制造虚假创作者")
            h.expectEqual(try fixture.db.query("SELECT library_kind FROM play_statistic WHERE work_id > 0").first?.string("library_kind"), "collection", "旧统计归入旧库")
            h.expectNil(try fixture.db.query("SELECT library_kind FROM play_statistic WHERE work_id = 0").first?.string("library_kind"), "来源不明摘选仍不强归类")
            h.expectEqual(try fixture.library.prepare(), 0, "重复启动不重复迁移")
            let reopened = try snapshot(fixture.db)
            for table in after.keys {
                h.expect(reopened[table] == after[table], "\(table) 重复启动数据完全不变")
            }
            h.expect(try fixture.db.query("PRAGMA foreign_key_check").isEmpty, "升级外键一致")
            h.expectEqual(try fixture.db.query("PRAGMA integrity_check").first?.string("integrity_check"), "ok", "数据库结构完好")
        }

        test("v17中途迁移失败回滚新表字段和版本，旧数据不动") {
            let f = try RelinkingFixture(version: 16)
            // This collision happens after CREATE creator and both ALTER work statements.
            try f.db.execute("CREATE INDEX work_creator ON work(id)")
            let schemaBefore = try f.db.query("SELECT * FROM sqlite_master ORDER BY name")
            try rejects(f.db) { try f.library.prepare() }
            h.expectEqual(f.db.userVersion, 16, "失败不推进版本")
            h.expectEqual(try f.db.query("SELECT * FROM sqlite_master ORDER BY name"), schemaBefore, "失败回滚全部结构变更")
        }

        test("创作者资料稳定保存，同名不合并，共享头像不会成为作品私有删除项") {
            let (db, library, source) = try makeLibrary()
            let created = Date(timeIntervalSince1970: 1_700_000_000)
            let id = try library.saveCreator(CreatorRecord(name: "  作者甲  ", avatarAssetPath: "Covers/avatar.jpg",
                coverMode: .avatar, note: "一行\n另一行", createdAt: created))
            let sameName = try library.saveCreator(CreatorRecord(name: "作者甲"))
            h.expect(id != sameName, "显示同名仍保留独立身份")
            let first = try addWork(library, source: source, key: "个人一", kind: .personal, creator: id)
            let second = try addWork(library, source: source, key: "个人二", kind: .personal, creator: id)
            var creator = try library.creator(id: id)!
            h.expectEqual(creator.name, "作者甲", "名字去掉首尾空白")
            h.expectEqual(creator.note, "一行\n另一行", "备注不丢换行")
            h.expectEqual(creator.effectiveCoverAssetPath, "Covers/avatar.jpg", "头像模式继承头像")
            creator.name = "改名作者"
            creator.avatarAssetPath = "Covers/new-avatar.jpg"
            creator.createdAt = Date()
            let worksBefore = try db.query("SELECT * FROM work ORDER BY id")
            h.expectEqual(try library.saveCreator(creator), id, "编辑保持作者ID")
            h.expectEqual(try library.creator(id: id)?.createdAt, created, "编辑不改创建时间")
            h.expectEqual(try library.creator(id: id)?.effectiveCoverAssetPath, "Covers/new-avatar.jpg", "共享封面立即跟随头像")
            h.expectEqual(try db.query("SELECT * FROM work ORDER BY id"), worksBefore, "作者编辑不改写每个作品")
            h.expectNil(try library.work(id: first)?.coverAssetPath, "作者图不落入作品私有封面")
            h.expect(try library.removeWorkFromLibrary(workID: first).isEmpty, "删除作品不返回共享头像供删除")
            h.expectEqual(try library.work(id: second)?.creatorID, id, "其他作品关联保留")
            h.expectNotNil(try library.creator(id: id), "删除作品不删作者")
            creator.coverMode = .none
            try library.saveCreator(creator)
            h.expectNil(try library.creator(id: id)?.effectiveCoverAssetPath, "默认无封面")
            creator.coverMode = .image
            creator.coverAssetPath = "Covers/custom.jpg"
            try library.saveCreator(creator)
            h.expectEqual(try library.creator(id: id)?.effectiveCoverAssetPath, "Covers/custom.jpg", "自选封面")
        }

        test("无效创作者名字路径封面和失效ID均不写入") {
            let (db, library, _) = try makeLibrary()
            for creator in [CreatorRecord(name: " \n"), CreatorRecord(id: -1, name: "甲"),
                            CreatorRecord(id: 999, name: "甲"), CreatorRecord(name: "甲", coverMode: .image),
                            CreatorRecord(name: "甲", avatarAssetPath: "../escape.jpg"),
                            CreatorRecord(name: "甲", coverAssetPath: "/absolute.jpg"),
                            CreatorRecord(name: "甲", avatarAssetPath: "Covers/\0bad.jpg")] {
                try rejects(db) { try library.saveCreator(creator) }
            }
        }

        test("重新打开数据库仍能读取创作者共享图像与个人作品身份") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("library.db").path
            let db = try SQLiteDatabase(path: path), library = LibraryRepository(database: db)
            try library.prepare()
            let source = try library.saveSource(LibrarySource(name: "内部音频"))
            let author = try library.saveCreator(CreatorRecord(name: "重开作者", avatarAssetPath: "Covers/avatar.jpg", coverMode: .avatar, note: "保留备注"))
            let work = try addWork(library, source: source, key: "重开作品", kind: .personal, creator: author)
            let savedAuthor = try library.creator(id: author)
            let savedWork = try library.work(id: work)
            db.close()
            let reopened = try SQLiteDatabase(path: path), repo = LibraryRepository(database: reopened)
            defer { reopened.close() }
            h.expectEqual(try repo.prepare(), 0, "新进程打开无需再次迁移")
            h.expectEqual(try repo.creator(id: author), savedAuthor, "完整作者资料保存")
            h.expectEqual(try repo.work(id: work), savedWork, "作品身份资料保存")
        }

        test("双库查询和作者搜索独立，默认全库，重扫不覆盖库归属作者或手填标题") {
            let (_, library, source) = try makeLibrary()
            let author = try library.saveCreator(CreatorRecord(name: "可搜索作者"))
            let collection = try addWork(library, source: source, key: "社团作品")
            let personal = try addWork(library, source: source, key: "个人作品", kind: .personal, creator: author)
            let unassigned = try addWork(library, source: source, key: "未署名个人", kind: .personal)
            h.expectEqual(Set(try library.works().map(\.id)), Set([collection, personal, unassigned]), "默认保留全库调用语义")
            h.expectEqual(try library.works(libraryKind: .collection).map(\.id), [collection], "社团筛选")
            h.expectEqual(Set(try library.works(libraryKind: .personal).map(\.id)), Set([personal, unassigned]), "个人筛选")
            h.expectEqual(try library.works(creatorID: author).map(\.id), [personal], "作者筛选")
            h.expectEqual(try library.works(searchText: "可搜索作者", libraryKind: .personal).map(\.id), [personal], "个人库可搜索作者")
            h.expect(try library.works(searchText: "可搜索作者", libraryKind: .collection).isEmpty, "当前社团库不混入个人搜索")
            try library.savePersonalWorkMetadata(workID: personal, title: " 用户修改标题 ", creatorID: author)
            let rescan = try addWork(library, source: source, key: "个人作品")
            h.expectEqual(rescan, personal, "重新扫描保持作品ID")
            let after = try library.work(id: personal)!
            h.expectEqual(after.libraryKind, .personal, "默认社团扫描参数不改变已有归属")
            h.expectEqual(after.creatorID, author, "重扫不清空作者")
            h.expectEqual(after.title, "用户修改标题", "手填标题独立于扫描标题")
        }

        test("个人标题作者原子修改仅改变三个字段，拒绝失效作者和社团作品") {
            let f = try RelinkingFixture()
            let author = try f.library.saveCreator(CreatorRecord(name: "个人作者"))
            try f.db.execute("UPDATE work SET library_kind = 'personal' WHERE id = ?", [.integer(f.workID)])
            let before = try snapshot(f.db)
            try f.library.savePersonalWorkMetadata(workID: f.workID, title: "新个人标题", creatorID: author)
            let after = try snapshot(f.db)
            for (table, rows) in before {
                let omitted: Set<String> = table == "work" ? ["title_override", "creator_id", "updated_at"] : []
                func retained(_ rows: [SQLRow]) -> [SQLRow] { rows.map { SQLRow($0.values.filter { !omitted.contains($0.key) }) } }
                h.expectEqual(retained(after[table, default: []]), retained(rows), "\(table) 除明确资料字段全部保留")
            }
            h.expectEqual(try f.library.work(id: f.workID)?.title, "新个人标题", "新标题")
            h.expectEqual(try f.library.work(id: f.workID)?.creatorID, author, "新作者")
            try rejects(f.db) { try f.library.savePersonalWorkMetadata(workID: f.workID, title: "不能部分写入", creatorID: 999) }
            try rejects(f.db) { try f.library.savePersonalWorkMetadata(workID: f.workID, title: " \n", creatorID: author) }
            try f.library.savePersonalWorkMetadata(workID: f.workID, title: "清空作者", creatorID: nil)
            h.expectNil(try f.library.work(id: f.workID)?.creatorID, "允许未署名个人作品")
            let collection = try f.addNeighbour()
            try rejects(f.db) { try f.library.savePersonalWorkMetadata(workID: collection, title: "错误入口", creatorID: author) }
            try rejects(f.db) { _ = try addWork(f.library, source: f.sourceID, key: "禁止社团作者", creator: author) }
            try rejects(f.db) { _ = try addWork(f.library, source: f.sourceID, key: "失效作者", kind: .personal, creator: 999) }
        }

        test("最近作者按最近收听作品去重，收藏和跨库列表原身份不变") {
            let (db, library, source) = try makeLibrary()
            let a = try library.saveCreator(CreatorRecord(name: "甲")), b = try library.saveCreator(CreatorRecord(name: "乙"))
            let collection = try addWork(library, source: source, key: "社团")
            let wa = try addWork(library, source: source, key: "甲一", kind: .personal, creator: a)
            let wa2 = try addWork(library, source: source, key: "甲二", kind: .personal, creator: a)
            let wb = try addWork(library, source: source, key: "乙一", kind: .personal, creator: b)
            h.expect(try library.recentCreators().isEmpty, "未听不进入最近作者")
            for (id, time) in [(wa, 100), (wa2, 300), (wb, 200)] {
                try db.execute("UPDATE work SET last_played_at = ? WHERE id = ?", [.integer(time), .integer(id)])
            }
            h.expectEqual(try library.recentCreators(limit: 10).map(\.id), [a, b], "按每位作者最新一次作品排序")
            h.expectEqual(try library.recentCreators(limit: 1).map(\.id), [a], "限量")
            h.expect(try library.recentCreators(limit: 0).isEmpty, "零限量")
            let playlist = PlaylistRepository(database: db)
            for id in [collection, wa] {
                try library.appendOwnedTracks(workID: id, tracks: [TrackRecord(workID: id, fileName: "\(id).wav", filePath: "ignored", fileType: "wav", assetRelativePath: "Audio/\(id).wav")])
                let track = try library.tracks(workID: id)[0]
                try library.setFavorite(true, workID: id)
                try playlist.addWholeTrack(trackID: track.id, title: track.fileName, workTitle: "列表标题")
                try playlist.addClip(trackID: track.id, title: "摘选", workTitle: "列表标题", startMS: 100, endMS: 200, filename: "\(id).caf")
            }
            h.expectEqual(try playlist.entries().count, 4, "同一播放列表允许跨库整曲和摘选")
            h.expectEqual(try library.works(filter: .favorite, libraryKind: .personal).map(\.id), [wa], "个人收藏筛选不改收藏关系")
            h.expectEqual(Set(try library.works(filter: .favorite).map(\.id)), Set([wa, collection]), "全库收藏保留")
        }

        test("个人重新关联保留库作者与全部用户数据") {
            let f = try RelinkingFixture()
            let author = try f.library.saveCreator(CreatorRecord(name: "重关联作者", avatarAssetPath: "Covers/shared.jpg"))
            try f.db.execute("UPDATE work SET library_kind = 'personal', creator_id = ? WHERE id = ?", [.integer(author), .integer(f.workID)])
            let before = try snapshot(f.db)
            var source = try f.source()
            source.rootPath = "/new-personal-root"
            source.grouping = .singleWork
            try f.library.relinkWork(existingID: f.workID, source: source, folderPath: source.rootPath!, folderRelativePath: ".",
                tracks: f.trackMappings(["renamed/A.wav", "renamed/B.wav"]), attachments: f.attachmentMappings())
            let after = try snapshot(f.db)
            let allowed: [String: Set<String>] = ["source": ["root_path", "grouping"],
                "work": ["source_id", "folder_path", "folder_rel", "cover_path", "script_path"],
                "track": ["file_path", "relative_path", "file_rel"], "work_attachment": ["relative_path"]]
            for (table, rows) in before {
                func retained(_ records: [SQLRow]) -> [SQLRow] { records.map { row in SQLRow(row.values.filter { !allowed[table, default: []].contains($0.key) }) } }
                h.expectEqual(retained(after[table, default: []]), retained(rows), "\(table) 重关联仅改位置")
            }
            h.expectEqual(try f.library.work(id: f.workID)?.libraryKind, .personal, "个人归属保留")
            h.expectEqual(try f.library.work(id: f.workID)?.creatorID, author, "作者ID保留")
            h.expect(try f.db.query("PRAGMA foreign_key_check").isEmpty, "重关联外键一致")
        }

        test("个人统计携带归属作者，删作品后历史保留，混合摘选不冒充任何库") {
            let (db, library, source) = try makeLibrary()
            let author = try library.saveCreator(CreatorRecord(name: "原作者"))
            let personal = try addWork(library, source: source, key: "个人", kind: .personal, creator: author)
            let collection = try addWork(library, source: source, key: "社团")
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let p = PlayStatRow(workID: personal, title: "个人", dateKey: "2026-11-11", hourSlot: 8, seconds: 30,
                libraryKind: .personal, creatorID: author, creatorName: "原作者")
            let history = ListeningSessionDelta(startedAt: date, startDateKey: "2026-11-11", workID: personal,
                trackID: 11, workTitle: "个人", trackTitle: "单音频", isSavedClip: false, seconds: 30,
                libraryKind: .personal, creatorID: author, creatorName: "原作者")
            let mixed = PlayStatRow(workID: 0, dateKey: "2026-11-11", hourSlot: 8, seconds: 7,
                libraryKind: .personal, creatorID: author, creatorName: "不能强归类")
            let mixedSession = ListeningSessionDelta(startedAt: date, workID: 0, trackID: -1, workTitle: "混合", trackTitle: "混合", isSavedClip: true,
                seconds: 7, libraryKind: .personal, creatorID: author, creatorName: "不能强归类")
            try library.recordListening([p, PlayStatRow(workID: collection, dateKey: "2026-10-10", hourSlot: 8, seconds: 20), mixed], sessions: [history, mixedSession])
            h.expectEqual(try library.listeningRows(period: .all, libraryKind: .personal).map(\.seconds), [30], "个人秒数")
            h.expectEqual(try library.listeningRows(period: .all, libraryKind: .collection).map(\.seconds), [20], "社团秒数")
            h.expectEqual(StatsAggregator.summary(try library.listeningRows(period: .all)).totalSeconds, 57, "合并总时长包含混合摘选但不重复")
            h.expectEqual(try library.listeningMonthKeys(libraryKind: .personal), ["2026-11"], "库内月份")
            h.expectEqual(try library.listeningMonthKeys(libraryKind: .collection), ["2026-10"], "另一库月份")
            h.expectEqual(try library.listeningHistory(period: .all, limit: 10, libraryKind: .personal).map(\.id), [history.id], "个人会话筛选")
            let unknown = try library.listeningRows(period: .all).first { $0.workID == 0 }!
            h.expectNil(unknown.libraryKind, "混合来源不归库")
            h.expectNil(unknown.creatorID, "混合来源不归作者")
            var creator = try library.creator(id: author)!
            creator.name = "改名作者"
            try library.saveCreator(creator)
            let beforeDelete = try library.listeningRows(period: .all, libraryKind: .personal)
            h.expectEqual(beforeDelete.first?.creatorName, "改名作者", "历史随作者资料显示最新名字")
            h.expectEqual(beforeDelete.first?.circleName, "改名作者", "合并统计映射社团维度")
            h.expectEqual(beforeDelete.first?.seiyuuNames, ["改名作者"], "合并统计映射声优维度")
            try library.deleteWork(id: personal)
            h.expectEqual(try library.listeningRows(period: .all, libraryKind: .personal), beforeDelete, "作品删除后统计身份与作者快照保留")
            h.expectEqual(try library.listeningHistory(period: .all, limit: 10, libraryKind: .personal).first?.creatorName, "改名作者", "删后明细归属保留")
            try library.recordListening([p], sessions: [history])
            h.expectEqual(try library.listeningRows(period: .all, libraryKind: .personal).first?.seconds, 60, "迟到结算仍累加")
            h.expectEqual(try library.listeningRows(period: .all, libraryKind: .personal).first?.creatorName, "改名作者", "迟到结算不盖回旧作者名")
            var invalid = p
            invalid.hourSlot = 25
            try rejects(db) { try library.recordListening([p, invalid], sessions: [history]) }
        }
    }
}
