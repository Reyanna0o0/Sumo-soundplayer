import Foundation

/// 字幕时间码的解析与格式化。
///
/// 内部一律用 **毫秒整数** 表示时间，避免浮点误差累积
/// （两小时音频用 Float 秒会出现 ±0.1s 级的漂移，字幕对不齐）。
public enum SubtitleTime {

    // MARK: - 解析

    /// 解析时间码字符串，返回毫秒。无法解析返回 nil。
    ///
    /// 支持格式：
    /// - `HH:MM:SS,mmm`（SRT）
    /// - `HH:MM:SS.mmm`（WebVTT）
    /// - `H:MM:SS.cc`   （ASS/SSA，厘秒）
    /// - `MM:SS.xx`     （LRC，厘秒）
    /// - `MM:SS`        （无小数）
    /// - 省略小时：`MM:SS.mmm`
    public static func parseMilliseconds(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 统一个小数分隔符，便于后面处理
        let unified = s.replacingOccurrences(of: ",", with: ".")
        let parts = unified.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let hourText = parts.count == 3 ? parts[0] : "0"
        let minuteText = parts.count == 3 ? parts[1] : parts[0]
        let secondText = parts.count == 3 ? parts[2] : parts[1]

        // 小时允许有符号（极少见，但不该崩）
        guard let hours = Int(hourText.trimmingCharacters(in: .whitespaces)),
              let minutes = Int(minuteText.trimmingCharacters(in: .whitespaces))
        else { return nil }
        guard hours >= 0, minutes >= 0, minutes < 60 else { return nil }

        // 秒部分可能带小数
        let secondSplit = secondText.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let secondsInt = Int(secondSplit[0].trimmingCharacters(in: .whitespaces)), secondsInt >= 0, secondsInt < 60
        else { return nil }

        var fractionMS = 0
        if secondSplit.count > 1 {
            guard let fractionMS_unwrapped = fractionToMilliseconds(secondSplit[1]) else { return nil }
            fractionMS = fractionMS_unwrapped
        }

        return ((hours * 3600) + (minutes * 60) + secondsInt) * 1000 + fractionMS
    }

    /// 把小数部分换算成毫秒。
    /// 1 位 = 十分之一秒，2 位 = 厘秒，3 位及以上 = 毫秒（多余位数四舍五入）。
    static func fractionToMilliseconds(_ digits: String) -> Int? {
        let d = digits.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty, d.allSatisfy(\.isNumber) else { return nil }
        switch d.count {
        case 1: return (Int(d) ?? 0) * 100
        case 2: return (Int(d) ?? 0) * 10
        case 3: return Int(d) ?? 0
        default:
            let head = String(d.prefix(3))
            let tail = String(d.dropFirst(3))
            var value = Int(head) ?? 0
            if let firstTail = tail.first, let n = firstTail.wholeNumberValue, n >= 5 { value += 1 }
            return value
        }
    }

    // MARK: - 格式化

    /// SRT：`00:01:23,456`（逗号）
    public static func srt(_ milliseconds: Int) -> String {
        let t = normalize(milliseconds)
        return String(format: "%02d:%02d:%02d,%03d", t.h, t.m, t.s, t.ms)
    }

    /// WebVTT：`00:01:23.456`（点）
    public static func vtt(_ milliseconds: Int) -> String {
        let t = normalize(milliseconds)
        return String(format: "%02d:%02d:%02d.%03d", t.h, t.m, t.s, t.ms)
    }

    /// LRC：`[01:23.45]`（厘秒）
    public static func lrc(_ milliseconds: Int) -> String {
        let t = normalize(milliseconds)
        let totalMinutes = t.h * 60 + t.m
        return String(format: "[%02d:%02d.%02d]", totalMinutes, t.s, t.ms / 10)
    }

    /// LRC 的时间部分（不含方括号）
    public static func lrcInner(_ milliseconds: Int) -> String {
        let t = normalize(milliseconds)
        let totalMinutes = t.h * 60 + t.m
        return String(format: "%02d:%02d.%02d", totalMinutes, t.s, t.ms / 10)
    }

    /// ASS/SSA：`0:00:01.23`（厘秒，小时不补零）
    public static func ass(_ milliseconds: Int) -> String {
        let t = normalize(milliseconds)
        return String(format: "%d:%02d:%02d.%02d", t.h, t.m, t.s, t.ms / 10)
    }

    /// 给人看的时钟：不足 1 小时 `12:34`，超过 `1:02:15`
    public static func clock(_ milliseconds: Int) -> String {
        let t = normalize(milliseconds)
        if t.h > 0 {
            return String(format: "%d:%02d:%02d", t.h, t.m, t.s)
        }
        return String(format: "%d:%02d", t.m, t.s)
    }

    /// 带毫秒的时钟：`01:23.456`，用于打轴界面
    public static func clockWithMilliseconds(_ milliseconds: Int) -> String {
        let t = normalize(milliseconds)
        if t.h > 0 {
            return String(format: "%d:%02d:%02d.%03d", t.h, t.m, t.s, t.ms)
        }
        return String(format: "%02d:%02d.%03d", t.m, t.s, t.ms)
    }

    /// 用于"−0.1s / +0.1s"这种微调显示，带正负号
    public static func signedSeconds(_ milliseconds: Int) -> String {
        let sign = milliseconds < 0 ? "−" : "+"
        let magnitude = abs(milliseconds)
        if magnitude < 1000 {
            return "\(sign)\(magnitude)ms"
        }
        return String(format: "%@%.1fs", sign, Double(magnitude) / 1000.0)
    }

    // MARK: - 内部

    struct Components { let h: Int; let m: Int; let s: Int; let ms: Int }

    static func normalize(_ milliseconds: Int) -> Components {
        let total = max(0, milliseconds)
        let h = total / 3_600_000
        let m = (total % 3_600_000) / 60_000
        let s = (total % 60_000) / 1000
        let ms = total % 1000
        return Components(h: h, m: m, s: s, ms: ms)
    }
}
