import Foundation

/// 没有台本时，把语音识别的词直接拼成字幕句。
public enum TokenCueBuilder {

    public struct Options: Sendable {
        /// 词与词之间超过这个间隔就断句
        public var breakGapMS: Int
        /// 一句话最多这么长（毫秒）就强制断开
        public var maximumDurationMS: Int
        /// 一句话最多这么多字符就强制断开
        public var maximumCharacters: Int
        /// 最短一句，太短的并到下一句
        public var minimumDurationMS: Int
        /// 遇到这些句末标点就断句（whisper 输出的标点很有信息量）
        public var sentenceEndings: Set<Character>

        public init(
            breakGapMS: Int = 600,
            maximumDurationMS: Int = 12_000,
            maximumCharacters: Int = 40,
            minimumDurationMS: Int = 400,
            sentenceEndings: Set<Character> = ["。", "！", "？", "!", "?", "…", "」", "』"]
        ) {
            self.breakGapMS = breakGapMS
            self.maximumDurationMS = maximumDurationMS
            self.maximumCharacters = maximumCharacters
            self.minimumDurationMS = minimumDurationMS
            self.sentenceEndings = sentenceEndings
        }
    }

    public static func build(tokens: [TimedToken], options: Options = .init()) -> [SubtitleCue] {
        guard !tokens.isEmpty else { return [] }
        let sorted = tokens.sorted { $0.startMS < $1.startMS }

        var groups: [[TimedToken]] = []
        var current: [TimedToken] = []

        for token in sorted {
            guard let last = current.last else {
                current = [token]
                continue
            }
            let gap = token.startMS - last.endMS
            let duration = token.endMS - current[0].startMS
            let length = current.reduce(0) { $0 + $1.text.count } + token.text.count

            // 上一句以句末标点结尾 → 断句
            let previousEndsSentence = last.text.last.map { options.sentenceEndings.contains($0) } ?? false
            let shouldBreak = gap >= options.breakGapMS
                || previousEndsSentence
                || duration >= options.maximumDurationMS
                || length > options.maximumCharacters

            if shouldBreak {
                groups.append(current)
                current = [token]
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { groups.append(current) }

        // 太短的分句并进下一句
        var merged: [[TimedToken]] = []
        var pending: [TimedToken] = []
        for group in groups {
            let duration = (group.last?.endMS ?? 0) - (group.first?.startMS ?? 0)
            if duration < options.minimumDurationMS {
                pending.append(contentsOf: group)
                continue
            }
            if !pending.isEmpty {
                pending.append(contentsOf: group)
                merged.append(pending)
                pending = []
            } else {
                merged.append(group)
            }
        }
        if !pending.isEmpty {
            if merged.isEmpty {
                merged.append(pending)
            } else {
                merged[merged.count - 1].append(contentsOf: pending)
            }
        }

        return merged.enumerated().map { index, group in
            SubtitleCue(
                index: index,
                startMS: group.first?.startMS ?? 0,
                endMS: group.last?.endMS ?? 0,
                text: joinText(group)
            )
        }
    }

    /// 拼接词。
    ///
    /// 中文词之间不该有空格；日文也不该有。这里统一不加空格，
    /// 因为识别结果的分词本来就是连续的。
    private static func joinText(_ tokens: [TimedToken]) -> String {
        tokens.map(\.text).joined()
    }
}
