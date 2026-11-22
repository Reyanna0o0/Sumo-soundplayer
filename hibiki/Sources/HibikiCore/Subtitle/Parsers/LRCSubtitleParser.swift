import Foundation

/// LRC（歌词）解析器。
///
/// 音声作品里经常只有 .lrc 歌词文件，或者在音频里内嵌 LRC 标签，
/// 所以这个解析器用得很多。处理要点：
/// - 元信息：`[ti:]` `[ar:]` `[al:]` `[by:]` `[offset:]`（offset 单位是毫秒，正值表示整体延后）
/// - 一行可以有多个时间标签：`[00:12.00][00:45.00]同一句`
/// - 时间可以是 `mm:ss.xx`（厘秒）或 `mm:ss.xxx`（毫秒）
/// - Enhanced LRC 的行内时间戳 `<00:15.30>` 要去掉（暂不支持卡拉OK逐字）
/// - LRC 只有开始时间，结束时间靠"下一条开始"推出来
public struct LRCSubtitleParser {

    /// 最后一条字幕没有下一条可参考，用这个默认时长
    public static let defaultTrailingDurationMS = 3000

    public static func parse(_ rawText: String) -> SubtitleParseResult {
        let lines = SubtitleText.lines(rawText)
        var entries: [(startMS: Int, text: String)] = []
        var metadata: [String: String] = [:]
        var warnings: [String] = []
        var offsetMS = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // 元信息标签
            if let meta = parseMetadata(trimmed) {
                if meta.key == "offset" {
                    if let v = Int(meta.value) { offsetMS = v }
                } else {
                    metadata[meta.key] = meta.value
                }
                // 元信息行可能同时带时间标签（少见），继续往下尝试
                if !trimmed.contains("]") || meta.isWholeLine {
                    continue
                }
            }

            // 收集行首所有 [..] 时间标签
            var timestamps: [Int] = []
            var cursor = trimmed.startIndex
            while cursor < trimmed.endIndex, trimmed[cursor] == "[" {
                guard let close = trimmed[cursor...].firstIndex(of: "]") else { break }
                let inner = String(trimmed[trimmed.index(after: cursor)..<close])
                if let ms = parseLRCStamp(inner) {
                    timestamps.append(ms)
                    cursor = trimmed.index(after: close)
                } else {
                    break  // 不是时间标签，说明这是元信息或普通文本
                }
            }

            guard !timestamps.isEmpty else { continue }

            var body = String(trimmed[cursor...])
            // 去掉 Enhanced LRC 的行内时间戳
            body = stripInlineTimestamps(body)
            body = SubtitleText.decodeEntities(body)
            body = body.trimmingCharacters(in: .whitespaces)

            for ts in timestamps {
                entries.append((startMS: max(0, ts + offsetMS), text: body))
            }
        }

        if entries.isEmpty {
            warnings.append(InterfaceLocalization.text("没有解析到任何带时间的歌词行"))
            return SubtitleParseResult(cues: [], format: .lrc, warnings: warnings, metadata: metadata)
        }

        // 稳定排序（同一时间保持原始顺序）
        let ordered = entries.enumerated().sorted { a, b in
            a.element.startMS == b.element.startMS
                ? a.offset < b.offset
                : a.element.startMS < b.element.startMS
        }.map(\.element)

        var cues: [SubtitleCue] = []
        for (idx, entry) in ordered.enumerated() {
            let endMS: Int
            if idx + 1 < ordered.count {
                endMS = ordered[idx + 1].startMS
            } else {
                endMS = entry.startMS + defaultTrailingDurationMS
            }
            cues.append(
                SubtitleCue(
                    index: idx,
                    startMS: entry.startMS,
                    endMS: max(entry.startMS + 100, endMS),
                    text: entry.text
                )
            )
        }

        return SubtitleParseResult(cues: cues, format: .lrc, warnings: warnings, metadata: metadata)
    }

    // MARK: - 内部

    struct MetadataMatch {
        let key: String
        let value: String
        /// 整行就是一个元信息标签（后面没有正文）
        let isWholeLine: Bool
    }

    static func parseMetadata(_ line: String) -> MetadataMatch? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let inner = String(line[line.index(after: line.startIndex)..<close])
        guard let colon = inner.firstIndex(of: ":") else { return nil }
        let key = String(inner[inner.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(inner[inner.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // 时间标签形如 00:12.00，会被 parseLRCStamp 认出来；这里只挑非数字开头的键
        guard !key.isEmpty, key.first?.isNumber == false else { return nil }
        let isWholeLine = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces).isEmpty
        return MetadataMatch(key: key, value: value, isWholeLine: isWholeLine)
    }

    /// 解析 `00:12.34` / `12.34` / `00:12` 这类 LRC 时间标签
    static func parseLRCStamp(_ inner: String) -> Int? {
        let s = inner.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // 纯数字且没有冒号：可能是 [123] 这种（非法），不认
        guard s.contains(":") else { return nil }
        return SubtitleTime.parseMilliseconds(s)
    }

    static func stripInlineTimestamps(_ body: String) -> String {
        guard body.contains("<"), body.contains(">") else { return body }
        var out = ""
        var inside = false
        for ch in body {
            if ch == "<" { inside = true; continue }
            if ch == ">" { inside = false; continue }
            if !inside { out.append(ch) }
        }
        return out
    }
}
