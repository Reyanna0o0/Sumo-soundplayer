import Foundation
import HibikiCore

private struct PlaylistOrderFixture {
    let db: SQLiteDatabase
    let library: LibraryRepository
    let lists: PlaylistRepository
    let tracks: [Int64]
    let work: Int64

    init(path: String = ":memory:", version: Int = Schema.currentVersion) throws {
        db = try SQLiteDatabase(path: path)
        try db.migrate(Schema.migrations.filter { $0.version <= version })
        library = LibraryRepository(database: db)
        lists = PlaylistRepository(database: db)
        let source = try library.saveSource(LibrarySource(name: "ordering fixture"))
        let workID = try library.upsertWork(WorkRecord(title: "source", folderPath: "/test/order", sourceID: source))
        work = workID
        try library.replaceTracks(workID: workID, tracks: (1...4).map {
            TrackRecord(workID: workID, fileName: "\($0).wav", filePath: "/test/order/\($0).wav", fileType: "wav", durationMS: 10_000)
        })
        tracks = try library.tracks(workID: work).map(\.id)
    }

    func add(_ track: Int, group: Int64 = 1) throws {
        try lists.addWholeTrack(trackID: tracks[track], title: "track \(track)", workTitle: "source", groupID: group)
    }
    func ids(_ group: Int64) throws -> [Int64] { try lists.entries().filter { $0.groupID == group }.map(\.id) }
}

func runPlaylistOrderingSuites(_ h: Harness) {
    func check(_ title: String, _ body: () throws -> Void) {
        h.test(title) { do { try body() } catch { h.expect(false, "意外错误：\(error)") } }
    }
    h.suite("播放列表条目排序与移动") {
        check("v25 升级保留旧记录与组内顺序，重新打开仍保留拖动排序") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
            defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
            let f = try PlaylistOrderFixture(path: url.path, version: 25)
            try f.add(0); try f.add(1); try f.add(2)
            let before = try f.lists.entries()
            try f.db.migrate(Schema.migrations)
            h.expectEqual(try f.lists.entries(), before, "升级不改原有记录")
            let original = try f.ids(1), reordered = [original[2], original[0], original[1]]
            try f.lists.orderEntries(groupID: 1, ids: reordered, expectedIDs: original)
            let reopened = try SQLiteDatabase(path: url.path)
            h.expectEqual(try PlaylistRepository(database: reopened).entries().map(\.id), reordered, "重开持久库")
            try f.add(3)
            h.expectEqual(try f.ids(1).prefix(3).map { $0 }, reordered, "新增曲目排在自定义顺序末尾")
            h.expectEqual(try f.ids(1).count, 4, "无丢失")
        }
        check("拒绝重复、跨组和过期拖动快照，失败不改数据") {
            let f = try PlaylistOrderFixture(); try f.add(0); try f.add(1)
            let other = try f.lists.createGroup(name: "other", isClips: false)
            try f.add(2, group: other)
            let original = try f.ids(1), foreign = try f.ids(other)[0], baseline = try f.lists.entries()
            for invalid in [[original[0], original[0]], [original[0], foreign], [original[0]]] {
                do { try f.lists.orderEntries(groupID: 1, ids: invalid, expectedIDs: original); h.expect(false, "应拒绝非法顺序") }
                catch PlaylistCollectionError.staleEntries {}
                h.expectEqual(try f.lists.entries(), baseline, "拒绝后原样")
            }
            try f.lists.orderEntries(groupID: 1, ids: original.reversed(), expectedIDs: original)
            do { try f.lists.orderEntries(groupID: 1, ids: original, expectedIDs: original); h.expect(false, "应拒绝过期快照") }
            catch PlaylistCollectionError.staleEntries {}
            h.expectEqual(try f.ids(1), Array(original.reversed()), "新顺序仍保留")
        }
        check("整曲移动追加到目标末尾，同曲重复时两边都保留") {
            let f = try PlaylistOrderFixture(); try f.add(0); try f.add(1)
            let target = try f.lists.createGroup(name: "target", isClips: false)
            try f.add(2, group: target)
            let origin = try f.ids(1), existing = try f.ids(target)
            try f.lists.moveEntry(id: origin[0], from: 1, to: target)
            h.expectEqual(try f.ids(target), existing + [origin[0]], "移动追加末尾")
            h.expectEqual(try f.ids(1), [origin[1]], "来源仅移走选中项")
            try f.add(1, group: target)
            let baseline = try f.lists.entries()
            do { try f.lists.moveEntry(id: origin[1], from: 1, to: target); h.expect(false, "重复应提示") }
            catch PlaylistCollectionError.duplicateEntry {}
            h.expectEqual(try f.lists.entries(), baseline, "重复不吞记录")
            do { try f.lists.moveEntry(id: origin[0], from: 1, to: target); h.expect(false, "过期来源应拒绝") }
            catch PlaylistCollectionError.staleEntries {}
        }
        check("视频与音轨编号相同也能共存，重复视频移动被拒绝") {
            let f = try PlaylistOrderFixture()
            try f.library.replaceScannedAttachments(workID: f.work,
                files: [WorkAttachment(relativePath: "video.mp4", kind: .video, byteCount: 1)])
            let video = try f.library.attachmentRecords(workID: f.work)[0]
            h.expectEqual(video.id, f.tracks[0], "覆盖两个表编号相同的情况")
            let target = try f.lists.createGroup(name: "videos", isClips: false)
            try f.add(0, group: target)
            try f.lists.addVideo(attachmentID: video.id, title: "video", workTitle: "source", groupID: 1)
            let entry = try f.ids(1)[0]
            try f.lists.moveEntry(id: entry, from: 1, to: target)
            h.expectEqual(try f.ids(target).count, 2, "音轨和视频不误判为重复")
            try f.lists.addVideo(attachmentID: video.id, title: "video", workTitle: "source", groupID: 1)
            let duplicate = try f.ids(1)[0], before = try f.lists.entries()
            do { try f.lists.moveEntry(id: duplicate, from: 1, to: target); h.expect(false, "重复视频应拒绝") }
            catch PlaylistCollectionError.duplicateEntry {}
            h.expectEqual(try f.lists.entries(), before, "两个视频条目均保留")
        }
        check("摘选和拼接移动、排序、删除分类后保留文件引用与字幕快照") {
            let f = try PlaylistOrderFixture()
            let target = try f.lists.createGroup(name: "clips", isClips: true)
            let snapshot = ClipSubtitleSnapshot(cues: [SubtitleCue(startMS: 0, endMS: 1000, text: "保存的字幕")],
                                                sourceLabel: "fixture", capturedAt: Date(timeIntervalSince1970: 100))
            try f.lists.addClip(trackID: f.tracks[0], title: "clip", workTitle: "work", startMS: 0, endMS: 1000,
                                filename: "preserved.caf", subtitles: snapshot)
            try f.lists.addMerged(title: "merged", workTitle: "work", coverWorkID: f.work, durationMS: 2000,
                                  filename: "merged.caf", groupID: target, subtitles: snapshot)
            let clip = try f.lists.entries().first { $0.clipFilename == "preserved.caf" }!
            let merged = try f.ids(target)[0]
            try f.lists.moveEntry(id: clip.id, from: 2, to: target)
            let moved = try f.lists.entries().first { $0.id == clip.id }!
            h.expectEqual(moved.clipFilename, clip.clipFilename, "同一个音频引用")
            h.expectEqual(moved.createdAt, clip.createdAt, "创建时间不变")
            h.expectEqual(moved.startMS, clip.startMS, "起点不变")
            h.expectEqual(moved.endMS, clip.endMS, "终点不变")
            h.expectEqual(try f.lists.clipSubtitles(entryID: clip.id), snapshot, "字幕不变")
            do { try f.lists.moveEntry(id: clip.id, from: target, to: 1); h.expect(false, "不能移到整曲分类") }
            catch PlaylistCollectionError.invalidGroup {}
            try f.lists.orderEntries(groupID: target, ids: [clip.id, merged], expectedIDs: [merged, clip.id])
            try f.lists.addMerged(title: "existing", workTitle: "", coverWorkID: nil, durationMS: 500,
                                  filename: "existing.caf", groupID: 2)
            let existing = try f.ids(2)
            try f.lists.deleteCollection(.clips, id: target)
            h.expectEqual(try f.ids(2), existing + [clip.id, merged], "分类移除后按源顺序追加")
            h.expectEqual(try f.lists.clipSubtitles(entryID: merged), snapshot, "拼接字幕仍保留")
            h.expectEqual(Set(try f.lists.entries().compactMap(\.clipFilename)), Set(["preserved.caf", "merged.caf", "existing.caf"]), "音频无丢失")
        }
    }
    h.suite("创作者、社团、声优排序持久化") {
        check("各目录独立、重建偏好对象后保留、重命名身份和新增项不打乱已有顺序") {
            let suite = "simo.order.tests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let prefs = DirectoryOrderPreferences(defaults: defaults)
            try prefs.reorder(["3", "1", "2"], visibleIDs: ["1", "2", "3"], allIDs: ["1", "2", "3"], scope: .creators)
            try prefs.reorder(["B", "A"], visibleIDs: ["A", "B"], allIDs: ["A", "B"], scope: .circles)
            let again = DirectoryOrderPreferences(defaults: UserDefaults(suiteName: suite)!)
            h.expectEqual(again.resolved(["2", "3", "1", "4"], scope: .creators), ["3", "1", "2", "4"], "按身份保持顺序，新作者追加")
            h.expectEqual(again.resolved(["A", "B"], scope: .circles), ["B", "A"], "社团保存")
            h.expectEqual(again.resolved(["A", "B"], scope: .performers), ["A", "B"], "声优不受影响")
        }
        check("筛选时只替换可见位置，过期或重复顺序不覆盖已保存内容") {
            let suite = "simo.order.tests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let prefs = DirectoryOrderPreferences(defaults: defaults)
            let all = ["name:A", "name:待填写", "name:C", "missing"]
            let visible = [all[0], all[2]]
            let swapped = [all[2], all[1], all[0], all[3]]
            h.expectEqual(try prefs.reorder(visible.reversed(), visibleIDs: visible, allIDs: all, scope: .performers), swapped, "隐藏项位置保留")
            for invalid in [[all[0], all[0]], visible] {
                do { try prefs.reorder(invalid, visibleIDs: visible, allIDs: all, scope: .performers); h.expect(false, "应拒绝非法或过期移动") }
                catch DirectoryOrderError.staleOrder {}
            }
            h.expectEqual(prefs.resolved(all, scope: .performers), swapped, "失败后原样")
            h.expectEqual(prefs.resolved([all[1], all[3]], scope: .performers), [all[1], all[3]], "名字待填写与未填项独立")
            h.expectEqual(prefs.resolved(all, scope: .performers), swapped, "筛选不抹去其他位置")
        }
    }
}
