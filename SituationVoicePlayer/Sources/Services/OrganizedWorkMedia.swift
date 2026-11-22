import Foundation

extension LibraryStore {
    func organizedSections(for work: WorkRecord, includeEmpty: Bool = false) -> [WorkMediaSection] {
        (try? repository?.organizedSections(workID: work.id, includeEmpty: includeEmpty)) ?? []
    }

    func attachmentRecords(for work: WorkRecord) -> [WorkAttachmentRecord] {
        (try? repository?.attachmentRecords(workID: work.id)) ?? []
    }

    /// After an explicitly paired media rename, its old-named cover/script is
    /// still the same attachment. Retain only references proven present in this
    /// scan; do not turn them into a fresh automatic subtitle import.
    func retainingFileWorkReferences(_ scans: [ScannedWork], sourceID: Int64,
                                     attachments: [String: [WorkAttachment]]) throws -> [ScannedWork] {
        guard let repository else { throw LibraryEditingError.unavailable }
        let previous = Dictionary(uniqueKeysWithValues: try repository.works(sourceID: sourceID).map { ($0.folderRelativePath, $0) })
        return scans.map { scan in
            guard let old = previous[scan.folderRelativePath] else { return scan }
            var kept = scan
            let available = attachments[scan.folderRelativePath] ?? []
            let parent = (scan.folderAbsolutePath as NSString).deletingLastPathComponent
            if let cover = old.coverPath, available.contains(where: { $0.relativePath == cover && $0.kind == .image }) {
                kept.coverRelativePath = cover
                kept.coverPath = LibraryPathResolver.join(root: parent, relative: cover)
            }
            if let script = old.scriptPath, available.contains(where: {
                $0.relativePath == script && [.pdf, .text, .document].contains($0.kind)
            }) {
                kept.scriptRelativePath = script
                kept.scriptPath = LibraryPathResolver.join(root: parent, relative: script)
            }
            return kept
        }
    }

    /// Scanned work roots are the source root or its direct children. Index the files once.
    func discoveredAttachments(files: [ScannedFile], works: [ScannedWork], grouping: ScanOptions.Grouping,
                               sourceID: Int64? = nil) -> [String: [WorkAttachment]] {
        if grouping == .filesAsWorks {
            let byPath = Dictionary(grouping: files, by: \.relativePath)
            let directories = Dictionary(grouping: files, by: \.directoryRelativePath)
            var retained: [String: [String]] = [:]
            if let sourceID, let repository, let existing = try? repository.works(sourceID: sourceID) {
                for work in existing {
                    retained[work.folderRelativePath] = (try? repository.attachmentRecords(workID: work.id))?
                        .filter { $0.assetRelativePath == nil }.map { $0.attachment.relativePath } ?? []
                }
            }
            return Dictionary(uniqueKeysWithValues: works.map { work in
                let media = byPath[work.folderRelativePath]?.first
                let companions = media.map { LibraryScanner.files(forIndividualMedia: $0,
                    in: directories[$0.directoryRelativePath] ?? [], retainingCompanions: retained[work.folderRelativePath] ?? []) } ?? []
                let attachments = companions.compactMap { file -> WorkAttachment? in
                    guard let kind = WorkAttachmentFinder.kind(forExtension: file.fileExtension) else { return nil }
                    return WorkAttachment(relativePath: file.fileName, kind: kind, byteCount: file.size)
                }.sorted { NaturalSort.compare($0.relativePath, $1.relativePath) }
                return (work.folderRelativePath, attachments)
            })
        }
        let keys = Set(works.map(\.folderRelativePath))
        let root: String?
        if keys.contains("") { root = "" }
        else if grouping == .automatic, works.count == 1,
                let key = works.first?.folderRelativePath, WorkAttachmentFinder.isLegacyFormatFolder(key) { root = key }
        else { root = nil }
        var result: [String: [WorkAttachment]] = [:]
        for file in files {
            guard let kind = WorkAttachmentFinder.kind(forExtension: file.fileExtension) else { continue }
            let key: String, relative: String
            if let root {
                key = root
                relative = file.relativePath
            } else {
                guard let slash = file.relativePath.firstIndex(of: "/") else { continue }
                key = String(file.relativePath[..<slash])
                guard keys.contains(key) else { continue }
                relative = String(file.relativePath[file.relativePath.index(after: slash)...])
            }
            result[key, default: []].append(WorkAttachment(relativePath: relative, kind: kind, byteCount: file.size))
        }
        return result.mapValues { $0.sorted { NaturalSort.compare($0.relativePath, $1.relativePath) } }
    }

    func refreshAttachments(for work: WorkRecord) async throws {
        let expectedRelinkRevision = fileRelinkRevision
        guard let repository else { throw LibraryEditingError.unavailable }
        guard let source = attachmentSource(for: work) else {
            let audio = try repository.tracks(workID: work.id)
            let attachments = try repository.attachmentRecords(workID: work.id)
            let ownedOnlySource = work.folderPath.hasPrefix("owned-audio/")
                && sources.contains { $0.id == work.sourceID && $0.type == .local && $0.rootPath == nil && $0.bookmark == nil }
            if (!audio.isEmpty || !attachments.isEmpty || ownedOnlySource),
               audio.allSatisfy({ $0.assetRelativePath != nil }),
               attachments.allSatisfy({ $0.assetRelativePath != nil }) { return }
            throw LibraryEditingError.unavailable
        }
        let files = try await Task.detached(priority: .userInitiated) {
            try WorkAttachmentAccess.scan(source).1
        }.value
        try Task.checkCancellation()
        guard fileRelinkRevision == expectedRelinkRevision,
              let current = try repository.work(id: work.id), attachmentSource(for: current) == source else {
            throw CancellationError()
        }
        try repository.validateAttachmentRescan(workID: work.id, files: files)
        try repository.replaceScannedAttachments(workID: work.id, files: files)
        if let summary = try repository.work(id: work.id),
           works.first(where: { $0.id == work.id })?.videoCount != summary.videoCount {
            reload()
        }
    }

    func openAttachment(_ record: WorkAttachmentRecord, in work: WorkRecord) throws -> (url: URL, lease: WorkAttachmentDirectoryLease) {
        guard record.workID == work.id else { throw LibraryEditingError.staleTrackOrder }
        if let path = record.assetRelativePath, let absolute = WorkAssetImporter.path(for: path) {
            let url = URL(fileURLWithPath: absolute)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
            return (url, WorkAttachmentDirectoryLease(directory: url.deletingLastPathComponent(), accessedURL: url, needsStop: false))
        }
        guard let source = attachmentSource(for: work) else { throw LibraryEditingError.unavailable }
        let lease = try WorkAttachmentAccess.open(source)
        guard let url = WorkAttachmentFinder.fileURL(for: record.attachment, in: lease.directory),
              FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
        return (url, lease)
    }

    func addMediaFiles(_ urls: [URL], to work: WorkRecord) async throws -> Int {
        guard let repository else { throw LibraryEditingError.unavailable }
        let (tracks, files) = try await Task.detached(priority: .userInitiated) {
            var tracks: [TrackRecord] = []
            var files: [WorkAttachmentRecord] = []
            do {
                for url in urls {
                    try Task.checkCancellation()
                    if WorkAttachmentFinder.kind(forExtension: url.pathExtension) != nil {
                        files.append(try WorkAssetImporter.copyAttachment(from: url, workID: work.id))
                    } else if MediaExtensions.audio.contains(url.pathExtension.lowercased()) {
                        tracks.append(try WorkAssetImporter.copyAudio(from: url, workID: work.id))
                    } else {
                        throw WorkAssetImportError.unsupportedFile(url.lastPathComponent)
                    }
                }
                return (tracks, files)
            } catch {
                for path in tracks.compactMap(\.assetRelativePath) + files.compactMap(\.assetRelativePath) { WorkAssetImporter.remove(path) }
                throw error
            }
        }.value
        do {
            try Task.checkCancellation()
            try repository.appendOwnedMedia(workID: work.id, tracks: tracks, attachments: files)
        } catch {
            for path in tracks.compactMap(\.assetRelativePath) + files.compactMap(\.assetRelativePath) { WorkAssetImporter.remove(path) }
            throw error
        }
        reload()
        return urls.count
    }

    func moveMedia(_ id: WorkMediaID, in work: WorkRecord, toCategory category: String, relativeTo: WorkMediaID?, after: Bool) throws {
        guard let repository else { throw LibraryEditingError.unavailable }
        try repository.moveMedia(workID: work.id, item: id, to: category, relativeTo: relativeTo, after: after)
        reload()
    }

    func applyReorder(_ payload: WorkReorderPayload, in work: WorkRecord,
                      to destination: WorkDropDestination, expected: WorkReorderSnapshot) throws {
        guard payload.workID == work.id, let repository else { throw LibraryEditingError.staleTrackOrder }
        if try repository.applyReorder(payload: payload, to: destination, expected: expected) { reload() }
    }

    func reorderCategories(in work: WorkRecord, keys: [String]) throws {
        guard let repository else { throw LibraryEditingError.unavailable }
        try repository.reorderCategories(workID: work.id, keys: keys)
        reload()
    }

    func removeTrack(_ track: TrackRecord, in work: WorkRecord) throws {
        guard let repository else { throw LibraryEditingError.unavailable }
        let owned = try repository.removeMedia(workID: work.id, id: .track(track.id))
        removedTrackIDs.send([track.id])
        if let owned { WorkAssetImporter.remove(owned) }
        reload()
    }

    func removeAttachment(_ record: WorkAttachmentRecord, in work: WorkRecord) throws {
        guard let repository else { throw LibraryEditingError.unavailable }
        let owned = try repository.removeMedia(workID: work.id, id: .attachment(record.id))
        removedAttachmentIDs.send([record.id])
        if let owned { WorkAssetImporter.remove(owned) }
        reload()
    }

    func removeWorkFromLibrary(_ work: WorkRecord) throws {
        guard let repository else { throw LibraryEditingError.unavailable }
        let callProfile = try repository.callProfile(ownerKind: .work, id: work.id)
        let ids = Set(try repository.tracks(workID: work.id).map(\.id))
        let attachmentIDs = Set(try repository.attachmentRecords(workID: work.id).map(\.id))
        let owned = try repository.removeWorkFromLibrary(workID: work.id)
        removedAttachmentIDs.send(attachmentIDs)
        removedTrackIDs.send(ids)
        removeUnreferencedCallAssets(owned + [callProfile?.avatarAssetPath, callProfile?.backgroundAssetPath].compactMap { $0 })
        reload()
    }
}
