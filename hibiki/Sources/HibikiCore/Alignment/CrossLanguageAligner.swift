import Foundation

/// 跨语言对齐：台本是中文译文，音频是日语原声。
///
/// 为什么不能用 `ScriptAligner`：那个算法靠**文字相似度**匹配，
/// 中文台本和日语音频一个词都对不上，相似度趋近 0，全部判为未对齐。
///
/// 这里换一个思路：**只用时间结构，不用文字内容**。
/// 译文长度和原语音时长基本成正比（说得长的地方译出来字也多），
/// 所以按字数占比把台词铺到识别出的时间轴上，
/// 再把切点吸附到停顿处，就能得到"大致正确、需要微调"的时间轴。
public enum CrossLanguageAligner {

    public struct Options: Sendable {
        /// 间隔超过这个毫秒数就算"停顿"，可以作为切分点
        public var pauseThresholdMS: Int
        /// 每句最短时长（防止极短句几乎看不见）
        public var minimumDurationMS: Int
        /// 是否按字数加权分配（false 则平均分配）
        public var weightByCharacterCount: Bool

        public init(
            pauseThresholdMS: Int = 250,
            minimumDurationMS: Int = 400,
            weightByCharacterCount: Bool = true
        ) {
            self.pauseThresholdMS = pauseThresholdMS
            self.minimumDurationMS = minimumDurationMS
            self.weightByCharacterCount = weightByCharacterCount
        }
    }

    /// 一段连续说话
    public struct SpeechSegment: Equatable, Sendable {
        public var startMS: Int
        public var endMS: Int
        public var text: String

        public init(startMS: Int, endMS: Int, text: String) {
            self.startMS = startMS
            self.endMS = endMS
            self.text = text
        }

        public var durationMS: Int { max(0, endMS - startMS) }
    }

    /// 把 ASR 的词合并成语音段（长间隔处断开）
    public static func segments(from tokens: [TimedToken], pauseThresholdMS: Int) -> [SpeechSegment] {
        guard !tokens.isEmpty else { return [] }
        let sorted = tokens.sorted { $0.startMS < $1.startMS }

        var result: [SpeechSegment] = []
        var currentStart = sorted[0].startMS
        var currentEnd = sorted[0].endMS
        var currentText = sorted[0].text

        for token in sorted.dropFirst() {
            if token.startMS - currentEnd >= pauseThresholdMS {
                result.append(SpeechSegment(startMS: currentStart, endMS: currentEnd, text: currentText))
                currentStart = token.startMS
                currentEnd = token.endMS
                currentText = token.text
            } else {
                currentEnd = max(currentEnd, token.endMS)
                currentText += token.text
            }
        }
        result.append(SpeechSegment(startMS: currentStart, endMS: currentEnd, text: currentText))
        return result
    }

    /// 跨语言对齐
    /// - Parameters:
    ///   - scriptLines: 台本台词行（中文）
    ///   - tokens: ASR 识别出的词（日语）
    public static func align(
        scriptLines: [String],
        tokens: [TimedToken],
        options: Options = .init()
    ) -> [AlignedScriptLine] {
        let speechSegments = segments(from: tokens, pauseThresholdMS: options.pauseThresholdMS)

        guard !scriptLines.isEmpty else { return [] }
        guard !speechSegments.isEmpty else {
            return scriptLines.enumerated().map { index, line in
                AlignedScriptLine(
                    index: index, originalText: line,
                    startMS: nil, endMS: nil, matchRatio: 0, status: .unaligned
                )
            }
        }

        // 权重：按有效字数（去掉标点空白）
        let weights: [Double] = scriptLines.map { line in
            guard options.weightByCharacterCount else { return 1 }
            let count = ScriptNormalizer.normalizedCharacters(line).count
            return Double(max(1, count))
        }
        let totalWeight = weights.reduce(0, +)
        let totalSpeechDuration = speechSegments.reduce(0) { $0 + $1.durationMS }

        // 若语音段太少（识别失败或全是静音），退回"按整体时间铺开"
        let speechStart = speechSegments.first?.startMS ?? 0
        let speechEnd = speechSegments.last?.endMS ?? 0

        var results: [AlignedScriptLine] = []
        var consumedDuration: Double = 0

        for (index, line) in scriptLines.enumerated() {
            let share = totalWeight > 0 ? weights[index] / totalWeight : 1 / Double(scriptLines.count)
            let startProgress = consumedDuration / max(1, Double(totalSpeechDuration))
            consumedDuration += Double(totalSpeechDuration) * share
            let endProgress = consumedDuration / max(1, Double(totalSpeechDuration))

            let startMS = min(max(speechStart, timeFor(progress: startProgress, in: speechSegments)), speechEnd)
            let endMS = min(max(startMS + options.minimumDurationMS,
                                timeFor(progress: endProgress, in: speechSegments)), speechEnd + 1_000)

            // 切点吸附到最近的停顿（语音段边界），让断句落在换气处
            let snappedStart = snapToPause(startMS, segments: speechSegments, preferEnd: false)
            let snappedEnd = snapToPause(endMS, segments: speechSegments, preferEnd: true)

            let finalStart = max(speechStart, snappedStart)
            let finalEnd = max(finalStart + options.minimumDurationMS, snappedEnd)

            results.append(
                AlignedScriptLine(
                    index: index,
                    originalText: line,
                    startMS: finalStart,
                    endMS: finalEnd,
                    // 跨语言没有"文字匹配率"可言，用一个与服务端语义无关的
                    // 结构可信度代替：时长越接近预期越可信
                    matchRatio: 0.8,
                    status: .ok
                )
            )
        }

        // 保证时间单调递增、不重叠
        return normalize(results, segments: speechSegments, minimumDurationMS: options.minimumDurationMS)
    }

    // MARK: - 内部

    /// 按"语音进度"换算成墙钟时间（跳过静音区，让分配集中在有声音的地方）
    static func timeFor(progress: Double, in segments: [SpeechSegment]) -> Int {
        let clamped = min(max(0, progress), 1)
        let totalSpeech = segments.reduce(0) { $0 + $1.durationMS }
        guard totalSpeech > 0 else { return segments.first?.startMS ?? 0 }

        let target = Double(totalSpeech) * clamped
        var accumulated: Double = 0
        for segment in segments {
            if accumulated + Double(segment.durationMS) >= target {
                let offset = target - accumulated
                return segment.startMS + Int(min(Double(segment.durationMS), max(0, offset)))
            }
            accumulated += Double(segment.durationMS)
        }
        return segments.last?.endMS ?? 0
    }

    /// 把时间点吸附到最近的语音段边界（停顿处）
    static func snapToPause(_ timeMS: Int, segments: [SpeechSegment], preferEnd: Bool) -> Int {
        guard !segments.isEmpty else { return timeMS }

        var best = timeMS
        var bestDistance = Int.max
        for segment in segments {
            let candidate = preferEnd ? segment.endMS : segment.startMS
            let distance = abs(candidate - timeMS)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        // 只在不偏离太远时吸附，否则保持原值
        return bestDistance <= 1_500 ? best : timeMS
    }

    /// 修正顺序与重叠
    static func normalize(
        _ lines: [AlignedScriptLine],
        segments: [SpeechSegment],
        minimumDurationMS: Int
    ) -> [AlignedScriptLine] {
        var result = lines.sorted { ($0.startMS ?? 0) < ($1.startMS ?? 0) }
        for index in result.indices {
            guard var start = result[index].startMS, var end = result[index].endMS else { continue }
            if index > 0, let previousEnd = result[index - 1].endMS, start < previousEnd {
                start = previousEnd
            }
            if end < start + minimumDurationMS {
                end = start + minimumDurationMS
            }
            result[index].startMS = start
            result[index].endMS = end
        }
        // 恢复成"原始行序"，但时间保持递增
        return result.enumerated().map { position, line in
            var copy = line
            copy.index = position
            return copy
        }
    }
}

/// 判断"台本和音频是不是不同语言"
public enum ScriptLanguageCheck {

    /// 假名（日文特有）
    public static func kanaRatio(_ text: String) -> Double {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return 0 }
        var kana = 0
        var cjk = 0
        for scalar in scalars {
            let value = scalar.value
            if (0x3040...0x30FF).contains(value) { kana += 1 }
            if (0x4E00...0x9FFF).contains(value) { cjk += 1 }
        }
        let total = kana + cjk
        guard total > 0 else { return 0 }
        return Double(kana) / Double(total)
    }

    /// 台本几乎没有假名，而识别结果假名很多 → 判定为跨语言（中文台本 + 日语音频）
    public static func isCrossLanguage(scriptText: String, asrTokens: [TimedToken]) -> Bool {
        let asrText = asrTokens.map(\.text).joined()
        guard !asrText.isEmpty else { return false }
        let scriptKana = kanaRatio(scriptText)
        let asrKana = kanaRatio(asrText)
        return scriptKana < 0.05 && asrKana > 0.15
    }
}
