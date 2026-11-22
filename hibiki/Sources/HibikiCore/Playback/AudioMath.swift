import Foundation

/// 速度 / 音调的取值限制与换算。
///
/// 记几个容易踩的点：
/// - `AVAudioUnitTimePitch.rate` 的可用范围是 1/32…32，但**超过 2 倍人耳就明显失真**，
///   所以我们限制在 0.5…4.0，并给界面一个"推荐区间"。
/// - 432Hz 调音 = 相对 440Hz 降 **31.77 音分**（不是整整一个半音）。
/// - `AVAudioUnitTimePitch.pitch` 的单位是**音分**（1 半音 = 100 音分）。
public enum AudioMath {

    /// 允许的播放速度范围
    public static let rateRange: ClosedRange<Double> = 0.5...4.0
    /// 界面上"听起来还自然"的速度范围
    public static let recommendedRateRange: ClosedRange<Double> = 0.75...1.5
    /// 允许的音调范围（半音）
    public static let semitoneRange: ClosedRange<Double> = -12...12
    /// 音分范围（相对 440Hz）
    public static let centsRange: ClosedRange<Double> = -1_200...1_200

    public static func clampRate(_ rate: Double) -> Double {
        min(max(rate, rateRange.lowerBound), rateRange.upperBound)
    }

    public static func clampSemitones(_ semitones: Double) -> Double {
        min(max(semitones, semitoneRange.lowerBound), semitoneRange.upperBound)
    }

    public static func clampCents(_ cents: Double) -> Double {
        min(max(cents, centsRange.lowerBound), centsRange.upperBound)
    }

    /// 频率比 → 音分
    public static func cents(from reference: Double, to frequency: Double) -> Double {
        guard reference > 0, frequency > 0 else { return 0 }
        return 1_200 * log2(frequency / reference)
    }

    /// 把 A4 基准频率换算成需要施加的音分偏移。
    /// 440Hz → 0；432Hz → 约 −31.77 音分。
    public static func centsFromStandardTuning(a4: Double) -> Double {
        cents(from: 440.0, to: a4)
    }

    /// 432Hz 调音对应的音分（常用预设）
    public static var cents432: Double { centsFromStandardTuning(a4: 432.0) }

    /// 半音 → 音分
    public static func cents(fromSemitones semitones: Double) -> Double {
        semitones * 100
    }

    /// 速度变化的听感提示（界面用）
    public static func isRateNatural(_ rate: Double) -> Bool {
        recommendedRateRange.contains(rate)
    }
}

/// 淡入淡出曲线。
///
/// 播放/暂停用等功率曲线（听感上音量变化更均匀），
/// 线性曲线在中段会显得"掉得快"。
public enum FadeCurve: String, Sendable, CaseIterable {
    case linear
    case equalPower

    public var displayName: String {
        switch self {
        case .linear: return InterfaceLocalization.text("线性")
        case .equalPower: return InterfaceLocalization.text("等功率（听感更匀）")
        }
    }
}

public enum FadeEnvelope {

    /// 计算淡入过程中的增益
    /// - Parameters:
    ///   - elapsed: 已经过去的时间（秒）
    ///   - duration: 淡入总时长（秒）；<= 0 时直接返回满音量
    public static func gain(elapsed: Double, duration: Double, curve: FadeCurve = .equalPower) -> Float {
        guard duration > 0 else { return 1 }
        let progress = min(max(elapsed / duration, 0), 1)
        return self.gain(progress: progress, curve: curve)
    }

    /// 计算某个进度点（0…1）的增益
    public static func gain(progress: Double, curve: FadeCurve = .equalPower) -> Float {
        let p = min(max(progress, 0), 1)
        switch curve {
        case .linear:
            return Float(p)
        case .equalPower:
            // sin 曲线：两端变化慢、中间快，听感更自然
            return Float(sin(p * .pi / 2))
        }
    }

    /// 淡出：`elapsed` 是淡出已经开始多久
    public static func fadeOutGain(elapsed: Double, duration: Double, curve: FadeCurve = .equalPower) -> Float {
        guard duration > 0 else { return 0 }
        let progress = min(max(elapsed / duration, 0), 1)
        let remaining = 1 - progress
        return gain(progress: remaining, curve: curve)
    }
}

/// 续播与"听完"的判定规则。
///
/// 这些规则看着琐碎，但直接决定统计准不准：
/// 听 3 秒就退出的不该记续播点；听到最后 2 秒退出不该下次又从最后 2 秒继续。
public enum ResumePolicy {

    /// 至少听了这么久才值得记续播点
    public static let minimumPositionToSaveMS = 5_000
    /// 距离结尾这么近就不记续播（下次从头开始更合理）
    public static let endThresholdMS = 10_000
    /// 听到这个比例就算"听完"
    public static let listenedRatio = 0.9

    /// 是否应该保存续播位置
    public static func shouldSavePosition(positionMS: Int, durationMS: Int?) -> Bool {
        guard positionMS >= minimumPositionToSaveMS else { return false }
        if let duration = durationMS, duration > 0 {
            // 已经到结尾附近了，不再记续播
            if positionMS >= duration - endThresholdMS { return false }
        }
        return true
    }

    /// 下次续播应该从哪开始
    public static func resumePosition(savedMS: Int, durationMS: Int?) -> Int {
        guard shouldSavePosition(positionMS: savedMS, durationMS: durationMS) else { return 0 }
        return savedMS
    }

    /// 是否算"听完"
    public static func shouldMarkListened(positionMS: Int, durationMS: Int?) -> Bool {
        guard let durationMS, durationMS > 0 else { return false }
        return Double(positionMS) / Double(durationMS) >= listenedRatio
    }
}
