import Foundation
import HibikiCore

/// 数据库与扫描器的测试套件
func runDatabaseSuites(_ h: Harness) {

    func makeRepo() throws -> LibraryRepository {
        let db = try SQLiteDatabase.inMemory()
        let repo = LibraryRepository(database: db)
        try repo.prepare()
        return repo
    }

    func file(_ rel: String, size: Int64 = 2_000_000) -> ScannedFile {
        ScannedFile(
            relativePath: rel,
            absolutePath: "/root/" + rel,
            size: size,
            modified: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // ─────────────────────────────────────────────────────────
    h.suite("数据库迁移") {
        h.test("首次建库并写版本号") {
            let db = try! SQLiteDatabase.inMemory()
            let applied = try! db.migrate(Schema.migrations)
            h.expectEqual(applied, Schema.migrations.count, "应用了全部迁移")
            h.expectEqual(db.userVersion, Schema.currentVersion, "user_version")
        }
        h.test("重复迁移不会重复执行") {
            let db = try! SQLiteDatabase.inMemory()
            _ = try! db.migrate(Schema.migrations)
            let second = try! db.migrate(Schema.migrations)
            h.expectEqual(second, 0, "第二次应无变化")
        }
        h.test("v22 音轨与同编号视频独立保存、去重和移除") {
            let db = try! SQLiteDatabase.inMemory()
            _ = try! db.migrate(Schema.migrations.filter { $0.version <= 22 })
            let library = LibraryRepository(database: db)
            let lists = PlaylistRepository(database: db)
            let source = try! library.saveSource(LibrarySource(name: "视频来源"))
            let work = try! library.upsertWork(WorkRecord(title: "混合作品", folderPath: "/work", sourceID: source))
            try! library.replaceTracks(workID: work, tracks: [
                TrackRecord(workID: work, fileName: "a.wav", filePath: "/work/a.wav", fileType: "wav")
            ])
            let id = try! library.tracks(workID: work)[0].id
            try! db.execute("INSERT INTO work_attachment(id, work_id, relative_path, kind, byte_count, sort_order) VALUES (?, ?, 'a.mp4', 'video', 512, 1)", [.integer(id), .integer(work)])
            try! lists.addWholeTrack(trackID: id, title: "旧音轨", workTitle: "旧作品")
            let oldEntries = try! lists.entries()
            _ = try! db.migrate(Schema.migrations)
            h.expectEqual(try! lists.entries(), oldEntries, "原有条目读出一致")
            let group = try! lists.createCollection(.playlists, name: "视频")
            try! lists.addVideo(attachmentID: id, title: "a.mp4", workTitle: "混合作品")
            try! lists.addVideo(attachmentID: id, title: "a.mp4", workTitle: "混合作品", groupID: group)
            try! lists.addVideo(attachmentID: id, title: "a.mp4", workTitle: "混合作品", groupID: group)
            h.expectEqual(try! lists.entries().count, 3, "每个分组内只加入一次")
            try! lists.deleteCollection(.playlists, id: group)
            let merged = try! lists.entries()
            h.expectEqual(merged.compactMap(\.wholeMediaID), [.track(id), .attachment(id)], "同编号源仍能区分")
            h.expectEqual(merged.last?.workID, work, "视频使用原作品身份")
            _ = try! library.removeMedia(workID: work, id: .attachment(id))
            h.expectEqual(try! lists.entries(), oldEntries, "删除原视频仅清理其列表项")
        }
        h.test("表都建出来了") {
            let repo = try! makeRepo()
            h.expectEqual(try! repo.counts().works, 0, "work 表存在")
            h.expectEqual(try! repo.sources().count, 0, "source 表存在")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("作品手动资料与独立曲目") {
        h.test("v8 升级、多人声优与封面经重扫和重启仍保留，留空也是有效修改") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("library.db").path
            let db = try! SQLiteDatabase(path: path)
            _ = try! db.migrate(Schema.migrations.filter { $0.version <= 8 })
            let repo = LibraryRepository(database: db)
            let sid = try! repo.saveSource(LibrarySource(name: "s"))
            let scan = WorkRecord(title: "作品", circleName: "扫描社团", seiyuuName: "旧声优",
                                  coverPath: "cover.png", folderPath: "/old/w", folderRelativePath: "w", sourceID: sid)
            let wid = try! repo.upsertWork(scan)
            h.expectEqual(try! repo.work(id: wid)?.seiyuuNames, ["旧声优"], "旧名字无需重新导入")
            h.expectEqual(try! repo.prepare(), Schema.currentVersion - 8, "v8 只执行新增迁移")
            try! repo.updateWorkMetadata(workID: wid, circleName: " 手填社团 ", seiyuuNames: ["甲", " 乙 ", ""])
            try! repo.updateWorkCover(workID: wid, assetRelativePath: "Covers/new.jpg")
            _ = try! repo.upsertWork(scan)
            let edited = try! repo.work(id: wid)!
            h.expectEqual(edited.circleName, "手填社团", "扫描不会覆盖社团")
            h.expectEqual(edited.seiyuuNames, ["甲", "乙"], "多人分别保存")
            h.expectEqual(edited.coverAssetPath, "Covers/new.jpg", "自选封面保留")
            h.expectEqual(edited.coverPath, "cover.png", "原封面仍可恢复")
            h.expectEqual(try! repo.works(searchText: "乙").map(\.id), [wid], "按第二位声优搜索")
            db.close()
            let reopened = try! SQLiteDatabase(path: path)
            let persisted = LibraryRepository(database: reopened)
            h.expectEqual(try! persisted.work(id: wid)?.seiyuuNames, ["甲", "乙"], "重启保留所有声优")
            try! persisted.updateWorkMetadata(workID: wid, circleName: "", seiyuuNames: [])
            _ = try! persisted.upsertWork(scan)
            h.expectEqual(try! persisted.work(id: wid)?.seiyuuNames, [], "清空后不恢复扫描资料")
            h.expectEqual(try! persisted.work(id: wid)?.circleName, "", "空社团不会回填")
            try! persisted.updateWorkCover(workID: wid, assetRelativePath: nil)
            h.expectNil(try! persisted.work(id: wid)?.coverAssetPath, "恢复原封面只清覆盖值")
        }
        h.test("追加保留旧字幕和排序，重扫与源目录消失不会删除独立曲目，失败整批回滚") {
            let db = try! SQLiteDatabase.inMemory()
            let repo = LibraryRepository(database: db)
            try! repo.prepare()
            let sid = try! repo.saveSource(LibrarySource(name: "s"))
            let wid = try! repo.upsertWork(WorkRecord(title: "w", folderPath: "/old/w", folderRelativePath: "w", sourceID: sid))
            func scanned(_ root: String) -> TrackRecord {
                TrackRecord(workID: wid, fileName: "same.wav", filePath: root + "/w/same.wav", relativePath: "same.wav", fileType: "wav")
            }
            func owned(_ relative: String) -> TrackRecord {
                TrackRecord(workID: wid, fileName: "same.wav", filePath: "/unused", fileType: "wav", durationMS: 1200, assetRelativePath: relative)
            }
            try! repo.replaceTracks(workID: wid, tracks: [scanned("/old")])
            let original = try! repo.tracks(workID: wid)[0].id
            let subs = SubtitleRepository(database: db)
            _ = try! subs.createTrack(trackID: original, kind: .manual, language: nil, label: "手改",
                                      cues: [SubtitleCue(startMS: 0, endMS: 1000, text: "保留")])
            let a = owned("Audio/a.wav"), b = owned("Audio/b.wav")
            try! repo.appendOwnedTracks(workID: wid, tracks: [a, b])
            let ids = try! repo.tracks(workID: wid).map(\.id)
            h.expectEqual(ids.count, 3, "同名音频按独立副本追加")
            try! repo.setTrackOrder(workID: wid, orderedTrackIDs: Array(ids.reversed()))
            try! repo.replaceTracks(workID: wid, tracks: [scanned("/new")])
            h.expectEqual(try! repo.tracks(workID: wid).map(\.id), Array(ids.reversed()), "重扫仍保留手动顺序与编号")
            h.expectEqual(try! subs.activeCues(trackID: original).first?.text, "保留", "旧字幕仍在")
            do {
                try repo.appendOwnedTracks(workID: wid, tracks: [owned("Audio/c.wav"), a])
                h.expect(false, "同一副本重复登记应失败")
            } catch {
                h.expectEqual(try! repo.tracks(workID: wid).count, 3, "此前批内新条目也回滚")
            }
            h.expectEqual(try! repo.deleteWorks(sourceID: sid, notInFolderPaths: []), 0, "有独立曲目的作品保留")
            h.expectEqual(try! repo.tracks(workID: wid).count, 2, "只清理消失目录里的原曲")
            h.expectEqual(try! repo.work(id: wid)?.totalDurationMS, 2400, "独立曲目参与统计")
        }
        h.test("自选文件用当前容器寻址并拒绝越出目录") {
            h.expectEqual(LibraryPathResolver.assetPath(relative: "Audio/a.wav", assetsRoot: "/new/Library/Application Support/WorkAssets"),
                          "/new/Library/Application Support/WorkAssets/Audio/a.wav", "不依赖原源目录或旧容器")
            for bad in ["", "../a.wav", "/old/a.wav", "Audio/../a.wav", "Audio//a.wav"] {
                h.expectNil(LibraryPathResolver.assetPath(relative: bad, assetsRoot: "/assets"), "拒绝非法路径")
            }
        }
    }

    h.suite("作品编辑整体保存与分组整理") {
        h.test("v9 升级后改名和内置分组更名跨重扫重开保留，搜索排序使用新名") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("metadata.db").path
            let db = try! SQLiteDatabase(path: path)
            _ = try! db.migrate(Schema.migrations.filter { $0.version <= 9 })
            let repo = LibraryRepository(database: db)
            let sid = try! repo.saveSource(LibrarySource(name: "source"))
            let scan = WorkRecord(title: "Z original", circleName: "扫描社团", coverPath: "original.png",
                                  folderPath: "/old/w", folderRelativePath: "w", sourceID: sid)
            let wid = try! repo.upsertWork(scan)
            try! repo.updateWorkCover(workID: wid, assetRelativePath: "Covers/old.jpg")
            h.expectEqual(try! repo.prepare(), Schema.currentVersion - 9, "v9 只执行后续迁移")
            h.expectEqual(try! repo.work(id: wid)?.title, "Z original", "升级不改变旧标题")
            h.expectEqual(try! repo.work(id: wid)?.coverAssetPath, "Covers/old.jpg", "升级保留自选封面")
            let second = try! repo.upsertWork(WorkRecord(title: "B other", folderPath: "/old/b", folderRelativePath: "b", sourceID: sid))
            try! repo.updateWorkMetadata(workID: wid, title: " A renamed ", circleName: "社团", seiyuuNames: ["甲", "乙"],
                                         cover: .replace(assetRelativePath: "Covers/new.jpg"))
            try! repo.renameCategory(workID: wid, key: "main", title: " 正片 ")
            _ = try! repo.upsertWork(scan)
            h.expectEqual(try! repo.work(id: wid)?.title, "A renamed", "重扫保留手填名")
            h.expectEqual(try! repo.works(sort: .title).map(\.id), [wid, second], "名称排序使用手填名")
            h.expectEqual(try! repo.works(searchText: "renamed").map(\.id), [wid], "可按手填名搜索")
            h.expectEqual(try! repo.works(searchText: "original").count, 0, "旧名不冒充当前名参与搜索")
            h.expectEqual(try! repo.categories(workID: wid).first { $0.key == "main" }?.title, "正片", "重扫保留内置分组名称")
            h.expectEqual(try! db.query("SELECT title FROM work WHERE id = ?", [.integer(wid)]).first?.string("title"),
                          "Z original", "扫描原名独立保留")
            db.close()
            let reopened = try! SQLiteDatabase(path: path)
            let persisted = LibraryRepository(database: reopened)
            h.expectEqual(try! persisted.work(id: wid)?.title, "A renamed", "重启保留改名")
            h.expectEqual(try! persisted.categories(workID: wid).first { $0.key == "main" }?.title, "正片", "重启保留分组名")
            h.expectEqual(try! persisted.work(id: wid)?.coverAssetPath, "Covers/new.jpg", "重启保留同步保存的封面")
            try! persisted.updateWorkMetadata(workID: wid, title: "A renamed", circleName: "社团", seiyuuNames: ["甲"], cover: .restoreOriginal)
            h.expectNil(try! persisted.work(id: wid)?.coverAssetPath, "恢复原图清除覆盖值")
            h.expectEqual(try! persisted.work(id: wid)?.coverPath, "original.png", "原图位置保留")
        }

        h.test("空名称及封面保存失败均不部分保存作品资料") {
            let db = try! SQLiteDatabase.inMemory()
            let repo = LibraryRepository(database: db)
            try! repo.prepare()
            let sid = try! repo.saveSource(LibrarySource(name: "s"))
            let wid = try! repo.upsertWork(WorkRecord(title: "原名", circleName: "原社团", folderPath: "/w", sourceID: sid))
            do {
                try repo.updateWorkMetadata(workID: wid, title: " \n ", circleName: "不可保存", seiyuuNames: ["新"])
                h.expect(false, "空名称应失败")
            } catch { h.expectEqual(try! repo.work(id: wid)?.circleName, "原社团", "验证失败未写入社团") }
            try! db.executeScript("""
                CREATE TRIGGER reject_cover BEFORE UPDATE OF cover_asset_path ON work
                WHEN NEW.cover_asset_path = 'Covers/reject.jpg' BEGIN SELECT RAISE(ABORT, 'cover failure'); END;
                """)
            do {
                try repo.updateWorkMetadata(workID: wid, title: "新名", circleName: "新社团", seiyuuNames: ["新"],
                                             cover: .replace(assetRelativePath: "Covers/reject.jpg"))
                h.expect(false, "封面更新失败应抛错")
            } catch {
                let unchanged = try! repo.work(id: wid)!
                h.expectEqual(unchanged.title, "原名", "失败保留标题")
                h.expectEqual(unchanged.circleName, "原社团", "失败保留社团")
                h.expectEqual(unchanged.seiyuuNames, [], "失败保留声优")
                h.expectNil(unchanged.coverAssetPath, "失败保留原封面")
            }
        }

        h.test("跨组到空组和组内排序原子保存，失败和过期快照不部分修改") {
            let db = try! SQLiteDatabase.inMemory()
            let repo = LibraryRepository(database: db)
            try! repo.prepare()
            let sid = try! repo.saveSource(LibrarySource(name: "s"))
            let scan = WorkRecord(title: "w", folderPath: "/w", folderRelativePath: "w", sourceID: sid)
            let wid = try! repo.upsertWork(scan)
            let scanned = ["a", "b", "c"].map {
                TrackRecord(workID: wid, fileName: $0 + ".wav", filePath: "/w/" + $0 + ".wav", relativePath: $0 + ".wav", fileType: "wav")
            }
            try! repo.replaceTracks(workID: wid, tracks: scanned)
            let ids = try! repo.tracks(workID: wid).map(\.id)
            let empty = try! repo.addCustomCategory(workID: wid, title: "空组")
            try! repo.commitTrackMove(workID: wid, trackIDs: [ids[0]], toCategory: empty.key, orderedTrackIDs: [ids[1], ids[2], ids[0]])
            h.expectEqual(try! repo.tracksGrouped(workID: wid).first { $0.category.key == empty.key }?.tracks.map(\.id), [ids[0]], "可放入空分组")
            try! repo.commitTrackMove(workID: wid, trackIDs: [ids[2]], toCategory: "main", orderedTrackIDs: [ids[2], ids[1], ids[0]])
            h.expectEqual(try! repo.tracksGrouped(workID: wid).first { $0.category.key == "main" }?.tracks.map(\.id), [ids[2], ids[1]], "同组可调整顺序")
            _ = try! repo.upsertWork(scan)
            try! repo.replaceTracks(workID: wid, tracks: scanned)
            h.expectEqual(try! repo.tracks(workID: wid).map(\.id), [ids[2], ids[1], ids[0]], "重扫保留顺序")
            h.expectEqual(try! repo.track(id: ids[0])?.categoryOverride, empty.key, "重扫保留移动分组")
            for badOrder in [[ids[0]], [ids[0], ids[1], ids[1]], [ids[0], ids[1], 999_999]] {
                do {
                    try repo.commitTrackMove(workID: wid, trackIDs: [ids[0]], toCategory: "bonus", orderedTrackIDs: badOrder)
                    h.expect(false, "不完整或无效顺序应拒绝")
                } catch { h.expectEqual(try! repo.track(id: ids[0])?.categoryOverride, empty.key, "拒绝前未改分组") }
            }
            do {
                try repo.commitTrackMove(workID: wid, trackIDs: [ids[0]], toCategory: "missing", orderedTrackIDs: ids)
                h.expect(false, "无效分组应拒绝")
            } catch { h.expectEqual(try! repo.track(id: ids[0])?.categoryOverride, empty.key, "拒绝无效分组") }
            try! db.executeScript("""
                CREATE TRIGGER reject_reorder BEFORE UPDATE OF sort_order ON track
                WHEN NEW.id = \(ids[1]) BEGIN SELECT RAISE(ABORT, 'order failure'); END;
                """)
            do {
                try repo.commitTrackMove(workID: wid, trackIDs: [ids[0]], toCategory: "bonus", orderedTrackIDs: ids)
                h.expect(false, "中途排序写入失败应抛错")
            } catch {
                h.expectEqual(try! repo.track(id: ids[0])?.categoryOverride, empty.key, "排序失败回滚分组变更")
                h.expectEqual(try! repo.tracks(workID: wid).map(\.id), [ids[2], ids[1], ids[0]], "排序失败回滚已写入的顺序")
            }
        }
    }

    h.suite("收藏夹与列表分类管理") {
        h.test("从 v10 迁移星标，收藏可入多个分类并跨重开保留排序") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appendingPathComponent("favorites.sqlite").path
            let db = try! SQLiteDatabase(path: path)
            _ = try! db.migrate(Schema.migrations.filter { $0.version <= 10 })
            let repo = LibraryRepository(database: db)
            let source = try! repo.saveSource(LibrarySource(name: "s"))
            let wid = try! repo.upsertWork(WorkRecord(title: "w", folderPath: "/w", sourceID: source))
            try! repo.setFavorite(true, workID: wid)
            try! repo.prepare()
            let lists = PlaylistRepository(database: db)
            h.expectEqual(try! lists.favoriteMemberships()[wid], [1], "原有星标进入默认收藏")
            let a = try! lists.createCollection(.favorites, name: " 夜读 ")
            let b = try! lists.createCollection(.favorites, name: "休息")
            try! lists.setFavoriteGroups(workID: wid, groupIDs: [a, b])
            h.expectEqual(try! lists.favoriteMemberships()[wid], [a, b], "一部作品可入多个分类")
            h.expectEqual(try! repo.works(filter: .favorite).map(\.id), [wid], "收藏筛选仍读到同一作品")
            try! lists.renameCollection(.favorites, id: a, name: "有声读物")
            try! lists.orderCollections(.favorites, ids: [b, 1, a])
            do { try lists.renameCollection(.favorites, id: a, name: "休息"); h.expect(false, "同名应拒绝") }
            catch { h.expectEqual(try! lists.collections(.favorites).last?.name, "有声读物", "冲突不会覆写") }
            do { try lists.setFavoriteGroups(workID: wid, groupIDs: [99]); h.expect(false, "无效分类应拒绝") }
            catch { h.expectEqual(try! lists.favoriteMemberships()[wid], [a, b], "失败不会改变收藏") }
            let reopened = PlaylistRepository(database: try! SQLiteDatabase(path: path))
            h.expectEqual(try! reopened.collections(.favorites).map(\.id), [b, 1, a], "重开后排序正确")
            try! reopened.deleteCollection(.favorites, id: a)
            h.expectEqual(try! reopened.favoriteMemberships()[wid], [1, b], "删收藏夹后作品保留")
            try! repo.setFavorite(false, workID: wid)
            h.expectNil(try! reopened.favoriteMemberships()[wid], "旧取消收藏入口同步归属")
            try! repo.setFavorite(true, workID: wid)
            h.expectEqual(try! reopened.favoriteMemberships()[wid], [1], "旧添加收藏入口同步归属")
            try! lists.setFavoriteGroups(workID: wid, groupIDs: [])
            h.expectEqual(try! repo.work(id: wid)?.favorite, false, "取消所有分类会取消整部收藏")
        }
        h.test("删列表转入默认组并保留每个独立 CAF；三类可分别排序、改名") {
            let db = try! SQLiteDatabase.inMemory()
            let library = LibraryRepository(database: db)
            try! library.prepare()
            let lists = PlaylistRepository(database: db)
            let source = try! library.saveSource(LibrarySource(name: "s"))
            let wid = try! library.upsertWork(WorkRecord(title: "w", folderPath: "/w", sourceID: source))
            try! library.replaceTracks(workID: wid, tracks: [
                TrackRecord(workID: wid, fileName: "t.wav", filePath: "/w/t.wav", fileType: "wav"),
                TrackRecord(workID: wid, fileName: "b.wav", filePath: "/w/b.wav", fileType: "wav")
            ])
            let tracks = try! library.tracks(workID: wid)
            let a = try! lists.createCollection(.playlists, name: "自建")
            let b = try! lists.createCollection(.clips, name: "自建")
            try! lists.orderCollections(.playlists, ids: [a, 1])
            try! lists.orderCollections(.clips, ids: [b, 2])
            try! lists.renameCollection(.clips, id: b, name: "精选")
            h.expectEqual(try! lists.collections(.clips).map(\.name), ["精选", "默认摘选"], "改名不改顺序")
            h.expectEqual(try! lists.collections(.playlists).map(\.id), [a, 1], "不同类型独立排序")
            do { try lists.orderCollections(.clips, ids: [b, b]); h.expect(false, "重复排序应拒绝") }
            catch { h.expectEqual(try! lists.collections(.clips).map(\.id), [b, 2], "拒绝过期排序") }
            do { try lists.deleteCollection(.clips, id: 2); h.expect(false, "默认组应保留") }
            catch { h.expectEqual(try! lists.collections(.clips).count, 2, "保留默认组") }
            let t = tracks[0].id
            try! lists.addWholeTrack(trackID: t, title: "t", workTitle: "w")
            try! lists.addWholeTrack(trackID: t, title: "t", workTitle: "w", groupID: a)
            try! lists.addWholeTrack(trackID: tracks[1].id, title: "b", workTitle: "w", groupID: a)
            try! lists.addClip(trackID: t, title: "a", workTitle: "w", startMS: 1, endMS: 100, filename: "a.caf")
            try! lists.addClip(trackID: t, title: "b", workTitle: "w", startMS: 1, endMS: 100, filename: "b.caf", groupID: b)
            try! lists.addMerged(title: "m", workTitle: "w", coverWorkID: wid, durationMS: 99, filename: "m.caf", groupID: b)
            let before = try! lists.entries().filter(\.isClip)
            try! lists.deleteCollection(.playlists, id: a)
            try! lists.deleteCollection(.clips, id: b)
            let after = try! lists.entries()
            h.expectEqual(after.filter { !$0.isClip }.map(\.trackID), [t, tracks[1].id], "整曲引用移入默认，同一原曲去重")
            h.expectEqual(after.filter(\.isClip).map(\.id), before.map(\.id), "每个摘选包括重复范围、拼接均沿用原编号")
            h.expectEqual(after.compactMap(\.clipFilename), ["a.caf", "b.caf", "m.caf"], "独立音频全部保留")
            h.expect(after.filter(\.isClip).allSatisfy { $0.groupID == 2 }, "删除分类后均可在默认摘选找到")
            h.expect(!(try! lists.addClip(trackID: t, title: "a", workTitle: "w", startMS: 1, endMS: 100, filename: "c.caf")),
                     "日常保存仍阻止同组重复范围")
        }
    }

    h.suite("播放列表") {
        h.test("v7 播放列表迁移保留音频、编号及失效原曲；支持多个收藏夹和合并") {
            let db = try! SQLiteDatabase.inMemory()
            _ = try! db.migrate(Schema.migrations.filter { $0.version <= 7 })
            let library = LibraryRepository(database: db)
            let source = try! library.saveSource(LibrarySource(name: "s"))
            let wid = try! library.upsertWork(WorkRecord(title: "w", folderPath: "/w", sourceID: source))
            try! library.replaceTracks(workID: wid, tracks: [
                TrackRecord(workID: wid, fileName: "a.wav", filePath: "/w/a.wav", fileType: "wav")
            ])
            let track = try! library.tracks(workID: wid)[0].id
            try! db.execute("""
                INSERT INTO playlist_entry (id, track_id, title, work_title, created_at)
                VALUES (11, ?, 'A', 'w', 123456)
                """, [.integer(track)])
            try! db.executeScript("""
                INSERT INTO playlist_entry (id, track_id, title, work_title, start_ms, end_ms, clip_filename, created_at)
                VALUES (19, NULL, '已移走', 'w', 200, 600, '旧文件.caf', 234567)
                """)
            h.expectEqual(try! library.prepare(), Schema.currentVersion - 7, "从 7 执行后续迁移")
            let lists = PlaylistRepository(database: db)
            let groups = try! lists.groups()
            let old = try! lists.entries()
            h.expectEqual(groups.map(\.isClips), [false, true], "两个默认组")
            h.expectEqual(old.map(\.id), [11, 19], "旧编号不变")
            h.expectEqual(old.map(\.groupID), groups.map(\.id), "旧条目各归其类")
            h.expectEqual(old[1].clipFilename, "旧文件.caf", "导出的文件无需重命名")
            h.expectEqual(old[1].endMS, 600, "旧摘选时间保留")
            h.expectEqual(old[1].createdAt, Date(timeIntervalSince1970: 234.567), "创建时间保留")
            h.expectNil(old[1].trackID, "独立音频可已无原曲")
            let songs = try! lists.createGroup(name: "晚安", isClips: false)
            let clips = try! lists.createGroup(name: "晚安", isClips: true)
            h.expectEqual(try! lists.createGroup(name: " 晚安 ", isClips: true), clips, "同类同名建组幂等")
            h.expect(songs != clips, "不同类型可同名")
            for _ in 0..<2 {
                try! lists.addWholeTrack(trackID: track, title: "A", workTitle: "w", groupID: songs)
            }
            h.expectEqual(try! lists.entries().filter { !$0.isClip }.count, 2, "整曲在两组各一份")
            h.expect(try! lists.addClip(trackID: track, title: "A", workTitle: "w", startMS: 1, endMS: 5,
                                        filename: "c1.caf"), "默认组保存")
            h.expect(try! lists.addClip(trackID: track, title: "A", workTitle: "w", startMS: 1, endMS: 5,
                                        filename: "c2.caf", groupID: clips), "相同摘选可进另一组")
            h.expect(!(try! lists.addClip(trackID: track, title: "A", workTitle: "w", startMS: 1, endMS: 5,
                                         filename: "unused.caf", groupID: clips)), "另一个组内同样去重")
            do {
                try lists.addWholeTrack(trackID: track, title: "A", workTitle: "w", groupID: clips)
                h.expect(false, "不得把整曲放进摘选组")
            } catch { h.expect(error is PlaylistCollectionError, "组类型检查") }
            try! lists.addMerged(title: "合集", workTitle: "w", coverWorkID: wid, durationMS: 1040,
                                 filename: "合并.caf", groupID: clips)
            let merged = try! lists.entries().last!
            h.expect(merged.isMerged && merged.isClip, "合并结果属于摘选")
            h.expectEqual(merged.mergedMS, 1040, "保留合并后的独立时长")
            h.expect(merged.startMS == nil && merged.endMS == nil && merged.trackID == nil, "没有捏造来源区间")
            h.expectEqual(merged.workID, wid, "作品仍在时可找封面")
            try! library.deleteWork(id: wid)
            let detached = try! lists.entries().last!
            h.expect(detached.clipFilename == "合并.caf" && detached.workID == nil, "删除作品后独立音频仍然保留")
        }
        h.test("改作品名更新整曲和摘选，跨作品合并保留自己的来源说明") {
            let db = try! SQLiteDatabase.inMemory()
            let library = LibraryRepository(database: db)
            try! library.prepare()
            let source = try! library.saveSource(LibrarySource(name: "s"))
            let work = try! library.upsertWork(WorkRecord(title: "扫描名", folderPath: "/w", sourceID: source))
            try! library.replaceTracks(workID: work, tracks: [
                TrackRecord(workID: work, fileName: "1.wav", filePath: "/w/1.wav", fileType: "wav")
            ])
            let track = try! library.tracks(workID: work)[0].id
            let lists = PlaylistRepository(database: db)
            try! lists.addWholeTrack(trackID: track, title: "一", workTitle: "创建时的名字")
            try! lists.addClip(trackID: track, title: "一", workTitle: "创建时的名字",
                               startMS: 100, endMS: 900, filename: "单曲摘选.caf")
            try! lists.addMerged(title: "合并", workTitle: "多部作品", coverWorkID: work,
                                 durationMS: 1234, filename: "合集.caf", groupID: 2)
            let before = try! lists.entries()
            h.expectEqual(before.map(\.workTitle), ["扫描名", "扫描名", "多部作品"], "只按原曲解析作品名")
            try! library.updateWorkMetadata(workID: work, title: "新名称", circleName: "", seiyuuNames: [])
            let after = try! lists.entries()
            h.expectEqual(after.map(\.workTitle), ["新名称", "新名称", "多部作品"], "整曲和单曲摘选跟随改名")
            h.expectEqual(after.map(\.id), before.map(\.id), "改名不会重建列表条目")
            h.expectEqual(after.compactMap(\.clipFilename), ["单曲摘选.caf", "合集.caf"], "保留对应音频文件")
            try! library.deleteWork(id: work)
            h.expectEqual(try! lists.entries().map(\.workTitle), after.map(\.workTitle), "移除原曲保留最后作品名")
        }
        h.test("从旧库升级、重复保存、重开，以及删除原曲") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("library.db").path
            let db = try! SQLiteDatabase(path: path)
            _ = try! db.migrate(Schema.migrations.filter { $0.version <= 6 })
            let library = LibraryRepository(database: db)
            let source = try! library.saveSource(LibrarySource(name: "s"))
            let work = try! library.upsertWork(WorkRecord(title: "作品", folderPath: "/w", sourceID: source))
            try! library.replaceTracks(workID: work, tracks: [
                TrackRecord(workID: work, fileName: "01.wav", filePath: "/w/01.wav", fileType: "wav")
            ])
            let track = try! library.tracks(workID: work)[0].id
            let subtitles = SubtitleRepository(database: db)
            // 用当时的表结构写入，模拟真正由旧版建立的资料库。
            try! db.execute("INSERT INTO subtitle_track (id, track_id, kind, label, is_active, created_at) VALUES (1, ?, 'sidecar', '字幕', 1, 0)", [.integer(track)])
            try! db.execute("INSERT INTO subtitle_version (id, subtitle_track_id, version_no, is_baseline, cue_count, created_at) VALUES (1, 1, 1, 1, 1, 0)")
            try! db.execute("INSERT INTO subtitle_cue (version_id, cue_index, start_ms, end_ms, source_text) VALUES (1, 0, 0, 500, '旧字幕')")
            h.expectEqual(try! library.prepare(), Schema.currentVersion - 6, "只执行新迁移")
            h.expectEqual(try! subtitles.activeCues(trackID: track).first?.text, "旧字幕", "旧库字幕保留")
            let playlist = PlaylistRepository(database: db)
            for _ in 0..<2 {
                try! playlist.addWholeTrack(trackID: track, title: "第一轨", workTitle: "作品")
            }
            func addClip(_ start: Int, _ name: String) -> Bool {
                try! playlist.addClip(trackID: track, title: "第一轨", workTitle: "作品",
                                      startMS: start, endMS: start + 1000, filename: name)
            }
            h.expect(addClip(0, "a.caf"), "已保存片段")
            h.expect(!addClip(0, "retry.caf"), "重复范围不会新增")
            h.expect(addClip(1000, "b.caf"), "同曲可有第二个片段")
            h.expectEqual(try! playlist.entries().count, 3, "一首整曲及两个片段")

            db.close()
            let reopened = try! SQLiteDatabase(path: path)
            h.expectEqual(try! LibraryRepository(database: reopened).prepare(), 0, "重开无需迁移")
            let saved = PlaylistRepository(database: reopened)
            let rows = try! saved.entries()
            h.expectEqual(rows.map(\.trackID), [track, track, track], "重启保留原曲关联")
            try! LibraryRepository(database: reopened).deleteWork(id: work)
            let detached = try! saved.entries()
            h.expect(detached.allSatisfy { $0.trackID == nil }, "原曲已移除")
            h.expectEqual(detached.compactMap(\.clipFilename), ["a.caf", "b.caf"], "独立片段仍可寻址")
            h.expectEqual(detached.map(\.workTitle), ["作品", "作品", "作品"], "删除作品保留标题")
            try! saved.remove(id: rows[0].id)
            try! saved.remove(id: rows[0].id)
            h.expectEqual(try! saved.entries().count, 2, "失效整曲可单独移除")
        }
    }

    h.suite("存储源读写") {
        h.test("新增并读回") {
            let repo = try! makeRepo()
            let bookmark = Data([0x01, 0x02, 0x03, 0xFF])
            let id = try! repo.saveSource(
                LibrarySource(name: "我的音乐", type: .local, rootPath: "/music", bookmark: bookmark)
            )
            h.expect(id > 0, "返回 id")
            let list = try! repo.sources()
            h.expectEqual(list.count, 1, "一条")
            h.expectEqual(list[0].name, "我的音乐", "名称")
            h.expectEqual(list[0].type, .local, "类型")
            h.expectEqual(list[0].bookmark, bookmark, "bookmark 二进制往返一致")
        }
        h.test("更新已有源") {
            let repo = try! makeRepo()
            var src = LibrarySource(name: "旧名", rootPath: "/a")
            src.id = try! repo.saveSource(src)
            src.name = "新名"
            _ = try! repo.saveSource(src)
            h.expectEqual(try! repo.sources()[0].name, "新名", "已更新")
            h.expectEqual(try! repo.sources().count, 1, "没新增")
        }
        h.test("删除源级联删作品") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            _ = try! repo.upsertWork(WorkRecord(title: "作品", folderPath: "/m/w", folderRelativePath: "w", sourceID: sid))
            h.expectEqual(try! repo.counts().works, 1, "有一个作品")
            try! repo.deleteSource(id: sid)
            h.expectEqual(try! repo.counts().works, 0, "级联删除")
        }
        h.test("禁用源不出现在默认列表") {
            let repo = try! makeRepo()
            _ = try! repo.saveSource(LibrarySource(name: "a", enabled: false))
            h.expectEqual(try! repo.sources().count, 0, "默认不返回")
            h.expectEqual(try! repo.sources(includeDisabled: true).count, 1, "显式要求时返回")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("作品读写") {
        h.test("新增作品") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let id = try! repo.upsertWork(
                WorkRecord(title: "素敵な作品", rjCode: "RJ01234567",
                           circleName: "社团", seiyuuName: "花子",
                           folderPath: "/m/作品", folderRelativePath: "作品", sourceID: sid)
            )
            h.expect(id > 0, "返回 id")
            let work = try! repo.work(id: id)
            h.expectEqual(work?.title, "素敵な作品", "标题")
            h.expectEqual(work?.rjCode, "RJ01234567", "RJ")
            h.expectEqual(work?.seiyuuName, "花子", "声优")
        }
        h.test("同目录重复扫描不会产生重复作品") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let spec = WorkRecord(title: "作品", folderPath: "/m/w", folderRelativePath: "w", sourceID: sid)
            let a = try! repo.upsertWork(spec)
            let b = try! repo.upsertWork(spec)
            h.expectEqual(a, b, "返回同一个 id")
            h.expectEqual(try! repo.counts().works, 1, "只有一条")
        }
        h.test("重复扫描会更新标题") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            var spec = WorkRecord(title: "旧标题", folderPath: "/m/w", folderRelativePath: "w", sourceID: sid)
            let id = try! repo.upsertWork(spec)
            spec.title = "新标题"
            _ = try! repo.upsertWork(spec)
            h.expectEqual(try! repo.work(id: id)?.title, "新标题", "标题已更新")
        }
        h.test("收藏/已听/评分") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let id = try! repo.upsertWork(WorkRecord(title: "w", folderPath: "/m/w", folderRelativePath: "w", sourceID: sid))
            try! repo.setFavorite(true, workID: id)
            try! repo.setListened(true, workID: id)
            try! repo.setRating(9, workID: id)
            let work = try! repo.work(id: id)
            h.expectEqual(work?.favorite, true, "收藏")
            h.expectEqual(work?.listened, true, "已听")
            h.expectEqual(work?.rating, 5, "评分被夹到 5")
        }
        h.test("断点续播") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let id = try! repo.upsertWork(WorkRecord(title: "w", folderPath: "/m/w", folderRelativePath: "w", sourceID: sid))
            try! repo.replaceTracks(workID: id, tracks: [
                TrackRecord(workID: id, fileName: "01.mp3", filePath: "/m/w/01.mp3", fileType: "mp3")
            ])
            let trackID = try! repo.tracks(workID: id)[0].id
            try! repo.savePlaybackPosition(workID: id, trackID: trackID, positionMS: 125_000)
            let work = try! repo.work(id: id)
            h.expectEqual(work?.lastPlayedTrackID, trackID, "记住曲目")
            h.expectEqual(work?.lastPlayedPositionMS, 125_000, "记住位置")
            h.expectEqual(work?.playCount, 1, "播放次数 +1")
        }
        h.test("排序：最近播放") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let a = try! repo.upsertWork(WorkRecord(title: "A", folderPath: "/m/a", folderRelativePath: "a", sourceID: sid))
            _ = try! repo.upsertWork(WorkRecord(title: "B", folderPath: "/m/b", folderRelativePath: "b", sourceID: sid))
            try! repo.replaceTracks(workID: a, tracks: [
                TrackRecord(workID: a, fileName: "1.mp3", filePath: "/m/a/1.mp3", fileType: "mp3")
            ])
            let t = try! repo.tracks(workID: a)[0].id
            try! repo.savePlaybackPosition(workID: a, trackID: t, positionMS: 1000)
            let sorted = try! repo.works(sort: .recentlyPlayed)
            h.expectEqual(sorted.first?.title, "A", "播放过的排前面")
        }
        h.test("筛选：收藏") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let a = try! repo.upsertWork(WorkRecord(title: "A", folderPath: "/m/a", folderRelativePath: "a", sourceID: sid))
            _ = try! repo.upsertWork(WorkRecord(title: "B", folderPath: "/m/b", folderRelativePath: "b", sourceID: sid))
            try! repo.setFavorite(true, workID: a)
            let favs = try! repo.works(filter: .favorite)
            h.expectEqual(favs.count, 1, "一条")
            h.expectEqual(favs[0].title, "A", "内容")
        }
        h.test("搜索标题/声优/社团/RJ") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            _ = try! repo.upsertWork(WorkRecord(title: "素敵な作品", rjCode: "RJ01234567",
                                                circleName: "サークル", seiyuuName: "花子",
                                                folderPath: "/m/a", folderRelativePath: "a", sourceID: sid))
            _ = try! repo.upsertWork(WorkRecord(title: "別の作品", folderPath: "/m/b", folderRelativePath: "b", sourceID: sid))
            h.expectEqual(try! repo.works(searchText: "素敵").count, 1, "按标题")
            h.expectEqual(try! repo.works(searchText: "花子").count, 1, "按声优")
            h.expectEqual(try! repo.works(searchText: "RJ0123").count, 1, "按 RJ")
            h.expectEqual(try! repo.works(searchText: "不存在").count, 0, "无结果")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("曲目读写") {
        h.test("整体替换并计入聚合") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let id = try! repo.upsertWork(WorkRecord(title: "w", folderPath: "/m/w", folderRelativePath: "w", sourceID: sid))
            try! repo.replaceTracks(workID: id, tracks: [
                TrackRecord(workID: id, fileName: "01.mp3", filePath: "/m/w/01.mp3", fileType: "mp3", durationMS: 60_000),
                TrackRecord(workID: id, fileName: "02.mp3", filePath: "/m/w/02.mp3", fileType: "mp3", durationMS: 90_000)
            ])
            let work = try! repo.work(id: id)
            h.expectEqual(work?.trackCount, 2, "曲目数")
            h.expectEqual(work?.totalDurationMS, 150_000, "总时长聚合")
        }
        h.test("重复替换不会累积") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let id = try! repo.upsertWork(WorkRecord(title: "w", folderPath: "/m/w", folderRelativePath: "w", sourceID: sid))
            let tracks = [TrackRecord(workID: id, fileName: "01.mp3", filePath: "/m/w/01.mp3", fileType: "mp3")]
            try! repo.replaceTracks(workID: id, tracks: tracks)
            try! repo.replaceTracks(workID: id, tracks: tracks)
            h.expectEqual(try! repo.tracks(workID: id).count, 1, "还是一条")
        }
        h.test("重扫：同名文件按目录区分，保留手改版本，删除消失的曲目") {
            let db = try! SQLiteDatabase.inMemory()
            let repo = LibraryRepository(database: db)
            try! repo.prepare()
            let subs = SubtitleRepository(database: db)
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/old"))
            let wid = try! repo.upsertWork(WorkRecord(title: "w", folderPath: "/old/w",
                                                      folderRelativePath: "w", sourceID: sid))
            func track(_ path: String, relative: String) -> TrackRecord {
                TrackRecord(workID: wid, fileName: "01.wav", filePath: path, relativePath: relative, fileType: "wav")
            }

            // 旧版曾把子目录漏掉，同作品不同文件可能都只存下「01.wav」。
            try! repo.replaceTracks(workID: wid, tracks: [
                track("/old/w/main/01.wav", relative: "01.wav"),
                track("/old/w/bonus/01.wav", relative: "01.wav")
            ])
            let old = try! repo.tracks(workID: wid)
            let saved = try! subs.createTrack(trackID: old[0].id, kind: .sidecar, language: "zh", label: "字幕",
                                              cues: [SubtitleCue(startMS: 0, endMS: 1200, text: "原版")])
            let edit = try! subs.insertVersion(subtitleTrackID: saved.track, note: "手改", isBaseline: false,
                                               cues: [SubtitleCue(startMS: 300, endMS: 900, text: "校订")])
            try! repo.replaceTracks(workID: wid, tracks: [
                track("/new/w/bonus/01.wav", relative: "bonus/01.wav"),
                track("/new/w/main/01.wav", relative: "main/01.wav")
            ])
            h.expectEqual(try! repo.track(id: old[0].id)?.filePath, "/new/w/main/01.wav", "同名文件没对调")
            h.expectEqual(try! repo.track(id: old[1].id)?.filePath, "/new/w/bonus/01.wav", "新的完整路径")
            h.expectEqual(try! subs.versions(subtitleTrackID: saved.track).map(\.id), [saved.version, edit], "两个版本完整")
            h.expectEqual(try! subs.activeCues(trackID: old[0].id).first?.text, "校订", "仍启用手改版本")
            try! repo.replaceTracks(workID: wid, tracks: [
                track("/new/w/main/01.wav", relative: "main/01.wav")
            ])
            h.expectNil(try! repo.track(id: old[1].id), "移走的曲目已删除")
            h.expectEqual(try! repo.tracks(workID: wid).map(\.id), [old[0].id], "保留原曲目编号")

            let duplicate = track("/new/w/main/01.wav", relative: "main/01.wav")
            do {
                try repo.replaceTracks(workID: wid, tracks: [duplicate, duplicate])
                h.expect(false, "重复路径应拒绝导入")
            } catch {
                h.expectEqual(try! repo.tracks(workID: wid).map(\.id), [old[0].id], "失败的重扫已回滚")
                h.expectEqual(try! subs.activeCues(trackID: old[0].id).first?.text, "校订", "失败不影响旧字幕")
            }
        }
        h.test("删除作品级联删曲目") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let id = try! repo.upsertWork(WorkRecord(title: "w", folderPath: "/m/w", folderRelativePath: "w", sourceID: sid))
            try! repo.replaceTracks(workID: id, tracks: [
                TrackRecord(workID: id, fileName: "01.mp3", filePath: "/m/w/01.mp3", fileType: "mp3")
            ])
            try! repo.deleteWork(id: id)
            h.expectEqual(try! repo.counts().tracks, 0, "曲目被级联删除")
        }
        h.test("增量同步：删除已消失的作品") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            _ = try! repo.upsertWork(WorkRecord(title: "A", folderPath: "/m/a", folderRelativePath: "a", sourceID: sid))
            _ = try! repo.upsertWork(WorkRecord(title: "B", folderPath: "/m/b", folderRelativePath: "b", sourceID: sid))
            let removed = try! repo.deleteWorks(sourceID: sid, notInFolderPaths: ["a"])
            h.expectEqual(removed, 1, "删掉 1 个")
            let left = try! repo.works(sourceID: sid)
            h.expectEqual(left.count, 1, "剩 1 个")
            h.expectEqual(left[0].title, "A", "留下的是 A")
        }
        h.test("空列表会清空全部") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            _ = try! repo.upsertWork(WorkRecord(title: "A", folderPath: "/m/a", folderRelativePath: "a", sourceID: sid))
            let removed = try! repo.deleteWorks(sourceID: sid, notInFolderPaths: [])
            h.expectEqual(removed, 1, "全删")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("设置项") {
        h.test("写入与读取") {
            let repo = try! makeRepo()
            try! repo.setSetting("subtitle_font_size", "28")
            h.expectEqual(try! repo.setting("subtitle_font_size"), "28", "读回")
        }
        h.test("重复写入覆盖") {
            let repo = try! makeRepo()
            try! repo.setSetting("k", "1")
            try! repo.setSetting("k", "2")
            h.expectEqual(try! repo.setting("k"), "2", "覆盖")
        }
        h.test("不存在返回 nil") {
            let repo = try! makeRepo()
            h.expectNil(try! repo.setting("nope"), "nil")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("扫描器") {
        h.test("整部作品的子目录保留在曲目路径里，并收集旁边的字幕") {
            let files = [file("wav/本編.wav"), file("字幕/本編.wav.vtt")]
            for grouping in [ScanOptions.Grouping.singleWork, .automatic] {
                let work = LibraryScanner.plan(files: files, sourceRoot: "/root",
                                               options: ScanOptions(grouping: grouping)).first
                h.expectEqual(work?.subtitlePaths, [files[1].absolutePath], "独立字幕目录")
                h.expectEqual(work?.tracks.first?.relativePath, grouping == .singleWork ? "wav/本編.wav" : "本編.wav", "相对作品而非源目录")
            }
        }
        h.test("多个作品各自只收集自己目录里的字幕") {
            let files = [file("A/01.mp3"), file("B/01.mp3"), file("B/字幕/01.srt")]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expectEqual(works.first?.subtitlePaths, [], "A 不使用 B 的字幕")
            h.expectEqual(works.last?.subtitlePaths, [files[2].absolutePath], "B 的字幕")
        }
        h.test("按目录分组作品") {
            let files = [
                file("作品A/01.mp3"),
                file("作品A/02.mp3"),
                file("作品B/01.mp3")
            ]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expectEqual(works.count, 2, "两个作品")
            h.expectEqual(works.first(where: { $0.folderRelativePath == "作品A" })?.tracks.count, 2, "A 两首")
        }
        h.test("曲目按文件名自然排序") {
            let files = (1...10).map { file("作品/\($0). 曲目.mp3") }
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expectEqual(works.count, 1, "一个作品")
            h.expectEqual(works[0].tracks.first?.fileName, "1. 曲目.mp3", "1 在最前")
            h.expectEqual(works[0].tracks.last?.fileName, "10. 曲目.mp3", "10 在最后")
        }
        h.test("按解析出的轨号排序") {
            let files = [file("作品/10.mp3"), file("作品/2.mp3"), file("作品/1.mp3")]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expectEqual(works[0].tracks.map(\.trackNumber), [1, 2, 10], "轨号顺序")
        }
        h.test("过滤太小的文件") {
            let files = [file("作品/01.mp3", size: 1000), file("作品/02.mp3", size: 5_000_000)]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expectEqual(works.count, 1, "一个作品")
            h.expectEqual(works[0].tracks.count, 1, "小文件被过滤")
        }
        h.test("排除目录") {
            let files = [file("作品/01.mp3"), file("作品/特典/01.mp3")]
            let options = ScanOptions(excludedFolderPrefixes: ["作品/特典"])
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root", options: options)
            h.expectEqual(works.count, 1, "只剩主目录")
            h.expectEqual(works[0].folderRelativePath, "作品", "路径")
        }
        h.test("非音频文件不参与") {
            let files = [file("作品/01.mp3"), file("作品/cover.jpg"), file("作品/readme.txt")]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expectEqual(works[0].tracks.count, 1, "只有音频算曲目")
        }
        h.test("封面挑选优先 cover") {
            let files = [
                file("作品/01.mp3"),
                file("作品/aaa.jpg"),
                file("作品/cover.jpg")
            ]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expect(works[0].coverPath?.contains("cover.jpg") == true, "选中 cover.jpg")
        }
        h.test("台本挑选") {
            let files = [
                file("作品/01.mp3"),
                file("作品/其他.pdf"),
                file("作品/台本.pdf")
            ]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expect(works[0].scriptPath?.contains("台本.pdf") == true, "选中台本.pdf")
        }
        h.test("txt 台本也能识别") {
            let files = [
                file("作品/01.mp3"),
                file("作品/cover.png"),
                file("作品/台本.txt")
            ]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expect(works[0].scriptPath?.contains("台本.txt") == true, "应识别 txt 台本，实际：\(String(describing: works[0].scriptPath))")
            h.expect(works[0].coverPath?.contains("cover.png") == true, "封面")
        }

        h.test("分类信息来自目录名") {
            let files = [file("[サークル名] 素敵な作品 RJ01234567/01.mp3")]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expectEqual(works[0].rjCode, "RJ01234567", "RJ")
            h.expectEqual(works[0].circleName, "サークル名", "社团")
            h.expectEqual(works[0].title, "素敵な作品", "标题")
        }
        h.test("空输入返回空") {
            h.expect(LibraryScanner.plan(files: [], sourceRoot: "/root").isEmpty, "空")
        }
        h.test("视频默认不收录") {
            let files = [file("作品/01.mkv"), file("作品/02.mp3")]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expectEqual(works[0].tracks.count, 1, "只有音频")
            let withVideo = LibraryScanner.plan(
                files: files, sourceRoot: "/root",
                options: ScanOptions(includeVideos: true)
            )
            h.expectEqual(withVideo[0].tracks.count, 2, "开启后收视频")
        }
        h.test("绝对路径拼接正确") {
            let files = [file("a/01.mp3")]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expectEqual(works[0].folderAbsolutePath, "/root/a", "目录")
            h.expectEqual(works[0].tracks[0].filePath, "/root/a/01.mp3", "文件")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("扫描器：每文件一作") {
        let options = ScanOptions(includeVideos: true, separateAudioFormats: true, grouping: .filesAsWorks)
        h.test("递归每媒体独立且不合并同名编码和SE版本") {
            let files = [file("A.wav"), file("A.mp3"), file("子目录/A.wav"), file("子目录/更深/Video.mp4"),
                         file("A.pdf"), file("cover.jpg"), file("子目录/说明.txt")]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root", options: options)
            h.expectEqual(Set(works.map(\.folderRelativePath)), Set(["A.wav", "A.mp3", "子目录/A.wav", "子目录/更深/Video.mp4"]), "每个完整媒体路径是独立身份")
            h.expectEqual(works.count, 4, "台本和图片不另建作品")
            h.expect(works.allSatisfy { $0.tracks.count == 1 && $0.tracks[0].variants.count == 1 }, "每作品只有所选文件，不吸收变体")
            h.expectEqual(works.flatMap(\.tracks).filter(\.isVideo).count, 1, "视频独立")
            for work in works {
                h.expectEqual(work.folderAbsolutePath, "/root/" + work.folderRelativePath, "身份绝对路径")
                h.expectEqual(work.tracks[0].filePath, work.folderAbsolutePath, "真实媒体路径")
                h.expectEqual(LibraryPathResolver.join(root: LibraryPathResolver.workDirectory(root: "/root", workRelativePath: work.folderRelativePath, grouping: .filesAsWorks), relative: work.tracks[0].relativePath), work.tracks[0].filePath, "播放父目录解析")
            }
        }
        h.test("同目录同名台本图片和语言字幕不串作品") {
            let files = [file("A.wav"), file("B.wav"), file("A.pdf"), file("B.txt"), file("A.zh.srt"),
                         file("B.ja.vtt"), file("A.jpg"), file("B.png"), file("cover.jpg"), file("不明.pdf"), file("other/random.txt")]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root", options: options)
            guard let a = works.first(where: { $0.folderRelativePath == "A.wav" }), let b = works.first(where: { $0.folderRelativePath == "B.wav" }) else { h.expect(false, "两部作品都存在"); return }
            h.expectEqual(a.scriptCandidates, ["/root/A.pdf"], "A仅自己的台本")
            h.expectEqual(b.scriptCandidates, ["/root/B.txt"], "B仅自己的台本")
            h.expectEqual(a.subtitlePaths, ["/root/A.zh.srt"], "A的语言字幕")
            h.expectEqual(b.subtitlePaths, ["/root/B.ja.vtt"], "B的语言字幕")
            h.expectEqual(a.coverRelativePath, "A.jpg", "同名图优先通用封面")
            h.expectEqual(b.coverRelativePath, "B.png", "B封面不串用")
            let aFiles = LibraryScanner.files(forIndividualMedia: files[0], in: files).map(\.relativePath)
            h.expect(aFiles.contains("cover.jpg"), "明确通用封面共享为附件")
            h.expect(!aFiles.contains("不明.pdf") && !aFiles.contains("other/random.txt") && !aFiles.contains("B.wav"), "不猜台本，不串目录和媒体")
        }
        h.test("同名不同格式可共享裸名字幕但格式专属字幕不串") {
            let files = [file("A.wav"), file("A.mp3"), file("A.srt"), file("A.mp3.zh.vtt")]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root", options: options)
            h.expectEqual(works.first { $0.folderRelativePath == "A.wav" }?.subtitlePaths, ["/root/A.srt"], "WAV不取得mp3专属字幕")
            h.expectEqual(Set(works.first { $0.folderRelativePath == "A.mp3" }?.subtitlePaths ?? []), Set(["/root/A.srt", "/root/A.mp3.zh.vtt"]), "MP3可选择两份")
            let lone = LibraryScanner.plan(files: [file("A.wav"), file("A.mp3.zh.vtt"), file("A.mp3.pdf")], sourceRoot: "/root", options: options)
            h.expectEqual(lone.first?.subtitlePaths, [], "单媒体也不取得其他格式专属字幕")
            h.expectEqual(lone.first?.scriptCandidates, [], "格式专属台本不误作单媒体通用台本")
            let languageName = LibraryScanner.plan(files: [file("A.wav"), file("A.ja.wav"), file("A.ja.pdf")], sourceRoot: "/root", options: options)
            h.expectEqual(languageName.first { $0.folderRelativePath == "A.ja.wav" }?.scriptCandidates, ["/root/A.ja.pdf"], "精确文件名先于语言后缀推断")
            h.expectEqual(languageName.first { $0.folderRelativePath == "A.wav" }?.scriptCandidates, [], "不抢其他媒体的精确同名台本")
        }
        h.test("单媒体目录收同目录资料但不收其他层级和未启用媒体") {
            let files = [file("独立/A.wav"), file("独立/台本.pdf"), file("独立/说明.txt"), file("独立/插图.png"), file("独立/更深/别处.pdf")]
            let work = LibraryScanner.plan(files: files, sourceRoot: "/root", options: options).first
            h.expectEqual(Set(work?.scriptCandidates ?? []), Set(["/root/独立/台本.pdf", "/root/独立/说明.txt"]), "唯一媒体可接收同目录台本")
            let mixed = [file("A.wav"), file("V.mp4"), file("不明.pdf")]
            let audioOnly = LibraryScanner.plan(files: mixed, sourceRoot: "/root", options: ScanOptions(grouping: .filesAsWorks))
            h.expectEqual(audioOnly.count, 1, "includeVideos仍受尊重")
            h.expectEqual(audioOnly.first?.scriptCandidates, [], "未导入的视频也使无名台本归属不明")
        }
        h.test("文件阈值排除目录和特典选项仍有效，资料本身不成作") {
            let files = [file("OK.wav"), file("small.wav", size: 10), file("omit/X.wav"), file("特典/B.wav"), file("V.mp4"), file("only.pdf")]
            let filtered = LibraryScanner.plan(files: files, sourceRoot: "/root", options: ScanOptions(includeBonus: false, excludedFolderPrefixes: ["omit"], grouping: .filesAsWorks))
            h.expectEqual(filtered.map(\.folderRelativePath), ["OK.wav"], "沿用扫描过滤条件")
            h.expect(LibraryScanner.plan(files: [file("x.pdf"), file("image.jpg")], sourceRoot: "/root", options: options).isEmpty, "资料不创建空作品")
        }
        h.test("目录身份不靠扩展名猜，根移动只改变真实路径") {
            h.expectEqual(LibraryPathResolver.workDirectory(root: "/root", workRelativePath: "Album.wav", grouping: .childrenAsWorks), "/root/Album.wav", "音频扩展名目录原样保留")
            h.expectEqual(LibraryPathResolver.workDirectory(root: "/root", workRelativePath: "Album.wav/A.mp3", grouping: .filesAsWorks), "/root/Album.wav", "每文件模式才取父目录")
            let first = LibraryScanner.plan(files: [file("nested/A.wav")], sourceRoot: "/root", options: options)
            let moved = [ScannedFile(relativePath: "nested/A.wav", absolutePath: "/new/nested/A.wav", size: 2_000_000, modified: Date())]
            let second = LibraryScanner.plan(files: moved, sourceRoot: "/new", options: options)
            h.expectEqual(first.map(\.folderRelativePath), second.map(\.folderRelativePath), "根改名相对身份不变")
            h.expectEqual(first.flatMap(\.tracks).map(\.relativePath), second.flatMap(\.tracks).map(\.relativePath), "轨相对路径不变")
            h.expectEqual(second.first?.tracks.first?.filePath, "/new/nested/A.wav", "新真实路径")
        }
    }

    h.suite("扫描器：真实作品结构") {
        // 复刻真实作品的目录形态：
        //   根目录/Readme.txt、本編SEあり/{mp3,wav}/、本編SEなし/{mp3,wav}/、
        //   台本（简繁体）、封面
        func realFiles() -> [ScannedFile] {
            [
                file("Readme.txt"),
                file("本編SEあり/mp3/Tr1_本編1.mp3", size: 8_000_000),
                file("本編SEあり/wav/Tr1_本編1.wav", size: 96_000_000),
                file("本編SEなし/mp3/Tr1_本編1.mp3", size: 7_900_000),
                file("本編SEなし/wav/Tr1_本編1.wav", size: 95_000_000),
                file("本編SEあり/mp3/Tr2_本編2.mp3", size: 9_000_000),
                file("本編SEあり/wav/Tr2_本編2.wav", size: 100_000_000),
                file("本編SEなし/mp3/Tr2_本編2.mp3", size: 9_100_000),
                file("本編SEなし/wav/Tr2_本編2.wav", size: 101_000_000),
                file("特典/SEあり/特典.mp3", size: 5_000_000),
                file("特典/SEなし/特典.mp3", size: 5_100_000),
                file("台本/作品_簡体字台本.pdf", size: 500_000),
                file("台本/作品_繁体字台本.pdf", size: 500_000),
                file("画像/キービジュアル.png", size: 800_000)
            ]
        }

        h.test("整个目录算一个作品，不再拆碎") {
            let works = LibraryScanner.plan(files: realFiles(), sourceRoot: "/root")
            h.expectEqual(works.count, 1, "应是一个作品，实际 \(works.count)")
            h.expectEqual(works[0].folderRelativePath, "", "作品根就是源根")
        }

        h.test("4 种变体归并成 1 首") {
            let works = LibraryScanner.plan(files: realFiles(), sourceRoot: "/root")
            let tr1 = works[0].tracks.first { $0.title.contains("本編1") }
            h.expectNotNil(tr1, "找到本編1")
            h.expectEqual(tr1?.variants.count, 4, "SE有無 × mp3/wav = 4 个变体")
        }

        h.test("分开收录不同音频格式，每个格式仍使用所选的音效版本") {
            let tracks = LibraryScanner.plan(files: realFiles(), sourceRoot: "/root",
                options: ScanOptions(separateAudioFormats: true, grouping: .singleWork))[0].tracks
            let first = tracks.filter { $0.title.contains("本編1") }
            h.expectEqual(tracks.count, 5, "两首正片各两种格式，另有一首特典")
            h.expectEqual(Set(first.map(\.fileType)), ["mp3", "wav"], "每个格式一行")
            h.expect(first.allSatisfy { $0.hasSoundEffects == true }, "各格式均选 SE あり")
        }

        h.test("默认选「带音效 + 无损」") {
            let works = LibraryScanner.plan(files: realFiles(), sourceRoot: "/root")
            let tr1 = works[0].tracks.first { $0.title.contains("本編1") }
            h.expectEqual(tr1?.fileType, "wav", "选无损")
            h.expectEqual(tr1?.hasSoundEffects, true, "选带音效")
        }

        h.test("可以改成优先无音效") {
            let options = ScanOptions(preferSoundEffects: false)
            let works = LibraryScanner.plan(files: realFiles(), sourceRoot: "/root", options: options)
            let tr1 = works[0].tracks.first { $0.title.contains("本編1") }
            h.expectEqual(tr1?.hasSoundEffects, false, "选无音效版本")
            h.expectEqual(tr1?.fileType, "wav", "仍然优先无损")
        }

        h.test("不含变体标记的文件只有 1 个变体") {
            let works = LibraryScanner.plan(files: realFiles(), sourceRoot: "/root")
            let bonus = works[0].tracks.first { $0.title.contains("特典") }
            h.expectNotNil(bonus, "找到特典")
            h.expectEqual(bonus?.variants.count, 2, "特典只有 SE有/无 两个变体")
        }

        h.test("Tr1 这种轨号能解析") {
            let works = LibraryScanner.plan(files: realFiles(), sourceRoot: "/root")
            let tr2 = works[0].tracks.first { $0.title.contains("本編2") }
            h.expectEqual(tr2?.trackNumber, 2, "轨号")
        }

        h.test("Readme 不当台本") {
            let works = LibraryScanner.plan(files: realFiles(), sourceRoot: "/root")
            h.expect(works[0].scriptPath?.contains("Readme") == false, "台本不能是 Readme")
            h.expect(works[0].scriptPath?.contains("簡体字") == true, "默认选简体台本")
        }

        h.test("台本候选保留全部") {
            let works = LibraryScanner.plan(files: realFiles(), sourceRoot: "/root")
            h.expectEqual(works[0].scriptCandidates.count, 2, "简繁两份")
        }

        h.test("台本可选繁体") {
            let options = ScanOptions(scriptPreference: .traditionalChinese)
            let works = LibraryScanner.plan(files: realFiles(), sourceRoot: "/root", options: options)
            h.expect(works[0].scriptPath?.contains("繁体字") == true, "选繁体")
        }

        h.test("封面选キービジュアル") {
            let works = LibraryScanner.plan(files: realFiles(), sourceRoot: "/root")
            h.expect(works[0].coverPath?.contains("キービジュアル") == true, "封面")
        }

        h.test("特典括号不被当成社团") {
            let works = LibraryScanner.plan(
                files: [file("【早期購入特典付き】作品/01.mp3")],
                sourceRoot: "/"
            )
            h.expectNil(works.first?.circleName, "社团应为空，实际：\(String(describing: works.first?.circleName))")
        }

        h.test("默认体积门槛不再误杀短语音") {
            // 259KB 的短语音消息应该被保留（旧默认 256KB 边界会漏）
            let files = [file("ボイス/01.mp3", size: 259_000), file("ボイス/02.mp3", size: 212_000)]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expectEqual(works.first?.tracks.count, 2, "两首都保留")
        }

        h.test("库根目录下多个作品能正确分开") {
            let files = [
                file("作品A/Readme.txt"),
                file("作品A/本編/01.mp3"),
                file("作品B/Readme.txt"),
                file("作品B/本編/01.mp3")
            ]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expectEqual(works.count, 2, "两个作品")
            h.expectEqual(works.map(\.title).sorted(), ["作品A", "作品B"], "标题")
        }
    }


    // ─────────────────────────────────────────────────────────
    h.suite("曲目类型分类（真实路径）") {
        h.test("正片") {
            h.expectEqual(TrackCategorizer.classify(relativePath: "本編SEあり/wav/Tr1_プロローグ.wav"), .main, "本編")
            h.expectEqual(TrackCategorizer.classify(relativePath: "本編SEなし/mp3/Tr2_本編.mp3"), .main, "本編 SEなし")
        }
        h.test("特典后日谈") {
            h.expectEqual(
                TrackCategorizer.classify(relativePath: "【300DL特典】本編後日談2_xxx/SEあり/xxx.wav"),
                .bonus,
                "含本編但其实是特典，必须归特典"
            )
        }
        h.test("语音消息") {
            h.expectEqual(
                TrackCategorizer.classify(relativePath: "【★早期購入特典】/【早期購入特典】ボイスメッセージ/wav/01_おはよう.wav"),
                .voiceMessage,
                "语音消息优先于特典"
            )
        }
        h.test("闲聊优先于特典") {
            h.expectEqual(
                TrackCategorizer.classify(relativePath: "【お気に入り特典】フリートーク/xxx.wav"),
                .talk,
                "同时含特典和フリートーク，应归闲聊"
            )
        }
        h.test("效果音目录") {
            h.expectEqual(TrackCategorizer.classify(relativePath: "SE/ドア.wav"), .soundEffect, "纯 SE 目录")
            h.expectEqual(TrackCategorizer.classify(relativePath: "効果音/雨.wav"), .soundEffect, "効果音")
        }
        h.test("SEあり 不是效果音目录") {
            h.expectEqual(
                TrackCategorizer.classify(relativePath: "本編SEあり/Tr1.wav"),
                .main,
                "SEあり 是变体标记，不能当成 SE 目录"
            )
        }
        h.test("简单作品默认正片") {
            h.expectEqual(TrackCategorizer.classify(relativePath: "01. 雨音.wav"), .main, "默认")
            h.expectEqual(TrackCategorizer.classify(relativePath: "第3話.wav"), .main, "第N話")
        }
        h.test("显示名与排序") {
            h.expectEqual(TrackCategory.main.sortOrder, 0, "正片最前")
            h.expect(TrackCategory.bonus.sortOrder < TrackCategory.voiceMessage.sortOrder, "特典在语音消息前")
            h.expectEqual(TrackCategory.voiceMessage.displayName, "语音消息", "显示名")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("曲目分类落库与分组") {
        h.test("类型能存能读") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let wid = try! repo.upsertWork(WorkRecord(title: "w", folderPath: "/m/w", folderRelativePath: "w", sourceID: sid))
            try! repo.replaceTracks(workID: wid, tracks: [
                TrackRecord(workID: wid, fileName: "Tr1.wav", filePath: "/m/w/Tr1.wav",
                            fileType: "wav", category: .main),
                TrackRecord(workID: wid, fileName: "v1.wav", filePath: "/m/w/v1.wav",
                            fileType: "wav", category: .voiceMessage)
            ])
            let tracks = try! repo.tracks(workID: wid)
            h.expectEqual(tracks.first(where: { $0.fileName == "Tr1.wav" })?.category, .main, "正片")
            h.expectEqual(tracks.first(where: { $0.fileName == "v1.wav" })?.category, .voiceMessage, "语音消息")
        }
        h.test("分组顺序：正片在前") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let wid = try! repo.upsertWork(WorkRecord(title: "w", folderPath: "/m/w", folderRelativePath: "w", sourceID: sid))
            try! repo.replaceTracks(workID: wid, tracks: [
                TrackRecord(workID: wid, fileName: "v1.wav", filePath: "/m/w/v1.wav",
                            fileType: "wav", category: .voiceMessage),
                TrackRecord(workID: wid, fileName: "Tr1.wav", filePath: "/m/w/Tr1.wav",
                            fileType: "wav", category: .main),
                TrackRecord(workID: wid, fileName: "b1.wav", filePath: "/m/w/b1.wav",
                            fileType: "wav", category: .bonus)
            ])
            let grouped = try! repo.tracksGrouped(workID: wid)
            h.expectEqual(grouped.count, 3, "三组")
            h.expectEqual(grouped[0].category.key, "main", "第一组是正片")
            h.expectEqual(grouped[1].category.key, "bonus", "第二组是特典")
            h.expectEqual(grouped[2].category.key, "voiceMessage", "第三组是语音消息")
        }
        h.test("空分组不返回") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let wid = try! repo.upsertWork(WorkRecord(title: "w", folderPath: "/m/w", folderRelativePath: "w", sourceID: sid))
            try! repo.replaceTracks(workID: wid, tracks: [
                TrackRecord(workID: wid, fileName: "Tr1.wav", filePath: "/m/w/Tr1.wav",
                            fileType: "wav", category: .main)
            ])
            h.expectEqual(try! repo.tracksGrouped(workID: wid).count, 1, "只有一组")
        }
    }


    // ─────────────────────────────────────────────────────────
    h.suite("路径解析（容器路径会变）") {
        h.test("简单拼接") {
            h.expectEqual(LibraryPathResolver.join(root: "/a/b", relative: "c/d"), "/a/b/c/d", "拼接")
            h.expectEqual(LibraryPathResolver.join(root: "/a/b/", relative: "/c"), "/a/b/c", "处理多余斜杠")
            h.expectEqual(LibraryPathResolver.join(root: "/a/b", relative: ""), "/a/b", "空相对路径")
        }
        h.test("重锚定到新的 Documents") {
            let stored = "/L/Developer/CoreSimulator/OLD-UUID/Documents/音乐库"
            let docs = "/L/Developer/CoreSimulator/NEW-UUID/Documents"
            let result = LibraryPathResolver.reanchor(storedRoot: stored, currentDocumentsRoot: docs)
            h.expectEqual(result, docs + "/音乐库", "UUID 换掉也能找回")
        }
        h.test("外部目录不重锚定") {
            let stored = "/Volumes/NAS/音乐库"
            h.expectNil(
                LibraryPathResolver.reanchor(storedRoot: stored, currentDocumentsRoot: "/docs"),
                "不在 Documents 下的路径不该被重锚定"
            )
        }
        h.test("完整解析：根目录还在就直接用") {
            let result = LibraryPathResolver.resolve(
                storedRoot: "/exists/root",
                relative: "作品/01.mp3",
                currentDocumentsRoot: "/docs",
                rootExists: { $0 == "/exists/root" }
            )
            h.expectEqual(result, "/exists/root/作品/01.mp3", "直接用")
        }
        h.test("完整解析：根目录没了就重锚定") {
            let stored = "/OLD/Documents/音乐库"
            let docs = "/NEW/Documents"
            let result = LibraryPathResolver.resolve(
                storedRoot: stored,
                relative: "作品/01.mp3",
                currentDocumentsRoot: docs,
                rootExists: { $0 == docs + "/音乐库" }
            )
            h.expectEqual(result, docs + "/音乐库/作品/01.mp3", "重锚定后拼上")
        }
        h.test("完整解析：都找不到返回 nil") {
            h.expectNil(
                LibraryPathResolver.resolve(
                    storedRoot: "/gone", relative: "a", currentDocumentsRoot: "/docs",
                    rootExists: { _ in false }
                ),
                "应返回 nil"
            )
        }
        h.test("作品按相对路径去重，不受容器变化影响") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            // 同一个作品目录，绝对路径变了（模拟重装），相对路径不变
            let a = try! repo.upsertWork(WorkRecord(
                title: "作品", folderPath: "/OLD/Documents/m/作品",
                folderRelativePath: "作品", sourceID: sid
            ))
            let b = try! repo.upsertWork(WorkRecord(
                title: "作品", folderPath: "/NEW/Documents/m/作品",
                folderRelativePath: "作品", sourceID: sid
            ))
            h.expectEqual(a, b, "仍是同一个作品")
            h.expectEqual(try! repo.counts().works, 1, "没有产生重复")
        }
    }


    // ─────────────────────────────────────────────────────────
    h.suite("分类：作品文件夹名不应污染曲目") {
        h.test("作品名含「特典」·正片仍是正片") {
            // 真实案例：文件夹叫「…特典付き」，里面有 tr01~tr18 正片
            let files = [
                file("【早期購入特典付き】作品/tr01_タイトルコール.mp3"),
                file("【早期購入特典付き】作品/tr02_お耳舐め.mp3"),
                file("【早期購入特典付き】作品/extr01_フリートーク.mp3"),
                file("【早期購入特典付き】作品/【購入特典】おまけ.mp3")
            ]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            h.expectEqual(works.count, 1, "一个作品")
            let byName = Dictionary(uniqueKeysWithValues: works[0].tracks.map { ($0.fileName, $0.category) })
            h.expectEqual(byName["tr01_タイトルコール.mp3"], .main, "正片应判为本編")
            h.expectEqual(byName["tr02_お耳舐め.mp3"], .main, "正片应判为本編")
            h.expectEqual(byName["extr01_フリートーク.mp3"], .talk, "闲聊")
            h.expectEqual(byName["【購入特典】おまけ.mp3"], .bonus, "特典")
        }

        h.test("作品内部的「特典」子目录仍能识别") {
            let files = [
                file("作品/本編/tr01.mp3"),
                file("作品/【購入特典】後日談/おまけ.mp3")
            ]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/root")
            let byName = Dictionary(uniqueKeysWithValues: works[0].tracks.map { ($0.fileName, $0.category) })
            h.expectEqual(byName["tr01.mp3"], .main, "正片")
            h.expectEqual(byName["おまけ.mp3"], .bonus, "内部特典子目录仍识别")
        }
    }


    // ─────────────────────────────────────────────────────────
    h.suite("手动分组与排序") {
        func setup() throws -> (LibraryRepository, Int64) {
            let repo = try makeRepo()
            let sid = try repo.saveSource(LibrarySource(name: "s", rootPath: "/m"))
            let wid = try repo.upsertWork(WorkRecord(title: "w", folderPath: "/m/w", folderRelativePath: "w", sourceID: sid))
            try repo.replaceTracks(workID: wid, tracks: [
                TrackRecord(workID: wid, fileName: "tr01.mp3", filePath: "/m/w/tr01.mp3",
                            relativePath: "tr01.mp3", fileType: "mp3", category: .main),
                TrackRecord(workID: wid, fileName: "tr02.mp3", filePath: "/m/w/tr02.mp3",
                            relativePath: "tr02.mp3", fileType: "mp3", category: .main),
                TrackRecord(workID: wid, fileName: "おまけ.mp3", filePath: "/m/w/おまけ.mp3",
                            relativePath: "おまけ.mp3", fileType: "mp3", category: .bonus)
            ])
            return (repo, wid)
        }

        h.test("新建自定义分组") {
            let (repo, wid) = try! setup()
            let cat = try! repo.addCustomCategory(workID: wid, title: "本篇")
            h.expectEqual(cat.title, "本篇", "标题")
            h.expect(cat.isBuiltin == false, "是自定义")
            let list = try! repo.categories(workID: wid)
            h.expect(list.contains { $0.key == cat.key }, "出现在分组列表里")
        }

        h.test("同名分组不重复创建") {
            let (repo, wid) = try! setup()
            let a = try! repo.addCustomCategory(workID: wid, title: "本篇")
            let b = try! repo.addCustomCategory(workID: wid, title: "本篇")
            h.expectEqual(a.key, b.key, "返回同一个")
            h.expectEqual(try! repo.customCategories(workID: wid).count, 1, "只有一个")
        }

        h.test("把曲目拖进自定义分组") {
            let (repo, wid) = try! setup()
            let cat = try! repo.addCustomCategory(workID: wid, title: "本篇")
            let tracks = try! repo.tracks(workID: wid)
            let tr01 = tracks.first { $0.fileName == "tr01.mp3" }!
            try! repo.setCategoryOverride(workID: wid, trackIDs: [tr01.id], key: cat.key)

            let grouped = try! repo.tracksGrouped(workID: wid)
            let custom = grouped.first { $0.category.key == cat.key }
            h.expectNotNil(custom, "出现自定义分组")
            h.expectEqual(custom?.tracks.count, 1, "里面有一首")
            h.expectEqual(custom?.tracks.first?.fileName, "tr01.mp3", "是 tr01")
        }

        h.test("自定义分组优先级高于自动识别") {
            let (repo, wid) = try! setup()
            let cat = try! repo.addCustomCategory(workID: wid, title: "本篇")
            let tracks = try! repo.tracks(workID: wid)
            let bonus = tracks.first { $0.fileName == "おまけ.mp3" }!
            h.expectEqual(bonus.category, .bonus, "自动识别是特典")
            try! repo.setCategoryOverride(workID: wid, trackIDs: [bonus.id], key: cat.key)
            let updated = try! repo.tracks(workID: wid).first { $0.id == bonus.id }!
            h.expectEqual(updated.category, .bonus, "自动结果保留")
            h.expectEqual(updated.effectiveCategoryKey, cat.key, "但生效的是手动值")
        }

        h.test("恢复自动识别") {
            let (repo, wid) = try! setup()
            let cat = try! repo.addCustomCategory(workID: wid, title: "本篇")
            let tr = try! repo.tracks(workID: wid).first { $0.fileName == "tr01.mp3" }!
            try! repo.setCategoryOverride(workID: wid, trackIDs: [tr.id], key: cat.key)
            try! repo.setCategoryOverride(workID: wid, trackIDs: [tr.id], key: nil)
            let back = try! repo.tracks(workID: wid).first { $0.id == tr.id }!
            h.expectNil(back.categoryOverride, "覆盖已清除")
            h.expectEqual(back.effectiveCategoryKey, "main", "回到自动识别")
        }

        h.test("删除分组后曲目回到自动分类") {
            let (repo, wid) = try! setup()
            let cat = try! repo.addCustomCategory(workID: wid, title: "本篇")
            let tr = try! repo.tracks(workID: wid).first { $0.fileName == "tr01.mp3" }!
            try! repo.setCategoryOverride(workID: wid, trackIDs: [tr.id], key: cat.key)
            try! repo.removeCustomCategory(workID: wid, key: cat.key)
            let after = try! repo.tracks(workID: wid).first { $0.id == tr.id }!
            h.expectNil(after.categoryOverride, "覆盖已清除")
            h.expectEqual(after.effectiveCategoryKey, "main", "回到本編")
        }

        h.test("重命名分组") {
            let (repo, wid) = try! setup()
            let cat = try! repo.addCustomCategory(workID: wid, title: "本篇")
            try! repo.renameCustomCategory(workID: wid, key: cat.key, title: "正片")
            let list = try! repo.customCategories(workID: wid)
            h.expectEqual(list.first?.title, "正片", "已改名")
        }

        h.test("手动排序生效") {
            let (repo, wid) = try! setup()
            let tracks = try! repo.tracks(workID: wid)
            let reversed = Array(tracks.reversed()).map(\.id)
            try! repo.setTrackOrder(workID: wid, orderedTrackIDs: reversed)
            let after = try! repo.tracks(workID: wid)
            h.expectEqual(after.map(\.id), reversed, "顺序已反转")
        }

        h.test("重新扫描保留手动分类与顺序") {
            let (repo, wid) = try! setup()
            let cat = try! repo.addCustomCategory(workID: wid, title: "本篇")
            let tr = try! repo.tracks(workID: wid).first { $0.fileName == "tr01.mp3" }!
            try! repo.setCategoryOverride(workID: wid, trackIDs: [tr.id], key: cat.key)
            try! repo.setTrackOrder(workID: wid, orderedTrackIDs: [tr.id])

            // 模拟重新扫描：内容一样，重新插入
            try! repo.replaceTracks(workID: wid, tracks: [
                TrackRecord(workID: wid, fileName: "tr01.mp3", filePath: "/m/w/tr01.mp3",
                            relativePath: "tr01.mp3", fileType: "mp3", category: .main),
                TrackRecord(workID: wid, fileName: "tr02.mp3", filePath: "/m/w/tr02.mp3",
                            relativePath: "tr02.mp3", fileType: "mp3", category: .main),
                TrackRecord(workID: wid, fileName: "おまけ.mp3", filePath: "/m/w/おまけ.mp3",
                            relativePath: "おまけ.mp3", fileType: "mp3", category: .bonus)
            ])
            let after = try! repo.tracks(workID: wid).first { $0.fileName == "tr01.mp3" }!
            h.expectEqual(after.categoryOverride, cat.key, "手动分类保住了")
            let grouped = try! repo.tracksGrouped(workID: wid)
            h.expect(grouped.contains { $0.category.key == cat.key }, "分组还在")
        }

        h.test("分组顺序：内置在前") {
            let (repo, wid) = try! setup()
            _ = try! repo.addCustomCategory(workID: wid, title: "本篇")
            let list = try! repo.categories(workID: wid)
            h.expectEqual(list.first?.key, "main", "第一个是内置本編")
            h.expect(list.last?.isBuiltin == false, "自定义在最后")
        }

        h.test("空的自定义分组也要显示（否则新建完看不见）") {
            let (repo, wid) = try! setup()
            _ = try! repo.addCustomCategory(workID: wid, title: "空分组")
            let grouped = try! repo.tracksGrouped(workID: wid)
            h.expect(grouped.contains { $0.category.title == "空分组" }, "空的自定义分组应显示")
            h.expectEqual(grouped.first { $0.category.title == "空分组" }?.tracks.count, 0, "里面是空的")
        }

        h.test("空的内置分组仍然隐藏") {
            let (repo, wid) = try! setup()
            let grouped = try! repo.tracksGrouped(workID: wid)
            h.expect(!grouped.contains { $0.category.key == "voiceMessage" }, "没有语音消息就不显示该组")
        }
    }


    // ─────────────────────────────────────────────────────────
    h.suite("导入：选中文件夹里没有子文件夹") {
        h.test("音频直接躺在所选目录里") {
            let files = [
                file("01. プロローグ.mp3"),
                file("02. 本編.mp3"),
                file("03. エピローグ.mp3")
            ]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/music/我的作品")
            h.expectEqual(works.count, 1, "应该是一个作品，实际 \(works.count)")
            h.expectEqual(works.first?.tracks.count, 3, "三首曲目")
            h.expectEqual(works.first?.folderRelativePath, "", "作品根就是所选目录")
            h.expectEqual(works.first?.folderAbsolutePath, "/music/我的作品", "绝对路径")
            h.expectEqual(works.first?.title, "我的作品", "标题用文件夹名")
        }

        h.test("只有一首歌的文件夹") {
            let works = LibraryScanner.plan(
                files: [file("single.mp3")],
                sourceRoot: "/music/单曲"
            )
            h.expectEqual(works.count, 1, "一个作品")
            h.expectEqual(works.first?.tracks.count, 1, "一首")
        }

        h.test("根目录音频 + 一个子目录") {
            let files = [
                file("01.mp3"),
                file("CD2/02.mp3")
            ]
            let works = LibraryScanner.plan(files: files, sourceRoot: "/music/作品")
            h.expectEqual(works.count, 1, "仍是一个作品（根目录有音频就不拆）")
            h.expectEqual(works.first?.tracks.count, 2, "两首")
        }
    }


    // ─────────────────────────────────────────────────────────
    h.suite("导入：根目录作品不能被清理逻辑误删") {
        h.test("storageKey 对根目录作品返回稳定键") {
            h.expectEqual(
                LibraryRepository.storageKey(relativePath: "", absolutePath: "/music/作品"),
                ".",
                "根目录作品用 . 作为键"
            )
            h.expectEqual(
                LibraryRepository.storageKey(relativePath: "作品A", absolutePath: "/music/作品A"),
                "作品A",
                "普通作品用相对路径"
            )
        }

        h.test("根目录作品入库后不会被清理删掉") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/music"))
            let key = LibraryRepository.storageKey(relativePath: "", absolutePath: "/music")
            let wid = try! repo.upsertWork(WorkRecord(
                title: "我的作品",
                folderPath: "/music",
                folderRelativePath: key,
                sourceID: sid
            ))
            h.expect(wid > 0, "入库成功")

            // 模拟导入完成后的清理
            let removed = try! repo.deleteWorks(sourceID: sid, notInFolderPaths: [key])
            h.expectEqual(removed, 0, "不该删掉任何东西")
            h.expectEqual(try! repo.counts().works, 1, "作品还在")
            h.expectEqual(try! repo.works().first?.title, "我的作品", "标题正确")
        }

        h.test("重复导入根目录作品不产生重复") {
            let repo = try! makeRepo()
            let sid = try! repo.saveSource(LibrarySource(name: "s", rootPath: "/music"))
            let key = LibraryRepository.storageKey(relativePath: "", absolutePath: "/music")
            let a = try! repo.upsertWork(WorkRecord(title: "我的作品", folderPath: "/music",
                                                    folderRelativePath: key, sourceID: sid))
            let b = try! repo.upsertWork(WorkRecord(title: "我的作品", folderPath: "/music",
                                                    folderRelativePath: key, sourceID: sid))
            h.expectEqual(a, b, "同一个作品")
            h.expectEqual(try! repo.counts().works, 1, "只有一条")
        }

        h.test("根目录作品的路径能正确解析") {
            let joined = LibraryPathResolver.join(root: "/music/我的作品", relative: ".")
            h.expectEqual(joined, "/music/我的作品", "点号表示目录本身")
        }
    }

}
