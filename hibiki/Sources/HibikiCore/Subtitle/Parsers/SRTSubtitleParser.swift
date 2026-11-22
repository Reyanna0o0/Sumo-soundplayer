import Foundation

/// SubRip (.srt) 解析器。
///
/// 真实世界的 SRT 文件比规范脏得多，这里按"能读就读"的原则处理：
/// - 序号缺失 / 序号重复 / 序号与内容不对齐
/// - 块之间没有空行
/// - 时间码用 `.` 而不是 `,`
/// - 时间行后面跟老式坐标参数（`X1:100 X2:200`）
/// - 文本里混入 `{\an8}` 之类的覆写标签
public struct SRTSubtitleParser {

    public static func parse(_ rawText: String) -> SubtitleParseResult {
        let lines = SubtitleText.lines(rawText)
        var cues: [SubtitleCue] = []
        var warnings: [String] = []

        var i = 0
        var ordinal = 0
        var pendingIndex: Int?

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 空行：跳过
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // 纯数字：可能是序号，也可能是下一块的序号
            if let n = Int(trimmed), pendingIndex == nil, !isTimeline(lines, at: i) {
                pendingIndex = n
                i += 1
                continue
            }

            // 时间行
            guard let timeline = TimelineLine.parse(line) else {
                // 既不是序号也不是时间行：说明上一个 cue 没有空行分隔，或文件头有杂项
                warnings.append(InterfaceLocalization.text("第 \(i + 1) 行不是合法的时间行，已跳过：\(String(trimmed.prefix(60)))"))
                i += 1
                continue
            }

            let blockStart = i + 1

            // 收集正文，直到空行或"下一块的序号 + 时间行"
            var bodyLines: [String] = []
            var j = blockStart
            while j < lines.count {
                let candidate = lines[j]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidateTrimmed.isEmpty { break }
                if Int(candidateTrimmed) != nil, isTimeline(lines, at: j) {
                    break  // 下一块开始（没有空行分隔）
                }
                bodyLines.append(candidate)
                j += 1
            }

            let text = SubtitleText.cleanBlock(bodyLines.joined(separator: "\n"))
            let speaker = extractSpeaker(from: bodyLines.joined(separator: "\n"))

            if !text.isEmpty {
                cues.append(
                    SubtitleCue(
                        index: ordinal,
                        startMS: timeline.startMS,
                        endMS: max(timeline.startMS, timeline.endMS),
                        text: text,
                        speaker: speaker
                    )
                )
                ordinal += 1
            } else {
                warnings.append(InterfaceLocalization.text("第 \(i + 1) 行的时间段没有文字，已跳过"))
            }

            pendingIndex = nil
            i = j
            if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
            }
        }

        // 结束时间早于开始时间的，修正为 1 秒
        for idx in cues.indices where cues[idx].endMS <= cues[idx].startMS {
            cues[idx].endMS = cues[idx].startMS + 1000
            warnings.append(InterfaceLocalization.text("第 \(idx + 1) 条的时间区间非法，已修正为 1 秒"))
        }

        return SubtitleParseResult(
            cues: cues,
            format: .srt,
            warnings: warnings,
            metadata: [:]
        )
    }

    /// 判断 `lines[at+1]`（或跳过空行后的下一行）是不是时间行 —— 用来区分"序号"和"正文里的数字"
    private static func isTimeline(_ lines: [String], at index: Int) -> Bool {
        var k = index + 1
        while k < lines.count {
            let t = lines[k].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { k += 1; continue }
            return TimelineLine.parse(lines[k]) != nil
        }
        return false
    }

    /// SRT 没有标准的说话人字段，但社区约定俗成会写 `- 名字: 台词` 或 `名字：台词`
    private static func extractSpeaker(from raw: String) -> String? {
        let cleaned = SubtitleText.stripBraceTags(SubtitleText.stripAngleTags(raw))
        let firstLine = cleaned
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return nil }

        // 冒号前不超过 12 字，且不含句读，才认为是说话人
        for separator in [": ", "："] as [String] {
            if let r = firstLine.range(of: separator) {
                let head = String(firstLine[firstLine.startIndex..<r.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                if !head.isEmpty, head.count <= 12,
                   !head.contains("。"), !head.contains("、"), !head.contains("！") {
                    return head
                }
            }
        }
        return nil
    }
}
