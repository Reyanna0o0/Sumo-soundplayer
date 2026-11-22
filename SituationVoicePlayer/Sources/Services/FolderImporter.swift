import Foundation
import UIKit

/// 从「文件」App 选择的目录导入。
///
/// iOS 的沙盒机制：用户选中的目录必须通过 **security-scoped bookmark**
/// 记住，否则重启 App 后就无权再访问。这里把"拿书签 / 恢复访问 / 枚举文件"
/// 三件事封装起来。
enum FolderImporter {

    /// 从用户选择的 URL 生成可持久化的书签
    static func makeBookmark(for url: URL) throws -> Data {
        // 必须先开始访问，否则某些位置（iCloud Drive）读不到
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        // 注意：bookmarkData(options:...) 没有 stale 输出参数，那是 resolve 时的参数
        return try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// 用书签恢复目录访问权限
    /// - Returns: 可访问的 URL 和"是否需要在用完后 stop"
    static func resolve(bookmark: Data) throws -> (url: URL, needsStop: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        let ok = url.startAccessingSecurityScopedResource()
        return (url, ok)
    }

    /// 枚举目录下的所有文件
    /// - Parameters:
    ///   - url: 已获得访问权限的目录
    ///   - rootPath: 该目录的绝对路径（用于生成相对路径）
    static func enumerate(url: URL, rootPath: String) throws -> [ScannedFile] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let canonicalRoot = url.resolvingSymlinksInPath().standardizedFileURL

        var scanError: Error?
        guard let enumerator = fileManager.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                scanError = error
                return false
            }
        ) else { throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url]) }

        var files: [ScannedFile] = []
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"

        for case let fileURL as URL in enumerator {
            // 只关心文件，忽略目录与符号链接
            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }

            // iOS can enumerate /private/var URLs for a root resolved as /var.
            // Compare both sides in the same canonical form, retaining the
            // containment check and the symbolic-link exclusion above.
            let absolute = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard absolute.hasPrefix(rootPrefix) else { continue }
            let relative = String(absolute.dropFirst(rootPrefix.count))

            files.append(
                ScannedFile(
                    relativePath: relative,
                    absolutePath: LibraryPathResolver.join(root: rootPath, relative: relative),
                    size: Int64(values.fileSize ?? 0),
                    modified: values.contentModificationDate ?? Date()
                )
            )
        }
        if let scanError { throw scanError }
        return files
    }

    /// 去掉路径前缀，得到用于显示的目录名
    static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}
