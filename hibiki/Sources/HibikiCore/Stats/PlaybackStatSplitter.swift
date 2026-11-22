import Foundation

/// 一段播放时长被切分到"某天某小时"之后的结果。
///
/// 为什么要切：你要求 24 小时收听热力图。如果只听"21:40 听到 22:30"这一整段，
/// 直接记到 21 点会少算 30 分钟，记到 22 点会多算 20 分钟。
/// 必须按整点切开：20 分钟给 21 点，30 分钟给 22 点。
public struct HourSlice: Equatable, Hashable, Sendable {
    /// 本地日期，形如 "2026-11-02"
    public let dateKey: String
    /// 0…23
    public let hourSlot: Int
    public let seconds: Int

    public init(dateKey: String, hourSlot: Int, seconds: Int) {
        self.dateKey = dateKey
        self.hourSlot = hourSlot
        self.seconds = seconds
    }
}

/// 把播放区间切成按小时计费的片段。
public enum PlaybackStatSplitter {

    /// 切分 `[start, end)`。
    ///
    /// - Parameters:
    ///   - start: 开始时刻
    ///   - end: 结束时刻（必须严格晚于 start，否则返回空）
    ///   - calendar: 用于取本地日期与整点边界；必须带正确的 timeZone
    public static func split(start: Date, end: Date, calendar: Calendar = .current) -> [HourSlice] {
        var slices: [HourSlice] = []
        forEachHour(start: start, end: end, calendar: calendar) { day, hour, duration in
            let seconds = Int(duration.rounded())
            if seconds > 0 {
                slices.append(HourSlice(dateKey: day, hourSlot: hour, seconds: seconds))
            }
        }
        return slices
    }

    static func forEachHour(start: Date, end: Date, calendar: Calendar,
                            visit: (String, Int, TimeInterval) -> Void) {
        var cursor = start
        for _ in 0..<(24 * 366) {
            guard cursor < end else { break }
            let boundary = calendar.dateInterval(of: .hour, for: cursor)?.end ?? cursor.addingTimeInterval(3600)
            let segmentEnd = min(boundary, end)
            guard segmentEnd > cursor else { break }
            let parts = calendar.dateComponents([.year, .month, .day, .hour], from: cursor)
            visit(dateKey(from: parts), parts.hour ?? 0, segmentEnd.timeIntervalSince(cursor))
            cursor = segmentEnd
        }
    }

    /// 合并同一 (日期, 小时) 的片段
    public static func merge(_ slices: [HourSlice]) -> [HourSlice] {
        var buckets: [String: Int] = [:]
        var order: [String] = []
        for s in slices {
            let key = "\(s.dateKey)#\(s.hourSlot)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: 0] += s.seconds
        }
        return order.map { key in
            let parts = key.split(separator: "#")
            let dateKey = String(parts[0])
            let hour = Int(parts[1]) ?? 0
            return HourSlice(dateKey: dateKey, hourSlot: hour, seconds: buckets[key] ?? 0)
        }
    }

    public static func dateKey(from comps: DateComponents) -> String {
        String(
            format: "%04d-%02d-%02d",
            comps.year ?? 1970,
            comps.month ?? 1,
            comps.day ?? 1
        )
    }

    public static func dateKey(from date: Date, calendar: Calendar = .current) -> String {
        dateKey(from: calendar.dateComponents([.year, .month, .day], from: date))
    }
}

/// 实时统计采集器。
///
/// 用法：
/// ```
/// recorder.play()        // 开始播
/// ...                    // 中途不要动它
/// recorder.pause()       // 暂停
/// let slices = recorder.flush()   // 结算，写数据库
/// ```
/// 关键点：**暂停、拖动进度、切歌、退到后台之前都要先 flush**，
/// 否则这段时长会丢（或者更糟：一直累加导致虚高）。
public final class PlaybackStatRecorder {

    private var sessionStart: Date?
    private var completedSlices: [HourSlice] = []
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public var isRunning: Bool { sessionStart != nil }

    /// 本次会话（从上次 flush 到现在）已累计的秒数
    public var accumulatedSeconds: Int {
        completedSlices.reduce(0) { $0 + $1.seconds }
    }

    public func play(at now: Date = Date()) {
        guard sessionStart == nil else { return }
        sessionStart = now
    }

    /// 暂停：把这段计入待结算
    public func pause(at now: Date = Date()) {
        guard let start = sessionStart else { return }
        completedSlices.append(contentsOf: PlaybackStatSplitter.split(start: start, end: now, calendar: calendar))
        sessionStart = nil
    }

    /// 拖动进度时调用：先结算，若仍在播放则从当前时刻重新计时
    public func seek(at now: Date = Date()) {
        let wasRunning = isRunning
        pause(at: now)
        if wasRunning { play(at: now) }
    }

    /// 结算并清空，返回按 (日期, 小时) 合并后的片段
    public func flush(at now: Date = Date()) -> [HourSlice] {
        if let start = sessionStart {
            completedSlices.append(contentsOf: PlaybackStatSplitter.split(start: start, end: now, calendar: calendar))
            sessionStart = now  // 保持继续计时
        }
        let result = PlaybackStatSplitter.merge(completedSlices)
        completedSlices.removeAll()
        return result
    }

    /// 丢弃当前累计（例如判断为无效播放）
    public func reset() {
        sessionStart = nil
        completedSlices.removeAll()
    }
}
