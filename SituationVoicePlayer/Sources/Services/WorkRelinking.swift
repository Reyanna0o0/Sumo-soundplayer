import Foundation

struct WorkRelinkEntry: Identifiable, Sendable {
    let id: WorkMediaID
    let title: String
    let relativePath: String
    let audioExtension: String?
    let attachmentKind: WorkAttachmentKind?

    func accepts(_ file: ScannedFile) -> Bool {
        if let audioExtension { return file.fileExtension == audioExtension.lowercased() }
        return WorkAttachmentFinder.kind(forExtension: file.fileExtension) == attachmentKind
    }
}

enum WorkRelinkError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Keeps the selected directory's permission alive throughout review and commit.
final class WorkRelinkDirectory: @unchecked Sendable {
    let url: URL
    let rootPath: String
    let bookmark: Data
    let files: [ScannedFile]
    private let needsStop: Bool

    init(url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        do {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw WorkRelinkError.message(InterfaceLocalization.text("请选择包含这部作品文件的文件夹。"))
            }
            let root = url.resolvingSymlinksInPath().standardizedFileURL.path
            let savedBookmark = try FolderImporter.makeBookmark(for: url)
            let scanned = try FolderImporter.enumerate(url: url, rootPath: root)
            self.url = url
            self.rootPath = root
            self.bookmark = savedBookmark
            self.files = scanned.sorted { NaturalSort.compare($0.relativePath, $1.relativePath) }
            self.needsStop = accessed
        } catch {
            if accessed { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    deinit { if needsStop { url.stopAccessingSecurityScopedResource() } }

    func validateFile(relativePath: String) throws {
        guard let file = files.first(where: { $0.relativePath == relativePath }),
              let path = LibraryPathResolver.assetPath(relative: relativePath, assetsRoot: rootPath) else {
            throw WorkRelinkError.message(InterfaceLocalization.text("选择的文件不在这个文件夹内，请重新选择。"))
        }
        let fileURL = URL(fileURLWithPath: path)
        let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(rootPath + "/") else {
            throw WorkRelinkError.message(InterfaceLocalization.text("选择的文件已移到其他位置，请重新选择文件夹。"))
        }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                         .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == file.size,
              values.contentModificationDate == file.modified else {
            throw WorkRelinkError.message(InterfaceLocalization.text("「\(relativePath)」在选择后发生了变化，请重新选择文件夹。"))
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        try handle.close()
    }
}

extension LibraryStore {
    func relinkEntries(for work: WorkRecord) throws -> [WorkRelinkEntry] {
        guard let repository, try repository.work(id: work.id) != nil else {
            throw LibraryEditingError.missingWork
        }
        let audio = try repository.tracks(workID: work.id).filter { $0.assetRelativePath == nil }.map { track in
            WorkRelinkEntry(id: .track(track.id), title: track.displayTitle,
                           relativePath: track.relativePath ?? track.fileName,
                           audioExtension: track.fileType, attachmentKind: nil)
        }
        let attachments = try repository.attachmentRecords(workID: work.id).filter { $0.assetRelativePath == nil }.map { record in
            WorkRelinkEntry(id: .attachment(record.id), title: record.attachment.fileName,
                           relativePath: record.attachment.relativePath,
                           audioExtension: nil, attachmentKind: record.attachment.kind)
        }
        return audio + attachments
    }

    func relinkFiles(in work: WorkRecord, directory: WorkRelinkDirectory,
                     selections: [WorkMediaID: String]) throws {
        guard !phase.isBusy else { throw WorkRelinkError.message(InterfaceLocalization.text("正在导入其他作品，请完成后再重新关联。")) }
        guard let repository, let current = try repository.work(id: work.id) else {
            throw LibraryEditingError.missingWork
        }
        let entries = try relinkEntries(for: current)
        guard !entries.isEmpty, Set(selections.keys) == Set(entries.map(\.id)),
              Set(selections.values).count == entries.count else {
            throw WorkRelinkError.message(InterfaceLocalization.text("请为每个原文件选择一个对应文件，同一个文件不能重复配对。"))
        }
        for entry in entries {
            guard let relative = selections[entry.id],
                  let file = directory.files.first(where: { $0.relativePath == relative }), entry.accepts(file) else {
                throw WorkRelinkError.message(InterfaceLocalization.text("「\(entry.title)」尚未选择相同格式的对应文件。"))
            }
            try directory.validateFile(relativePath: relative)
        }
        let sources = try repository.sources(includeDisabled: true)
        let tracks = entries.compactMap { entry -> TrackRelinkMapping? in
            guard case .track(let id) = entry.id, let path = selections[entry.id] else { return nil }
            return TrackRelinkMapping(trackID: id, relativePath: path)
        }
        let attachments = entries.compactMap { entry -> AttachmentRelinkMapping? in
            guard case .attachment(let id) = entry.id, let path = selections[entry.id] else { return nil }
            return AttachmentRelinkMapping(attachmentID: id, relativePath: path)
        }
        // A single-file work may be renamed in its current containing directory
        // without changing the shared source or any neighbouring work. Every
        // source media/attachment is still explicitly paired by the user above.
        if let originalSource = sources.first(where: { $0.id == current.sourceID }),
           originalSource.grouping == .filesAsWorks, let storedRoot = originalSource.rootPath,
           let access = attachmentSource(for: current) {
            let expectedDirectory = LibraryPathResolver.workDirectory(root: access.sourceRootPath,
                workRelativePath: current.folderRelativePath, grouping: .filesAsWorks)
            if URL(fileURLWithPath: expectedDirectory).resolvingSymlinksInPath().standardizedFileURL.path == directory.rootPath,
               URL(fileURLWithPath: access.sourceRootPath).resolvingSymlinksInPath().standardizedFileURL.path == directory.rootPath {
                let primary = entries.filter { $0.audioExtension != nil || $0.attachmentKind == .video }
                guard primary.count == 1, let mediaName = selections[primary[0].id],
                      selections.values.allSatisfy({ !$0.contains("/") }) else {
                    throw WorkRelinkError.message(InterfaceLocalization.text("同目录重新配对只适用于一个原音频或视频，请把对应附件也选在当前目录；其他位置请选作品自己的文件夹。"))
                }
                let parent = (current.folderRelativePath as NSString).deletingLastPathComponent
                let newIdentity = parent.isEmpty ? mediaName : parent + "/" + mediaName
                try repository.db.transaction {
                    // The user explicitly reselected this exact source root.
                    // Renew only its authorization; every sibling keeps its
                    // root, grouping and media references. A failed pairing
                    // rolls the bookmark back in the same transaction.
                    var renewedSource = originalSource
                    if !directory.bookmark.isEmpty { renewedSource.bookmark = directory.bookmark }
                    try repository.saveSource(renewedSource)
                    _ = try repository.relinkWork(existingID: current.id, source: renewedSource,
                        folderPath: LibraryPathResolver.join(root: storedRoot, relative: newIdentity),
                        folderRelativePath: newIdentity, tracks: tracks, attachments: attachments)
                }
                finishFileRelink(Dictionary(uniqueKeysWithValues: tracks.map {
                    ($0.trackID, LibraryPathResolver.join(root: directory.rootPath, relative: $0.relativePath))
                }), attachmentPaths: Dictionary(uniqueKeysWithValues: attachments.map {
                    ($0.attachmentID, LibraryPathResolver.join(root: directory.rootPath, relative: $0.relativePath))
                }))
                return
            }
        }
        // A selected child directory cannot renew its parent's authorization.
        // Give this work its own source; siblings keep their original root.
        let siblings = try repository.works(sourceID: current.sourceID)
        var source = siblings.count == 1
            ? sources.first(where: { $0.id == current.sourceID })
            : nil
        for other in sources where other.id != source?.id {
            if let path = other.rootPath,
               URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path == directory.rootPath,
               !(try repository.works(sourceID: other.id)).isEmpty {
                throw WorkRelinkError.message(InterfaceLocalization.text("这个文件夹已关联到其他作品，请选择这部作品自己的文件夹。"))
            }
        }
        if source == nil { source = LibrarySource(name: directory.url.lastPathComponent, type: .local) }
        source!.rootPath = directory.rootPath
        source!.bookmark = directory.bookmark
        source!.enabled = true
        source!.grouping = .singleWork
        _ = try repository.relinkWork(existingID: current.id, source: source!, folderPath: directory.rootPath,
                                      folderRelativePath: ".", tracks: tracks, attachments: attachments)
        finishFileRelink(Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.trackID, LibraryPathResolver.join(root: directory.rootPath, relative: $0.relativePath))
        }), attachmentPaths: Dictionary(uniqueKeysWithValues: attachments.map {
            ($0.attachmentID, LibraryPathResolver.join(root: directory.rootPath, relative: $0.relativePath))
        }))
    }
}
