import Foundation

/// 支持的输入/输出字幕格式。
public enum SubtitleFormat: String, CaseIterable, Codable, Sendable {
    case srt
    case vtt
    case lrc
    case ass
    case ssa
    case smi

    public var displayName: String {
        switch self {
        case .srt: return "SubRip (SRT)"
        case .vtt: return "WebVTT"
        case .lrc: return InterfaceLocalization.text("LRC 歌词")
        case .ass: return "ASS (Advanced SubStation)"
        case .ssa: return "SSA (SubStation Alpha)"
        case .smi: return "SAMI"
        }
    }

    public var fileExtension: String {
        switch self {
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .lrc: return "lrc"
        case .ass: return "ass"
        case .ssa: return "ssa"
        case .smi: return "smi"
        }
    }

    /// 是否支持导出（SMI 只读不写，实际几乎没人要导出 SAMI）
    public var isExportable: Bool { self != .smi }

    public static func from(fileExtension ext: String) -> SubtitleFormat? {
        switch ext.lowercased() {
        case "srt": return .srt
        case "vtt", "webvtt": return .vtt
        case "lrc": return .lrc
        case "ass": return .ass
        case "ssa": return .ssa
        case "smi", "sami": return .smi
        default: return nil
        }
    }
}

/// 单条字幕的对齐状态。
///
/// 台本对齐（锚点匹配）之后，有些台本行在音频里找不到对应位置，
/// 这些行会保持 `.unaligned`，交给用户手动打轴。
public enum CueStatus: String, Codable, Sendable {
    /// 时间与文字都可信
    case ok
    /// 台本行存在，但没能和音频对齐（没有可靠时间）
    case unaligned
    /// 只导入了台本文字，尚未设置时间。
    case untimed
    /// 已有起点，结束位置按显示窗口自动补齐，可由用户指定。
    case provisional
    /// AI 识别置信度低的句子
    case lowConfidence

    public var needsAttention: Bool { self != .ok }
}

/// 一条字幕。
///
/// 时间用毫秒整数；`translatedText` 与 `text` 同属一条，
/// 这样双语不会因为两个文件行数不同而错位。
public struct SubtitleCue: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    /// 在所属字幕版本中的顺序（0 基）
    public var index: Int
    public var startMS: Int
    public var endMS: Int
    /// 原文
    public var text: String
    /// 译文（可为空）
    public var translatedText: String?
    /// 说话人 / 角色名（`<v Speaker>`、ASS 的 Name 字段、台本的角色列）
    public var speaker: String?
    public var status: CueStatus

    public init(
        id: UUID = UUID(),
        index: Int = 0,
        startMS: Int,
        endMS: Int,
        text: String,
        translatedText: String? = nil,
        speaker: String? = nil,
        status: CueStatus = .ok
    ) {
        self.id = id
        self.index = index
        self.startMS = startMS
        self.endMS = endMS
        self.text = text
        self.translatedText = translatedText
        self.speaker = speaker
        self.status = status
    }

    public var durationMS: Int { max(0, endMS - startMS) }

    /// 可以跟随播放、跳转或摘选的时间；未对齐的估算值不算有效时间。
    public var hasTiming: Bool {
        status != .untimed && status != .unaligned && startMS >= 0 && endMS > startMS
    }

    /// 是否与该时间点相交（毫秒）
    public func contains(_ positionMS: Int) -> Bool {
        hasTiming && positionMS >= startMS && positionMS < endMS
    }

    /// 用于列表显示的文本：有译文时原文 + 译文
    public var displayText: String {
        guard let t = translatedText, !t.isEmpty else { return text }
        return "\(text)\n\(t)"
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

/// 一次解析的结果。
public struct SubtitleParseResult: Sendable {
    public var cues: [SubtitleCue]
    public var format: SubtitleFormat
    /// 解析过程中遇到的问题（不致命，用于设置页的"详情"和日志）
    public var warnings: [String]
    /// 文件里带的一些元信息（LRC 的 ti/ar/al、ASS 的 Title 等）
    public var metadata: [String: String]

    public init(
        cues: [SubtitleCue],
        format: SubtitleFormat,
        warnings: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.cues = cues
        self.format = format
        self.warnings = warnings
        self.metadata = metadata
    }

    public var isEmpty: Bool { cues.isEmpty }
}

/// 一套字幕（一个版本的全部条目）。
public struct SubtitleDocument: Equatable, Codable, Sendable {
    public var format: SubtitleFormat
    public var cues: [SubtitleCue]
    /// 主语言（`ja` / `zh` / `en` …）
    public var language: String?
    public var metadata: [String: String]

    public init(
        format: SubtitleFormat,
        cues: [SubtitleCue],
        language: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.format = format
        self.cues = cues
        self.language = language
        self.metadata = metadata
    }

    /// 重排 index，保证连续
    public mutating func reindex() {
        for i in cues.indices {
            cues[i].index = i
        }
    }

    /// 按开始时间稳定排序后重排 index
    public mutating func sortByTime() {
        cues.sort { a, b in
            a.startMS == b.startMS ? a.index < b.index : a.startMS < b.startMS
        }
        reindex()
    }

    public var totalDurationMS: Int {
        guard let last = cues.map(\.endMS).max() else { return 0 }
        return last
    }
}
