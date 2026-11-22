import Foundation
import HibikiCore

func runListeningRecorderSuite(_ h: Harness) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7,
                                                   hour: 23, minute: 59, second: 58))!
    let first = PlayStatRow(workID: 1, title: "本篇", dateKey: "", seconds: 0)
    let second = PlayStatRow(workID: 2, title: "特典", dateKey: "", seconds: 0)
    func detail(_ work: PlayStatRow, _ date: Date) -> ListeningSessionDelta {
        ListeningSessionDelta(startedAt: date, workID: work.workID, trackID: work.workID * 10,
                              workTitle: work.title!, trackTitle: "试听音轨", isSavedClip: false)
    }

    h.suite("实际收听计时") {
        h.test("跨午夜、主动结算和再次结算") {
            var clock = ListeningTimeRecorder()
            let playback = detail(first, start)
            clock.start(work: first, detail: playback, uptime: 10)
            clock.checkpoint(date: start.addingTimeInterval(3), uptime: 13, continuing: true, calendar: calendar)
            var saved: [PlayStatRow] = []
            clock.save { rows, sessions in
                saved += rows
                h.expectEqual(sessions.map(\.id), [playback.id], "跨午夜仍算同次播放")
                h.expectEqual(sessions.first?.seconds, 3, "第一次检查点的明细增量")
            }
            h.expectEqual(saved.first { $0.dateKey == "2026-11-07" }?.seconds, 2, "午夜之前")
            h.expectEqual(saved.first { $0.hourSlot == 0 }?.seconds, 1, "午夜之后")
            clock.checkpoint(date: start.addingTimeInterval(4), uptime: 14, continuing: false, calendar: calendar)
            clock.save { rows, sessions in
                saved += rows
                h.expectEqual(sessions.first?.id, playback.id, "继续同一条明细")
                h.expectEqual(sessions.first?.seconds, 1, "后续只记新增时长")
            }
            clock.save { _, _ in h.expect(false, "重复结算不应再写") }
            h.expectEqual(saved.map(\.seconds).reduce(0, +), 4, "播放总量")
        }
        h.test("频繁暂停恢复与快速切换作品") {
            var clock = ListeningTimeRecorder()
            for n in 0..<8 {
                let t = Double(n * 10)
                let date = start.addingTimeInterval(t)
                clock.start(work: first, detail: detail(first, date), uptime: t)
                clock.checkpoint(date: date.addingTimeInterval(0.25), uptime: t + 0.25,
                                 continuing: false, calendar: calendar)
                clock.start(work: second, detail: detail(second, date.addingTimeInterval(3)), uptime: t + 3)
                clock.checkpoint(date: date.addingTimeInterval(3.5), uptime: t + 3.5,
                                 continuing: false, calendar: calendar)
            }
            var recorded: [ListeningSessionDelta] = []
            clock.save { rows, sessions in
                recorded = sessions
                h.expectEqual(rows.filter { $0.workID == 1 }.map(\.seconds).reduce(0, +), 2, "短播累积")
                h.expectEqual(rows.filter { $0.workID == 2 }.map(\.seconds).reduce(0, +), 4, "静音间隔不计")
            }
            h.expectEqual(recorded.map(\.seconds).reduce(0, +), 6, "明细与总时长一致")
        }
        h.test("同一轨暂停再播放留下两次开始时间") {
            var clock = ListeningTimeRecorder()
            let initial = detail(first, start)
            clock.start(work: first, detail: initial, uptime: 1)
            clock.checkpoint(date: start.addingTimeInterval(2), uptime: 3, continuing: false, calendar: calendar)
            let resumeDate = start.addingTimeInterval(60)
            let resumed = ListeningSessionDelta(startedAt: resumeDate, startTimeZoneID: "America/Los_Angeles",
                                                workID: first.workID, trackID: initial.trackID,
                                                workTitle: initial.workTitle, trackTitle: initial.trackTitle,
                                                isSavedClip: false)
            clock.start(work: first, detail: resumed, uptime: 61)
            clock.checkpoint(date: resumeDate.addingTimeInterval(3), uptime: 64, continuing: false, calendar: calendar)
            var history: [ListeningSessionDelta] = []
            clock.save { _, sessions in history = sessions.sorted { $0.startedAt < $1.startedAt } }
            h.expectEqual(history.map(\.id), [initial.id, resumed.id], "重新开播生成新会话")
            h.expectEqual(history.map(\.seconds), [2, 3], "中间的 58 秒不计")
            h.expectEqual(history.last?.startDateKey, "2026-11-07", "保留开听时的当地日期")
            h.expectEqual(history.last?.startTimeZoneID, "America/Los_Angeles", "保留当时时区")
        }
        h.test("校时、写入失败和换轨后重试") {
            var clock = ListeningTimeRecorder()
            let initial = detail(first, start)
            clock.start(work: first, detail: initial, uptime: 100)
            let adjusted = start.addingTimeInterval(86400)
            clock.checkpoint(date: adjusted, uptime: 105, continuing: false, calendar: calendar)
            enum Failure: Error { case unavailable }
            do {
                try clock.save { _, _ in throw Failure.unavailable }
                h.expect(false, "存储错误应上抛")
            } catch {}
            let clip = ListeningSessionDelta(startedAt: adjusted, workID: 2, trackID: -3,
                                             workTitle: "特典", trackTitle: "独立摘选", isSavedClip: true)
            clock.start(work: second, detail: clip, uptime: 150)
            clock.checkpoint(date: adjusted.addingTimeInterval(3), uptime: 153, continuing: false, calendar: calendar)
            var saved: [PlayStatRow] = []
            clock.save { rows, sessions in
                saved = rows
                h.expectEqual(Set(sessions.map(\.id)), Set([initial.id, clip.id]), "失败后两次会话都保留")
                h.expectEqual(sessions.first { $0.isSavedClip }?.trackID, -3, "保留独立摘选来源")
            }
            h.expectEqual(saved.filter { $0.workID == 1 }.map(\.seconds).reduce(0, +), 5, "旧记录按连续走时保留")
            h.expectEqual(saved.filter { $0.workID == 2 }.map(\.seconds).reduce(0, +), 3, "未串到新作品")
            clock.save { _, _ in h.expect(false, "重试成功后不可重复写") }
        }
    }
}
