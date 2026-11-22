import Foundation

/// ASS / SSA 解析器。
///
/// 关键难点是 `[Events]` 段的 `Format:` 行 —— **字段顺序是文件自己声明的**，
/// 不能写死。有的文件是
///   `Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text`
/// 有的 SSA 是
///   `Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text`
/// 所以这里先记住 Format 的字段名，再按下标取值。
///
/// Text 是最后一个字段，内部可以含逗号，因此分割时要限制份数。
public struct ASSSubtitleParser {

    public static func parse(_ rawText: String) -> SubtitleParseResult {
        let lines = SubtitleText.lines(rawText)
        var cues: [SubtitleCue] = []
        var warnings: [String] = []
        var metadata: [String: String] = [:]

        var section = ""
        var eventFields: [String] = []
        var ordinal = 0
        var isSSA = false

        for (lineNumber, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // 段头
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.lowercased()
                if section.contains("v4 styles") && !section.contains("v4+") {
                    isSSA = true
                }
                continue
            }

            // [Script Info] 的键值
            if section == "[script info]" {
                if let colon = line.firstIndex(of: ":") {
                    let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { metadata[key] = value }
                }
                continue
            }

            guard section == "[events]" else { continue }

            // Format 行
            if line.lowercased().hasPrefix("format:") {
                let rest = String(line.dropFirst("format:".count))
                eventFields = rest
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }

            // 只解析 Dialogue，跳过 Comment
            let lower = line.lowercased()
            guard lower.hasPrefix("dialogue:") else { continue }

            let rest = String(line.dropFirst("dialogue:".count))
            let fields = splitFields(rest, limit: eventFields.count)

            if eventFields.isEmpty {
                // 没读到 Format 行，按最常见的 10 字段回退
                eventFields = ["layer", "start", "end", "style", "name",
                               "marginl", "marginr", "marginv", "effect", "text"]
            }

            guard fields.count >= 2 else {
                warnings.append(InterfaceLocalization.text("第 \(lineNumber + 1) 行的 Dialogue 字段不足，已跳过"))
                continue
            }

            func field(_ name: String, fallbackIndex: Int) -> String {
                if let idx = eventFields.firstIndex(of: name), idx < fields.count {
                    return fields[idx]
                }
                return fallbackIndex < fields.count ? fields[fallbackIndex] : ""
            }

            let startText = field("start", fallbackIndex: 1)
            let endText = field("end", fallbackIndex: 2)
            let nameText = field("name", fallbackIndex: 4)
            let styleText = field("style", fallbackIndex: 3)
            let effectText = field("effect", fallbackIndex: 8)
            let textIndex = eventFields.firstIndex(of: "text") ?? (fields.count - 1)
            let rawBody = textIndex < fields.count ? fields[textIndex] : ""

            guard let startMS = SubtitleTime.parseMilliseconds(startText) else {
                warnings.append(InterfaceLocalization.text("第 \(lineNumber + 1) 行的开始时间无法解析：\(startText)"))
                continue
            }
            guard let endMS = SubtitleTime.parseMilliseconds(endText) else {
                warnings.append(InterfaceLocalization.text("第 \(lineNumber + 1) 行的结束时间无法解析：\(endText)"))
                continue
            }

            // 去覆写标签 → 转换 \N
            let withoutTags = SubtitleText.stripBraceTags(rawBody)
            let withNewlines = SubtitleText.convertAssNewlines(withoutTags)
            let text = SubtitleText.cleanBlock(withNewlines)

            // "karaoke"/"scroll" 等 effect 的空行仍然保留（有时间意义），但完全空的跳过
            guard !text.isEmpty else { continue }

            var speaker = nameText.trimmingCharacters(in: .whitespaces)
            if speaker.isEmpty { speaker = styleText.trimmingCharacters(in: .whitespaces) }
            if speaker.isEmpty || speaker.lowercased() == "default" { speaker = "" }

            if effectText.trimmingCharacters(in: .whitespaces).isEmpty {
                // 占位，仅为可读性
            }

            cues.append(
                SubtitleCue(
                    index: ordinal,
                    startMS: startMS,
                    endMS: max(startMS, endMS),
                    text: text,
                    speaker: speaker.isEmpty ? nil : speaker
                )
            )
            ordinal += 1
        }

        for idx in cues.indices where cues[idx].endMS <= cues[idx].startMS {
            cues[idx].endMS = cues[idx].startMS + 1000
            warnings.append(InterfaceLocalization.text("第 \(idx + 1) 条的时间区间非法，已修正为 1 秒"))
        }

        return SubtitleParseResult(
            cues: cues,
            format: isSSA ? .ssa : .ass,
            warnings: warnings,
            metadata: metadata
        )
    }

    /// 按逗号分割，但限定份数 —— 这样最后一段（Text）里含逗号也不会被切碎
    static func splitFields(_ input: String, limit: Int) -> [String] {
        let parts = input.split(separator: ",", maxSplits: max(0, limit - 1), omittingEmptySubsequences: false)
        return parts.map(String.init)
    }
}
