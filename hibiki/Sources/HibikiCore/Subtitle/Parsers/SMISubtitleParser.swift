import Foundation

/// SAMI (.smi) 解析器。
///
/// 老式日韩字幕格式，结构是"一堆 `<SYNC Start=毫秒>` 打点"：
/// ```
/// <SYNC Start=1000><P Class=KRCC>あ、そこは
/// <SYNC Start=3000><P Class=KRCC>&nbsp;
/// ```
/// 特点：**只有开始时间**，结束时间靠下一条 SYNC 推出来；
/// 空内容（`&nbsp;`）表示这段时间不显示字幕，也就是"上一条在这里结束"。
public struct SMISubtitleParser {

    public static func parse(_ rawText: String) -> SubtitleParseResult {
        let normalized = SubtitleText.normalizeNewlines(rawText)
        var warnings: [String] = []
        var rawSegments: [(startMS: Int, html: String)] = []

        // 用 <SYNC ...> 把全文切开
        let pattern = "(?i)<sync\\s+start\\s*=\\s*(\\d+)\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return SubtitleParseResult(cues: [], format: .smi, warnings: [InterfaceLocalization.text("内部正则构造失败")], metadata: [:])
        }

        let ns = normalized as NSString
        let matches = regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length))

        if matches.isEmpty {
            warnings.append(InterfaceLocalization.text("没有找到任何 <SYNC> 标记，可能不是 SAMI 文件"))
            return SubtitleParseResult(cues: [], format: .smi, warnings: warnings, metadata: [:])
        }

        for (i, m) in matches.enumerated() {
            guard let startRange = Range(m.range(at: 1), in: normalized) else { continue }
            guard let startMS = Int(normalized[startRange]) else { continue }

            let bodyStart = m.range.location + m.range.length
            let bodyEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            guard bodyEnd >= bodyStart else { continue }
            let bodyRange = NSRange(location: bodyStart, length: bodyEnd - bodyStart)
            let body = ns.substring(with: bodyRange)
            rawSegments.append((startMS: startMS, html: body))
        }

        // 转成 cue：内容为空 → 只是分隔点
        var cues: [SubtitleCue] = []
        var ordinal = 0

        for (idx, seg) in rawSegments.enumerated() {
            let text = cleanSAMIHTML(seg.html)
            let nextStart: Int? = (idx + 1 < rawSegments.count) ? rawSegments[idx + 1].startMS : nil

            if text.isEmpty { continue }

            let endMS: Int
            if let next = nextStart, next > seg.startMS {
                endMS = next
            } else {
                endMS = seg.startMS + 2000
            }

            cues.append(
                SubtitleCue(
                    index: ordinal,
                    startMS: seg.startMS,
                    endMS: endMS,
                    text: text
                )
            )
            ordinal += 1
        }

        return SubtitleParseResult(cues: cues, format: .smi, warnings: warnings, metadata: [:])
    }

    static func cleanSAMIHTML(_ html: String) -> String {
        var s = html
        // <P Class=...> 等标签去掉，但先去掉 <P> 之前可能残留的光标
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</p>", with: "\n", options: .regularExpression)
        s = SubtitleText.stripAngleTags(s)
        s = SubtitleText.decodeEntities(s)
        // &nbsp; 已被解码成不换行空格，这里当空白处理
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        return SubtitleText.cleanBlock(s)
    }
}
