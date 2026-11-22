import Foundation

/// 字幕查找器：按播放位置二分查找当前句。
///
/// 一处细节：真实字幕里会出现**时间重叠**（一句话还没结束下一句就开始了），
/// 所以不能假设"每个时刻只有一句"。这里返回"覆盖该时刻的第一句"，
/// 另外提供 `allIndices(at:)` 给需要同时显示两句的场景（比如双人对话）。
public struct SubtitleLocator: Sendable {

    /// 按 startMS 升序排好的副本
    public let cues: [SubtitleCue]
    private let startTimes: [Int]

    public init(cues: [SubtitleCue]) {
        let sorted = cues.filter(\.hasTiming).enumerated().sorted { a, b in
            a.element.startMS == b.element.startMS ? a.offset < b.offset : a.element.startMS < b.element.startMS
        }.map(\.element)
        self.cues = sorted
        self.startTimes = sorted.map(\.startMS)
    }

    /// 返回覆盖 `positionMS` 的条目下标；没有则 nil
    public func index(at positionMS: Int) -> Int? {
        indices(at: positionMS).active
    }

    /// 阅读定位在句间空白保持最近已开始的句子，片头定位第一句。
    public func readingCue(at positionMS: Int) -> SubtitleCue? {
        indices(at: positionMS).reading.map { cues[$0] }
    }

    private func indices(at positionMS: Int) -> (active: Int?, reading: Int?) {
        guard !cues.isEmpty else { return (nil, nil) }
        // 找到最后一个 start <= positionMS 的位置
        var lo = 0
        var hi = cues.count - 1
        var candidate: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if startTimes[mid] <= positionMS {
                candidate = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard var idx = candidate else { return (nil, 0) }
        // 从候选往前回溯最多若干条，处理重叠与"上一句还没结束"
        let floor = max(0, idx - 8)
        while idx >= floor {
            if cues[idx].contains(positionMS) { return (idx, idx) }
            if idx == 0 { break }
            idx -= 1
        }
        return (nil, candidate)
    }

    public func cue(at positionMS: Int) -> SubtitleCue? {
        index(at: positionMS).map { cues[$0] }
    }

    /// 所有覆盖该时刻的条目（重叠时可能多于一条）
    public func allIndices(at positionMS: Int) -> [Int] {
        guard let base = index(at: positionMS) else { return [] }
        var result = [base]
        var i = base - 1
        while i >= 0, cues[i].contains(positionMS), result.count < 8 {
            result.append(i)
            i -= 1
        }
        i = base + 1
        while i < cues.count, cues[i].contains(positionMS), result.count < 8 {
            result.append(i)
            i += 1
        }
        return result.sorted()
    }

    /// 给定位置的下一句（用于"提前预读"）
    public func next(after positionMS: Int) -> SubtitleCue? {
        guard let idx = index(at: positionMS) else {
            // 还没到第一句，或者已经结束
            if let first = cues.first, first.startMS > positionMS { return first }
            return nil
        }
        return idx + 1 < cues.count ? cues[idx + 1] : nil
    }

    /// 距离 `positionMS` 最近的句子开始时间（用于"跳到下一句"按钮）
    public func nextStart(after positionMS: Int) -> Int? {
        cues.lazy.map(\.startMS).first { $0 > positionMS }
    }

    public func previousStart(before positionMS: Int) -> Int? {
        cues.lazy.map(\.startMS).last { $0 < positionMS - 200 }
    }
}
