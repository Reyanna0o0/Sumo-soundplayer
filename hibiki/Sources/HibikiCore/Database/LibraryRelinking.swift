import Foundation

/// A pairing explicitly reviewed by the user. Paths are relative to the newly
/// selected work folder; they never identify a new library recording.
public struct TrackRelinkMapping: Equatable, Sendable {
    public let trackID: Int64
    public let relativePath: String

    public init(trackID: Int64, relativePath: String) {
        self.trackID = trackID
        self.relativePath = relativePath
    }
}

public struct AttachmentRelinkMapping: Equatable, Sendable {
    public let attachmentID: Int64
    public let relativePath: String

    public init(attachmentID: Int64, relativePath: String) {
        self.attachmentID = attachmentID
        self.relativePath = relativePath
    }
}

public enum LibraryRelinkingError: LocalizedError, Equatable {
    case missingScannedItem(String)
    case missingWork
    case invalidSource
    case sharedSource
    case invalidPath
    case incompleteMapping
    case duplicateMapping
    case incompatibleType(String)
    case destinationOccupied

    public var errorDescription: String? {
        switch self {
        case .missingScannedItem(let name):
            return InterfaceLocalization.text("检测到「\(name)」可能已改名或移动。本次未更新，已有作品资料和字幕已保留。请在作品菜单选择‘重新关联文件夹’。")
        case .missingWork:
            return InterfaceLocalization.text("这部作品已不在媒体库中，请返回媒体库后重试。")
        case .invalidSource:
            return InterfaceLocalization.text("无法使用这个文件夹位置，请重新选择本地文件夹。")
        case .sharedSource:
            return InterfaceLocalization.text("这个原文件夹还关联着其他作品，请为当前作品使用单独的文件夹关联。")
        case .invalidPath:
            return InterfaceLocalization.text("所选文件不在新作品文件夹内，或文件位置无效，请重新选择。")
        case .incompleteMapping:
            return InterfaceLocalization.text("请为这部作品原有的每个音频和附件选择对应文件，不要漏选或加入其他作品的记录。")
        case .duplicateMapping:
            return InterfaceLocalization.text("同一个文件不能重复配对，请检查音频和附件的选择。")
        case .incompatibleType(let name):
            return InterfaceLocalization.text("「\(name)」的文件类型与原记录不一致，请选择相同类型的文件。")
        case .destinationOccupied:
            return InterfaceLocalization.text("这个位置已经关联到其他作品或音频，请选择尚未关联的位置。")
        }
    }
}

extension LibraryRepository {
    /// Read-only preflight for a complete source scan. Call this before saving
    /// the source, clearing exclusions, or updating any work. A missing file is
    /// not evidence that its library record should be deleted.
    public func validateSourceRescan(
        sourceID: Int64,
        works scannedWorks: [ScannedWork],
        attachments: [String: [WorkAttachment]]
    ) throws {
        let byFolder = Dictionary(grouping: scannedWorks) {
            Self.storageKey(relativePath: $0.folderRelativePath, absolutePath: $0.folderAbsolutePath)
        }
        guard byFolder.values.allSatisfy({ $0.count == 1 }) else {
            throw LibraryRelinkingError.duplicateMapping
        }
        let excludedWorks = try excludedWorkPaths(sourceID: sourceID)
        for work in try works(sourceID: sourceID) where !excludedWorks.contains(work.folderRelativePath) {
            let allTracks = try tracks(workID: work.id)
            let allAttachments = try attachmentRecords(workID: work.id)
            let hiddenTracks = try excludedFiles(workID: work.id, kind: "track")
            let sourceTracks = allTracks.filter {
                $0.assetRelativePath == nil && !hiddenTracks.contains(Self.sourceRelativePath($0, work: work))
            }
            let hiddenAttachments = try excludedFiles(workID: work.id, kind: "attachment")
            let sourceAttachments = allAttachments.filter {
                $0.assetRelativePath == nil && !hiddenAttachments.contains($0.attachment.relativePath)
            }
            guard let scanned = byFolder[work.folderRelativePath]?.first else {
                // Existing synchronization already preserves works made only
                // of independent App-owned copies. They need no source files.
                let onlyIndependentOrExcluded = sourceTracks.isEmpty && sourceAttachments.isEmpty
                    && (!allTracks.isEmpty || !allAttachments.isEmpty)
                if onlyIndependentOrExcluded { continue }
                throw LibraryRelinkingError.missingScannedItem(work.title)
            }
            let byTrackPath = Dictionary(grouping: scanned.tracks.filter { !$0.isVideo }, by: \.relativePath)
            for track in sourceTracks {
                let found = byTrackPath[Self.sourceRelativePath(track, work: work)] ?? []
                guard found.count == 1, found[0].fileType.lowercased() == track.fileType.lowercased(),
                      found[0].isVideo == track.isVideo else {
                    throw LibraryRelinkingError.missingScannedItem(track.displayTitle)
                }
            }
            try validateAttachmentRescan(workID: work.id, files: attachments[scanned.folderRelativePath] ?? [])
        }
    }

    /// Work-detail refreshes also discover attachments, so they need the same
    /// protection even when the user has not requested a full source rescan.
    public func validateAttachmentRescan(workID: Int64, files: [WorkAttachment]) throws {
        guard try work(id: workID) != nil else { throw LibraryRelinkingError.missingWork }
        let byPath = Dictionary(grouping: files, by: \.relativePath)
        guard byPath.values.allSatisfy({ $0.count == 1 }) else {
            throw LibraryRelinkingError.duplicateMapping
        }
        let hidden = try excludedFiles(workID: workID, kind: "attachment")
        for record in try attachmentRecords(workID: workID)
        where record.assetRelativePath == nil && !hidden.contains(record.attachment.relativePath) {
            guard let found = byPath[record.attachment.relativePath]?.first,
                  found.kind == record.attachment.kind else {
                throw LibraryRelinkingError.missingScannedItem(record.attachment.fileName)
            }
        }
    }

    /// Change locations only, after the user has confirmed a complete pairing.
    /// No scan, metadata import, subtitle import, or media deletion happens here.
    /// File accessibility is checked by the caller while its folder grant is open.
    @discardableResult
    public func relinkWork(
        existingID: Int64,
        source: LibrarySource,
        folderPath: String,
        folderRelativePath: String,
        tracks mappings: [TrackRelinkMapping],
        attachments attachmentMappings: [AttachmentRelinkMapping]
    ) throws -> Int64 {
        try db.transaction {
            guard let previous = try work(id: existingID) else { throw LibraryRelinkingError.missingWork }
            guard source.type == .local, source.id >= 0,
                  let root = source.rootPath,
                  let normalizedRoot = Self.absoluteRelinkingPath(root),
                  let normalizedFolder = Self.absoluteRelinkingPath(folderPath),
                  folderRelativePath == "." || Self.validRelinkingRelativePath(folderRelativePath),
                  Self.absoluteRelinkingPath(LibraryPathResolver.join(root: normalizedRoot, relative: folderRelativePath)) == normalizedFolder else {
                throw LibraryRelinkingError.invalidPath
            }

            let originalSource = try sources(includeDisabled: true).first { $0.id == previous.sourceID }
            let originalSourceWorks = try works(sourceID: previous.sourceID)
            let attachmentsUseSourceRoot = originalSource?.grouping == .automatic
                && originalSourceWorks.count == 1
                && WorkAttachmentFinder.isLegacyFormatFolder(previous.folderRelativePath)
            let repairingFileIdentity = source.grouping == .filesAsWorks
            guard !repairingFileIdentity || source.id == previous.sourceID else {
                throw LibraryRelinkingError.invalidSource
            }
            let contentDirectory = LibraryPathResolver.workDirectory(root: normalizedRoot,
                workRelativePath: folderRelativePath, grouping: source.grouping)
            var destinationSource = source
            destinationSource.rootPath = normalizedRoot
            if source.id > 0 {
                guard let existingSource = try sources(includeDisabled: true).first(where: { $0.id == source.id }),
                      existingSource.type == .local else { throw LibraryRelinkingError.invalidSource }
                let owners = try works(sourceID: source.id)
                if repairingFileIdentity {
                    // Only an explicitly reviewed rename inside one file-work's
                    // existing parent may keep a shared source. Never change its
                    // root, bookmark, grouping or any other source metadata.
                    guard existingSource.grouping == .filesAsWorks,
                          existingSource.rootPath.flatMap(Self.absoluteRelinkingPath) == normalizedRoot,
                          existingSource.bookmark == source.bookmark,
                          (previous.folderRelativePath as NSString).deletingLastPathComponent
                            == (folderRelativePath as NSString).deletingLastPathComponent else {
                        throw LibraryRelinkingError.sharedSource
                    }
                    destinationSource = existingSource
                } else {
                    guard owners.count == 1, owners[0].id == existingID else {
                        throw LibraryRelinkingError.sharedSource
                    }
                }
                // Source display metadata is not part of a file-location repair.
                destinationSource.name = existingSource.name
                destinationSource.createdAt = existingSource.createdAt
            }

            let originalTracks = try tracks(workID: existingID).filter { $0.assetRelativePath == nil }
            let originalAttachments = try attachmentRecords(workID: existingID).filter { $0.assetRelativePath == nil }
            let trackIDs = Set(originalTracks.map(\.id))
            let attachmentIDs = Set(originalAttachments.map(\.id))
            guard Set(mappings.map(\.trackID)).count == mappings.count,
                  Set(attachmentMappings.map(\.attachmentID)).count == attachmentMappings.count else {
                throw LibraryRelinkingError.duplicateMapping
            }
            guard Set(mappings.map(\.trackID)) == trackIDs,
                  Set(attachmentMappings.map(\.attachmentID)) == attachmentIDs else {
                throw LibraryRelinkingError.incompleteMapping
            }
            let relativePaths = mappings.map(\.relativePath) + attachmentMappings.map(\.relativePath)
            guard relativePaths.allSatisfy(Self.validRelinkingRelativePath) else {
                throw LibraryRelinkingError.invalidPath
            }
            guard Set(relativePaths.map(\.precomposedStringWithCanonicalMapping)).count == relativePaths.count else {
                throw LibraryRelinkingError.duplicateMapping
            }
            if repairingFileIdentity {
                let videos = originalAttachments.filter { $0.attachment.kind == .video }
                guard originalTracks.count + videos.count == 1,
                      relativePaths.allSatisfy({ !$0.contains("/") }) else {
                    throw LibraryRelinkingError.incompleteMapping
                }
                let primary = originalTracks.first.flatMap { track in mappings.first { $0.trackID == track.id }?.relativePath }
                    ?? videos.first.flatMap { video in attachmentMappings.first { $0.attachmentID == video.id }?.relativePath }
                guard primary == (folderRelativePath as NSString).lastPathComponent else {
                    throw LibraryRelinkingError.invalidPath
                }
            }
            let tracksByID = Dictionary(uniqueKeysWithValues: originalTracks.map { ($0.id, $0) })
            for mapping in mappings {
                let track = tracksByID[mapping.trackID]!
                let ext = (mapping.relativePath as NSString).pathExtension.lowercased()
                guard ext == track.fileType.lowercased(),
                      MediaExtensions.kind(forExtension: ext) == (track.isVideo ? .video : .audio) else {
                    throw LibraryRelinkingError.incompatibleType(track.displayTitle)
                }
                let target = LibraryPathResolver.join(root: contentDirectory, relative: mapping.relativePath)
                let occupants = try db.query("SELECT id FROM track WHERE file_path = ?", [.text(target)])
                guard occupants.allSatisfy({ $0.int64("id").map(trackIDs.contains) ?? false }) else {
                    throw LibraryRelinkingError.destinationOccupied
                }
            }
            let attachmentsByID = Dictionary(uniqueKeysWithValues: originalAttachments.map { ($0.id, $0) })
            for mapping in attachmentMappings {
                let record = attachmentsByID[mapping.attachmentID]!
                let ext = (mapping.relativePath as NSString).pathExtension.lowercased()
                guard WorkAttachmentFinder.kind(forExtension: ext) == record.attachment.kind else {
                    throw LibraryRelinkingError.incompatibleType(record.attachment.fileName)
                }
            }

            let sourceID = try saveSource(destinationSource)
            let occupied = try db.query("""
                SELECT id FROM work WHERE id != ? AND source_id = ?
                    AND (folder_path = ? OR folder_rel = ?)
                """, [.integer(existingID), .integer(sourceID), .text(normalizedFolder), .text(folderRelativePath)])
            guard occupied.isEmpty else { throw LibraryRelinkingError.destinationOccupied }

            // Free every old key before assigning any new one. Renaming A to B
            // and B to A must not violate SQLite's immediate unique constraints.
            let temporary = "__siyu_relink_" + UUID().uuidString
            for mapping in mappings {
                try db.execute("UPDATE track SET file_path = ? WHERE id = ?",
                               [.text("/" + temporary + "/track-\(mapping.trackID)"), .integer(mapping.trackID)])
            }
            for mapping in attachmentMappings {
                try db.execute("UPDATE work_attachment SET relative_path = ? WHERE id = ?",
                               [.text(temporary + "/attachment-\(mapping.attachmentID)"), .integer(mapping.attachmentID)])
            }
            for mapping in mappings {
                try db.execute("UPDATE track SET file_path = ?, relative_path = ?, file_rel = ? WHERE id = ?",
                               [.text(LibraryPathResolver.join(root: contentDirectory, relative: mapping.relativePath)),
                                .text(mapping.relativePath), .text(mapping.relativePath), .integer(mapping.trackID)])
            }
            for mapping in attachmentMappings {
                try db.execute("UPDATE work_attachment SET relative_path = ? WHERE id = ?",
                               [.text(mapping.relativePath), .integer(mapping.attachmentID)])
            }
            // The reviewed pairing explicitly restores these destinations. A
            // leftover exclusion for one would otherwise delete the repaired
            // record on the next scan. Unselected exclusions remain unchanged.
            for mapping in mappings {
                try db.execute("DELETE FROM excluded_work_file WHERE work_id = ? AND kind = 'track' AND relative_path = ?",
                               [.integer(existingID), .text(mapping.relativePath)])
            }
            for mapping in attachmentMappings {
                try db.execute("DELETE FROM excluded_work_file WHERE work_id = ? AND kind = 'attachment' AND relative_path = ?",
                               [.integer(existingID), .text(mapping.relativePath)])
            }
            let attachmentPathChanges = Dictionary(uniqueKeysWithValues: attachmentMappings.map {
                (attachmentsByID[$0.attachmentID]!.attachment.relativePath, $0.relativePath)
            })
            // Legacy automatic wav/mp3 works keep attachment paths relative to
            // the source, but cover/script references relative to the work.
            // Match the same original file before moving to the new work root.
            func relocatedReference(_ relativePath: String?) -> String? {
                relativePath.map {
                    let attachmentPath = attachmentsUseSourceRoot
                        ? previous.folderRelativePath + "/" + $0 : $0
                    return attachmentPathChanges[attachmentPath] ?? $0
                }
            }
            let cover = relocatedReference(previous.coverPath)
            let script = relocatedReference(previous.scriptPath)
            try db.execute("""
                UPDATE work SET source_id = ?, folder_path = ?, folder_rel = ?, cover_path = ?, script_path = ? WHERE id = ?
                """, [.integer(sourceID), .text(normalizedFolder), .text(folderRelativePath),
                      .optional(cover), .optional(script), .integer(existingID)])

            if sourceID != previous.sourceID || (repairingFileIdentity && folderRelativePath != previous.folderRelativePath) {
                try db.execute("INSERT OR IGNORE INTO excluded_source_work(source_id, folder_rel) VALUES (?, ?)",
                               [.integer(previous.sourceID), .text(previous.folderRelativePath)])
            }
            // Explicitly choosing this destination restores only this work's
            // exact exclusion. All other work/file exclusions remain untouched.
            try restoreExplicitWork(sourceID: sourceID, folder: folderRelativePath)
            return sourceID
        }
    }

    private static func sourceRelativePath(_ track: TrackRecord, work: WorkRecord) -> String {
        let prefix = work.folderPath.hasSuffix("/") ? work.folderPath : work.folderPath + "/"
        if track.filePath.hasPrefix(prefix) { return String(track.filePath.dropFirst(prefix.count)) }
        return track.relativePath ?? track.fileName
    }

    private static func validRelinkingRelativePath(_ path: String) -> Bool {
        !path.contains("\0") && LibraryPathResolver.assetPath(relative: path, assetsRoot: "/") != nil
    }

    private static func absoluteRelinkingPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
