import Foundation

/// 台本里的一行台词
public struct ScriptLine: Identifiable, Equatable, Sendable {
    public var id: Int { index }
    /// 在台本中的行号（从 0 开始）
    public var index: Int
    /// 说话人（可能没有）
    public var speaker: String?
    /// 台词正文（已去掉说话人前缀）
    public var text: String
    /// 同一段的译文；无法确认语言边界时保留原正文，不猜测。
    public var translatedText: String?
    /// 台本本身印出的起点；一般台本没有这一项。
    public var printedStartMS: Int?
    /// 台本明确印出的结束时间；只有起点时仍由用户校准句尾。
    public var printedEndMS: Int?
    /// 原始行内容，排查问题时用
    public var rawLine: String
    /// Original body rows only; retained for import review, not persisted as cues.
    public var sourceLines: [ScriptTextLine] = []
    public var bilingualDecision: ScriptBilingualDecision?

    public init(index: Int, speaker: String? = nil, text: String, rawLine: String, printedStartMS: Int? = nil,
                printedEndMS: Int? = nil, translatedText: String? = nil,
                sourceLines: [ScriptTextLine] = [], bilingualDecision: ScriptBilingualDecision? = nil) {
        self.index = index
        self.speaker = speaker
        self.text = text
        self.rawLine = rawLine
        self.printedStartMS = printedStartMS
        self.printedEndMS = printedEndMS
        self.translatedText = translatedText
        self.sourceLines = sourceLines
        self.bilingualDecision = bilingualDecision
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 把台本文本切开成一行行台词。
///
/// 音声作品的台本格式五花八门，这里覆盖最常见的几种：
/// ```
/// 男主「あ、そこはだめ……」
/// 男主：あ、そこはだめ……
/// 【男主】あ、そこはだめ……
/// （ドアを叩く）           ← 舞台指示，丢弃
/// 「あ、そこはだめ……」     ← 没有说话人
/// ```
public enum ScriptParser {

    /// 解析台本
    /// - Parameter text: 已解码的台本文本（PDF 抽出的文字也走这里）
    public static func parse(_ text: String) -> [ScriptLine] {
        parse(text, allowUnlabelled: true)
    }

    private static func parse(_ text: String, allowUnlabelled: Bool) -> [ScriptLine] {
        // 空行是无时间台本的段落边界，不能跨段找漏掉的译文。
        let rawLines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var result: [ScriptLine] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            let raw = paragraph.joined(separator: "\n")
            if let pairs = BilingualText.labelledPairs(raw) {
                result += pairs.map { pairedLine($0, raw: raw) }
            } else if !allowUnlabelled {
                // Unsupported PDF reading order cannot justify a language pair.
                // Preserve the old per-line script behavior instead of merging
                // an entire page/document into one giant untimed cue.
                result += parseUnpaired(raw)
            } else if let pair = BilingualText.split(raw) {
                result.append(pairedLine(pair, raw: raw))
            } else {
                result += parseUnpaired(raw)
            }
            paragraph.removeAll()
        }
        for line in rawLines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() }
            else { paragraph.append(line) }
        }
        flush()
        for index in result.indices { result[index].index = index }
        return result
    }

    private static func parseUnpaired(_ text: String) -> [ScriptLine] {
        var result: [ScriptLine] = []
        let rawLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if isNoise(trimmed) { continue }

            let (speaker, body) = splitSpeaker(trimmed)
            let cleaned = cleanBody(body)
            guard !cleaned.isEmpty else { continue }
            // 整行都是括号说明的丢弃
            if ScriptNormalizer.normalizedCharacters(cleaned).isEmpty { continue }

            result.append(
                ScriptLine(
                    index: result.count,
                    speaker: speaker,
                    text: cleaned,
                    rawLine: trimmed
                )
            )
        }
        return result
    }

    /// 印在段落开头的时间属于整段；PDF 排版折行不应被当作新的一句。
    static func parseSection(_ rawLines: [String]) -> [ScriptLine] {
        parseSection(rawLines.map { ScriptTextLine(text: $0) })
    }

    static func parseSection(_ source: [ScriptTextLine]) -> [ScriptLine] {
        if source.contains(where: { TimelineLine.parse($0.text) != nil }) {
            return parseTimedBlocks(source)
        }
        let parsed = parseLegacySection(source.map(\.text), allowUnlabelled: reliableOrder(source))
        return ScriptLayoutBilingual.separating(separating(attachSources(parsed, source: source),
            allowUnattributed: !source.contains { $0.layout != nil }))
    }

    private static func parseLegacySection(_ rawLines: [String], allowUnlabelled: Bool) -> [ScriptLine] {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.contains(where: { printedStamp(in: $0) != nil }) else {
            return parse(rawLines.joined(separator: "\n"), allowUnlabelled: allowUnlabelled)
        }
        var result: [ScriptLine] = []
        var paragraph: Int?
        for line in lines {
            // 有的合集在角色切换前印总时长、角色卡；下一轨已经由 Sectioner 独立切分。
            if line.range(of: #"(?i)^(?:[总總][时時][长長]|total (?:run\s?time|duration)|총 재생시간)\s*[:：]\s*[0-9０-９]"#,
                          options: .regularExpression) != nil { break }
            if line.range(of: #"(?i)^CV\s*[:：]"#, options: .regularExpression) != nil { continue }
            let stamp = printedStamp(in: line)
            let body = stamp?.body ?? line
            if body.isEmpty { paragraph = nil; continue }
            if isNoise(body) { continue }
            // 印刷台本可在台词内使用括号、书名号；这里仅采用明确的角色前缀。
            let explicitSpeaker = body.hasPrefix("【") || body.range(of: #"^[^\s:：「」『』（()）]{1,12}[:：]"#,
                                                                  options: .regularExpression) != nil
            let (speaker, spoken) = explicitSpeaker ? splitSpeaker(body) : (nil, body)
            let clean = spoken.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty, !ScriptNormalizer.normalizedCharacters(clean).isEmpty else { continue }
            if stamp == nil, let previous = paragraph, speaker == nil {
                result[previous].text += "\n" + clean
                result[previous].rawLine += "\n" + line
            } else {
                paragraph = stamp != nil ? result.count : nil
                result.append(ScriptLine(index: result.count, speaker: speaker, text: clean,
                                         rawLine: line, printedStartMS: stamp?.ms))
            }
        }
        // PDF 的取字顺序偶尔与排版相反。只按明确、互不重复的原文时间重新排序。
        let stamps = result.compactMap(\.printedStartMS)
        if stamps.count == result.count, Set(stamps).count == result.count, stamps != stamps.sorted() {
            result.sort { ($0.printedStartMS ?? 0) < ($1.printedStartMS ?? 0) }
            for i in result.indices { result[i].index = i }
        }
        return result
    }

    /// PDF 里可能直接印着 SRT。以时间行、明确空段和序号界定正文，普通折行仍保留；
    /// 第一条时间前的文字没有可靠归属，只保留为无时间正文。
    private static func parseTimedBlocks(_ source: [ScriptTextLine]) -> [ScriptLine] {
        let rawLines = source.map(\.text)
        var result: [ScriptLine] = []
        var body: [ScriptTextLine] = []
        var timeline: TimelineLine.Parsed?
        var timelineText = ""
        func nextNonemptyLine(after index: Int) -> String? {
            rawLines.dropFirst(index + 1).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        let numbered = rawLines.indices.filter { index in
            Int(rawLines[index].trimmingCharacters(in: .whitespaces)) != nil
                && nextNonemptyLine(after: index).flatMap(completeTimeline) != nil
        }.count >= 2
        var lastSequence: Int?
        func flush() {
            while body.last?.text.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
            let text = body.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            defer { body.removeAll() }
            guard !text.isEmpty else { return }
            guard let timeline else {
                if text.components(separatedBy: "\n").contains(where: { TimelineLine.parse($0) != nil }) {
                    result.append(ScriptLine(index: 0, text: text, rawLine: text, sourceLines: body))
                } else { result += attachSources(parse(text, allowUnlabelled: reliableOrder(body)), source: body) }
                return
            }
            let raw = timelineText + "\n" + text
            var line = ScriptLine(index: 0, text: text, rawLine: raw, sourceLines: body)
            line.printedStartMS = timeline.startMS
            line.printedEndMS = timeline.endMS
            result.append(line)
        }
        for (index, raw) in rawLines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if numbered, let sequence = Int(trimmed), sequence > 0,
               nextNonemptyLine(after: index).flatMap(completeTimeline) != nil
                || (sequence == lastSequence.map({ $0 + 1 }) && (index == 0 || rawLines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty)) {
                flush()
                timeline = nil
                lastSequence = sequence
            } else if let next = completeTimeline(raw) {
                flush()
                timeline = next
                timelineText = raw
            } else if TimelineLine.parse(raw) != nil {
                // A timeline-like line with inline prose is unsupported, not
                // disposable VTT settings. Keep the whole text without timing.
                flush()
                timeline = nil
                body.append(source[index])
            } else if trimmed.isEmpty {
                // 真实段落空白后又出现正文但缺时间，必须作为无时间段保留；
                // 不能把缺失部分接到上一条译文上。PDF 跨页由提取层用普通换行连接。
                flush()
                timeline = nil
            } else { body.append(source[index]) }
        }
        flush()
        // 不按语言结果调序，不让含糊短句影响后面任何一块。
        for index in result.indices { result[index].index = index }
        return ScriptLayoutBilingual.separating(separating(result,
            allowUnattributed: !source.contains { $0.layout != nil }))
    }

    private static func completeTimeline(_ line: String) -> TimelineLine.Parsed? {
        let clock = #"[0-9]{1,3}:[0-5][0-9](?::[0-5][0-9])?(?:[.,][0-9]{1,3})?"#
        let pattern = #"^\s*"# + clock + #"\s*(?:-->|->|—>|–>)\s*"# + clock + #"\s*$"#
        guard line.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return TimelineLine.parse(line)
    }

    private static func separating(_ lines: [ScriptLine], allowUnattributed: Bool) -> [ScriptLine] {
        let allowed = lines.map {
            ((allowUnattributed || !$0.sourceLines.isEmpty) && reliableOrder($0.sourceLines))
                || BilingualText.labelledPairs($0.text)?.count == 1
        }
        // Do not let an untrusted PDF block act as an anchor in the old text pass.
        let cues = lines.enumerated().map { index, line in
            SubtitleCue(startMS: 0, endMS: 0, text: allowed[index] ? line.text : "", translatedText: line.translatedText)
        }
        let separated = BilingualText.separating(cues)
        return lines.enumerated().map { index, line in
            guard line.translatedText == nil, let translation = separated[index].translatedText else { return line }
            var result = pairedLine(BilingualText.Pair(original: separated[index].text, translation: translation), raw: line.rawLine)
            result.index = line.index
            result.speaker = line.speaker ?? result.speaker
            result.printedStartMS = line.printedStartMS
            result.printedEndMS = line.printedEndMS
            result.sourceLines = line.sourceLines
            return result
        }
    }

    private static func reliableOrder(_ source: [ScriptTextLine]) -> Bool {
        !source.contains { $0.layout != nil && $0.layout?.isUsable != true }
    }

    /// Legacy no-time scripts retain source rows without enabling layout guesses.
    /// A provenance match must be exact (apart from known speaker/language labels).
    private static func attachSources(_ lines: [ScriptLine], source: [ScriptTextLine]) -> [ScriptLine] {
        var used = Set<Int>()
        return lines.map { line in
            var copy = line
            let raw = line.rawLine.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let duplicateRaw = lines.filter { $0.rawLine == line.rawLine }.count > 1
            if !duplicateRaw, let start = source.indices.first(where: { index in
                index + raw.count <= source.count
                    && (index..<index + raw.count).allSatisfy { !used.contains($0) }
                    && Array(source[index..<index + raw.count]).map { $0.text.trimmingCharacters(in: .whitespaces) } == raw
            }) {
                copy.sourceLines = Array(source[start..<start + raw.count])
                used.formUnion(start..<start + raw.count)
                return copy
            }
            let texts = (line.text + (line.translatedText.map { "\n" + $0 } ?? ""))
                .components(separatedBy: "\n").filter { !$0.isEmpty }
            var selected: [Int] = []
            for text in texts {
                guard let match = source.indices.first(where: { index in
                    !used.contains(index) && !selected.contains(index)
                        && BilingualText.withoutSpeaker(BilingualText.withoutLanguageLabel(source[index].text.trimmingCharacters(in: .whitespaces)))
                        .trimmingCharacters(in: .whitespaces) == text.trimmingCharacters(in: .whitespaces)
                }) else { return copy }
                selected.append(match)
            }
            if let first = selected.min(), let last = selected.max(), last - first + 1 == selected.count {
                copy.sourceLines = Array(source[first...last]); used.formUnion(first...last)
            }
            return copy
        }
    }

    static func pairedLine(_ pair: BilingualText.Pair, raw: String) -> ScriptLine {
        func clean(_ text: String) -> (String?, String) {
            var lines = text.components(separatedBy: "\n")
            let firstLine = lines[0]
            let explicitSpeaker = firstLine.hasPrefix("【") || firstLine.range(
                of: #"^[^\s:：「」『』（()）]{1,12}[:：]"#, options: .regularExpression) != nil
            let (speaker, first) = explicitSpeaker ? splitSpeaker(firstLine) : (nil, firstLine)
            // 此处已确认语言/角色边界，正文引号和括号仍是作者原文。
            lines[0] = first.trimmingCharacters(in: .whitespaces)
            return (speaker, lines.joined(separator: "\n"))
        }
        let (speaker, original) = clean(pair.original)
        let (_, translation) = clean(pair.translation)
        return ScriptLine(index: 0, speaker: speaker, text: original, rawLine: raw, translatedText: translation)
    }

    // 数字冒号只有在行首、格式完整且与正文隔开时才是时间，避免误判对白或比例。
    private static let stampPattern = try! NSRegularExpression(
        pattern: #"^([0-9]{1,3}[:：][0-5][0-9](?:[:：][0-5][0-9])?(?:[.,][0-9]{1,3})?)\s+(.+)$"#
    )
    private static func printedStamp(in line: String) -> (ms: Int, body: String)? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = stampPattern.firstMatch(in: line, range: range),
              let stamp = Range(match.range(at: 1), in: line),
              let body = Range(match.range(at: 2), in: line) else { return nil }
        let clock = line[stamp].replacingOccurrences(of: "：", with: ":")
        let parts = clock.split(separator: ":")
        // mm:ss 的分钟数可能超过 59。
        let canonical: String
        if parts.count == 2, let minutes = Int(parts[0]), minutes >= 60 {
            canonical = "\(minutes / 60):\(minutes % 60):\(parts[1])"
        } else {
            canonical = clock
        }
        guard let ms = SubtitleTime.parseMilliseconds(canonical) else { return nil }
        return (ms, String(line[body]))
    }

    /// 只取台词正文，喂给对齐器
    public static func alignableLines(_ lines: [ScriptLine]) -> [String] {
        lines.map(\.text)
    }

    // MARK: - 内部

    /// 页码、页眉、分隔线这类噪声
    static func isNoise(_ line: String) -> Bool {
        // 纯数字（页码）
        if line.range(of: "^[0-9]{1,4}$", options: .regularExpression) != nil { return true }
        // - 12 - / — 12 — / Page 12
        if line.range(of: "^[-—–\\s]*[0-9]{1,4}[-—–\\s]*$", options: .regularExpression) != nil { return true }
        if line.range(of: "^[Pp]age\\s*[0-9]{1,4}$", options: .regularExpression) != nil { return true }
        // 分隔线
        if line.range(of: "^[-=_*—–]{3,}$", options: .regularExpression) != nil { return true }
        // 只有标点
        if ScriptNormalizer.normalizedCharacters(line).isEmpty { return true }

        // 章节标题：以 ■●◆★☆◎▶※ 开头，且不太长
        // （真实台本里这些是"■主水 Ash 様 自由谈话"这种段落标题，不是台词）
        let titleMarkers: Set<Character> = ["■", "●", "◆", "★", "☆", "◎", "▶", "►", "※", "▽", "▼"]
        if let first = line.first, titleMarkers.contains(first), line.count <= 40 {
            return true
        }

        // 结束标记
        let endings: Set<String> = ["end", "fin", "完", "終", "终", "おわり", "おしまい", "以上", "完结", "全文完"]
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if endings.contains(normalized) { return true }
        if normalized.hasPrefix("end") && normalized.count <= 6 { return true }

        return false
    }

    /// 判断一段文字像不像"说话人名字"
    ///
    /// 必须有这一关：否则 `「はあ……（息）……だめ」` 里的 `「はあ……`
    /// 会被误判成人名，把台词切坏。
    static func looksLikeSpeakerName(_ candidate: String) -> Bool {
        let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 20 else { return false }
        // 含引号、括号、冒号的不是名字
        let forbidden: Set<Character> = ["「", "」", "『", "』", "\"", "“", "”", "（", "）", "(", ")", "【", "】", ":", "："]
        if name.contains(where: { forbidden.contains($0) }) { return false }
        // 名字里不该有句子标点
        let trailingPunctuation: Set<Character> = ["…", "。", "、", "！", "？", "!", "?", "，", ","]
        if let last = name.last, trailingPunctuation.contains(last) { return false }
        // 太长的不是名字
        if name.count > 12 && name.contains(" ") { return false }
        return true
    }

    /// 拆出说话人
    ///
    /// 支持 `名前：台词`、`名前「台词」`、`【名前】台词`、`名前（小声）台词`
    static func splitSpeaker(_ line: String) -> (speaker: String?, body: String) {
        // 【名前】台词
        if line.hasPrefix("【"),
           let close = line.firstIndex(of: "】") {
            let name = String(line[line.index(after: line.startIndex)..<close])
            let rest = String(line[line.index(after: close)...])
            if looksLikeSpeakerName(name), rest.contains(where: { !$0.isWhitespace }) {
                return (name.trimmingCharacters(in: .whitespaces), rest)
            }
        }

        // 名前：台词 / 名前: 台词
        if let range = line.range(of: "^[^:：]{1,20}[:：]", options: .regularExpression) {
            let head = String(line[range])
            let name = String(head.dropLast())
            let rest = String(line[range.upperBound...])
            // 排除 "http://" 这种；说话人名里不该有空格太多
            if looksLikeSpeakerName(name), !name.contains("//"),
               rest.trimmingCharacters(in: .whitespaces).isEmpty == false {
                return (name.trimmingCharacters(in: .whitespaces), rest)
            }
        }

        // 名前「台词」
        if let openQuote = line.firstIndex(of: "「") {
            let name = String(line[line.startIndex..<openQuote]).trimmingCharacters(in: .whitespaces)
            if looksLikeSpeakerName(name) {
                return (name, String(line[openQuote...]))
            }
        }

        // 名前（小声）台词 —— 名字后面紧跟括号
        if let paren = line.firstIndex(where: { $0 == "（" || $0 == "(" }) {
            let name = String(line[line.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
            if looksLikeSpeakerName(name), name.count <= 12,
               !name.contains(" "), !name.contains("　") {
                // 括号后面的内容要保留（可能是台词的一部分）
                return (name, String(line[line.index(after: paren)...]))
            }
        }

        return (nil, line)
    }

    /// 去掉包裹的「」『』"" 等，让匹配更干净
    static func cleanBody(_ body: String) -> String {
        var s = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉首尾的引号
        let pairs: [(Character, Character)] = [("「", "」"), ("『", "』"), ("\"", "\""), ("“", "”"), ("（", "）"), ("(", ")")]
        var changed = true
        var guardCount = 0
        // 真实台本里引号常常跨行不闭合（`庵：「哎呀…` 后接续行），
        // 所以单独的起始/结束引号也要去掉
        let loneOpen: Set<Character> = ["「", "『", "（", "(", "\"", "“"]
        let loneClose: Set<Character> = ["」", "』", "）", ")", "\"", "”"]
        while changed, guardCount < 4 {
            changed = false
            guardCount += 1
            for (open, close) in pairs {
                if s.first == open, s.last == close, s.count >= 2 {
                    s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }
        // 去掉单独出现在首/尾的引号
        while let first = s.first, loneOpen.contains(first) {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let last = s.last, loneClose.contains(last) {
            s = String(s.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}
