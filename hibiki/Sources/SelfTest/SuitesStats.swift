import Foundation
import HibikiCore

/// 播放统计的测试套件
func runStatsSuites(_ h: Harness) {
    runListeningRecorderSuite(h)

    // 固定时区，保证测试结果不随机器设置漂移
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!

    func date(_ y: Int, _ mo: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0, _ ss: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = hh; c.minute = mm; c.second = ss
        return cal.date(from: c)!
    }

    func row(_ workID: Int64, _ dateKey: String, _ hour: Int?, _ seconds: Int,
             seiyuu: String? = nil, circle: String? = nil, title: String? = nil) -> PlayStatRow {
        PlayStatRow(workID: workID, title: title, seiyuuName: seiyuu,
                    circleName: circle, dateKey: dateKey, hourSlot: hour, seconds: seconds)
    }

    h.suite("趋势图空档") {
        h.test("七天里没播放的日期同样占一格") {
            let rows = [row(1, "2026-11-01", 22, 60), row(1, "2026-11-03", 1, 30)]
            let trend = ListeningTrend(rows: rows, period: .lastDays(7), now: date(2026, 11, 4), calendar: cal)
            h.expectEqual(trend.points.map(\.seconds), [0, 0, 0, 60, 0, 30, 0], "完整七日")
            h.expectEqual(trend.points.first?.bucketKey, "2026-10-29", "跨月开始")
            h.expectEqual(trend.points.last?.bucketKey, "2026-11-04", "止于当天")
        }
        h.test("今年补齐月份但不画尚未发生的月份") {
            let trend = ListeningTrend(rows: [row(1, "2026-03-01", 1, 17)], period: .thisYear,
                                       now: date(2026, 4, 5), calendar: cal)
            h.expectEqual(trend.points.map(\.seconds), [0, 0, 17, 0], "按月补零")
        }
    }
    // ─────────────────────────────────────────────────────────
    h.suite("播放时长按小时切分") {
        h.test("跨一小时：21:40 → 22:30") {
            let start = date(2026, 11, 2, 21, 40)
            let end = date(2026, 11, 2, 22, 30)
            let slices = PlaybackStatSplitter.split(start: start, end: end, calendar: cal)
            h.expectEqual(slices.count, 2, "应切成两段")
            h.expectEqual(slices[0].dateKey, "2026-11-02", "日期")
            h.expectEqual(slices[0].hourSlot, 21, "第一段在 21 点")
            h.expectEqual(slices[0].seconds, 20 * 60, "21 点应得 20 分钟")
            h.expectEqual(slices[1].hourSlot, 22, "第二段在 22 点")
            h.expectEqual(slices[1].seconds, 30 * 60, "22 点应得 30 分钟")
        }

        h.test("跨三个小时") {
            let start = date(2026, 11, 2, 21, 50)
            let end = date(2026, 11, 2, 23, 10)
            let slices = PlaybackStatSplitter.split(start: start, end: end, calendar: cal)
            h.expectEqual(slices.count, 3, "三段")
            h.expectEqual(slices.map(\.hourSlot), [21, 22, 23], "小时序列")
            h.expectEqual(slices.map(\.seconds), [600, 3600, 600], "各段秒数")
        }

        h.test("跨午夜") {
            let start = date(2026, 11, 2, 23, 50)
            let end = date(2026, 11, 3, 0, 20)
            let slices = PlaybackStatSplitter.split(start: start, end: end, calendar: cal)
            h.expectEqual(slices.count, 2, "两段")
            h.expectEqual(slices[0].dateKey, "2026-11-02", "第一天")
            h.expectEqual(slices[0].hourSlot, 23, "23 点")
            h.expectEqual(slices[0].seconds, 600, "10 分钟")
            h.expectEqual(slices[1].dateKey, "2026-11-03", "第二天")
            h.expectEqual(slices[1].hourSlot, 0, "0 点")
            h.expectEqual(slices[1].seconds, 1200, "20 分钟")
        }

        h.test("正好整点起止") {
            let start = date(2026, 11, 2, 21, 0)
            let end = date(2026, 11, 2, 22, 0)
            let slices = PlaybackStatSplitter.split(start: start, end: end, calendar: cal)
            h.expectEqual(slices.count, 1, "不应切成两段")
            h.expectEqual(slices[0].hourSlot, 21, "归 21 点")
            h.expectEqual(slices[0].seconds, 3600, "整整一小时")
        }

        h.test("零长与倒置") {
            let t = date(2026, 11, 2, 21, 0)
            h.expect(PlaybackStatSplitter.split(start: t, end: t, calendar: cal).isEmpty, "零长应为空")
            h.expect(PlaybackStatSplitter.split(start: t, end: t.addingTimeInterval(-100), calendar: cal).isEmpty, "倒置应为空")
        }

        h.test("不足一秒不丢（四舍五入）") {
            let start = date(2026, 11, 2, 21, 0, 0)
            let end = start.addingTimeInterval(0.6)
            let slices = PlaybackStatSplitter.split(start: start, end: end, calendar: cal)
            h.expectEqual(slices.count, 1, "一段")
            h.expectEqual(slices[0].seconds, 1, "0.6s 进位成 1s")
        }

        h.test("合并同一桶") {
            let slices = [
                HourSlice(dateKey: "2026-11-02", hourSlot: 21, seconds: 100),
                HourSlice(dateKey: "2026-11-02", hourSlot: 21, seconds: 200),
                HourSlice(dateKey: "2026-11-02", hourSlot: 22, seconds: 50)
            ]
            let merged = PlaybackStatSplitter.merge(slices)
            h.expectEqual(merged.count, 2, "桶数")
            h.expectEqual(merged[0].seconds, 300, "同桶相加")
            h.expectEqual(merged[1].seconds, 50, "另一桶")
        }

        h.test("日期键格式化") {
            h.expectEqual(PlaybackStatSplitter.dateKey(from: date(2026, 1, 5), calendar: cal), "2026-01-05", "补零")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("实时采集器") {
        h.test("播放→暂停→结算") {
            let recorder = PlaybackStatRecorder(calendar: cal)
            h.expect(!recorder.isRunning, "初始未运行")
            recorder.play(at: date(2026, 11, 2, 21, 40))
            h.expect(recorder.isRunning, "运行中")
            recorder.pause(at: date(2026, 11, 2, 22, 30))
            h.expect(!recorder.isRunning, "已暂停")
            let slices = recorder.flush(at: date(2026, 11, 2, 22, 30))
            h.expectEqual(slices.count, 2, "跨小时两段")
            h.expectEqual(slices[0].seconds, 1200, "21 点 20 分钟")
            h.expectEqual(slices[1].seconds, 1800, "22 点 30 分钟")
        }

        h.test("重复 play 不重复计时") {
            let recorder = PlaybackStatRecorder(calendar: cal)
            recorder.play(at: date(2026, 11, 2, 21, 0))
            recorder.play(at: date(2026, 11, 2, 21, 10))
            recorder.pause(at: date(2026, 11, 2, 21, 20))
            let slices = recorder.flush(at: date(2026, 11, 2, 21, 20))
            h.expectEqual(slices.first?.seconds, 1200, "只算第一次 play 之后")
        }

        h.test("seek 会先结算再继续") {
            let recorder = PlaybackStatRecorder(calendar: cal)
            recorder.play(at: date(2026, 11, 2, 21, 0))
            recorder.seek(at: date(2026, 11, 2, 21, 10))
            h.expect(recorder.isRunning, "拖动后仍在播放")
            recorder.pause(at: date(2026, 11, 2, 21, 20))
            let slices = recorder.flush(at: date(2026, 11, 2, 21, 20))
            h.expectEqual(slices.first?.seconds, 1200, "拖动前后共 20 分钟")
        }

        h.test("未播放时 flush 为空") {
            let recorder = PlaybackStatRecorder(calendar: cal)
            h.expect(recorder.flush(at: Date()).isEmpty, "应为空")
        }

        h.test("reset 丢弃累计") {
            let recorder = PlaybackStatRecorder(calendar: cal)
            recorder.play(at: date(2026, 11, 2, 21, 0))
            recorder.pause(at: date(2026, 11, 2, 21, 30))
            recorder.reset()
            h.expect(recorder.flush(at: date(2026, 11, 2, 21, 30)).isEmpty, "已清空")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("统计汇总") {
        let rows = [
            row(1, "2026-11-01", 21, 1800, seiyuu: "花子", circle: "社A", title: "作品一"),
            row(1, "2026-11-02", 22, 3600, seiyuu: "花子", circle: "社A", title: "作品一"),
            row(2, "2026-11-02", 23, 1200, seiyuu: "太郎", circle: "社B", title: "作品二"),
            row(3, "2026-11-04", 20, 600, seiyuu: "花子", circle: "社B", title: "作品三")
        ]

        h.test("总量与活跃天数") {
            let s = StatsAggregator.summary(rows, calendar: cal)
            h.expectEqual(s.totalSeconds, 7200, "总秒数")
            h.expectEqual(s.activeDays, 3, "活跃天数")
            h.expectEqual(s.distinctWorks, 3, "作品数")
            h.expectEqual(s.dailyAverageSeconds, 2400, "日均")
        }

        h.test("空数据不崩") {
            let s = StatsAggregator.summary([], calendar: cal)
            h.expectEqual(s.totalSeconds, 0, "总量")
            h.expectEqual(s.activeDays, 0, "天数")
            h.expectEqual(s.dailyAverageSeconds, 0, "日均")
            h.expectEqual(s.longestStreakDays, 0, "连续")
        }

        h.test("最长连续天数") {
            let s = StatsAggregator.summary(rows, calendar: cal)
            // 11/1, 11/2 连续 2 天；11/4 断开
            h.expectEqual(s.longestStreakDays, 2, "最长连续")
        }

        h.test("24 小时直方图") {
            let bins = StatsAggregator.hourHistogram(rows)
            h.expectEqual(bins.count, 24, "长度")
            h.expectEqual(bins[21], 1800, "21 点")
            h.expectEqual(bins[22], 3600, "22 点")
            h.expectEqual(bins[23], 1200, "23 点")
            h.expectEqual(bins[0], 0, "0 点为空")
        }

        h.test("hourSlot 缺失时不进直方图") {
            let r = [row(1, "2026-11-01", nil, 500)]
            let bins = StatsAggregator.hourHistogram(r)
            h.expectEqual(bins.reduce(0, +), 0, "缺小时的不计入")
        }

        h.test("星期×小时矩阵") {
            let matrix = StatsAggregator.weekdayHourMatrix(rows, calendar: cal)
            h.expectEqual(matrix.count, 7, "7 行")
            h.expectEqual(matrix[0].count, 24, "24 列")
            // 2026-11-01 是周日
            h.expectEqual(cal.component(.weekday, from: date(2026, 11, 1)), 1, "确认 11/1 是周日")
            h.expectEqual(matrix[0][21], 1800, "周日 21 点")
        }

        h.test("峰值时段") {
            let peak = StatsAggregator.peakSlot(rows, calendar: cal)
            h.expectNotNil(peak, "应有时段")
            h.expectEqual(peak?.seconds, 3600, "峰值秒数")
            h.expectEqual(peak?.hour, 22, "峰值小时")
        }

        h.test("按天趋势") {
            let daily = StatsAggregator.dailyTotals(rows)
            h.expectEqual(daily.count, 3, "三天")
            h.expectEqual(daily[0].bucketKey, "2026-11-01", "排序")
            h.expectEqual(daily[1].seconds, 4800, "11/2 合计（3600+1200）")
        }

        h.test("按周/月趋势") {
            let monthly = StatsAggregator.trend(rows, granularity: .month, calendar: cal)
            h.expectEqual(monthly.count, 1, "都在 11 月")
            h.expectEqual(monthly[0].seconds, 7200, "合计")
            h.expectEqual(monthly[0].bucketKey, "2026-11", "月份键")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("排行") {
        let rows = [
            row(1, "2026-11-01", 21, 1800, seiyuu: "花子", circle: "社A", title: "作品一"),
            row(1, "2026-11-02", 22, 3600, seiyuu: "花子", circle: "社A", title: "作品一"),
            row(2, "2026-11-02", 23, 1200, seiyuu: "太郎", circle: "社B", title: "作品二"),
            row(3, "2026-11-03", 20, 600, seiyuu: "花子", circle: "社B", title: "作品三")
        ]

        h.test("作品排行") {
            let top = StatsAggregator.topWorks(rows, limit: 3)
            h.expectEqual(top.count, 3, "条目数")
            h.expectEqual(top[0].name, "作品一", "第一名")
            h.expectEqual(top[0].seconds, 5400, "累计时长")
        }

        h.test("声优排行") {
            let top = StatsAggregator.topSeiyuu(rows, limit: 5)
            h.expectEqual(top[0].name, "花子", "第一名")
            h.expectEqual(top[0].seconds, 6000, "花子合计")
            h.expectEqual(top[0].workCount, 2, "花子有 2 部作品")
        }

        h.test("社团排行") {
            let top = StatsAggregator.topCircles(rows, limit: 5)
            h.expectEqual(top[0].name, "社A", "第一名")
            h.expectEqual(top[0].seconds, 5400, "社A 合计")
        }

        h.test("上限生效") {
            h.expectEqual(StatsAggregator.topSeiyuu(rows, limit: 1).count, 1, "限制为 1")
        }

        h.test("缺失名字归入未知") {
            let r = [row(9, "2026-11-01", 21, 100)]
            let top = StatsAggregator.topSeiyuu(r, limit: 5)
            h.expectEqual(top[0].name, "未知", "无名归未知")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("统计周期") {
        let now = date(2026, 11, 2, 15, 0)   // 2026-11-02 周一

        h.test("今天") {
            let r = StatPeriod.today.dateKeyRange(now: now, calendar: cal)
            h.expectEqual(r?.from, "2026-11-02", "from")
            h.expectEqual(r?.to, "2026-11-02", "to")
        }

        h.test("本周") {
            let r = StatPeriod.thisWeek.dateKeyRange(now: now, calendar: cal)
            // 2026-11-02 是周一，本周应是 11/1(周日) 或 11/2 起，取决于日历设置
            h.expectNotNil(r, "应有范围")
            if let r {
                h.expect(r.from <= "2026-11-02", "起点不晚于今天")
                h.expect(r.to >= "2026-11-02", "终点不早于今天")
            }
        }

        h.test("本月") {
            let r = StatPeriod.thisMonth.dateKeyRange(now: now, calendar: cal)
            h.expectEqual(r?.from, "2026-11-01", "from")
            h.expectEqual(r?.to, "2026-11-30", "to")
        }

        h.test("今年") {
            let r = StatPeriod.thisYear.dateKeyRange(now: now, calendar: cal)
            h.expectEqual(r?.from, "2026-01-01", "from")
            h.expectEqual(r?.to, "2026-12-31", "to")
        }

        h.test("最近 7 天") {
            let r = StatPeriod.lastDays(7).dateKeyRange(now: now, calendar: cal)
            h.expectEqual(r?.from, "2026-10-27", "from")
            h.expectEqual(r?.to, "2026-11-02", "to")
        }

        h.test("全部无范围") {
            h.expectNil(StatPeriod.all.dateKeyRange(now: now, calendar: cal), "应为 nil")
        }

        h.test("过滤生效") {
            let rows = [
                row(1, "2026-10-01", 21, 100),
                row(1, "2026-11-02", 21, 200)
            ]
            let filtered = StatPeriod.thisMonth.filter(rows, now: now, calendar: cal)
            h.expectEqual(filtered.count, 1, "只保留本月")
            h.expectEqual(filtered[0].seconds, 200, "内容正确")
        }

        h.test("自定义范围自动纠正顺序") {
            let a = date(2026, 11, 10)
            let b = date(2026, 11, 1)
            let r = StatPeriod.custom(from: a, to: b).dateKeyRange(now: now, calendar: cal)
            h.expectEqual(r?.from, "2026-11-01", "from")
            h.expectEqual(r?.to, "2026-11-10", "to")
        }

        h.test("显示名") {
            h.expectEqual(StatPeriod.thisMonth.displayName, "本月", "本月")
            h.expectEqual(StatPeriod.lastDays(30).displayName, "最近 30 天", "最近")
        }
    }
    runListeningDatabaseSuite(h)
}
