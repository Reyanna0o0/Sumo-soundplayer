import Foundation

/// 一条统计记录（对应数据库 `play_statistic` 表的一行）。
public struct PlayStatRow: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var workID: Int64
    public var title: String?
    public var seiyuuNames: [String]
    public var seiyuuName: String? {
        get { seiyuuNames.isEmpty ? nil : seiyuuNames.joined(separator: "、") }
        set { seiyuuNames = newValue.map(FolderClassifier.performerNames) ?? [] }
    }
    public var circleName: String?
    /// Nil means a mixed or otherwise unattributable independent clip.
    public var libraryKind: MediaLibraryKind?
    public var creatorID: Int64?
    public var creatorName: String?
    /// "2026-11-02"
    public var dateKey: String
    /// 0…23；历史数据可能为 nil
    public var hourSlot: Int?
    public var seconds: Int

    public init(
        id: Int64 = 0,
        workID: Int64,
        title: String? = nil,
        seiyuuName: String? = nil,
        seiyuuNames: [String]? = nil,
        circleName: String? = nil,
        dateKey: String,
        hourSlot: Int? = nil,
        seconds: Int,
        libraryKind: MediaLibraryKind? = .collection,
        creatorID: Int64? = nil,
        creatorName: String? = nil
    ) {
        self.id = id
        self.workID = workID
        self.title = title
        self.seiyuuNames = seiyuuNames ?? seiyuuName.map(FolderClassifier.performerNames) ?? []
        self.circleName = circleName
        self.dateKey = dateKey
        self.hourSlot = hourSlot
        self.seconds = seconds
        self.libraryKind = workID > 0 ? libraryKind : nil
        self.creatorID = workID > 0 && libraryKind == .personal ? creatorID : nil
        self.creatorName = workID > 0 && libraryKind == .personal ? creatorName : nil
    }
}

/// 统计概览
public struct StatsSummary: Equatable, Sendable {
    public var totalSeconds: Int = 0
    public var activeDays: Int = 0
    public var distinctWorks: Int = 0
    public var dailyAverageSeconds: Double = 0
    /// 连续收听天数（最长）
    public var longestStreakDays: Int = 0
    /// 当前连续天数（截至最近一次有记录的日子）
    public var currentStreakDays: Int = 0
}

/// Identity of the listening rows contributing to a displayed name bucket.
public enum RankAttribution: Equatable, Sendable {
    case creator(Int64?)
    case voice
    case circle
    case mixed
}

/// 排行条目
public struct RankEntry: Equatable, Sendable, Identifiable {
    public var id: String { workID.map { "work-\($0)" } ?? name }
    public var workID: Int64?
    public var name: String
    public var seconds: Int
    public var workCount: Int
    public var attribution: RankAttribution?

    public init(name: String, seconds: Int, workCount: Int = 0, workID: Int64? = nil,
                attribution: RankAttribution? = nil) {
        self.attribution = attribution
        self.workID = workID
        self.name = name
        self.seconds = seconds
        self.workCount = workCount
    }
}

/// 按天/周/月的趋势点
public struct TrendPoint: Equatable, Sendable, Identifiable {
    public var id: String { bucketKey }
    public var bucketKey: String
    public var seconds: Int
    public var label: String

    public init(bucketKey: String, seconds: Int, label: String) {
        self.bucketKey = bucketKey
        self.seconds = seconds
        self.label = label
    }
}

public enum TrendGranularity: String, Sendable {
    case day
    case week
    case month
}

/// 统计汇总计算。
///
/// 全部是纯函数：传入行数组，返回结果。不碰数据库、不碰 UI，
/// 这样能在没装 Xcode 的环境里完整验证（事实如此：本文件已被自测覆盖）。
public enum StatsAggregator {

    // MARK: - 概览

    public static func summary(_ rows: [PlayStatRow], calendar: Calendar = .current, now: Date = Date()) -> StatsSummary {
        var result = StatsSummary()
        guard !rows.isEmpty else { return result }

        var daily: [String: Int] = [:]
        var works = Set<Int64>()
        for row in rows {
            result.totalSeconds += row.seconds
            daily[row.dateKey, default: 0] += row.seconds
            if row.workID > 0 { works.insert(row.workID) }
        }

        result.activeDays = daily.count
        result.distinctWorks = works.count
        result.dailyAverageSeconds = daily.isEmpty
            ? 0
            : Double(result.totalSeconds) / Double(daily.count)

        let sortedDays = daily.keys.sorted()
        result.longestStreakDays = longestStreak(sortedDays, calendar: calendar)
        result.currentStreakDays = currentStreak(sortedDays, now: now, calendar: calendar)
        return result
    }

    static func longestStreak(_ sortedDateKeys: [String], calendar: Calendar) -> Int {
        guard !sortedDateKeys.isEmpty else { return 0 }
        var best = 1
        var run = 1
        var previous = parseDateKey(sortedDateKeys[0], calendar: calendar)
        for key in sortedDateKeys.dropFirst() {
            guard let current = parseDateKey(key, calendar: calendar) else { continue }
            if let prev = previous, daysBetween(prev, current, calendar: calendar) == 1 {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = current
        }
        return best
    }

    static func currentStreak(_ sortedDateKeys: [String], now: Date, calendar: Calendar) -> Int {
        guard let lastKey = sortedDateKeys.last,
              let last = parseDateKey(lastKey, calendar: calendar)
        else { return 0 }

        let today = calendar.startOfDay(for: now)
        let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: today).day
        // 今天或昨天有记录才算"当前连续"
        guard gap == 0 || gap == 1 else { return 0 }

        var streak = 1
        var previous = last
        for key in sortedDateKeys.dropLast().reversed() {
            guard let current = parseDateKey(key, calendar: calendar) else { continue }
            if daysBetween(current, previous, calendar: calendar) == 1 {
                streak += 1
                previous = current
            } else {
                break
            }
        }
        return streak
    }

    // MARK: - 按天

    public static func dailyTotals(_ rows: [PlayStatRow]) -> [TrendPoint] {
        var buckets: [String: Int] = [:]
        for row in rows { buckets[row.dateKey, default: 0] += row.seconds }
        return buckets.keys.sorted().map { key in
            TrendPoint(bucketKey: key, seconds: buckets[key] ?? 0, label: shortLabel(key))
        }
    }

    // MARK: - 热力图

    /// 24 小时分布（长度为 24 的秒数数组）
    public static func hourHistogram(_ rows: [PlayStatRow]) -> [Int] {
        var bins = [Int](repeating: 0, count: 24)
        for row in rows {
            guard let hour = row.hourSlot, (0...23).contains(hour) else { continue }
            bins[hour] += row.seconds
        }
        return bins
    }

    /// 星期 × 小时 矩阵：`[weekday][hour]`，weekday 0 = 周日（与 Calendar 一致）
    public static func weekdayHourMatrix(
        _ rows: [PlayStatRow], calendar: Calendar = .current
    ) -> [[Int]] {
        var matrix = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 7)
        for row in rows {
            guard let hour = row.hourSlot, (0...23).contains(hour) else { continue }
            guard let date = parseDateKey(row.dateKey, calendar: calendar) else { continue }
            let weekday = calendar.component(.weekday, from: date) - 1
            guard (0...6).contains(weekday) else { continue }
            matrix[weekday][hour] += row.seconds
        }
        return matrix
    }

    /// 找出一周里听得最多的那个"时段"（例如周日晚 22 点）
    public static func peakSlot(_ rows: [PlayStatRow], calendar: Calendar = .current) -> (weekday: Int, hour: Int, seconds: Int)? {
        let matrix = weekdayHourMatrix(rows, calendar: calendar)
        var best: (Int, Int, Int)?
        for weekday in 0..<7 {
            for hour in 0..<24 {
                let v = matrix[weekday][hour]
                if v > (best?.2 ?? 0) { best = (weekday, hour, v) }
            }
        }
        guard let b = best else { return nil }
        return (weekday: b.0, hour: b.1, seconds: b.2)
    }

    // MARK: - 排行

    public static func topWorks(_ rows: [PlayStatRow], limit: Int = 10) -> [RankEntry] {
        var seconds: [Int64: Int] = [:]
        var titles: [Int64: String] = [:]
        for row in rows where row.workID > 0 {
            seconds[row.workID, default: 0] += row.seconds
            if let t = row.title, !t.isEmpty { titles[row.workID] = t }
        }
        var entries: [RankEntry] = []
        entries.reserveCapacity(seconds.count)
        for (workID, secs) in seconds {
            let title = titles[workID] ?? InterfaceLocalization.text("作品 #\(workID)")
            entries.append(RankEntry(name: title, seconds: secs, workID: workID))
        }
        entries.sort { a, b in
            if a.seconds != b.seconds { return a.seconds > b.seconds }
            if a.name != b.name { return a.name < b.name }
            return (a.workID ?? 0) < (b.workID ?? 0)
        }
        return Array(entries.prefix(max(0, limit)))
    }

    public static func topSeiyuu(_ rows: [PlayStatRow], limit: Int = 10,
                                 attribution: ((PlayStatRow) -> RankAttribution)? = nil) -> [RankEntry] {
        rankBy(rows, names: { $0.seiyuuNames }, limit: limit, attribution: attribution)
    }

    public static func topCircles(_ rows: [PlayStatRow], limit: Int = 10,
                                  attribution: ((PlayStatRow) -> RankAttribution)? = nil) -> [RankEntry] {
        rankBy(rows, names: { [$0.circleName ?? ""] }, limit: limit, attribution: attribution)
    }

    static func rankBy(
        _ rows: [PlayStatRow],
        names: (PlayStatRow) -> [String],
        limit: Int,
        attribution: ((PlayStatRow) -> RankAttribution)? = nil
    ) -> [RankEntry] {
        var seconds: [String: Int] = [:]
        var works: [String: Set<Int64>] = [:]
        var subjects: [String: RankAttribution] = [:]
        let unknown = "未知"
        for row in rows where row.workID > 0 {
            var keys = Set(names(row).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            keys.remove("")
            if keys.isEmpty { keys.insert(unknown) }
            let subject = attribution?(row)
            for key in keys {
                if let subject {
                    if let existing = subjects[key], existing != subject {
                        subjects[key] = .mixed
                    } else {
                        subjects[key] = subject
                    }
                }
                seconds[key, default: 0] += row.seconds
                works[key, default: []].insert(row.workID)
            }
        }
        var entries: [RankEntry] = []
        entries.reserveCapacity(seconds.count)
        for (key, secs) in seconds {
            let count = works[key].map { $0.count } ?? 0
            entries.append(RankEntry(name: key, seconds: secs, workCount: count, attribution: subjects[key]))
        }
        entries.sort { a, b in
            if a.seconds != b.seconds { return a.seconds > b.seconds }
            return a.name < b.name
        }
        return Array(entries.prefix(max(0, limit)))
    }

    // MARK: - 趋势

    public static func trend(
        _ rows: [PlayStatRow],
        granularity: TrendGranularity,
        calendar: Calendar = .current
    ) -> [TrendPoint] {
        var buckets: [String: Int] = [:]
        for row in rows {
            let key = bucketKey(for: row.dateKey, granularity: granularity, calendar: calendar)
            buckets[key, default: 0] += row.seconds
        }
        return buckets.keys.sorted().map { key in
            TrendPoint(bucketKey: key, seconds: buckets[key] ?? 0, label: bucketLabel(key))
        }
    }

    static func bucketKey(for dateKey: String, granularity: TrendGranularity, calendar: Calendar) -> String {
        guard let date = parseDateKey(dateKey, calendar: calendar) else { return dateKey }
        switch granularity {
        case .day:
            return dateKey
        case .week:
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return String(format: "%04d-W%02d", comps.yearForWeekOfYear ?? 1970, comps.weekOfYear ?? 1)
        case .month:
            return String(dateKey.prefix(7))
        }
    }

    static func bucketLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        if key.contains("-W") { return String(key.suffix(3)) }
        if parts.count >= 3 { return "\(parts[1])/\(parts[2])" }
        if parts.count == 2 { return "\(parts[0])/\(parts[1])" }
        return key
    }

    static func shortLabel(_ dateKey: String) -> String {
        let parts = dateKey.split(separator: "-")
        guard parts.count == 3 else { return dateKey }
        return "\(parts[1])/\(parts[2])"
    }

    // MARK: - 日期工具

    public static func parseDateKey(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = 12  // 正午，避开夏令时边界
        return calendar.date(from: comps)
    }

    static func daysBetween(_ a: Date, _ b: Date, calendar: Calendar) -> Int {
        let startA = calendar.startOfDay(for: a)
        let startB = calendar.startOfDay(for: b)
        let diff = calendar.dateComponents([.day], from: startA, to: startB).day ?? 0
        return abs(diff)
    }
}

// MARK: - 时间范围

/// 统计周期
public enum StatPeriod: Equatable, Sendable {
    case today
    case thisWeek
    case thisMonth
    case thisYear
    case all
    case lastDays(Int)
    case custom(from: Date, to: Date)

    /// 返回日期键范围（含首含尾）；`.all` 返回 nil
    public func dateKeyRange(now: Date = Date(), calendar: Calendar = .current) -> (from: String, to: String)? {
        let today = calendar.startOfDay(for: now)
        func key(_ date: Date) -> String { PlaybackStatSplitter.dateKey(from: date, calendar: calendar) }

        switch self {
        case .all:
            return nil
        case .today:
            let k = key(today)
            return (k, k)
        case .thisWeek:
            let interval = calendar.dateInterval(of: .weekOfYear, for: today)
            let start = interval?.start ?? today
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            return (key(start), key(end))
        case .thisMonth:
            let interval = calendar.dateInterval(of: .month, for: today)
            let start = interval?.start ?? today
            let end = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .month, value: 1, to: start) ?? start) ?? start
            return (key(start), key(end))
        case .thisYear:
            let interval = calendar.dateInterval(of: .year, for: today)
            let start = interval?.start ?? today
            let end = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .year, value: 1, to: start) ?? start) ?? start
            return (key(start), key(end))
        case .lastDays(let n):
            let count = max(1, n)
            let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
            return (key(start), key(today))
        case .custom(let from, let to):
            let a = calendar.startOfDay(for: min(from, to))
            let b = calendar.startOfDay(for: max(from, to))
            return (key(a), key(b))
        }
    }

    /// 过滤行
    public func filter(_ rows: [PlayStatRow], now: Date = Date(), calendar: Calendar = .current) -> [PlayStatRow] {
        guard let range = dateKeyRange(now: now, calendar: calendar) else { return rows }
        return rows.filter { $0.dateKey >= range.from && $0.dateKey <= range.to }
    }

    public var displayName: String {
        switch self {
        case .today: return InterfaceLocalization.text("今天")
        case .thisWeek: return InterfaceLocalization.text("本周")
        case .thisMonth: return InterfaceLocalization.text("本月")
        case .thisYear: return InterfaceLocalization.text("今年")
        case .all: return InterfaceLocalization.text("全部")
        case .lastDays(let n): return InterfaceLocalization.text("最近 \(n) 天")
        case .custom: return InterfaceLocalization.text("自定义")
        }
    }
}
