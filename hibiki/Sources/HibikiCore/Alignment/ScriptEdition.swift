import Foundation

/// 一个作品内可能同时有台本副本、译本或互不相关的剧本。这里只比较争用同一音轨的候选。
public struct ScriptEdition: Sendable {
    public let path: String
    public let digest: String
    public let tracks: Set<Int>
    public init(path: String, digest: String, tracks: Set<Int>) {
        self.path = path
        self.digest = digest
        self.tracks = tracks
    }

    private enum Language: Int, CaseIterable {
        case simplified, traditional, japanese, english, korean
        var markers: [String] {
            switch self {
            case .simplified: return ["簡体中文", "简体中文", "簡體中文", "簡体字", "簡體字", "简体字", "簡体", "简体", "簡體", "簡中", "简中", "zh-cn", "zh-hans", "simplified chinese"]
            case .traditional: return ["繁體中文", "繁体中文", "繁體字", "繁体字", "繁体", "繁體", "繁中", "zh-tw", "zh-hant", "traditional chinese"]
            case .japanese: return ["日本語", "日本语", "日文", "日语", "日語", "japanese"]
            case .english: return ["english", "英語", "英语", "英文"]
            case .korean: return ["韓国語", "韓國語", "韩国语", "韓語", "韩语", "韓文", "韩文", "korean", "한국어"]
            }
        }
    }

    private var parent: String { (path as NSString).deletingLastPathComponent }
    private var name: String { (path as NSString).lastPathComponent.lowercased() }
    private var language: Language? {
        let localFolder = (parent as NSString).lastPathComponent.lowercased()
        let matches = Language.allCases.filter { lang in
            lang.markers.contains(where: name.contains) || lang.markers.contains(localFolder)
        }
        return matches.count == 1 ? matches[0] : nil
    }
    public var preference: Int { language?.rawValue ?? Int.max }
    private var translationShelf: Bool {
        let names = ["language", "languages", "translation", "translations", "译本", "譯本", "翻译", "翻譯", "翻訳"]
        return names.contains((parent as NSString).lastPathComponent.lowercased())
    }

    private var neutralPath: String {
        guard let language else { return path.lowercased() }
        return language.markers.reduce(path.lowercased()) { $0.replacingOccurrences(of: $1, with: "") }
    }

    /// 字节相同的候选只留一份，优先保留有语言标识、在翻译目录的那份。
    private static func preferredCopy(_ left: ScriptEdition, _ right: ScriptEdition) -> Bool {
        if left.preference != right.preference { return left.preference < right.preference }
        if left.translationShelf != right.translationShelf { return left.translationShelf }
        return left.path < right.path
    }

    public static func selection(from candidates: [ScriptEdition]) -> Set<String> {
        let copies = Dictionary(grouping: candidates, by: \.digest)
        let editions = copies.values.compactMap { $0.min(by: preferredCopy) }
        if editions.count <= 1 { return Set(editions.map(\.path)) }

        // 同语言多份不同稿或语言不明保留人工选择，避免把同号剧本当成翻译。
        guard Set(editions.compactMap(\.language)).count == editions.count else { return [] }
        let pairedNames = Set(editions.map(\.neutralPath)).count == 1
        let sameTranslationFolder = editions.allSatisfy(\.translationShelf)
            && Set(editions.map(\.parent)).count == 1 && Set(editions.map(\.tracks)).count == 1
        return pairedNames || sameTranslationFolder ? Set(editions.map(\.path)) : []
    }
}
