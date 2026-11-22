import Foundation

/// 导出选项
public struct SubtitleExportOptions: Sendable {
    /// 是否把译文一起写进去
    public var includeTranslation: Bool
    /// 双语排版方式
    public enum BilingualLayout: Sendable {
        /// 原文一行、译文一行（同一文件）
        case twoLines
        /// 拆成两个文件（`.ja.srt` + `.zh.srt`）
        case splitFiles
    }
    public var bilingualLayout: BilingualLayout
    /// 是否保留"未对齐"的条目（一般保留，方便继续校对）
    public var includeUnaligned: Bool

    public init(
        includeTranslation: Bool = true,
        bilingualLayout: BilingualLayout = .twoLines,
        includeUnaligned: Bool = true
    ) {
        self.includeTranslation = includeTranslation
        self.bilingualLayout = bilingualLayout
        self.includeUnaligned = includeUnaligned
    }
}

/// 导出的一个文件
public struct SubtitleExportFile: Equatable, Sendable {
    /// 文件名后缀，如 "ja" / "zh" / ""（单语时不带）
    public let languageSuffix: String?
    public let content: String
    public let format: SubtitleFormat
    public let suggestedFileName: String
}

/// 字幕导出。
public enum SubtitleExporter {

    /// 导出单个文件
    public static func export(
        _ cues: [SubtitleCue],
        format: SubtitleFormat,
        options: SubtitleExportOptions = .init()
    ) -> String {
        let filtered = options.includeUnaligned ? cues : cues.filter { $0.status == .ok }
        let ordered = CueEditor.sorted(filtered)

        switch format {
        case .srt: return exportSRT(ordered, options: options)
        case .vtt: return exportVTT(ordered, options: options)
        case .lrc: return exportLRC(ordered, options: options)
        case .ass, .ssa: return exportASS(ordered, options: options)
        case .smi: return exportSRT(ordered, options: options)  // SAMI 不支持导出，退回 SRT
        }
    }

    /// 双语导出：按选项决定是"一个文件两行"还是"两个文件"
    public static func exportFiles(
        _ cues: [SubtitleCue],
        format: SubtitleFormat,
        baseName: String,
        primaryLanguage: String?,
        secondaryLanguage: String?,
        options: SubtitleExportOptions = .init()
    ) -> [SubtitleExportFile] {
        guard options.includeTranslation,
              options.bilingualLayout == .splitFiles,
              cues.contains(where: { !($0.translatedText ?? "").isEmpty })
        else {
            let content = export(cues, format: format, options: options)
            let name = suggestedFileName(
                baseName: baseName,
                language: primaryLanguage,
                format: format
            )
            return [
                SubtitleExportFile(
                    languageSuffix: primaryLanguage,
                    content: content,
                    format: format,
                    suggestedFileName: name
                )
            ]
        }

        // 原文文件
        let primaryCues = cues.map { cue -> SubtitleCue in
            var c = cue
            c.translatedText = nil
            return c
        }
        // 译文文件：把译文当正文
        let secondaryCues = cues.map { cue -> SubtitleCue in
            var c = cue
            c.text = cue.translatedText ?? ""
            c.translatedText = nil
            return c
        }

        let primaryContent = export(primaryCues, format: format, options: options)
        let secondaryContent = export(secondaryCues, format: format, options: options)

        return [
            SubtitleExportFile(
                languageSuffix: primaryLanguage,
                content: primaryContent,
                format: format,
                suggestedFileName: suggestedFileName(
                    baseName: baseName, language: primaryLanguage, format: format
                )
            ),
            SubtitleExportFile(
                languageSuffix: secondaryLanguage,
                content: secondaryContent,
                format: format,
                suggestedFileName: suggestedFileName(
                    baseName: baseName, language: secondaryLanguage, format: format
                )
            )
        ]
    }

    /// 生成文件名，例如 `作品名.ja.srt`
    public static func suggestedFileName(
        baseName: String,
        language: String?,
        format: SubtitleFormat
    ) -> String {
        let cleanedBase = sanitizeFileName(baseName)
        if let language, !language.isEmpty {
            return "\(cleanedBase).\(language).\(format.fileExtension)"
        }
        return "\(cleanedBase).\(format.fileExtension)"
    }

    static func sanitizeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "subtitle" : trimmed
    }

    // MARK: - 各格式

    static func bodyText(_ cue: SubtitleCue, options: SubtitleExportOptions) -> String {
        guard options.includeTranslation,
              options.bilingualLayout == .twoLines,
              let translation = cue.translatedText,
              !translation.isEmpty
        else { return cue.text }
        return cue.text + "\n" + translation
    }

    static func exportSRT(_ cues: [SubtitleCue], options: SubtitleExportOptions) -> String {
        var out = ""
        for (idx, cue) in cues.enumerated() {
            out += "\(idx + 1)\n"
            out += "\(SubtitleTime.srt(cue.startMS)) --> \(SubtitleTime.srt(cue.endMS))\n"
            out += bodyText(cue, options: options) + "\n\n"
        }
        return out
    }

    static func exportVTT(_ cues: [SubtitleCue], options: SubtitleExportOptions) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            out += "\(SubtitleTime.vtt(cue.startMS)) --> \(SubtitleTime.vtt(cue.endMS))\n"
            out += bodyText(cue, options: options) + "\n\n"
        }
        return out
    }

    static func exportLRC(_ cues: [SubtitleCue], options: SubtitleExportOptions) -> String {
        var out = ""
        for cue in cues {
            // LRC 一行一条；双语时用换行分隔（部分播放器支持）
            let text = bodyText(cue, options: options).replacingOccurrences(of: "\n", with: " / ")
            out += "\(SubtitleTime.lrc(cue.startMS))\(text)\n"
        }
        return out
    }

    static func exportASS(_ cues: [SubtitleCue], options: SubtitleExportOptions) -> String {
        var out = """
        [Script Info]
        Title: Exported by Hibiki
        ScriptType: v4.00+
        WrapStyle: 0
        ScaledBorderAndShadow: yes
        PlayResX: 1920
        PlayResY: 1080

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,64,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,3,1,2,20,20,40,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        for cue in cues {
            let start = SubtitleTime.ass(cue.startMS)
            // ASS 的最小单位为 10 毫秒，极短有效句至少占一个这样的单位。
            let sameCentisecond = cue.hasTiming && cue.startMS / 10 == cue.endMS / 10
            let endMS = sameCentisecond && cue.endMS <= Int.max - 10 ? cue.endMS + 10 : cue.endMS
            let end = SubtitleTime.ass(endMS)
            let name = cue.speaker ?? ""
            let text = bodyText(cue, options: options)
                .replacingOccurrences(of: "\n", with: "\\N")
            out += "Dialogue: 0,\(start),\(end),Default,\(name),0,0,0,,\(text)\n"
        }
        return out
    }

    // MARK: - 其他导出

    /// 导出"台本对照表"（CSV），方便在表格软件里校对
    public static func exportCSV(_ cues: [SubtitleCue]) -> String {
        var out = "序号,开始,结束,时长(秒),说话人,原文,译文\n"
        for cue in cues {
            let fields = [
                String(cue.index + 1),
                SubtitleTime.clockWithMilliseconds(cue.startMS),
                SubtitleTime.clockWithMilliseconds(cue.endMS),
                String(format: "%.2f", Double(cue.durationMS) / 1000.0),
                cue.speaker ?? "",
                cue.text,
                cue.translatedText ?? ""
            ]
            out += fields.map(csvEscape).joined(separator: ",") + "\n"
        }
        return out
    }

    /// 只导出"未校对/未对齐"的条目，方便继续修改
    public static func exportNeedsReview(_ cues: [SubtitleCue], format: SubtitleFormat) -> String {
        export(cues.filter(\.status.needsAttention), format: format)
    }

    static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
