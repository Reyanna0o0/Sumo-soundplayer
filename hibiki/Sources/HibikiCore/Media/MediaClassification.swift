import Foundation

// MARK: - 媒体类型

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case audio
    case video
    case subtitle
    case image
    case document
    case archive
    case unknown
}

/// 导入时按扩展名归类。播放器在打开文件时另外检查能否解码。
public enum MediaExtensions {

    public static let audio: Set<String> = [
        "mp3", "flac", "m4a", "m4b", "aac", "ogg", "oga", "opus", "wav", "wave",
        "aiff", "aif", "caf", "wma", "amr", "ape", "wv", "mid", "midi", "mka", "tak", "tta"
    ]

    public static let video: Set<String> = [
        "mp4", "m4v", "mkv", "webm", "avi", "mov", "mpg", "mpeg", "m2ts", "mts",
        "3gp", "3g2", "flv", "wmv", "ogv", "rmvb", "vob", "ts"
    ]

    public static let subtitle: Set<String> = [
        "srt", "ass", "ssa", "vtt", "lrc", "sub", "smi", "sami", "ttml", "dfxp", "sbv"
    ]

    public static let image: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif", "avif", "ico"
    ]

    public static let document: Set<String> = [
        "txt", "md", "pdf", "epub", "mobi", "docx", "doc", "rtf", "html", "htm"
    ]

    public static let archive: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz"
    ]

    /// 从扩展名判断类型
    public static func kind(forExtension ext: String) -> MediaKind {
        let e = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if audio.contains(e) { return .audio }
        if video.contains(e) { return .video }
        if subtitle.contains(e) { return .subtitle }
        if image.contains(e) { return .image }
        if document.contains(e) { return .document }
        if archive.contains(e) { return .archive }
        return .unknown
    }

    public static func kind(forFileName name: String) -> MediaKind {
        kind(forExtension: (name as NSString).pathExtension)
    }

    /// 是否应该出现在"媒体库"里（音频 + 视频）
    public static func isLibraryMedia(_ name: String) -> Bool {
        let k = kind(forFileName: name)
        return k == .audio || k == .video
    }

    /// 音频文件按常见命名区分用途（音声作品里通常分"本篇/特典/SE/图片"等）
    public static func isLikelyBonus(_ name: String) -> Bool {
        let lower = name.lowercased()
        let bonusMarkers = ["特典", "おまけ", "omake", "bonus", "se", "効果音", "effect",
                            "free", "sample", "サンプル", "体験版", "trial", "pv", "cm"]
        return bonusMarkers.contains { lower.contains($0) }
    }
}

// MARK: - 自然排序

/// 自然排序：让 `第2話` 排在 `第10話` 前面（普通字符串排序会反过来）。
public enum NaturalSort {

    public static func compare(_ a: String, _ b: String) -> Bool {
        let result = naturalCompare(a, b)
        if result != .orderedSame { return result == .orderedAscending }
        return a < b   // 完全等价时用字典序保证稳定
    }

    public static func naturalCompare(_ a: String, _ b: String) -> ComparisonResult {
        let left = Array(a.lowercased())
        let right = Array(b.lowercased())
        var i = 0
        var j = 0

        while i < left.count && j < right.count {
            let lc = left[i]
            let rc = right[j]

            if lc.isNumber && rc.isNumber {
                // 取出两边的数字串比较数值
                var ln = ""
                while i < left.count, left[i].isNumber { ln.append(left[i]); i += 1 }
                var rn = ""
                while j < right.count, right[j].isNumber { rn.append(right[j]); j += 1 }
                let lv = Int(ln) ?? 0
                let rv = Int(rn) ?? 0
                if lv != rv { return lv < rv ? .orderedAscending : .orderedDescending }
                // 数值相等时，前导零少的优先（"2" < "02"）
                if ln.count != rn.count {
                    return ln.count < rn.count ? .orderedAscending : .orderedDescending
                }
                continue
            }

            if lc != rc {
                return lc < rc ? .orderedAscending : .orderedDescending
            }
            i += 1
            j += 1
        }

        if i < left.count { return .orderedDescending }
        if j < right.count { return .orderedAscending }
        return .orderedSame
    }

    public static func sorted(_ names: [String]) -> [String] {
        names.sorted(by: compare)
    }
}

// MARK: - 文件夹名解析

/// 从文件夹 / 文件名里提取结构化信息。
///
/// 音声作品的命名极不统一，常见几种：
/// ```
/// [サークル名] 作品タイトル [声優名] RJ01234567
/// RJ01234567 作品タイトル
/// 作品タイトル (声優名) [サークル名]
/// ```
/// 这里的原则是"宁可少提取，不要错提取"——提错了比不提更烦人，
/// 用户可以在界面上手动改。
public enum FolderNameParser {

    private static let workCodePattern = #"(?i)(?<![a-z0-9])(?:RJ\s*[0-9]{6,8}|BJ\s*[0-9]+)(?![0-9])"#

    /// 兼容旧库对扫描出的 RJ 补零的约定。商业作品保留目录里完整的 BJ 编号。
    public static func rjCode(from name: String) -> String? {
        guard let range = name.range(of: workCodePattern, options: .regularExpression) else { return nil }
        let token = name[range]
        let digits = String(token.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        if token.prefix(2).uppercased() == "BJ" { return "BJ" + digits }
        return "RJ" + String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }

    /// 提取所有方括号 / 圆括号 / 直角括号里的段落
    public static func bracketedSegments(from name: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var depth = 0
        let openers: Set<Character> = ["[", "【", "（", "(", "［", "《", "〈"]
        let closers: Set<Character> = ["]", "】", "）", ")", "］", "》", "〉"]

        for ch in name {
            if openers.contains(ch) {
                depth += 1
                if depth > 1 { current.append(ch) }
                continue
            }
            if closers.contains(ch) {
                depth = max(0, depth - 1)
                if depth == 0 {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { segments.append(trimmed) }
                    current = ""
                } else {
                    current.append(ch)
                }
                continue
            }
            if depth > 0 { current.append(ch) }
        }
        return segments
    }

    /// 去掉括号段、作品编号、多余空白，得到"干净的作品名"
    public static func cleanTitle(from name: String, removeRJCode: Bool = true) -> String {
        var result = ""
        var depth = 0
        let openers: Set<Character> = ["[", "【", "（", "(", "［", "《", "〈"]
        let closers: Set<Character> = ["]", "】", "）", ")", "］", "》", "〉"]

        for ch in name {
            if openers.contains(ch) { depth += 1; continue }
            if closers.contains(ch) { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(ch) }
        }

        if removeRJCode {
            result = result.replacingOccurrences(
                of: workCodePattern, with: " ", options: .regularExpression
            )
        }

        // 压缩连续空白
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        // 去掉首尾的装饰性符号
        let trimSet = CharacterSet(charactersIn: " \t-_—・、,，.。!！:：~～").union(.whitespacesAndNewlines)
        return result.trimmingCharacters(in: trimSet)
    }

    /// 从文件名里去掉常见的"轨号前缀"，得到曲目标题
    ///
    /// 例：`01. タイトル` → `タイトル`；`第3話「タイトル」` → `第3話「タイトル」`
    public static func trackTitle(from fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let patterns = [
            "^\\s*\\d{1,3}\\s*[\\.\\-_\\)]\\s*",       // "01. " / "01 - " / "01) "
            "^\\s*[Tt]rack\\s*\\d{1,3}\\s*[\\.\\-_:]\\s*",
            "^\\s*\\d{1,3}\\s+"                        // "01 "
        ]
        var result = base
        for pattern in patterns {
            if let range = result.range(of: pattern, options: .regularExpression) {
                result = String(result[range.upperBound...])
                break
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 提取轨号（用于排序）：`01. xxx` → 1
    public static func trackNumber(from fileName: String) -> Int? {
        let base = (fileName as NSString).deletingPathExtension
        let patterns = [
            "^\\s*(\\d{1,3})\\s*[\\.\\-_\\)]",   // "01. xxx" / "01 - xxx"
            "^\\s*(?:[Tt]rack|[Tt]r)\\s*[\\.\\-_ ]?\\s*(\\d{1,3})",  // "track01" / "Tr1_"
            "^\\s*(\\d{1,3})\\s+",                 // "01 xxx"
            "^\\s*(\\d{1,3})\\s*$"                 // 整个文件名就是数字："10"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
               let range = Range(match.range(at: 1), in: base) {
                return Int(base[range])
            }
        }
        return nil
    }
}

// MARK: - 规则驱动的自动分类

/// 一条分类规则（对应原版 `keywords` 表的一行）
public struct ClassificationRule: Equatable, Sendable, Identifiable {
    public var id: Int64
    /// 匹配用的文本（关键词或正则）
    public var pattern: String
    /// 维度：`seiyuu` / `circle` / `genre` / `rj`
    public var dimension: String
    /// 命中后写入的值；为空表示"用命中的文本本身"
    public var targetValue: String?
    public var isRegex: Bool
    /// 是否在执行"清理标题"时把命中内容删掉
    public var useForStrip: Bool
    /// 优先级，大的先匹配
    public var priority: Int
    public var enabled: Bool

    public init(
        id: Int64 = 0,
        pattern: String,
        dimension: String,
        targetValue: String? = nil,
        isRegex: Bool = false,
        useForStrip: Bool = false,
        priority: Int = 0,
        enabled: Bool = true
    ) {
        self.id = id
        self.pattern = pattern
        self.dimension = dimension
        self.targetValue = targetValue
        self.isRegex = isRegex
        self.useForStrip = useForStrip
        self.priority = priority
        self.enabled = enabled
    }
}

public struct ClassificationResult: Equatable, Sendable {
    public var rjCode: String?
    /// 维度 → 命中的值（可能多个）
    public var tags: [String: [String]]
    /// 清理后的标题
    public var cleanedTitle: String
    /// 命中的规则 id
    public var matchedRuleIDs: [Int64]

    public init(
        rjCode: String? = nil,
        tags: [String: [String]] = [:],
        cleanedTitle: String = "",
        matchedRuleIDs: [Int64] = []
    ) {
        self.rjCode = rjCode
        self.tags = tags
        self.cleanedTitle = cleanedTitle
        self.matchedRuleIDs = matchedRuleIDs
    }

    public var seiyuu: [String] { tags["seiyuu"] ?? [] }
    public var circle: [String] { tags["circle"] ?? [] }
}

/// 从名字推断作品信息。
public enum FolderClassifier {

    /// 用规则 + 括号位置启发式做分类
    public static func classify(name: String, rules: [ClassificationRule] = []) -> ClassificationResult {
        var result = ClassificationResult()
        result.rjCode = FolderNameParser.rjCode(from: name)

        var working = name
        let sortedRules = rules.filter(\.enabled).sorted { $0.priority > $1.priority }

        var hitIDs: [Int64] = []
        for rule in sortedRules {
            let matchedTexts = matchAll(rule: rule, in: working)
            guard !matchedTexts.isEmpty else { continue }
            hitIDs.append(rule.id)

            let values = matchedTexts.compactMap { text -> String? in
                if let target = rule.targetValue, !target.isEmpty { return target }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            if !values.isEmpty {
                var bucket = result.tags[rule.dimension] ?? []
                for v in values where !bucket.contains(v) { bucket.append(v) }
                result.tags[rule.dimension] = bucket
            }

            if rule.useForStrip {
                working = strip(rule: rule, from: working)
            }
        }

        let segments = FolderNameParser.bracketedSegments(from: name)
        let performer = #"(?:ＣＶ|CV|声优|聲優|声優|出演|配音)"#
        let circle = #"(?:社团|社團|サークル(?:名)?|制作社团|制作社團|制作サークル|Circle)"#
        func labelledValues(_ label: String) -> [String] {
            let rule = ClassificationRule(pattern: "^" + label + #"\s*[:：.．]\s*(.+)$"#,
                                          dimension: "", isRegex: true)
            let enclosed = segments.flatMap { matchAll(rule: rule, in: $0) }
            let trailing = ClassificationRule(pattern: #"(?:^|\s)"# + label + #"\s*[:：]\s*([^【】\[\]（）()［］]+)$"#,
                                              dimension: "", isRegex: true)
            return enclosed + matchAll(rule: trailing, in: name)
        }
        if result.seiyuu.isEmpty {
            result.tags["seiyuu"] = labelledValues(performer).flatMap(performerNames)
        }
        if result.circle.isEmpty, let named = labelledValues(circle).first {
            result.tags["circle"] = [named.trimmingCharacters(in: .whitespaces)]
        }
        let markers = ["特典", "限定", "早期購入", "おまけ", "omake", "bonus", "体験版", "サンプル",
                       "無料", "ダウンロード", "dl版", "セット", "中文版", "日本語版", "中文化", "汉化", "漢化",
                       "簡体", "简体", "繁體", "繁体", "バイノーラル", "asmr", "r18", "r-18"]
        func possibleName(_ segment: String) -> Bool {
            let lower = segment.lowercased()
            return !markers.contains(where: lower.contains) &&
                FolderNameParser.rjCode(from: segment) == nil &&
                segment.range(of: "^(" + performer + "|" + circle + #")\s*[:：.．]"#,
                              options: [.regularExpression, .caseInsensitive]) == nil
        }
        // Only infer unlabelled names from the conventional [circle] title [performer] layout.
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let opens = Set("[【（(［《〈"), closes = Set("]】）)］》〉")
        if result.circle.isEmpty, let first = segments.first, possibleName(first),
           let initial = trimmed.first, opens.contains(initial) {
            result.tags["circle"] = [first]
        }
        if result.seiyuu.isEmpty, segments.count > 1, let last = segments.last, possibleName(last),
           let end = trimmed.last, closes.contains(end) {
            result.tags["seiyuu"] = performerNames(last)
        }
        result.cleanedTitle = FolderNameParser.cleanTitle(from: working)
        result.matchedRuleIDs = hitIDs
        return result
    }

    public static func performerNames(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: "、,，/／＆&;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func matchAll(rule: ClassificationRule, in text: String) -> [String] {
        guard !rule.pattern.isEmpty else { return [] }
        if rule.isRegex {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { return [] }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            return matches.compactMap { m in
                // 有捕获组时取第一组，否则取整段
                let range = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
                guard range.location != NSNotFound, let r = Range(range, in: text) else { return nil }
                return String(text[r])
            }
        }
        if let range = text.range(of: rule.pattern, options: .caseInsensitive) {
            return [String(text[range])]
        }
        return []
    }

    static func strip(rule: ClassificationRule, from text: String) -> String {
        if rule.isRegex {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { return text }
            return regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: " "
            )
        }
        return text.replacingOccurrences(of: rule.pattern, with: " ", options: .caseInsensitive)
    }
}
