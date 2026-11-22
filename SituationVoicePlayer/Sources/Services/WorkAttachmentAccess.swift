import Foundation

struct WorkAttachmentSource: Hashable, Sendable {
    let sourceRootPath: String
    let bookmark: Data?
    let workRelativePath: String
    var includeSourceRootAttachments = false
    var grouping: ScanOptions.Grouping = .automatic
    var retainedCompanionPaths: [String] = []
}

/// 一次附件浏览持有一次目录授权，退出浏览后成对释放。
final class WorkAttachmentDirectoryLease: @unchecked Sendable {
    let directory: URL
    let accessedURL: URL
    private let needsStop: Bool

    init(directory: URL, accessedURL: URL, needsStop: Bool) {
        self.directory = directory
        self.accessedURL = accessedURL
        self.needsStop = needsStop
    }

    deinit { if needsStop { accessedURL.stopAccessingSecurityScopedResource() } }
}

enum WorkAttachmentAccess {
    static func open(_ source: WorkAttachmentSource) throws -> WorkAttachmentDirectoryLease {
        var restoredRoot: (url: URL, needsStop: Bool)?
        if let bookmark = source.bookmark, let restored = try? FolderImporter.resolve(bookmark: bookmark) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: restored.url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                restoredRoot = restored
            } else if restored.needsStop {
                // App 容器搬迁后，旧书签仍可能解析成功，但已经不指向现存目录。
                restored.url.stopAccessingSecurityScopedResource()
            }
        }
        let root = restoredRoot?.url ?? URL(fileURLWithPath: source.sourceRootPath, isDirectory: true)
        let needsStop = restoredRoot?.needsStop ?? root.startAccessingSecurityScopedResource()
        var succeeded = false
        defer { if !succeeded && needsStop { root.stopAccessingSecurityScopedResource() } }

        let directory: URL
        let relative = source.grouping == .filesAsWorks
            ? (source.workRelativePath as NSString).deletingLastPathComponent : source.workRelativePath
        if relative.isEmpty || relative == "." ||
            (source.includeSourceRootAttachments && WorkAttachmentFinder.isLegacyFormatFolder(relative)) {
            directory = root
        } else {
            guard let path = LibraryPathResolver.assetPath(relative: relative, assetsRoot: root.path) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            directory = URL(fileURLWithPath: path, isDirectory: true)
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedDirectory == resolvedRoot || resolvedDirectory.hasPrefix(resolvedRoot + "/") else {
            throw CocoaError(.fileReadNoPermission)
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw CocoaError(.fileReadNoSuchFile) }
        succeeded = true
        return WorkAttachmentDirectoryLease(directory: directory, accessedURL: root, needsStop: needsStop)
    }

    static func scan(_ source: WorkAttachmentSource) throws -> (WorkAttachmentDirectoryLease, [WorkAttachment]) {
        let lease = try open(source)
        var coordinationError: NSError?
        var result: Result<[WorkAttachment], Error>?
        NSFileCoordinator().coordinate(readingItemAt: lease.directory, options: [], error: &coordinationError) { url in
            result = Result {
                guard source.grouping == .filesAsWorks else { return try WorkAttachmentFinder.find(in: url) }
                let files = try FolderImporter.enumerate(url: url, rootPath: url.path)
                let name = (source.workRelativePath as NSString).lastPathComponent
                guard let media = files.first(where: { $0.relativePath == name && ($0.kind == .audio || $0.kind == .video) }) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                return LibraryScanner.files(forIndividualMedia: media, in: files,
                    retainingCompanions: source.retainedCompanionPaths).compactMap { file in
                    WorkAttachmentFinder.kind(forExtension: file.fileExtension).map {
                        WorkAttachment(relativePath: file.relativePath, kind: $0, byteCount: file.size)
                    }
                }.sorted { NaturalSort.compare($0.relativePath, $1.relativePath) }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return (lease, try result.get())
    }
}
