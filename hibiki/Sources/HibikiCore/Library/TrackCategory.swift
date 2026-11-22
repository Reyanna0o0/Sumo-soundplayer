import Foundation

/// 曲目内容类型。
///
/// 真实音声作品里一个文件夹塞着好几类完全不同的音频：
/// ```
/// 本編SEあり/Tr1_….wav        ← 正片
/// 【300DL特典】本編後日談2/…  ← 特典后日谈
/// 【早期購入特典】ボイスメッセージ/…  ← 短语音消息
/// 【お気に入り特典】フリートーク/…    ← 声优闲聊
/// ```
/// 21 首混在一起找正片很痛苦，所以按类型分节显示。
public enum TrackCategory: String, Codable, Sendable, CaseIterable {
    /// 正片（本編）
    case main
    /// 特典 / 后日谈
    case bonus
    /// 语音消息（短语音）
    case voiceMessage
    /// 闲聊 / Free Talk
    case talk
    /// 效果音素材
    case soundEffect
    /// 其它
    case other

    public var displayName: String {
        switch self {
        case .main: return "本編"
        case .bonus: return "特典"
        case .voiceMessage: return "语音消息"
        case .talk: return "闲聊"
        case .soundEffect: return "效果音"
        case .other: return "其它"
        }
    }

    public var iconName: String {
        switch self {
        case .main: return "play.circle"
        case .bonus: return "gift"
        case .voiceMessage: return "waveform"
        case .talk: return "bubble.left.and.bubble.right"
        case .soundEffect: return "sparkles"
        case .other: return "doc"
        }
    }

    /// 显示顺序
    public var sortOrder: Int {
        switch self {
        case .main: return 0
        case .bonus: return 1
        case .voiceMessage: return 2
        case .talk: return 3
        case .soundEffect: return 4
        case .other: return 5
        }
    }
}

/// 根据路径与文件名判断曲目类型。
///
/// 判定顺序很重要，用真实作品验证过：
/// - `【お気に入り特典】フリートーク` 同时含"特典"和"フリートーク" → 应归 **闲聊**
/// - `【300DL特典】本編後日談2` 同时含"特典"和"本編" → 应归 **特典**（不是正片）
/// - `本編SEあり/Tr1` 里的 `SEあり` 是**变体标记**，不能当成"效果音目录"
public enum TrackCategorizer {

    public static func classify(relativePath: String) -> TrackCategory {
        let lower = relativePath.lowercased()
        let components = lower
            .split(separator: "/")
            .map { String($0) }
        let fileName = components.last ?? lower

        // ① 语音消息（最具体，优先判断）
        if containsAny(lower, ["ボイスメッセージ", "voice_message", "voicemessage", "ボイスmsg",
                                "音声メッセージ", "语音消息", "語音訊息"]) {
            return .voiceMessage
        }

        // ② 闲聊
        if containsAny(lower, ["フリートーク", "freetalk", "free_talk", "フリートーク",
                                "座談", "ざつだん", "雑談", "トークパート", "闲聊", "閒聊"]) {
            return .talk
        }

        // ③ 效果音目录：只认"纯粹的 SE 目录"，不认 SEあり/SEなし 变体标记
        if components.contains(where: { isPureSoundEffectFolder($0) }) {
            return .soundEffect
        }

        // ④ 特典 / 后日谈
        if containsAny(lower, ["特典", "おまけ", "omake", "bonus", "後日談", "后日谈",
                                "アフター", "afterstory", "after_story", "限定", "早期購入"]) {
            return .bonus
        }

        // ⑤ 正片
        if containsAny(lower, ["本編", "本编", "本篇", "mainstory", "main_story"]) {
            return .main
        }
        // 形如 Tr1 / Track 3 / 第2話 的轨名，默认按正片处理
        if matchesTrackPattern(fileName) {
            return .main
        }

        // ⑥ 兜底：当作正片（简单作品只有一个文件夹，都是正片）
        return .main
    }

    // MARK: - 内部

    static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    /// 目录名是否"就是效果音目录"
    static func isPureSoundEffectFolder(_ component: String) -> Bool {
        let trimmed = component.trimmingCharacters(in: .whitespaces)
        // 精确等于 se / sfx / bgm
        if ["se", "sfx", "bgm", "se素材", "効果音", "效果音", "ジングル", "jingle",
            "soundeffect", "sound_effect", "sound effects"].contains(trimmed) {
            return true
        }
        // 含"効果音/效果音"也算
        if trimmed.contains("効果音") || trimmed.contains("效果音") {
            return true
        }
        return false
    }

    static func matchesTrackPattern(_ fileName: String) -> Bool {
        let base = (fileName as NSString).deletingPathExtension
        let patterns = [
            "^tr\\s*\\d{1,3}",
            "^track\\s*\\d{1,3}",
            "^第\\s*\\d{1,3}\\s*[話话章]",
            "^\\d{1,3}[_\\.\\-\\s]"
        ]
        return patterns.contains { base.range(of: $0, options: .regularExpression) != nil }
    }
}
