import Foundation
import HibikiCore

func runListeningDatabaseSuite(_ h: Harness) {
    h.suite("真实收听记录") {
        h.test("旧库升级，保留原进度，从零统计，重启与移除作品不丢历史") {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
            defer { try? FileManager.default.removeItem(at: file) }
            let db = try! SQLiteDatabase(path: file.path)
            _ = try! db.migrate(Schema.migrations.filter { $0.version <= 13 })
            let library = LibraryRepository(database: db)
            let source = try! library.saveSource(LibrarySource(name: "原库"))
            let workID = try! library.upsertWork(WorkRecord(title: "原题", seiyuuName: "甲、乙",
                                                            folderPath: "/source", sourceID: source))
            try! library.savePlaybackPosition(workID: workID, trackID: 10, positionMS: 600_000)
            _ = try! library.prepare()
            h.expectEqual(try! library.work(id: workID)?.lastPlayedPositionMS, 600_000, "老进度未动")
            h.expect(try! library.listeningRows(period: .all).isEmpty, "不把历史位置猜成时长")
            let row = PlayStatRow(workID: workID, title: "原题", dateKey: "2026-11-07", hourSlot: 3, seconds: 7)
            try! library.recordListening([row, row])
            var previousDay = row
            previousDay.dateKey = "2026-11-06"
            try! library.recordListening([previousDay])
            let original = try! library.listeningRows(period: .all)
            h.expectEqual(original.map(\.seconds), [7, 14], "同一小时累加，不同日期分开")
            h.expectEqual(original.last?.seiyuuNames, ["甲", "乙"], "沿用媒体库原多人标签")
            try! library.updateWorkMetadata(workID: workID, title: "新名", circleName: "社团", seiyuuNames: ["甲 & 乙", "丙"])
            let edited = try! library.listeningRows(period: .all)
            h.expectEqual(edited.last?.title, "新名", "改名后历史显示现名")
            h.expectEqual(edited.last?.seiyuuNames, ["甲 & 乙", "丙"], "手填姓名保留内部符号")
            try! library.deleteWork(id: workID)
            db.close()
            let reopened = try! SQLiteDatabase(path: file.path)
            let repo = LibraryRepository(database: reopened)
            h.expectEqual(try! repo.prepare(), 0, "重新打开无需二次升级")
            h.expectEqual(try! repo.listeningRows(period: .all), edited, "删除作品后保留最近资料和秒数")
            try! repo.recordListening([row])
            let final = try! repo.listeningRows(period: .all).last
            h.expectEqual(final?.seconds, 21, "删除过程中尚待保存的几秒也计入")
            h.expectEqual(final?.title, "新名", "迟到的原名不覆盖删除时的最新名称")
        }
        h.test("整批失败回滚，重试只计算一次") {
            let db = try! SQLiteDatabase.inMemory()
            let library = LibraryRepository(database: db)
            _ = try! library.prepare()
            let row = PlayStatRow(workID: 0, dateKey: "2026-11-07", hourSlot: 12, seconds: 20)
            var invalid = row
            invalid.hourSlot = 25
            do {
                try library.recordListening([row, invalid])
                h.expect(false, "须拒绝无效小时")
            } catch {
                h.expect(try! library.listeningRows(period: .all).isEmpty, "失败不留下半批")
            }
            try! library.recordListening([row])
            let rows = try! library.listeningRows(period: .all)
            let summary = StatsAggregator.summary(rows)
            h.expectEqual(summary.totalSeconds, 20, "独立摘选照计收听")
            h.expectEqual(StatsAggregator.hourHistogram(rows)[12], 20, "时段中有摘选")
            h.expectEqual(summary.distinctWorks, 0, "来源不明不计作品数")
            h.expect(StatsAggregator.topWorks(rows).isEmpty, "不冒充来源作品")
            h.expect(StatsAggregator.topSeiyuu(rows).isEmpty, "独立摘选不算进声优")
        }
        h.test("同名作品、多人署名与相同总时长") {
            let a = PlayStatRow(workID: 1, title: "同名", seiyuuNames: ["甲", "甲", "乙"], dateKey: "2026-11-07", seconds: 15)
            var b = a
            b.workID = 2
            b.seiyuuNames = ["甲"]
            let rows = [b, a]
            let works = StatsAggregator.topWorks(rows)
            h.expectEqual(works.map(\.workID), [1, 2], "相同时长排序稳定")
            h.expectEqual(Set(works.map(\.id)).count, 2, "同名作品有各自的行")
            let actors = StatsAggregator.topSeiyuu(rows)
            h.expectEqual(actors.map(\.seconds), [30, 15], "双人分别统计同一轨，不累计重复署名")
            h.expectEqual(actors.map(\.workCount), [2, 1], "作品数各自计算")
            h.expectEqual(StatsAggregator.summary(rows).totalSeconds, 30, "双人不重复计算总时长")
        }
        h.test("本地午夜、滚动周期与夏令时") {
            let database = try! SQLiteDatabase.inMemory()
            let library = LibraryRepository(database: database)
            _ = try! library.prepare()
            var nz = Calendar(identifier: .gregorian)
            nz.timeZone = TimeZone(identifier: "Pacific/Auckland")!
            let clock = ISO8601DateFormatter()
            let now = clock.date(from: "2026-11-07T11:30:00Z")!  // 本地 11/8 00:30
            for day in ["2026-10-09", "2026-10-10", "2026-11-01", "2026-11-02", "2026-11-07", "2026-11-08"] {
                try! library.recordListening([PlayStatRow(workID: 1, dateKey: day, hourSlot: 5, seconds: 10)])
            }
            func days(_ period: StatPeriod) -> [String] {
                try! library.listeningRows(period: period, now: now, calendar: nz).map(\.dateKey)
            }
            h.expectEqual(days(.today), ["2026-11-08"], "本地今天，非 UTC 今天")
            h.expectEqual(days(.lastDays(7)), ["2026-11-02", "2026-11-07", "2026-11-08"], "包含今天的七个自然日")
            h.expectEqual(days(.lastDays(30)).first, "2026-10-10", "近三十日左边界")
            let start = clock.date(from: "2026-04-04T13:30:00Z")! // 02:30 NZDT → 02:30 NZST
            let slices = PlaybackStatSplitter.split(start: start, end: start.addingTimeInterval(3600), calendar: nz)
            h.expectEqual(PlaybackStatSplitter.merge(slices),
                          [HourSlice(dateKey: "2026-04-05", hourSlot: 2, seconds: 3600)], "重复的小时如实合计")
        }
        h.test("逐次明细、小时增量和新播放次数在同一事务提交") {
            let db = try! SQLiteDatabase.inMemory()
            let library = LibraryRepository(database: db)
            _ = try! db.migrate(Schema.migrations.filter { $0.version <= 14 })
            let source = try! library.saveSource(LibrarySource(name: "源"))
            let work = try! library.upsertWork(WorkRecord(title: "作品", folderPath: "/a", sourceID: source))
            let old = PlayStatRow(workID: work, title: "作品", dateKey: "2026-11-06", hourSlot: 23, seconds: 7)
            try! library.recordListening([old])
            _ = try! library.prepare()
            h.expect(try! library.listeningHistory(period: .all, limit: 10).isEmpty, "升级保留小时统计且不伪造旧明细")
            let clock = ISO8601DateFormatter()
            let start = clock.date(from: "2026-11-06T10:59:52Z")!
            let tz = TimeZone(identifier: "Pacific/Auckland")!
            var nz = Calendar(identifier: .gregorian)
            nz.timeZone = tz
            let session = ListeningSessionDelta(startedAt: start, startTimeZoneID: tz.identifier, workID: work,
                                                trackID: -3, workTitle: "作品", trackTitle: "摘选", isSavedClip: true, seconds: 7)
            try! library.recordListening([old], sessions: [session])
            var later = old
            later.dateKey = "2026-11-07"
            later.hourSlot = 0
            later.seconds = 16
            var delta = session
            delta.seconds = later.seconds
            var invalid = session
            invalid.seconds = -1
            do {
                try library.recordListening([later], sessions: [delta, invalid])
                h.expect(false, "历史写入失败必须抛错")
            } catch {
                h.expectEqual(try! library.listeningRows(period: .all).map(\.seconds), [14], "小时表回滚")
                h.expectEqual(try! library.listeningHistory(period: .all, limit: 10).map(\.seconds), [7], "明细表回滚")
            }
            try! library.recordListening([later], sessions: [delta])
            try! library.savePlaybackPosition(workID: work, trackID: 45, positionMS: 60_000, countAsPlay: false)
            h.expectEqual(try! library.work(id: work)?.playCount, 1, "多次结算和保存续播不重复记次数")
            let nextDay = start.addingTimeInterval(60)
            let history = try! library.listeningHistory(period: .today, limit: 20, now: start, calendar: nz)
            h.expectEqual(history.map(\.id), [session.id], "跨午夜时所有结算仍属于同一明细")
            h.expectEqual(history.first?.seconds, 23, "回滚重试后恰好一次")
            h.expectEqual(history.first?.startTimeZoneID, tz.identifier, "保留当地时区以供日后旅行后显示")
            h.expectEqual(history.first?.startDateKey, "2026-11-06", "按开听日归类")
            h.expectEqual(history.first?.isSavedClip, true, "明细识别摘选")
            h.expect(try! library.listeningHistory(period: .today, limit: 10, now: nextDay, calendar: nz).isEmpty,
                     "跨午夜的同次播放不会在第二天明细中重复出现")
            h.expectEqual(try! library.listeningRows(period: .today, now: nextDay, calendar: nz).map(\.seconds),
                          [16], "第二天仍有实际听到的秒数")
            let next = ListeningSessionDelta(startedAt: nextDay, startTimeZoneID: tz.identifier, workID: work, trackID: 5,
                                             workTitle: "作品", trackTitle: "正片", isSavedClip: false, seconds: 5)
            var second = later
            second.seconds = 5
            try! library.recordListening([second], sessions: [next])
            h.expectEqual(try! library.work(id: work)?.playCount, 2, "换曲是新会话")
            h.expectEqual(try! library.listeningHistory(period: .all, limit: 1).first?.trackTitle, "正片", "按最近排序并取指定条数")
            try! library.deleteWork(id: work)
            h.expectEqual(try! library.listeningHistory(period: .all, limit: 10).map(\.workTitle),
                          ["作品", "作品"], "作品移除仍能看到原明细")
        }
    }
}
