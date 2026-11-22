import Foundation

/// 路径解析：把"数据库里存的路径"变成"现在能用的绝对路径"。
///
/// 为什么需要这一层：iOS 的 App 容器路径**会变**。
/// 重装 App、从备份恢复、甚至某些系统迁移，都会让
/// `/…/Application/<UUID>/Documents/…` 里的 UUID 换掉。
/// 如果把绝对路径直接存进数据库，重装之后所有记录都指向不存在的目录。
///
/// 所以数据库里存的都是**相对路径**：
/// - 作品/曲目 → 相对"存储源根目录"
/// - 封面/台本 → 相对"作品目录"
///
/// 运行时再用当前真实的根目录拼回去。
public enum LibraryPathResolver {

    /// Per-file works use the media path as their stable identity, while their
    /// track/cover/script paths stay relative to the containing directory.
    /// Only the stored grouping selects this behavior; a directory may itself
    /// have an audio-looking name and must never be inferred to be a file.
    public static func workDirectory(root: String, workRelativePath: String, grouping: ScanOptions.Grouping) -> String {
        let relative = grouping == .filesAsWorks
            ? (workRelativePath as NSString).deletingLastPathComponent : workRelativePath
        return join(root: root, relative: relative)
    }

    /// 自选副本不依赖原作品目录，容器搬迁后直接使用当前 App 的根目录。
    public static func assetPath(relative: String, assetsRoot: String) -> String? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return join(root: assetsRoot, relative: relative)
    }

    /// 把相对路径拼到根目录上。
    ///
    /// `"."` 和 `""` 都表示"就是根目录本身"——
    /// 用 `"."` 是为了让"整个源根目录是一个作品"这种情况在数据库里
    /// 有一个稳定、非空的键（空字符串容易和各种"未提供"混淆）。
    public static func join(root: String, relative: String) -> String {
        guard !relative.isEmpty, relative != "." else { return root }
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        let normalizedRelative = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        return normalizedRoot + "/" + normalizedRelative
    }

    /// 当存下来的根目录已经失效时，尝试把它"重锚定"到当前的 Documents 目录。
    ///
    /// 例：
    /// ```
    /// 存的：/…/Application/OLD-UUID/Documents/音乐库
    /// 现在：/…/Application/NEW-UUID/Documents
    /// 结果：/…/Application/NEW-UUID/Documents/音乐库
    /// ```
    /// 只处理"路径里含 `/Documents/`"的情况（也就是 App 自己沙盒里的目录）；
    /// 外部目录（用户用文件选择器授权的）应该靠 security-scoped bookmark 恢复，
    /// 重锚定不适用。
    public static func reanchor(storedRoot: String, currentDocumentsRoot: String) -> String? {
        guard let range = storedRoot.range(of: "/Documents/") else { return nil }
        let tail = String(storedRoot[range.upperBound...])
        guard !tail.isEmpty else { return nil }
        return join(root: currentDocumentsRoot, relative: tail)
    }

    /// 完整的解析流程
    /// - Parameters:
    ///   - storedRoot: 数据库里存的源根目录（可能是过期的绝对路径）
    ///   - relative: 相对路径
    ///   - currentDocumentsRoot: 当前 App 的 Documents 目录（用于重锚定）
    ///   - rootExists: 判断某个路径当前是否可用；测试里可以注入
    public static func resolve(
        storedRoot: String?,
        relative: String,
        currentDocumentsRoot: String?,
        rootExists: (String) -> Bool
    ) -> String? {
        guard let storedRoot, !storedRoot.isEmpty else { return nil }

        if rootExists(storedRoot) {
            return join(root: storedRoot, relative: relative)
        }

        if let documents = currentDocumentsRoot,
           let reanchored = reanchor(storedRoot: storedRoot, currentDocumentsRoot: documents),
           rootExists(reanchored) {
            return join(root: reanchored, relative: relative)
        }

        return nil
    }
}
