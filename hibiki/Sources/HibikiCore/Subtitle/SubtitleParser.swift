import Foundation

/// 字幕解析的统一入口：按格式分发，不指定格式时自动嗅探。
public enum SubtitleParser {

    /// 解析字幕文本。
    ///
    /// - Parameters:
    ///   - text: 已经解码成字符串的字幕内容（编码问题在 `TextEncodingDetector` 解决）
    ///   - formatHint: 从扩展名或用户指定得到的格式；为 nil 时自动嗅探
    public static func parse(_ text: String, formatHint: SubtitleFormat? = nil) -> SubtitleParseResult {
        guard !text.isEmpty else {
            return SubtitleParseResult(cues: [], format: formatHint ?? .srt, warnings: [InterfaceLocalization.text("字幕内容为空")], metadata: [:])
        }

        if let hint = formatHint {
            let direct = parseAs(text, format: hint)
            if !direct.cues.isEmpty { return direct }
            // 扩展名和内容不符（常见：.txt 里装的是 ASS），退回嗅探
            if let detected = detectFormat(text), detected != hint {
                let second = parseAs(text, format: detected)
                if second.cues.count > direct.cues.count {
                    var merged = second
                    merged.warnings.insert(InterfaceLocalization.text("扩展名提示为 \(hint.rawValue)，实际判定为 \(detected.rawValue)"), at: 0)
                    return merged
                }
            }
            return direct
        }

        if let detected = detectFormat(text) {
            let result = parseAs(text, format: detected)
            if !result.cues.isEmpty { return result }
        }

        // 最后兜底：每种都试，取条目最多的
        let candidates: [SubtitleFormat] = [.srt, .vtt, .ass, .lrc, .smi]
        var best = SubtitleParseResult(cues: [], format: .srt, warnings: [InterfaceLocalization.text("无法识别的字幕格式")], metadata: [:])
        for f in candidates {
            let r = parseAs(text, format: f)
            if r.cues.count > best.cues.count { best = r }
        }
        return best
    }

    /// 只按指定格式解析，不做嗅探
    public static func parseAs(_ text: String, format: SubtitleFormat) -> SubtitleParseResult {
        var result: SubtitleParseResult
        switch format {
        case .srt: result = SRTSubtitleParser.parse(text)
        case .vtt: result = WebVTTSubtitleParser.parse(text)
        case .lrc: result = LRCSubtitleParser.parse(text)
        case .ass, .ssa: result = ASSSubtitleParser.parse(text)
        case .smi: result = SMISubtitleParser.parse(text)
        }
        result.cues = BilingualText.separating(result.cues)
        return result
    }

    /// 根据内容嗅探格式（只看特征，不解析全部）
    public static func detectFormat(_ text: String) -> SubtitleFormat? {
        let head = text.prefix(4096)
        let upper = head.uppercased()

        if upper.contains("WEBVTT") { return .vtt }
        if upper.contains("<SAMI") || upper.contains("<SYNC") { return .smi }

        let lines = SubtitleText.lines(String(text.prefix(64 * 1024)))

        // ASS / SSA：[Script Info] / [Events] / Dialogue:
        for line in lines.prefix(200) {
            let t = line.trimmingCharacters(in: .whitespaces)
            let lower = t.lowercased()
            if lower == "[events]" || lower.hasPrefix("[v4+ styles]") { return .ass }
            if lower.hasPrefix("[v4 styles]") { return .ssa }
            if lower.hasPrefix("dialogue:") { return .ass }
        }

        // SRT / VTT：含 "-->" 行
        let arrowLines = lines.filter { $0.contains("-->") }
        if !arrowLines.isEmpty {
            if upper.contains("WEBVTT") { return .vtt }
            // SRT 的时间用逗号，VTT 用点；两者混用也有，但要能区分
            let commaCount = arrowLines.filter { $0.contains(",") }.count
            let dotCount = arrowLines.filter { $0.contains(".") }.count
            if commaCount == 0 && dotCount > 0 { return .vtt }
            return .srt
        }

        // LRC：以 [mm:ss] 开头，且这样的行够多
        var lrcLineCount = 0
        for line in lines.prefix(500) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("["), t.count > 5,
               let close = t.firstIndex(of: "]"), t[t.index(after: t.startIndex)..<close].contains(":") {
                let inner = String(t[t.index(after: t.startIndex)..<close])
                if LRCSubtitleParser.parseLRCStamp(inner) != nil {
                    lrcLineCount += 1
                }
            }
        }
        if lrcLineCount >= 2 { return .lrc }

        return nil
    }

    /// 从文件名推断格式
    public static func detectFormat(fromFileName name: String) -> SubtitleFormat? {
        let url = URL(fileURLWithPath: name)
        return SubtitleFormat.from(fileExtension: url.pathExtension)
    }
}
