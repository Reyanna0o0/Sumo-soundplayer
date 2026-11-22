import Foundation
import HibikiCore

func runFormalVideoSuites(_ h: Harness) {
    h.suite("正式视频身份与续播") {
        h.test("音轨、视频和摘选编号互不混淆；删改保留队列身份和随机顺序") {
            let audio = PlaybackQueueItem(workID: 1, trackID: 8, workTitle: "A", trackTitle: "audio", filePath: "a.wav", fileType: "wav")
            let video = PlaybackQueueItem(workID: 1, trackID: 0, workTitle: "A", trackTitle: "video", filePath: "v.mp4", fileType: "mp4", attachmentID: 8)
            let clip = PlaybackQueueItem(workID: 1, trackID: -8, workTitle: "A", trackTitle: "clip", filePath: "c.caf", fileType: "caf")
            var queue = PlaybackQueue.make(items: [audio, video, clip], startingAt: 1, shuffled: true, seed: 4)
            let identity = queue.current?.id
            queue.updateFilePaths([8: "renamed.wav", 0: "wrong.mp4"])
            h.expectEqual(queue.current?.filePath, "v.mp4", "音轨重配不混入附件")
            queue.removeTracks([8])
            h.expectEqual(queue.current?.id, identity, "保留当前视频身份")
            h.expectEqual(queue.items.count, 2, "仅移除音轨")
            h.expect(queue.isShuffled, "保留随机模式")
            queue.removeMedia([.attachment(8)])
            h.expectEqual(queue.items, [clip], "附件移除不误删同号摘选")
            h.expect(video.isVideo && !video.isSavedClip, "正式视频不标成摘选")
        }
        h.test("v18迁移原表不变；视频位置独立、重扫保持、删除级联") {
            do {
                let fixture = try RelinkingFixture(version: 18)
                let db = fixture.db, repo = fixture.library
                let names = try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").compactMap { $0.string("name") }
                var before: [String: [SQLRow]] = [:]
                for name in names { before[name] = try db.query("SELECT * FROM \"\(name)\" ORDER BY rowid") }
                h.expectEqual(try db.migrate(Schema.migrations.filter { $0.version <= 19 }), 1, "运行 v19 视频位置迁移")
                for name in names { h.expectEqual(try db.query("SELECT * FROM \"\(name)\" ORDER BY rowid"), before[name]!, "保留 \(name)") }
                let file = WorkAttachment(relativePath: "video.mp4", kind: .video, byteCount: 123)
                try repo.appendOwnedMedia(workID: fixture.workID, tracks: [], attachments: [WorkAttachmentRecord(workID: fixture.workID, attachment: file, assetRelativePath: "Attachments/video.mp4")])
                let video = try repo.attachmentRecords(workID: fixture.workID).first { $0.attachment.kind == .video }!
                try repo.saveVideoPlaybackPosition(attachmentID: video.id, workID: fixture.workID, positionMS: 43210)
                h.expectEqual(try repo.videoPlaybackPosition(attachmentID: video.id), 43210, "视频位置")
                let work = try repo.work(id: fixture.workID)!
                h.expectEqual(work.lastPlayedTrackID, fixture.tracks[0].id, "不覆盖音频续播轨道")
                h.expectEqual(work.lastPlayedPositionMS, 12345, "不覆盖音频续播位置")
                do { try repo.saveVideoPlaybackPosition(attachmentID: video.id, workID: fixture.workID + 100, positionMS: 22); h.expect(false, "错误作品必须拒绝") }
                catch { h.expectEqual(try repo.videoPlaybackPosition(attachmentID: video.id), 43210, "错误归属不修改") }
                try repo.replaceScannedAttachments(workID: fixture.workID, files: fixture.attachments.map(\.attachment))
                h.expectEqual(try repo.videoPlaybackPosition(attachmentID: video.id), 43210, "重扫保留独立视频")
                _ = try repo.removeMedia(workID: fixture.workID, id: .attachment(video.id))
                h.expectEqual(try db.query("SELECT count(*) AS n FROM video_playback_position").first?.int("n"), 0, "删除级联")
            } catch { h.expect(false, "\(error)") }
        }
    }
}
