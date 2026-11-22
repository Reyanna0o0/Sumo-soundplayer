import Foundation

/// 一个作品里的"分组"（界面上的分节）。
///
/// 内置分组（本編/特典/语音消息/闲聊/效果音/其它）的 key 固定，显示名可以修改；
/// 用户还可以自己新建，例如把 `tr01~tr18` 归到自建的「本篇」里。
public struct WorkCategory: Identifiable, Equatable, Hashable, Sendable {
    /// 稳定标识：内置用 `main` / `bonus` …，自定义用 `custom_<时间戳>`
    public var key: String
    /// 显示名
    public var title: String
    /// 显示顺序（小的在前）
    public var sortOrder: Int
    /// 是否内置
    public var isBuiltin: Bool

    public var id: String { key }

    public init(key: String, title: String, sortOrder: Int, isBuiltin: Bool) {
        self.key = key
        self.title = title
        self.sortOrder = sortOrder
        self.isBuiltin = isBuiltin
    }

    /// 从内置枚举构造
    public init(_ category: TrackCategory) {
        self.key = category.rawValue
        self.title = category.displayName
        self.sortOrder = category.sortOrder
        self.isBuiltin = true
    }

    /// 内置分组的完整顺序
    public static var builtins: [WorkCategory] {
        TrackCategory.allCases
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { WorkCategory($0) }
    }

    /// 用 key 找内置定义
    public static func builtin(forKey key: String) -> WorkCategory? {
        TrackCategory(rawValue: key).map { WorkCategory($0) }
    }
}

/// 自定义分组的持久化形态（存在 `work.custom_categories` 这一列里）
struct StoredCustomCategory: Codable {
    var key: String
    var title: String
    var sortOrder: Int
}

enum CustomCategoryCodec {

    static func encode(_ categories: [WorkCategory]) -> String? {
        let stored = categories
            .filter { !$0.isBuiltin }
            .map { StoredCustomCategory(key: $0.key, title: $0.title, sortOrder: $0.sortOrder) }
        guard !stored.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(stored) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> [WorkCategory] {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        guard let stored = try? JSONDecoder().decode([StoredCustomCategory].self, from: data) else { return [] }
        return stored.map {
            WorkCategory(key: $0.key, title: $0.title, sortOrder: $0.sortOrder, isBuiltin: false)
        }
    }

    /// 生成一个新的自定义分组 key
    static func newKey(existing: [WorkCategory]) -> String {
        let existingKeys = Set(existing.map(\.key))
        var index = 1
        while existingKeys.contains("custom_\(index)") { index += 1 }
        return "custom_\(index)"
    }
}
