import Foundation
import HibikiCore

private struct ClipSubtitleFixture {
    let db: SQLiteDatabase
    let library: LibraryRepository
    let playlist: PlaylistRepository
    let trackID: Int64
    let workID: Int64

    init(version: Int = Schema.currentVersion) throws {
        db = try SQLiteDatabase.inMemory()
        _ = try db.migrate(Schema.migrations.filter { $0.version <= version })
        library = LibraryRepository(database: db)
        playlist = PlaylistRepository(database: db)
        let sourceID = try library.saveSource(LibrarySource(name: "clip subtitle fixture"))
        workID = try library.upsertWork(WorkRecord(title: "source work", folderPath: "/clips/source", sourceID: sourceID))
        try library.replaceTracks(workID: workID, tracks: [
            TrackRecord(workID: workID, fileName: "source.wav", filePath: "/clips/source/source.wav", fileType: "wav", durationMS: 10_000)
        ])
        trackID = try library.tracks(workID: workID)[0].id
    }

    @discardableResult
    func add(_ snapshot: ClipSubtitleSnapshot? = nil, startMS: Int = 1000) throws -> Int64 {
        try playlist.addClip(trackID: trackID, title: "excerpt", workTitle: "source work", startMS: startMS,
                             endMS: startMS + 2500, filename: UUID().uuidString + ".caf", subtitles: snapshot)
        return try playlist.entries().first { $0.startMS == startMS }!.id
    }
}

func runClipSubtitleSuites(_ h: Harness) {
    func cue(_ start: Int, _ end: Int, _ text: String, translated: String? = nil,
             status: CueStatus = .ok) -> SubtitleCue {
        SubtitleCue(startMS: start, endMS: end, text: text, translatedText: translated, speaker: "speaker", status: status)
    }
    let original = [cue(0, 1500, "head", translated: "开头"), cue(2000, 5000, "tail", translated: "结尾")]
    let snapshot = ClipSubtitleSnapshot(cues: ClipSubtitleTimeline.crop(original, startMS: 1000, endMS: 3500),
                                        sourceLabel: "日本語 / 中文", capturedAt: Date(timeIntervalSince1970: 1_700_000_000))

    h.suite("摘选字幕时间轴") {
        h.test("头尾截断并归零，双语、角色和状态保留") {
            let source = [cue(0, 1500, "head", translated: "开头", status: .provisional),
                          cue(2000, 5000, "tail", translated: "结尾")]
            let cropped = ClipSubtitleTimeline.crop(source, startMS: 1000, endMS: 3500)
            h.expectEqual(cropped.map(\.startMS), [0, 1000])
            h.expectEqual(cropped.map(\.endMS), [500, 2500])
            h.expectEqual(cropped.map(\.text), ["head", "tail"])
            h.expectEqual(cropped.map(\.translatedText), ["开头", "结尾"])
            h.expectEqual(cropped.map(\.speaker), ["speaker", "speaker"])
            h.expectEqual(cropped[0].status, .provisional)
            h.expectEqual(cropped.map(\.index), [0, 1])
            h.expect(Set(source.map(\.id)).isDisjoint(with: cropped.map(\.id)), "摘选拥有独立 cue ID")
        }
        h.test("半开边界与未对齐文字不会被误带入") {
            let source = [cue(0, 1000, "before"), cue(1000, 2000, "inside"), cue(2000, 2500, "after"),
                          cue(1200, 1600, "untimed", status: .untimed), cue(1200, 1600, "unaligned", status: .unaligned),
                          cue(1400, 1400, "zero"), cue(-100, 1500, "invalid")]
            h.expectEqual(ClipSubtitleTimeline.crop(source, startMS: 1000, endMS: 2000).map(\.text), ["inside"])
            h.expect(ClipSubtitleTimeline.crop(source, startMS: -1, endMS: 2000).isEmpty, "拒绝负范围")
            h.expect(ClipSubtitleTimeline.crop(source, startMS: 2000, endMS: 1000).isEmpty, "拒绝反向范围")
        }
        h.test("无序重叠条目稳定排序，不丢同时出现的句子") {
            let result = ClipSubtitleTimeline.crop([cue(2000, 4000, "later"), cue(1000, 3500, "first"),
                                                    cue(1000, 2500, "second")], startMS: 1500, endMS: 3000)
            h.expectEqual(result.map(\.text), ["first", "second", "later"])
            h.expectEqual(result.map(\.startMS), [0, 0, 500])
            h.expectEqual(result.map(\.endMS), [1500, 1000, 1500])
        }
        h.test("按传入拼接顺序偏移，无字幕段也占时间，重复段有独立 ID") {
            let repeated = [cue(250, 1750, "same", translated: "同一句")]
            let result = try! ClipSubtitleTimeline.concatenate([
                ClipSubtitleSegment(cues: repeated, durationMS: 1000),
                ClipSubtitleSegment(cues: [], durationMS: 2750),
                ClipSubtitleSegment(cues: repeated, durationMS: 2000)
            ])
            h.expectEqual(result.map(\.startMS), [250, 4000])
            h.expectEqual(result.map(\.endMS), [1000, 5500])
            h.expectEqual(result.map(\.translatedText), ["同一句", "同一句"])
            h.expectEqual(result.map(\.index), [0, 1])
            h.expectEqual(Set(result.map(\.id)).count, 2)
        }
        h.test("非法或溢出片段时长拒绝保存") {
            for durations in [[0], [-1], [Int.max, 1]] {
                do {
                    _ = try ClipSubtitleTimeline.concatenate(durations.map { ClipSubtitleSegment(cues: [], durationMS: $0) })
                    h.expect(false, "必须拒绝 \(durations)")
                } catch { h.expect(true, "已拒绝非法时长") }
            }
        }
    }

    h.suite("摘选字幕独立持久化") {
        h.test("v21 迁移保留旧 CAF 条目，未回填与空快照可以区分") {
            let f = try! ClipSubtitleFixture(version: 21)
            let id = try! f.add()
            h.expectNil(try! f.playlist.clipSubtitles(entryID: id))
            _ = try! f.db.migrate(Schema.migrations)
            h.expectEqual(try! f.playlist.entries().map(\.id), [id])
            h.expectEqual(try! f.playlist.entries()[0].startMS, 1000)
            h.expectNil(try! f.playlist.clipSubtitles(entryID: id))
            try! f.playlist.saveClipSubtitles(entryID: id, snapshot: ClipSubtitleSnapshot(cues: []), onlyIfMissing: true)
            h.expectEqual(try! f.playlist.clipSubtitles(entryID: id)?.cues, [])
        }
        h.test("原曲字幕修改或删除整部作品，不改变已保存双语快照") {
            let f = try! ClipSubtitleFixture()
            let subtitles = SubtitleRepository(database: f.db)
            let source = try! subtitles.createTrack(trackID: f.trackID, kind: .manual, language: "ja", label: "source", cues: original)
            let id = try! f.add(snapshot)
            try! subtitles.replaceCues(versionID: source.version, with: [cue(0, 5000, "edited")])
            h.expectEqual(try! f.playlist.clipSubtitles(entryID: id), snapshot)
            try! f.library.deleteWork(id: f.workID)
            h.expectNil(try! f.library.track(id: f.trackID))
            h.expectNil(try! f.playlist.entries()[0].trackID)
            h.expectEqual(try! f.playlist.clipSubtitles(entryID: id), snapshot)
        }
        h.test("重复保存与补填不会覆盖原快照") {
            let f = try! ClipSubtitleFixture()
            let id = try! f.add(snapshot)
            let changed = ClipSubtitleSnapshot(cues: [cue(0, 2000, "changed")])
            let inserted = try! f.playlist.addClip(trackID: f.trackID, title: "duplicate", workTitle: "source", startMS: 1000,
                                                   endMS: 3500, filename: "duplicate.caf", subtitles: changed)
            h.expectEqual(inserted, false)
            try! f.playlist.saveClipSubtitles(entryID: id, snapshot: changed, onlyIfMissing: true)
            h.expectEqual(try! f.playlist.clipSubtitles(entryID: id), snapshot)
            h.expectEqual(try! f.db.queryInt("SELECT COUNT(*) FROM playlist_clip_subtitle"), 1)
        }
        h.test("字幕写入失败时，单段与拼接条目一起回滚") {
            let f = try! ClipSubtitleFixture()
            try! f.db.execute("""
                CREATE TRIGGER reject_clip_subtitles BEFORE INSERT ON playlist_clip_subtitle
                BEGIN SELECT RAISE(ABORT, 'injected subtitle persistence failure'); END;
                """)
            do { _ = try f.add(snapshot); h.expect(false, "单段必须失败") }
            catch { h.expect(true, "单段事务回滚") }
            do {
                try f.playlist.addMerged(title: "merged", workTitle: "source", coverWorkID: f.workID, durationMS: 2500,
                                         filename: "merged.caf", groupID: 2, subtitles: snapshot)
                h.expect(false, "拼接必须失败")
            } catch { h.expect(true, "拼接事务回滚") }
            h.expectEqual(try! f.playlist.entries().count, 0)
            h.expectEqual(try! f.db.queryInt("SELECT COUNT(*) FROM playlist_clip_subtitle"), 0)
        }
        h.test("删除摘选级联清除快照，不能给整曲或不存在条目写快照") {
            let f = try! ClipSubtitleFixture()
            let id = try! f.add(snapshot)
            try! f.playlist.remove(id: id)
            h.expectNil(try! f.playlist.clipSubtitles(entryID: id))
            try! f.playlist.addWholeTrack(trackID: f.trackID, title: "whole", workTitle: "source")
            let whole = try! f.playlist.entries()[0]
            for target in [whole.id, Int64.max] {
                do { try f.playlist.saveClipSubtitles(entryID: target, snapshot: snapshot); h.expect(false, "必须拒绝无效条目") }
                catch { h.expect(true, "拒绝无效条目") }
            }
        }
        h.test("拼接快照不依赖原始摘选或原作品") {
            let f = try! ClipSubtitleFixture()
            let id = try! f.add(snapshot)
            try! f.playlist.addMerged(title: "merged", workTitle: "source", coverWorkID: f.workID, durationMS: 5000,
                                     filename: "merged.caf", groupID: 2, subtitles: snapshot)
            let merged = try! f.playlist.entries().first(where: \.isMerged)!
            try! f.playlist.remove(id: id)
            try! f.library.deleteWork(id: f.workID)
            h.expectEqual(try! f.playlist.clipSubtitles(entryID: merged.id), snapshot)
            h.expectEqual(try! f.playlist.entries().map(\.id), [merged.id])
        }
    }
}
