import Foundation

/// 把"对齐后的台本行"变成可以显示的字幕条目。
public enum ScriptToCues {

    public struct Options: Sendable {
        /// 低于这个匹配率的行不用（多半是 ASR 听错或台本多出来）
        public var minimumMatchRatio: Double
        /// 每句最短显示时长
        public var minimumDurationMS: Int
        /// 每句最长显示时长（防止一句话霸屏）
        public var maximumDurationMS: Int
        /// 相邻两句之间留的空隙
        public var gapMS: Int

        public init(
            minimumMatchRatio: Double = 0.4,
            minimumDurationMS: Int = 300,
            maximumDurationMS: Int = 15_000,
            gapMS: Int = 60
        ) {
            self.minimumMatchRatio = minimumMatchRatio
            self.minimumDurationMS = minimumDurationMS
            self.maximumDurationMS = maximumDurationMS
            self.gapMS = gapMS
        }
    }

    /// 生成字幕条目
    /// - Parameters:
    ///   - aligned: 对齐结果
    ///   - totalDurationMS: 音频总时长，用于给最后一句封口
    public static func build(
        aligned: [AlignedScriptLine],
        totalDurationMS: Int? = nil,
        options: Options = .init()
    ) -> [SubtitleCue] {
        // 只留下有可靠时间的行
        let usable = aligned.filter { line in
            guard let start = line.startMS, let end = line.endMS else { return false }
            guard line.matchRatio >= options.minimumMatchRatio else { return false }
            return end > start
        }
        guard !usable.isEmpty else { return [] }

        var cues: [SubtitleCue] = []
        for (position, line) in usable.enumerated() {
            guard let start = line.startMS, var end = line.endMS else { continue }

            // 下一句开始前留出空隙，避免两句话重叠
            if position + 1 < usable.count, let nextStart = usable[position + 1].startMS, nextStart > start {
                end = min(end, nextStart - options.gapMS)
            }
            // 最后一句：没有下一句参考时，封到音频末尾或上限
            if position == usable.count - 1 {
                if let total = totalDurationMS, total > start {
                    end = min(max(end, start + options.minimumDurationMS), total)
                } else {
                    end = min(end, start + options.maximumDurationMS)
                }
            }
            if end - start < options.minimumDurationMS {
                end = start + options.minimumDurationMS
            }
            if end - start > options.maximumDurationMS {
                end = start + options.maximumDurationMS
            }
            if let nextStart = position + 1 < usable.count ? usable[position + 1].startMS : nil,
               end > nextStart {
                end = max(start + 1, nextStart - options.gapMS)
            }

            cues.append(
                SubtitleCue(
                    index: cues.count,
                    startMS: start,
                    endMS: end,
                    text: line.originalText,
                    status: line.status
                )
            )
        }
        return cues
    }

    /// 统计信息，用于告诉用户对齐效果
    public struct Summary: Equatable, Sendable {
        public var totalLines: Int
        public var alignedLines: Int
        public var highConfidenceLines: Int
        public var averageMatchRatio: Double

        public init(totalLines: Int, alignedLines: Int, highConfidenceLines: Int, averageMatchRatio: Double) {
            self.totalLines = totalLines
            self.alignedLines = alignedLines
            self.highConfidenceLines = highConfidenceLines
            self.averageMatchRatio = averageMatchRatio
        }

        public var alignedRatio: Double {
            totalLines > 0 ? Double(alignedLines) / Double(totalLines) : 0
        }

        public var description: String {
            let percent = Int((alignedRatio * 100).rounded())
            return InterfaceLocalization.text("\(alignedLines)/\(totalLines) 句对齐（\(percent)%），平均匹配 \(Int(averageMatchRatio * 100))%")
        }
    }

    public static func summarize(_ aligned: [AlignedScriptLine]) -> Summary {
        let alignedLines = aligned.filter { $0.startMS != nil }
        let high = aligned.filter { $0.isReliable && $0.matchRatio >= 0.7 }
        let average = aligned.isEmpty
            ? 0
            : aligned.map(\.matchRatio).reduce(0, +) / Double(aligned.count)
        return Summary(
            totalLines: aligned.count,
            alignedLines: alignedLines.count,
            highConfidenceLines: high.count,
            averageMatchRatio: average
        )
    }
}
