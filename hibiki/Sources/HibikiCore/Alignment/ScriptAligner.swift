import Foundation

/// 带时间戳的识别 token（ASR 输出的最小单位）。
public struct TimedToken: Equatable, Sendable {
    public var text: String
    public var startMS: Int
    public var endMS: Int

    public init(text: String, startMS: Int, endMS: Int) {
        self.text = text
        self.startMS = startMS
        self.endMS = endMS
    }
}

/// 台本对齐结果的一行
public struct AlignedScriptLine: Equatable, Sendable, Identifiable {
    public var id: Int { index }
    /// 台本里的行号（0 基）
    public var index: Int
    /// 台本原文
    public var originalText: String
    /// 推断出的开始时间。**即使 `status == .unaligned` 也可能有值**（那是按比例估的位置），
    /// 所以界面要结合 status 判断能不能直接信。
    public var startMS: Int?
    public var endMS: Int?
    /// 与音频的字符匹配率 0…1
    public var matchRatio: Double
    public var status: CueStatus

    public init(
        index: Int,
        originalText: String,
        startMS: Int?,
        endMS: Int?,
        matchRatio: Double,
        status: CueStatus
    ) {
        self.index = index
        self.originalText = originalText
        self.startMS = startMS
        self.endMS = endMS
        self.matchRatio = matchRatio
        self.status = status
    }

    public var isReliable: Bool { status == .ok && startMS != nil }
}

public struct ScriptAlignmentOptions: Sendable {
    /// 每条台本行在前方/后方各搜索多少字符
    public var searchWindowChars: Int
    /// 匹配率低于此值判为"未对齐"
    public var minimumMatchRatio: Double
    /// 生成字幕时的最短时长
    public var minimumDurationMS: Int

    public init(
        searchWindowChars: Int = 500,
        minimumMatchRatio: Double = 0.45,
        minimumDurationMS: Int = 120
    ) {
        self.searchWindowChars = searchWindowChars
        self.minimumMatchRatio = minimumMatchRatio
        self.minimumDurationMS = minimumDurationMS
    }
}

/// 文本归一化：把"看起来不同但实际相同"的字符统一掉，再参与匹配。
///
/// 只保留"有语音对应"的字符：字母、数字、假名、汉字、谚文。
/// 标点、空格、全角符号、括号注释全部丢弃 —— 台本里的「（ドアを叩く）」
/// 这种音效说明本来就不会被识别出来，留着只会拉低匹配率。
public enum ScriptNormalizer {

    /// 括号内的舞台指示 / 音效说明（「（ドアを叩く）」「(SE)」「【息】」）整段丢弃。
    /// 这些内容不会被语音识别出来，留着只会拉低匹配率。
    static let parentheticalOpen: Set<Character> = ["（", "(", "【", "［", "["]
    static let parentheticalClose: Set<Character> = ["）", ")", "】", "］", "]"]

    public static func strippingParentheticals(_ text: String) -> String {
        guard text.contains(where: { parentheticalOpen.contains($0) }) else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var depth = 0
        for ch in text {
            if parentheticalOpen.contains(ch) {
                depth += 1
                continue
            }
            if parentheticalClose.contains(ch) {
                if depth > 0 { depth -= 1 }
                continue
            }
            if depth == 0 { out.append(ch) }
        }
        return out
    }

    public static func normalizedCharacters(_ text: String) -> [Character] {
        var result: [Character] = []
        let stripped = strippingParentheticals(text)
        result.reserveCapacity(stripped.count)
        for scalar in stripped.unicodeScalars {
            guard let normalized = normalizeScalar(scalar) else { continue }
            result.append(Character(normalized))
        }
        return result
    }

    public static func normalize(_ text: String) -> String {
        String(normalizedCharacters(text))
    }

    static func normalizeScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        let value = scalar.value

        // 全角 ASCII → 半角；半角若仍不是"有音字符"（如 ! ? ( )）则丢弃
        if value >= 0xFF01 && value <= 0xFF5E {
            guard let half = Unicode.Scalar(value - 0xFEE0) else { return nil }
            return normalizeScalar(half)
        }
        // 全角空格
        if value == 0x3000 { return nil }

        // 半角 ASCII：保留字母数字，字母转小写
        if value >= 0x30 && value <= 0x39 { return scalar }           // 0-9
        if value >= 0x41 && value <= 0x5A {                            // A-Z
            return Unicode.Scalar(value + 0x20)
        }
        if value >= 0x61 && value <= 0x7A { return scalar }            // a-z

        // 平假名 / 片假名
        if value >= 0x3040 && value <= 0x309F { return scalar }
        if value >= 0x30A0 && value <= 0x30FF { return scalar }
        // 半角片假名
        if value >= 0xFF66 && value <= 0xFF9D { return scalar }

        // 汉字
        if value >= 0x4E00 && value <= 0x9FFF { return scalar }
        if value >= 0x3400 && value <= 0x4DBF { return scalar }
        if value >= 0xF900 && value <= 0xFAFF { return scalar }

        // 谚文
        if value >= 0xAC00 && value <= 0xD7AF { return scalar }
        if value >= 0x1100 && value <= 0x11FF { return scalar }

        // 其余（标点、符号、空白、emoji）一律丢弃
        return nil
    }
}

/// 台本 ↔ 音频 的锚点对齐。
///
/// 思路（大白话）：
/// 识别结果给我们"每个字在第几秒"；台本给我们"准确的文字"。
/// 拿台本每一行，去识别结果里找"这行字大概出现在哪一段"，
/// 找到就把那一段的起止时间给这行。
///
/// 为什么不用"平均分配"：一集里有人说话快有人慢，还有停顿，
/// 平均分配能差出几十秒，完全没法用。
public enum ScriptAligner {

    /// 对齐
    /// - Parameters:
    ///   - scriptLines: 台本行（空行会被跳过）
    ///   - tokens: ASR 输出的带时间 token
    public static func align(
        scriptLines: [String],
        tokens: [TimedToken],
        options: ScriptAlignmentOptions = .init()
    ) -> [AlignedScriptLine] {
        // 1) 把 token 摊平成"逐字符 + 时间"
        let (asrChars, asrStarts, asrEnds) = flatten(tokens: tokens)

        guard !asrChars.isEmpty else {
            return scriptLines.enumerated().map { idx, line in
                AlignedScriptLine(
                    index: idx,
                    originalText: line,
                    startMS: nil,
                    endMS: nil,
                    matchRatio: 0,
                    status: .unaligned
                )
            }
        }

        let totalDuration = tokens.last?.endMS ?? 0

        // 2) 预处理台本：每行的归一化字符
        var lineCharsList: [[Character]] = []
        lineCharsList.reserveCapacity(scriptLines.count)
        var totalScriptChars = 0
        for line in scriptLines {
            let chars = ScriptNormalizer.normalizedCharacters(line)
            lineCharsList.append(chars)
            totalScriptChars += chars.count
        }

        var results: [AlignedScriptLine] = []
        results.reserveCapacity(scriptLines.count)

        var consumedScriptChars = 0
        var previousEndMS = 0
        var previousEndCharIndex = 0

        for (lineIndex, line) in scriptLines.enumerated() {
            let lineChars = lineCharsList[lineIndex]

            // 台本里的空行 / 纯符号行（如「（効果音）」）→ 不对齐
            if lineChars.isEmpty {
                results.append(
                    AlignedScriptLine(
                        index: lineIndex,
                        originalText: line,
                        startMS: nil,
                        endMS: nil,
                        matchRatio: 0,
                        status: .unaligned
                    )
                )
                continue
            }

            // 3) 估算这一行在 ASR 字符序列里的大概位置
            let fraction = totalScriptChars > 0
                ? Double(consumedScriptChars) / Double(totalScriptChars)
                : 0
            let expectedIndex = Int(Double(asrChars.count) * fraction)
            let lowerBound = max(previousEndCharIndex, expectedIndex - options.searchWindowChars)
            let upperBound = min(
                asrChars.count - 1,
                max(lowerBound, expectedIndex + options.searchWindowChars)
            )

            // 4) 在窗口内找最佳匹配
            let match = bestMatch(
                lineChars: lineChars,
                asrChars: asrChars,
                searchFrom: lowerBound,
                searchTo: upperBound
            )

            let ratio = Double(match.count) / Double(lineChars.count)

            if ratio < options.minimumMatchRatio || match.first == nil {
                // 未对齐：给一个"按比例估"的时间，方便在列表里排到大致位置
                let proportionalStart = totalDuration > 0
                    ? Int(Double(totalDuration) * fraction)
                    : previousEndMS
                // 即使只是估算值，也不能倒退回上一行之前
                let estimatedStart = max(proportionalStart, previousEndMS)
                results.append(
                    AlignedScriptLine(
                        index: lineIndex,
                        originalText: line,
                        startMS: estimatedStart,
                        endMS: estimatedStart + options.minimumDurationMS,
                        matchRatio: ratio,
                        status: .unaligned
                    )
                )
                consumedScriptChars += lineChars.count
                previousEndMS = estimatedStart
                continue
            }

            // 5) 用匹配到的首末字符推算时间
            var startMS = match.first.map { asrStarts[$0] } ?? previousEndMS
            let lastIndex = match.last ?? (match.first ?? 0)
            var endMS = asrEnds[lastIndex]

            // 单调性：不允许倒退回上一行之前
            if startMS < previousEndMS {
                startMS = previousEndMS
                if endMS < startMS + options.minimumDurationMS {
                    endMS = startMS + options.minimumDurationMS
                }
            }
            if endMS < startMS + options.minimumDurationMS {
                endMS = startMS + options.minimumDurationMS
            }

            results.append(
                AlignedScriptLine(
                    index: lineIndex,
                    originalText: line,
                    startMS: startMS,
                    endMS: endMS,
                    matchRatio: ratio,
                    status: ratio >= 0.8 ? .ok : .lowConfidence
                )
            )

            consumedScriptChars += lineChars.count
            previousEndMS = endMS
            previousEndCharIndex = match.last ?? previousEndCharIndex
        }

        return results
    }

    /// 把对齐结果转成字幕条目
    public static func makeCues(
        from aligned: [AlignedScriptLine],
        translated: [String]? = nil,
        dropUnalignable: Bool = false
    ) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var ordinal = 0
        for line in aligned {
            if dropUnalignable && line.status == .unaligned { continue }
            guard let startMS = line.startMS, let endMS = line.endMS else { continue }
            let translation = translated.flatMap { $0.indices.contains(line.index) ? $0[line.index] : nil }
            cues.append(
                SubtitleCue(
                    index: ordinal,
                    startMS: startMS,
                    endMS: endMS,
                    text: line.originalText,
                    translatedText: (translation?.isEmpty ?? true) ? nil : translation,
                    status: line.status
                )
            )
            ordinal += 1
        }
        return cues
    }

    // MARK: - 内部

    /// token → 逐字符 + 时间（token 内部按字符数均分时间）
    static func flatten(tokens: [TimedToken]) -> ([Character], [Int], [Int]) {
        var chars: [Character] = []
        var starts: [Int] = []
        var ends: [Int] = []

        for token in tokens {
            let tokenChars = ScriptNormalizer.normalizedCharacters(token.text)
            guard !tokenChars.isEmpty else { continue }
            let span = max(0, token.endMS - token.startMS)
            let step = span / max(1, tokenChars.count)
            for (i, ch) in tokenChars.enumerated() {
                chars.append(ch)
                starts.append(token.startMS + i * step)
                ends.append(token.startMS + (i + 1) * step)
            }
        }
        return (chars, starts, ends)
    }

    /// 在 `[searchFrom, searchTo]` 范围内找与 `lineChars` 最匹配的字符下标集合
    static func bestMatch(
        lineChars: [Character],
        asrChars: [Character],
        searchFrom: Int,
        searchTo: Int
    ) -> [Int] {
        guard !lineChars.isEmpty, searchFrom <= searchTo, searchTo < asrChars.count else { return [] }

        // 用前两个字符做锚点候选，避免逐个位置蛮力扫描
        var anchors: [Int] = []
        let first = lineChars[0]
        let second: Character? = lineChars.count > 1 ? lineChars[1] : nil

        var i = searchFrom
        while i <= searchTo && anchors.count < 60 {
            if asrChars[i] == first {
                if let second {
                    if i + 1 <= searchTo, asrChars[i + 1] == second {
                        anchors.append(i)
                    }
                } else {
                    anchors.append(i)
                }
            }
            i += 1
        }

        // 锚点都没找到：退化成只按首字符找
        if anchors.isEmpty {
            i = searchFrom
            while i <= searchTo && anchors.count < 60 {
                if asrChars[i] == first { anchors.append(i) }
                i += 1
            }
        }
        if anchors.isEmpty { return [] }

        var best: [Int] = []
        for anchor in anchors {
            let matched = greedyMatch(lineChars: lineChars, asrChars: asrChars, from: anchor)
            if matched.count > best.count {
                best = matched
            }
            if best.count == lineChars.count { break }  // 完美匹配，不必再找
        }
        return best
    }

    /// 从 `start` 开始按顺序贪心匹配，返回命中的 ASR 字符下标
    static func greedyMatch(
        lineChars: [Character],
        asrChars: [Character],
        from start: Int
    ) -> [Int] {
        var matched: [Int] = []
        matched.reserveCapacity(lineChars.count)
        var j = start
        // 允许少量错字（例如把「だめ」听成「だべ」），但不能无限容错
        var missesLeft = max(1, lineChars.count / 4)
        let limit = min(asrChars.count, start + lineChars.count * 3 + 32)
        // 单个台本字最多向后找几个识别字（应对识别多吐/漏吐字）
        let lookahead = 6

        for ch in lineChars {
            guard j < limit else { break }
            let windowEnd = min(limit, j + lookahead)
            var foundAt: Int?
            var k = j
            while k < windowEnd {
                if asrChars[k] == ch {
                    foundAt = k
                    break
                }
                k += 1
            }

            if let f = foundAt {
                matched.append(f)
                j = f + 1
            } else if missesLeft > 0 {
                // 当作识别错字：跳过一个识别字，继续对后面的字
                missesLeft -= 1
                j = min(j + 1, asrChars.count)
            } else {
                break
            }
        }
        return matched
    }
}
