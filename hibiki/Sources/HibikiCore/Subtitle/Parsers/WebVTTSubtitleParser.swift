import Foundation

/// WebVTT (.vtt) 解析器。
///
/// 处理要点：
/// - `WEBVTT` 头 + 可选的 Kind/Language 行
/// - `NOTE` / `STYLE` / `REGION` 块整块跳过
/// - cue 可以有标识行（identifier），也可以没有
/// - 时间行后面的 cue settings（`align:start position:10%`）
/// - 文本里的 `<c.class>` `<b>` `<i>` `<v 张三>` `<00:00:01.000>` 等标签
public struct WebVTTSubtitleParser {

    public static func parse(_ rawText: String) -> SubtitleParseResult {
        let lines = SubtitleText.lines(rawText)
        var cues: [SubtitleCue] = []
        var warnings: [String] = []
        var metadata: [String: String] = [:]

        var i = 0
        var ordinal = 0

        // 1) 头部：第一行必须是 WEBVTT（允许带后缀）
        if let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            if !first.uppercased().hasPrefix("WEBVTT") {
                warnings.append(InterfaceLocalization.text("文件缺少 WEBVTT 头，仍按 VTT 解析"))
            }
        }
        // 跳过头部直到空行
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { i += 1; break }
            if let colon = t.firstIndex(of: ":"), !t.contains("-->") {
                let key = String(t[t.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if key.lowercased() != "webvtt", !value.isEmpty {
                    metadata[key] = value
                }
            }
            i += 1
        }

        // 2) 正文块
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            let upper = trimmed.uppercased()
            if upper.hasPrefix("NOTE") {
                i = skipBlock(lines, from: i)
                continue
            }
            if upper == "STYLE" || upper.hasPrefix("STYLE ") {
                i = skipBlock(lines, from: i)
                continue
            }
            if upper == "REGION" || upper.hasPrefix("REGION ") {
                i = skipBlock(lines, from: i)
                continue
            }

            // 当前行可能是 identifier，也可能是时间行
            var timelineLineIndex = i
            if TimelineLine.parse(raw) == nil {
                // 往后找时间行
                var k = i + 1
                while k < lines.count, TimelineLine.parse(lines[k]) == nil {
                    if lines[k].trimmingCharacters(in: .whitespaces).isEmpty { break }
                    k += 1
                }
                guard k < lines.count, let _ = TimelineLine.parse(lines[k]) else {
                    warnings.append(InterfaceLocalization.text("第 \(i + 1) 行起的块没有找到时间行，已跳过"))
                    i = skipBlock(lines, from: i)
                    continue
                }
                timelineLineIndex = k
            }

            guard let timeline = TimelineLine.parse(lines[timelineLineIndex]) else {
                i += 1
                continue
            }

            // 收集正文
            var bodyLines: [String] = []
            var j = timelineLineIndex + 1
            while j < lines.count {
                if lines[j].trimmingCharacters(in: .whitespaces).isEmpty { break }
                bodyLines.append(lines[j])
                j += 1
            }

            let rawBody = bodyLines.joined(separator: "\n")
            let speaker = extractSpeaker(from: rawBody)
            let text = SubtitleText.cleanBlock(rawBody)

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
            }

            if let pos = parsePosition(timeline.settings) {
                metadata["_cuePosition_\(ordinal - 1)"] = pos
            }

            i = j
        }

        for idx in cues.indices where cues[idx].endMS <= cues[idx].startMS {
            cues[idx].endMS = cues[idx].startMS + 1000
            warnings.append(InterfaceLocalization.text("第 \(idx + 1) 条的时间区间非法，已修正为 1 秒"))
        }

        return SubtitleParseResult(cues: cues, format: .vtt, warnings: warnings, metadata: metadata)
    }

    private static func skipBlock(_ lines: [String], from index: Int) -> Int {
        var k = index
        while k < lines.count {
            if lines[k].trimmingCharacters(in: .whitespaces).isEmpty { return k + 1 }
            k += 1
        }
        return k
    }

    /// `<v 张三>台词</v>` 形式的说话人
    private static func extractSpeaker(from raw: String) -> String? {
        guard let start = raw.range(of: "<v "),
              let end = raw.range(of: ">", range: start.upperBound..<raw.endIndex)
        else { return nil }
        let name = String(raw[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func parsePosition(_ settings: String) -> String? {
        for token in settings.split(separator: " ") {
            if token.lowercased().hasPrefix("position:") {
                return String(token.dropFirst("position:".count))
            }
        }
        return nil
    }
}
