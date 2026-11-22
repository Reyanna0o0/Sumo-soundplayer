import Foundation

/// 字幕编辑操作。
///
/// 全部是**纯函数**：输入旧数组，输出新数组，不改原对象。
/// 这样撤销栈、版本对比、并发都很好处理，也方便单元测试。
public enum CueEditor {

    /// 句子长度下限：拆分/拖动时不允许把句子压成 100ms 以内
    public static let minimumDurationMS = 100

    /// 起点由用户或台本给定，句尾最多延后五秒，并停在下一起点、音轨末尾之前。
    public static func automaticEndMS(startMS: Int, nextStartMS: Int?, durationMS: Int?) -> Int? {
        guard startMS >= 0, startMS < Int.max else { return nil }
        var end = startMS + min(5_000, Int.max - startMS)
        if let nextStartMS, nextStartMS > startMS { end = min(end, nextStartMS) }
        if let durationMS, durationMS > 0 { end = min(end, durationMS) }
        return end > startMS ? end : nil
    }

    public static func automaticEndMS(in cues: [SubtitleCue], at index: Int?, startMS: Int, durationMS: Int?) -> Int? {
        if let index, !cues.indices.contains(index) { return nil }
        let next = cues.enumerated().compactMap { offset, cue -> Int? in
            guard offset != index, cue.hasTiming, cue.startMS > startMS else { return nil }
            return cue.startMS
        }.min()
        return automaticEndMS(startMS: startMS, nextStartMS: next, durationMS: durationMS)
    }

    /// 编辑表单可指定到毫秒，留空的句尾需能在下一次编辑时继续自动调整。
    public static func settingEditableRange(_ cues: [SubtitleCue], at index: Int, startMS: Int,
                                            endMS: Int?, durationMS: Int?) -> [SubtitleCue]? {
        guard cues.indices.contains(index), startMS >= 0 else { return nil }
        let end: Int
        if let endMS {
            guard endMS > startMS else { return nil }
            if let durationMS, durationMS > 0, endMS > durationMS { return nil }
            end = endMS
        } else {
            guard let estimated = automaticEndMS(in: cues, at: index, startMS: startMS, durationMS: durationMS)
            else { return nil }
            end = estimated
        }
        var result = cues
        result[index].startMS = startMS
        result[index].endMS = end
        result[index].status = endMS == nil ? .provisional : .ok
        return result
    }

    /// 保存编辑版本时统一重算。邻句可以移走、被删除，也可能在台本顺序的前面。
    public static func resolvingAutomaticEnds(_ cues: [SubtitleCue], durationMS: Int?) -> [SubtitleCue] {
        guard cues.contains(where: { $0.status == .provisional }) else { return cues }
        let starts = Set(cues.filter(\.hasTiming).map(\.startMS)).sorted()
        let nextByStart = Dictionary(uniqueKeysWithValues: zip(starts, starts.dropFirst()))
        var result = cues
        for index in result.indices where result[index].status == .provisional {
            let start = result[index].startMS
            if let end = automaticEndMS(startMS: start, nextStartMS: nextByStart[start], durationMS: durationMS) {
                result[index].endMS = end
            } else {
                result[index].endMS = 0
                result[index].status = .untimed
            }
        }
        return result
    }

    // MARK: - 时间调整

    /// 统一平移所有句子的时间（用于"整轨提前/延后 N 秒"）
    public static func shiftAll(_ cues: [SubtitleCue], by deltaMS: Int) -> [SubtitleCue] {
        cues.map { cue in
            guard cue.hasTiming else { return cue }
            var c = cue
            c.startMS = max(0, c.startMS + deltaMS)
            c.endMS = max(c.startMS + minimumDurationMS, c.endMS + deltaMS)
            return c
        }
    }

    /// 只平移指定下标（用于选中几句一起挪）
    public static func shift(_ cues: [SubtitleCue], at indices: Set<Int>, by deltaMS: Int) -> [SubtitleCue] {
        cues.enumerated().map { idx, cue in
            guard indices.contains(idx), cue.hasTiming else { return cue }
            var c = cue
            c.startMS = max(0, c.startMS + deltaMS)
            c.endMS = max(c.startMS + minimumDurationMS, c.endMS + deltaMS)
            return c
        }
    }

    /// 设置某句的开始时间（打轴用："现在 = 这句开头"）
    public static func settingStart(_ cues: [SubtitleCue], at index: Int, to newStartMS: Int) -> [SubtitleCue] {
        guard cues.indices.contains(index) else { return cues }
        var result = cues
        var c = result[index]
        let clampedStart = max(0, newStartMS)
        if !c.hasTiming {
            c.startMS = clampedStart
            c.endMS = max(clampedStart + minimumDurationMS, c.endMS)
            c.status = .ok
            result[index] = c
            return result
        }
        // 开始时间不能越过自己的结束时间
        c.startMS = min(clampedStart, c.endMS - minimumDurationMS)
        result[index] = c
        return result
    }

    /// 设置某句的结束时间（"现在 = 这句结尾"）
    public static func settingEnd(_ cues: [SubtitleCue], at index: Int, to newEndMS: Int) -> [SubtitleCue] {
        guard cues.indices.contains(index) else { return cues }
        var result = cues
        var c = result[index]
        c.endMS = max(newEndMS, c.startMS + minimumDurationMS)
        c.status = .ok
        result[index] = c
        return result
    }

    /// 把某句的起止设为给定区间
    public static func settingRange(
        _ cues: [SubtitleCue], at index: Int, startMS: Int, endMS: Int
    ) -> [SubtitleCue] {
        guard cues.indices.contains(index) else { return cues }
        var result = cues
        var c = result[index]
        c.startMS = max(0, startMS)
        c.endMS = max(c.startMS + minimumDurationMS, endMS)
        c.status = .ok
        result[index] = c
        return result
    }

    /// 让所有句子的结束时间贴合下一句的开始时间（修掉缝隙/重叠）
    ///
    /// `gapMS` 是保留的小空隙，避免两句紧贴导致闪烁。
    public static func snapEndsToNextStart(_ cues: [SubtitleCue], gapMS: Int = 40) -> [SubtitleCue] {
        guard cues.count > 1 else { return cues }
        var result = cues
        for i in 0..<(result.count - 1) {
            guard result[i].hasTiming, result[i + 1].hasTiming else { continue }
            let nextStart = result[i + 1].startMS
            let desiredEnd = nextStart - gapMS
            if desiredEnd > result[i].startMS + minimumDurationMS {
                result[i].endMS = desiredEnd
            }
        }
        return result
    }

    // MARK: - 文本

    public static func settingText(_ cues: [SubtitleCue], at index: Int, to text: String) -> [SubtitleCue] {
        guard cues.indices.contains(index) else { return cues }
        var result = cues
        result[index].text = text
        // 改文字可以确认已有时间的句子，但不能替未知/估算时间作确认。
        // .untimed / .unaligned 仅在用户显式设置时间区间后变成 .ok。
        if result[index].hasTiming && result[index].status != .provisional { result[index].status = .ok }
        return result
    }

    public static func settingTranslation(
        _ cues: [SubtitleCue], at index: Int, to translation: String?
    ) -> [SubtitleCue] {
        guard cues.indices.contains(index) else { return cues }
        var result = cues
        let trimmed = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        result[index].translatedText = (trimmed?.isEmpty ?? true) ? nil : trimmed
        return result
    }

    public static func settingSpeaker(_ cues: [SubtitleCue], at index: Int, to speaker: String?) -> [SubtitleCue] {
        guard cues.indices.contains(index) else { return cues }
        var result = cues
        let trimmed = speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
        result[index].speaker = (trimmed?.isEmpty ?? true) ? nil : trimmed
        return result
    }

    public static func settingStatus(_ cues: [SubtitleCue], at index: Int, to status: CueStatus) -> [SubtitleCue] {
        guard cues.indices.contains(index) else { return cues }
        var result = cues
        result[index].status = status
        return result
    }

    // MARK: - 结构操作

    /// 拆分：在 `offsetMS`（相对该句开始的毫秒）处切成两句。
    ///
    /// 文字会尽量按比例猜测切点（中文/日文按字符数，英文按空格），
    /// 猜不准也没关系，用户可以再改。
    public static func split(
        _ cues: [SubtitleCue], at index: Int, offsetMS: Int? = nil, textSplitIndex: Int? = nil
    ) -> [SubtitleCue] {
        guard cues.indices.contains(index) else { return cues }
        var result = cues
        let original = result[index]
        guard original.hasTiming else { return cues }

        let splitPoint = offsetMS ?? (original.durationMS / 2)
        let clampedOffset = min(max(minimumDurationMS, splitPoint), original.durationMS - minimumDurationMS)
        let midTime = original.startMS + clampedOffset

        let (headText, tailText) = splitText(
            original.text, translation: original.translatedText, at: textSplitIndex
        )

        var first = original
        first.endMS = midTime
        first.text = headText.text
        first.translatedText = headText.translation

        var second = SubtitleCue(
            index: index + 1,
            startMS: midTime,
            endMS: original.endMS,
            text: tailText.text,
            translatedText: tailText.translation,
            speaker: original.speaker,
            status: original.status
        )
        second.endMS = max(second.startMS + minimumDurationMS, second.endMS)

        result[index] = first
        result.insert(second, at: index + 1)
        return reindex(result)
    }

    /// 合并：把 `index` 与 `index+1` 合成一句
    public static func merge(_ cues: [SubtitleCue], at index: Int, separator: String = "\n") -> [SubtitleCue] {
        guard cues.indices.contains(index), index + 1 < cues.count else { return cues }
        var result = cues
        let a = result[index]
        let b = result[index + 1]

        var merged = a
        merged.startMS = min(a.startMS, b.startMS)
        merged.endMS = max(a.endMS, b.endMS)
        merged.text = joinNonEmpty(a.text, b.text, separator: separator)
        if a.translatedText != nil || b.translatedText != nil {
            merged.translatedText = joinNonEmpty(
                a.translatedText ?? "", b.translatedText ?? "", separator: separator
            )
        }
        if merged.speaker == nil { merged.speaker = b.speaker }
        merged.status = (a.status == .ok && b.status == .ok) ? .ok : .lowConfidence
        if !a.hasTiming || !b.hasTiming {
            merged.startMS = 0
            merged.endMS = 0
            merged.status = .untimed
        }

        result[index] = merged
        result.remove(at: index + 1)
        return reindex(result)
    }

    /// 插入一条空字幕（漏句时用），时间默认落在前后之间
    public static func insertEmpty(_ cues: [SubtitleCue], after index: Int) -> [SubtitleCue] {
        var result = cues
        let insertAt = max(0, min(index + 1, result.count))
        let prevEnd = insertAt > 0 ? result[insertAt - 1].endMS : 0
        let nextStart = insertAt < result.count ? result[insertAt].startMS : prevEnd + 2000
        let start = min(prevEnd, max(0, nextStart - 1000))
        let end = max(start + minimumDurationMS, min(nextStart, start + 2000))
        let untimed = !result.isEmpty && !result[min(max(0, index), result.count - 1)].hasTiming
        let cue = SubtitleCue(index: insertAt, startMS: untimed ? 0 : start,
                              endMS: untimed ? 0 : end, text: "", status: untimed ? .untimed : .ok)
        result.insert(cue, at: insertAt)
        return reindex(result)
    }

    /// 删除指定下标
    public static func delete(_ cues: [SubtitleCue], at indices: Set<Int>) -> [SubtitleCue] {
        let filtered = cues.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
        return reindex(filtered)
    }

    /// 删除所有空句
    public static func removingEmpty(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        reindex(cues.filter { !$0.isEmpty })
    }

    /// 重排 index，保证连续
    public static func reindex(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var result = cues
        for i in result.indices { result[i].index = i }
        return result
    }

    /// 按开始时间排序并重排
    public static func sorted(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var result = cues.enumerated().sorted { a, b in
            a.element.startMS == b.element.startMS ? a.offset < b.offset : a.element.startMS < b.element.startMS
        }.map(\.element)
        for i in result.indices { result[i].index = i }
        return result
    }

    // MARK: - 内部

    struct SplitText {
        let text: String
        let translation: String?
    }

    static func splitText(_ text: String, translation: String?, at explicitIndex: Int?) -> (SplitText, SplitText) {
        let chars = Array(text)
        guard !chars.isEmpty else {
            return (SplitText(text: "", translation: translation), SplitText(text: "", translation: nil))
        }

        let cut: Int
        if let explicitIndex {
            cut = min(max(1, explicitIndex), chars.count - 1)
        } else {
            cut = preferredTextCut(chars)
        }

        let head = String(chars[0..<cut]).trimmingCharacters(in: .whitespaces)
        let tail = String(chars[cut...]).trimmingCharacters(in: .whitespaces)

        // 译文如果存在，按同样的字符比例切
        var headTranslation: String?
        var tailTranslation: String?
        if let translation, !translation.isEmpty {
            let tChars = Array(translation)
            let tCut = max(1, min(tChars.count - 1, Int(Double(tChars.count) * Double(cut) / Double(chars.count))))
            if tChars.count > 1 {
                headTranslation = String(tChars[0..<tCut]).trimmingCharacters(in: .whitespaces)
                tailTranslation = String(tChars[tCut...]).trimmingCharacters(in: .whitespaces)
            }
        }

        return (
            SplitText(text: head, translation: headTranslation),
            SplitText(text: tail, translation: tailTranslation)
        )
    }

    /// 猜一个合理的文字切点：优先在标点后切，其次是空格
    static func preferredTextCut(_ chars: [Character]) -> Int {
        let middle = chars.count / 2
        let punctuation: Set<Character> = ["。", "、", "！", "？", "…", "，", ".", ",", "!", "?", " ", "　", "」", "）"]

        var bestIndex: Int?
        var bestDistance = Int.max
        for (idx, ch) in chars.enumerated() where punctuation.contains(ch) {
            guard idx > 0, idx < chars.count - 1 else { continue }
            let distance = abs(idx + 1 - middle)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = idx + 1
            }
        }
        return bestIndex ?? middle
    }

    static func joinNonEmpty(_ a: String, _ b: String, separator: String) -> String {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.isEmpty { return y }
        if y.isEmpty { return x }
        return x + separator + y
    }
}
