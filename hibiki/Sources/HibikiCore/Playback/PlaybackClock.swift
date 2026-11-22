import Foundation

/// 播放位置的时间模型。
///
/// 为什么需要它：音频引擎给出的位置来自渲染时间戳，**更新频率只有几 Hz**，
/// 直接拿来驱动进度条会一跳一跳的。这里维护一个"锚点 + 速率"的时钟，
/// 界面每帧按它算位置，等到引擎回传真实位置时再校准（seek / 卡顿时）。
///
/// 纯时间数学，不碰音频，所以能完整单元测试。
public struct PlaybackClock: Equatable, Sendable {

    /// 锚点位置（毫秒）
    public private(set) var anchorPositionMS: Int
    /// 锚点时刻
    public private(set) var anchorDate: Date?
    /// 播放速率（1.0 = 原速）
    public private(set) var rate: Double
    public private(set) var isRunning: Bool
    /// 当前音轨总时长（毫秒），用于夹紧位置；nil 表示未知
    public private(set) var durationMS: Int?

    public init(positionMS: Int = 0, rate: Double = 1.0, isRunning: Bool = false, durationMS: Int? = nil) {
        self.anchorPositionMS = max(0, positionMS)
        self.anchorDate = nil
        self.rate = AudioMath.clampRate(rate)
        self.isRunning = isRunning
        self.durationMS = durationMS
    }

    /// 当前应该播放到哪里（毫秒）
    public func position(at now: Date = Date()) -> Int {
        guard isRunning, let anchorDate else { return anchorPositionMS }
        let elapsed = now.timeIntervalSince(anchorDate)
        guard elapsed > 0 else { return anchorPositionMS }
        let advanced = Int(elapsed * rate * 1000)
        var position = anchorPositionMS + advanced
        if let durationMS, durationMS > 0 {
            position = min(position, durationMS)
        }
        return max(0, position)
    }

    /// 播放进度 0…1（时长未知时返回 0）
    public func progress(at now: Date = Date()) -> Double {
        guard let durationMS, durationMS > 0 else { return 0 }
        return min(1, max(0, Double(position(at: now)) / Double(durationMS)))
    }

    public mutating func play(at now: Date = Date()) {
        guard !isRunning else { return }
        // 把当前位置固化到锚点，再开始计时
        anchorPositionMS = position(at: now)
        anchorDate = now
        isRunning = true
    }

    public mutating func pause(at now: Date = Date()) {
        guard isRunning else { return }
        anchorPositionMS = position(at: now)
        anchorDate = nil
        isRunning = false
    }

    /// 跳转（播放中跳转会从新位置继续计时）
    public mutating func seek(to positionMS: Int, at now: Date = Date()) {
        var target = max(0, positionMS)
        if let durationMS, durationMS > 0 {
            target = min(target, durationMS)
        }
        anchorPositionMS = target
        anchorDate = isRunning ? now : nil
    }

    /// 改变速率（保持当前位置连续）
    public mutating func setRate(_ newRate: Double, at now: Date = Date()) {
        let clamped = AudioMath.clampRate(newRate)
        guard clamped != rate else { return }
        // 先把已播放的部分结算进锚点，再换速率
        anchorPositionMS = position(at: now)
        anchorDate = isRunning ? now : nil
        rate = clamped
    }

    /// 换一首歌时重置
    public mutating func reset(positionMS: Int = 0, durationMS: Int? = nil, at now: Date = Date()) {
        self.durationMS = durationMS
        self.anchorPositionMS = max(0, positionMS)
        self.anchorDate = isRunning ? now : nil
    }

    public mutating func setDuration(_ durationMS: Int?) {
        self.durationMS = durationMS
        if let durationMS, durationMS > 0, anchorPositionMS > durationMS {
            anchorPositionMS = durationMS
        }
    }

    /// 用引擎回传的真实位置校准（漂移超过阈值才校正，避免抖动）
    /// - Returns: 是否真的校正了
    @discardableResult
    public mutating func reconcile(enginePositionMS: Int, at now: Date = Date(), toleranceMS: Int = 250) -> Bool {
        let current = position(at: now)
        guard abs(current - enginePositionMS) > toleranceMS else { return false }
        anchorPositionMS = max(0, enginePositionMS)
        anchorDate = isRunning ? now : nil
        return true
    }
}
