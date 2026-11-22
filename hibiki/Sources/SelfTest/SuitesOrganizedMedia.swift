import Foundation
import HibikiCore

func runOrganizedMediaSuites(_ h: Harness) {
    h.suite("分组、音轨和独立附件") {
        h.test("手动 RJ 号的搜索、清空与重新扫描") {
            do {
                let db = try SQLiteDatabase.inMemory()
                let repo = LibraryRepository(database: db)
                try repo.prepare()
                let sid = try repo.saveSource(LibrarySource(name: "库"))
                let original = WorkRecord(title: "标题", rjCode: "RJ123456", folderPath: "/w", sourceID: sid)
                let id = try repo.upsertWork(original)
                try repo.updateWorkMetadata(workID: id, rjCode: " ００１２３４５６ ", circleName: "", seiyuuNames: [])
                _ = try repo.upsertWork(original)
                h.expectEqual(try repo.work(id: id)?.rjCode, "RJ00123456", "全角数字规范化后保留前导零")
                h.expectEqual(try repo.works(searchText: "RJ00123456").map(\.id), [id], "可搜到手动 RJ 号")
                try repo.updateWorkMetadata(workID: id, rjCode: "", circleName: "", seiyuuNames: [])
                _ = try repo.upsertWork(original)
                h.expectNil(try repo.work(id: id)?.rjCode, "明确清空后重扫仍为空")
                h.expect(try repo.works(searchText: "RJ123456").isEmpty, "清空后旧码也不参与搜索")
                try repo.updateWorkMetadata(workID: id, rjCode: " ｂｊ００１２３４ ", circleName: "", seiyuuNames: [])
                _ = try repo.upsertWork(original)
                h.expectEqual(try repo.work(id: id)?.rjCode, "BJ001234", "BJ 保留前缀和前导零")
                h.expectEqual(try repo.works(searchText: "BJ001234").map(\.id), [id], "可搜索商业作品")
                do {
                    try repo.updateWorkMetadata(workID: id, title: "不可部分写入", rjCode: "BJ12X", circleName: "", seiyuuNames: [])
                    h.expect(false, "应拦截错误编号")
                } catch LibraryEditingError.invalidRJ {
                    h.expectEqual(try repo.work(id: id)?.title, "标题", "无效输入不改作品")
                }
                try repo.updateWorkMetadata(workID: id, rjCode: "", circleName: "", seiyuuNames: [])
                h.expectNil(try repo.work(id: id)?.rjCode, "BJ 也可留空")
            } catch { h.expect(false, "RJ 号：\(error)") }
        }
        h.test("移除队列中的音轨，保留摘选与相对次序") {
            let items = [1, 2, 3, -4].map { id in
                PlaybackQueueItem(workID: 1, trackID: Int64(id), workTitle: "作品", trackTitle: "音轨",
                                  filePath: "/x", fileType: "wav")
            }
            var queue = PlaybackQueue.make(items: items, startingAt: 1)
            queue.removeTracks([1])
            h.expectEqual(queue.current?.trackID, 2, "删前一首时继续听当前首")
            queue.removeTracks([2])
            h.expectEqual(queue.current?.trackID, 3, "删当前首后移到下一首")
            queue.removeTracks([3])
            h.expectEqual(queue.items.map(\.trackID), [-4], "整部作品从队列移除后独立摘选可继续听")
        }
        h.test("v12作品升级；跨类型混排、旧编号、折叠组顺序与清理策略") {
            do {
                let db = try SQLiteDatabase.inMemory()
                try db.migrate(Schema.migrations.filter { $0.version <= 12 })
                let repo = LibraryRepository(database: db)
                let sid = try repo.saveSource(LibrarySource(name: "库"))
                let work = WorkRecord(title: "旧作品", folderPath: "/old", folderRelativePath: ".", sourceID: sid)
                let wid = try repo.upsertWork(work)
                let input = ["1.wav", "2.wav"].map {
                    TrackRecord(workID: wid, fileName: $0, filePath: "/old/" + $0, relativePath: $0, fileType: "wav")
                }
                try repo.replaceTracks(workID: wid, tracks: input)
                h.expectEqual(try repo.work(id: wid)?.mediaCountText, "2 曲", "v12 老库仍能打开详情")
                h.expectEqual(try repo.works(sort: .rjCode, searchText: "旧作").first?.videoCount, 0, "v12 搜索和按 RJ 排序仍可读取作品")
                let oldTracks = try repo.tracks(workID: wid)
                let lists = PlaylistRepository(database: db)
                try lists.addWholeTrack(trackID: oldTracks[0].id, title: "整曲", workTitle: "旧作品")
                try lists.addClip(trackID: oldTracks[0].id, title: "摘选", workTitle: "旧作品", startMS: 100, endMS: 900, filename: "old.caf")
                try repo.prepare()
                let scanned = WorkAttachment(relativePath: "图片/a.png", kind: .image, byteCount: 11)
                let scannedPDF = WorkAttachment(relativePath: "台本/a.pdf", kind: .pdf, byteCount: 20)
                try repo.replaceScannedAttachments(workID: wid, files: [scanned, scannedPDF])
                let originalFiles = try repo.attachmentRecords(workID: wid)
                let first = oldTracks[0], second = oldTracks[1], photo = originalFiles[0]
                try repo.moveMedia(workID: wid, item: .attachment(photo.id), to: "main", relativeTo: .track(second.id), after: false)
                let mixed = try repo.organizedSections(workID: wid)[0].items.map(\.id)
                h.expectEqual(mixed, [.track(first.id), .attachment(photo.id), .track(second.id)], "图能插在两首之间")
                h.expectEqual(try repo.tracksGrouped(workID: wid).flatMap(\.tracks).map(\.id), [first.id, second.id], "音频队列不会夹入附件")
                let grp = try repo.addCustomCategory(workID: wid, title: "早期")
                try repo.moveMedia(workID: wid, item: .track(second.id), to: grp.key, relativeTo: nil, after: false)
                try repo.moveMedia(workID: wid, item: .attachment(photo.id), to: grp.key, relativeTo: .track(second.id), after: true)
                let keys = try repo.categories(workID: wid).map(\.key)
                try repo.reorderCategories(workID: wid, keys: [grp.key] + keys.filter { $0 != grp.key })
                h.expectEqual(try repo.organizedSections(workID: wid)[0].items.map(\.id), [.track(second.id), .attachment(photo.id)], "自建组能排在内置组之前")
                h.expectEqual(try repo.tracksGrouped(workID: wid).flatMap(\.tracks).map(\.id), [second.id, first.id], "作品队列按新分组顺序播放")
                try repo.replaceScannedAttachments(workID: wid, files: [scannedPDF, scanned])
                h.expectEqual(try repo.attachmentRecords(workID: wid).first { $0.id == photo.id }?.categoryKey, grp.key, "重扫保留附件身份和手动位置")
                try repo.removeCustomCategory(workID: wid, key: grp.key)
                h.expectEqual(try repo.attachmentRecords(workID: wid).first { $0.id == photo.id }?.categoryKey, WorkCategory.attachments.key, "移除分组后图仍可见")
                h.expectNil(try repo.removeMedia(workID: wid, id: .attachment(photo.id)), "移除来源附件只删库内记录")
                try repo.replaceScannedAttachments(workID: wid, files: [scanned, scannedPDF])
                h.expectEqual(try repo.attachmentRecords(workID: wid).map(\.attachment.relativePath), ["台本/a.pdf"], "重扫不复活来源附件")
                h.expectNil(try repo.removeMedia(workID: wid, id: .track(first.id)), "移除来源音频不删除原文件")
                try repo.replaceTracks(workID: wid, tracks: input)
                h.expectEqual(try repo.tracks(workID: wid).map(\.id), [second.id], "隐藏音轨重扫后不出现")
                h.expectEqual(try lists.entries().compactMap(\.clipFilename), ["old.caf"], "删除原曲仍可寻址独立摘选")
                h.expectEqual(try lists.entries().count, 1, "整曲的播放列表引用同时清除")
                let video = WorkAttachment(relativePath: "附件.avi", kind: .video, byteCount: 10)
                let owned = WorkAttachmentRecord(workID: wid, attachment: video, assetRelativePath: "Attachments/video.avi")
                try repo.appendOwnedMedia(workID: wid, tracks: [], attachments: [owned])
                h.expectEqual(try repo.works().first?.mediaCountText, "1 曲 · 1 个视频", "卡片同时列出音轨与视频，PDF 不计入视频")
                _ = try repo.deleteWorks(sourceID: sid, notInFolderPaths: [])
                h.expectEqual(try repo.work(id: wid)?.mediaCountText, "1 个视频", "纯视频作品无需列出零首音轨")
                h.expectNotNil(try repo.work(id: wid), "源目录损失时保留自选附件及作品")
                h.expectEqual(try repo.removeWorkFromLibrary(workID: wid), ["Attachments/video.avi"], "显式移除作品仅返回自有磁盘文件")
                h.expectEqual(try repo.excludedWorkPaths(sourceID: sid), ["."], "整库重扫记住已移除作品")
                try repo.restoreExplicitWork(sourceID: sid, folder: ".")
                h.expect(try repo.excludedWorkPaths(sourceID: sid).isEmpty, "重新明确导入原作品可以恢复")
                h.expectEqual(try db.query("PRAGMA foreign_key_check").count, 0, "外键正常")
            } catch { h.expect(false, "整理验证失败：\(error)") }
        }
    }

    h.suite("拖动提示与保存共用目标") {
        let a = WorkMediaID.track(1), b = WorkMediaID.track(2), c = WorkMediaID.track(3)
        let d = WorkMediaID.attachment(4), e = WorkMediaID.track(5)
        let snapshot = WorkReorderSnapshot(workID: 7, groups: [
            .init(category: WorkCategory(.main), itemIDs: [a, b, c]),
            .init(category: WorkCategory(.bonus), itemIDs: [d, e]),
            .init(category: WorkCategory(.voiceMessage), itemIDs: []),
            .init(category: WorkCategory(key: "empty", title: "空组", sortOrder: 9, isBuiltin: false), itemIDs: [])
        ])
        func plan(_ id: WorkMediaID, _ target: WorkDropDestination) throws -> WorkReorderPlan {
            try WorkReorderPlanner.plan(payload: .init(workID: 7, content: .item(id)), to: target, in: snapshot)
        }
        h.test("行前后、组首组尾、空组和混排都有精确结果") {
            do {
                let cases: [(WorkMediaID, WorkDropDestination, String, [WorkMediaID])] = [
                    (b, .item(category: "main", neighbor: c, after: true), "main", [a, c, b]),
                    (c, .item(category: "main", neighbor: b, after: false), "main", [a, c, b]),
                    (a, .groupEnd("main"), "main", [b, c, a]),
                    (c, .groupStart("main"), "main", [c, a, b]),
                    (a, .groupStart("bonus"), "bonus", [a, d, e]),
                    (a, .groupEnd("bonus"), "bonus", [d, e, a]),
                    (a, .item(category: "bonus", neighbor: e, after: false), "bonus", [d, a, e]),
                    (a, .item(category: "bonus", neighbor: d, after: true), "bonus", [d, a, e]),
                    (a, .groupStart("empty"), "empty", [a]),
                    (a, .groupEnd("empty"), "empty", [a]),
                    (d, .item(category: "main", neighbor: b, after: false), "main", [a, d, b, c])
                ]
                for (id, target, category, ids) in cases {
                    h.expectEqual(try plan(id, target), .item(id: id, category: category, orderedIDs: ids), "移除原项后按稳定邻项插入")
                }
                for after in [false, true] {
                    h.expectEqual(try plan(b, .item(category: "main", neighbor: b, after: after)), .unchanged, "self-drop 安静不动")
                }
                h.expectEqual(try plan(a, .groupStart("main")), .unchanged, "已在组首")
                h.expectEqual(try plan(c, .groupEnd("main")), .unchanged, "已在组尾")
                h.expectEqual(try plan(b, .item(category: "main", neighbor: a, after: true)), .unchanged, "相邻等价落点")
            } catch { h.expect(false, "落点计算：\(error)") }
        }
        h.test("整组移动保留隐藏默认组，项目悬停对应整组末尾") {
            do {
                func group(_ key: String, _ target: WorkDropDestination) throws -> WorkReorderPlan {
                    try WorkReorderPlanner.plan(payload: .init(workID: 7, content: .group(key)), to: target, in: snapshot)
                }
                let afterBonus = WorkReorderPlan.groups(["bonus", "main", "voiceMessage", "empty"])
                h.expectEqual(try group("main", .groupEdge(category: "bonus", after: true)), afterBonus, "组下沿")
                h.expectEqual(try group("main", .item(category: "bonus", neighbor: d, after: false)), afterBonus, "项目上沿也只表示其整组之后")
                h.expectEqual(try group("main", .groupEnd("bonus")), afterBonus, "组尾")
                h.expectEqual(try group("empty", .groupStart("main")), .groups(["empty", "main", "bonus", "voiceMessage"]), "空组可整组移到前面")
                h.expectEqual(try group("bonus", .groupEdge(category: "main", after: false)), .groups(["bonus", "main", "voiceMessage", "empty"]), "向前移动没有偏一位")
                h.expectEqual(try group("main", .groupEdge(category: "main", after: true)), .unchanged, "组放自己不报错")
                h.expectEqual(try group("main", .groupStart("bonus")), .unchanged, "已经紧邻目标之前")
            } catch { h.expect(false, "分组落点：\(error)") }
        }
        h.test("跨作品、失效邻项和不完整的重复身份拒绝规划") {
            let invalid: [(WorkReorderPayload, WorkDropDestination)] = [
                (.init(workID: 8, content: .item(a)), .groupEnd("bonus")),
                (.init(workID: 8, content: .group("main")), .groupEdge(category: "bonus", after: true)),
                (.init(workID: 7, content: .item(.track(999))), .groupStart("main")),
                (.init(workID: 7, content: .group("missing")), .groupEnd("main")),
                (.init(workID: 7, content: .item(a)), .groupEnd("missing")),
                (.init(workID: 7, content: .item(a)), .item(category: "bonus", neighbor: b, after: false)),
                (.init(workID: 7, content: .item(a)), .item(category: "bonus", neighbor: a, after: true)),
                (.init(workID: 7, content: .item(a)), .groupEdge(category: "bonus", after: true)),
                (.init(workID: 7, content: .group("main")), .item(category: "bonus", neighbor: b, after: false))
            ]
            for (payload, target) in invalid {
                do { _ = try WorkReorderPlanner.plan(payload: payload, to: target, in: snapshot); h.expect(false, "失效落点不可猜") }
                catch { h.expect(true, "拒绝失效落点") }
            }
            let duplicate = WorkReorderSnapshot(workID: 7, groups: snapshot.groups + [snapshot.groups[0]])
            do {
                _ = try WorkReorderPlanner.plan(payload: .init(workID: 7, content: .item(a)), to: .groupEnd("bonus"), in: duplicate)
                h.expect(false, "重复身份应拒绝")
            } catch { h.expect(true, "不因 Dictionary 重复键崩溃") }
        }
    }

    h.suite("拖动事务、陈旧投递与重开") {
        func setup(_ database: SQLiteDatabase? = nil) throws -> (SQLiteDatabase, LibraryRepository, Int64, [TrackRecord], String) {
            let db = try database ?? SQLiteDatabase.inMemory()
            let repo = LibraryRepository(database: db)
            try repo.prepare()
            let source = try repo.saveSource(LibrarySource(name: "移动测试"))
            let work = try repo.upsertWork(WorkRecord(title: "作品", folderPath: "/move", folderRelativePath: ".", sourceID: source))
            try repo.replaceTracks(workID: work, tracks: ["a", "b", "c", "d", "e"].enumerated().map {
                TrackRecord(workID: work, fileName: $0.element + ".wav", filePath: "/move/" + $0.element + ".wav",
                    relativePath: $0.element + ".wav", fileType: "wav", category: $0.offset < 3 ? .main : .bonus)
            })
            let empty = try repo.addCustomCategory(workID: work, title: "空组")
            return (db, repo, work, try repo.tracks(workID: work), empty.key)
        }
        func snapshot(_ repo: LibraryRepository, _ work: Int64) throws -> WorkReorderSnapshot {
            WorkReorderSnapshot(workID: work, sections: try repo.organizedSections(workID: work, includeEmpty: true))
        }
        h.test("保存使用提示计划，组尾不再被 nil 邻项误当组首") {
            do {
                let (_, repo, work, tracks, empty) = try setup()
                let before = try snapshot(repo, work)
                let payload = WorkReorderPayload(workID: work, content: .item(.track(tracks[0].id)))
                let destination = WorkDropDestination.groupEnd("bonus")
                let preview = try WorkReorderPlanner.plan(payload: payload, to: destination, in: before)
                h.expectEqual(preview, .item(id: .track(tracks[0].id), category: "bonus",
                    orderedIDs: [.track(tracks[3].id), .track(tracks[4].id), .track(tracks[0].id)]), "预览具体落点")
                h.expect(try repo.applyReorder(payload: payload, to: destination, expected: before), "实际有改变")
                let after = try snapshot(repo, work)
                h.expectEqual(after.groups.first { $0.category.key == "bonus" }?.itemIDs,
                    [.track(tracks[3].id), .track(tracks[4].id), .track(tracks[0].id)], "保存与预览一致")
                h.expectEqual(after.groups.first { $0.category.key == "main" }?.itemIDs,
                    [.track(tracks[1].id), .track(tracks[2].id)], "来源组其它项相对顺序保持")
                _ = try repo.applyReorder(payload: payload, to: .groupEnd(empty), expected: after)
                h.expectEqual(try snapshot(repo, work).groups.first { $0.category.key == empty }?.itemIDs,
                    [.track(tracks[0].id)], "空组可投递")
                let current = try snapshot(repo, work)
                h.expectEqual(try repo.applyReorder(payload: payload, to: .groupEnd(empty), expected: current), false, "合法原位不写库")
            } catch { h.expect(false, "预览与保存：\(error)") }
        }
        h.test("隐藏默认分类必须包含在快照，整组搬动保持内容") {
            do {
                let (_, repo, work, _, empty) = try setup()
                let visible = WorkReorderSnapshot(workID: work, sections: try repo.organizedSections(workID: work))
                let full = try snapshot(repo, work)
                let payload = WorkReorderPayload(workID: work, content: .group(empty))
                do { _ = try repo.applyReorder(payload: payload, to: .groupStart("main"), expected: visible); h.expect(false, "不能用可见分类覆盖完整集合") }
                catch { h.expectEqual(try snapshot(repo, work), full, "拒绝后全部分类仍在") }
                _ = try repo.applyReorder(payload: payload, to: .groupStart("main"), expected: full)
                let after = try snapshot(repo, work)
                h.expectEqual(after.groups.map { $0.category.key }, [empty] + full.groups.map { $0.category.key }.filter { $0 != empty }, "仅移动整组位置")
                for group in full.groups {
                    h.expectEqual(after.groups.first { $0.category.key == group.category.key }?.itemIDs, group.itemIDs, "组内原顺序保持")
                }
            } catch { h.expect(false, "完整分组：\(error)") }
        }
        h.test("异步读取载荷期间列表变化必须重新操作，不能套用旧提示") {
            do {
                let (_, repo, work, tracks, empty) = try setup()
                let old = try snapshot(repo, work)
                let payload = WorkReorderPayload(workID: work, content: .item(.track(tracks[0].id)))
                _ = try repo.applyReorder(payload: .init(workID: work, content: .item(.track(tracks[4].id))), to: .groupStart("bonus"), expected: old)
                let newer = try snapshot(repo, work)
                do { _ = try repo.applyReorder(payload: payload, to: .groupEnd("bonus"), expected: old); h.expect(false, "旧坐标提示应失效") }
                catch { h.expectEqual(try snapshot(repo, work), newer, "不能覆盖期间的新顺序") }
                try repo.renameCategory(workID: work, key: empty, title: "新的组名")
                let renamed = try snapshot(repo, work)
                do { _ = try repo.applyReorder(payload: payload, to: .groupEnd(empty), expected: newer); h.expect(false, "改名后的旧提示应失效") }
                catch { h.expectEqual(try snapshot(repo, work), renamed, "不能静默改投新目标") }
                let foreign = WorkReorderPayload(workID: work + 100, content: .group("main"))
                do { _ = try repo.applyReorder(payload: foreign, to: .groupEnd("bonus"), expected: renamed); h.expect(false, "同名组也不能跨作品") }
                catch { h.expectEqual(try snapshot(repo, work), renamed, "跨作品无写入") }
            } catch { h.expect(false, "陈旧投递：\(error)") }
        }
        h.test("目标或原项删除后拒绝投递，排序写入失败完整回滚") {
            do {
                let (db, repo, work, tracks, _) = try setup()
                let old = try snapshot(repo, work)
                let payload = WorkReorderPayload(workID: work, content: .item(.track(tracks[0].id)))
                try db.executeScript("CREATE TRIGGER reject_move BEFORE UPDATE OF sort_order ON track WHEN NEW.id = \(tracks[3].id) BEGIN SELECT RAISE(ABORT, 'blocked'); END;")
                do { _ = try repo.applyReorder(payload: payload, to: .groupStart("bonus"), expected: old); h.expect(false, "中途写入应失败") }
                catch {
                    h.expectEqual(try snapshot(repo, work), old, "成员及次序全部回滚")
                    h.expectNil(try repo.track(id: tracks[0].id)?.categoryOverride, "自动分类不被部分改写")
                }
                try db.executeScript("DROP TRIGGER reject_move;")
                _ = try repo.removeMedia(workID: work, id: .track(tracks[3].id))
                let removed = try snapshot(repo, work)
                do { _ = try repo.applyReorder(payload: payload, to: .item(category: "bonus", neighbor: .track(tracks[3].id), after: true), expected: removed); h.expect(false, "目标消失不猜组尾") }
                catch { h.expectEqual(try snapshot(repo, work), removed, "目标消失没有写入") }
                _ = try repo.removeMedia(workID: work, id: .track(tracks[0].id))
                let sourceGone = try snapshot(repo, work)
                do { _ = try repo.applyReorder(payload: payload, to: .groupEnd("bonus"), expected: sourceGone); h.expect(false, "拖出的原项消失") }
                catch { h.expectEqual(try snapshot(repo, work), sourceGone, "原项消失没有写入") }
            } catch { h.expect(false, "失败原子性：\(error)") }
        }
        h.test("跨关闭重开保留组顺序、成员身份和组内插入位置") {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            do {
                let (db, repo, work, tracks, empty) = try setup(SQLiteDatabase(path: path))
                _ = try repo.applyReorder(payload: .init(workID: work, content: .item(.track(tracks[0].id))),
                    to: .item(category: "bonus", neighbor: .track(tracks[4].id), after: false), expected: snapshot(repo, work))
                _ = try repo.applyReorder(payload: .init(workID: work, content: .group("bonus")),
                    to: .groupStart("main"), expected: snapshot(repo, work))
                let expected = try snapshot(repo, work)
                db.close()
                let reopened = try SQLiteDatabase(path: path)
                h.expectEqual(try snapshot(LibraryRepository(database: reopened), work), expected, "重开保留精确结果")
                h.expect(expected.groups.contains { $0.category.key == empty }, "空组未丢")
                h.expectEqual(try reopened.query("PRAGMA foreign_key_check").count, 0, "外键完整")
                reopened.close()
            } catch { h.expect(false, "重开：\(error)") }
        }
    }
}
