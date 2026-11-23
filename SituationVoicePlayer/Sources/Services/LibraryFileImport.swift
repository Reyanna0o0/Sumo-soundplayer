import Foundation
import AVFoundation

/// New local-file imports never replace an existing work or reuse its IDs.
extension LibraryStore {
    func importAudioWorks(_ urls: [URL], library: MediaLibraryKind, creatorID: Int64?,
                          directLink: DirectLinkMetadata? = nil) async throws {
        guard !phase.isBusy, !urls.isEmpty else { throw WorkRelinkError.message(InterfaceLocalization.text("请选择音频，并等待当前导入完成。")) }
        guard let repository else { throw LibraryEditingError.unavailable }
        if let directLink {
            guard urls.count == 1, directLink.site == .soundgasm else { throw DirectLinkError.message(InterfaceLocalization.text("链接导入内容无效。")) }
            let link = try DirectLink(directLink.sourceURL, site: .soundgasm)
            guard try repository.workForDirectLink(link, library: library) == nil else {
                throw DirectLinkError.message(InterfaceLocalization.text("这个 Soundgasm 链接已在所选媒体库中，已有作品保持原样。"))
            }
        }
        setImportPhase(.scanning(found: urls.count))
        var copied: [TrackRecord] = []
        do {
            let operation = Task.detached(priority: .userInitiated) {
                var result: [TrackRecord] = []
                do {
                    for url in urls {
                        try Task.checkCancellation()
                        result.append(try WorkAssetImporter.copyAudio(from: url, workID: 0))
                    }
                    try Task.checkCancellation()
                    return result
                } catch {
                    result.compactMap(\.assetRelativePath).forEach(WorkAssetImporter.remove)
                    throw error
                }
            }
            copied = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            setImportPhase(.saving(current: 0, total: copied.count))
            try repository.db.transaction {
                let sourceID = try repository.saveSource(LibrarySource(name: "单独导入的音频", type: .local, grouping: .childrenAsWorks))
                for (index, original) in copied.enumerated() {
                    let key = UUID().uuidString
                    let workID = try repository.upsertWork(WorkRecord(
                        title: directLink?.title ?? (original.fileName as NSString).deletingPathExtension,
                        folderPath: "owned-audio/" + key, folderRelativePath: key,
                        sourceID: sourceID, libraryKind: library,
                        creatorID: library == .personal ? creatorID : nil))
                    var track = original
                    track.workID = workID
                    if let directLink { track.fileName = String(directLink.title.prefix(180)) + ".m4a" }
                    try repository.appendOwnedMedia(workID: workID, tracks: [track], attachments: [])
                    if let directLink { try repository.saveDirectLink(directLink, workID: workID) }
                    setImportPhase(.saving(current: index + 1, total: copied.count))
                }
            }
            setCurrentLibrary(library)
            reload()
            setImportSummary(InterfaceLocalization.text("每个音频已保存为一个独立作品"))
            setImportPhase(.done(works: copied.count, tracks: copied.count, subtitles: 0, unmatchedSubtitles: 0, pendingPDFs: 0))
        } catch {
            copied.compactMap(\.assetRelativePath).forEach(WorkAssetImporter.remove)
            if error is CancellationError { clearPhase() }
            else { reportError(InterfaceLocalization.text("导入失败：\(error.localizedDescription)")) }
            throw error
        }
    }

    func hasImportedZIP(_ digest: String, library: MediaLibraryKind) throws -> Bool {
        guard let repository else { return false }
        let original = try repository.setting("importedZIP.\(library.rawValue).\(digest)") ?? ""
        let copies = try repository.setting("importedZIPCopies.\(library.rawValue).\(digest)") ?? ""
        for sourceID in Set((original + "," + copies).split(separator: ",").compactMap { Int64($0) }) {
            if try !repository.works(sourceID: sourceID).isEmpty { return true }
        }
        return false
    }

    /// File copying, decoding and script parsing finish before the one DB transaction.
    func importZIP(_ archive: PreparedZIPImport, grouping: ScanOptions.Grouping,
                   library: MediaLibraryKind, creatorID: Int64?, importIndependentCopy: Bool = false) async throws {
        guard !phase.isBusy else { throw WorkRelinkError.message(InterfaceLocalization.text("请等待当前导入完成。")) }
        guard let repository, let subtitleRepository else { throw LibraryEditingError.unavailable }
        guard try importIndependentCopy || !hasImportedZIP(archive.archiveSHA256, library: library) else {
            throw WorkRelinkError.message(InterfaceLocalization.text("这个 ZIP 已导入当前媒体库，已有作品没有改动。"))
        }
        setImportPhase(.scanning(found: 0))
        do {
            let originalName = archive.originalFileName
            let staging = archive.stagingURL
            let operation = Task.detached(priority: .userInitiated) {
                try PreparedArchiveLibrary.read(root: staging, originalName: originalName, grouping: grouping)
            }
            let prepared = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            guard !prepared.works.isEmpty else { throw WorkRelinkError.message(InterfaceLocalization.text("ZIP 中没有找到可导入的音频或视频，请检查作品划分方式。")) }
            let final = try archive.promote()
            let bookmark = try FolderImporter.makeBookmark(for: final)
            let attachmentGroups = discoveredAttachments(files: prepared.files, works: prepared.works.map(\.scan), grouping: grouping)
            var audioCount = 0, subtitleCount = 0, unmatched = 0, pendingPDFs = 0
            var importedIDs = Set<Int64>()
            setImportPhase(.saving(current: 0, total: prepared.works.count))
            try repository.db.transaction {
                let sourceID = try repository.saveSource(LibrarySource(name: originalName, rootPath: final.path,
                    bookmark: bookmark, grouping: grouping))
                var reservedTitles = Set(try repository.works(libraryKind: library).map(\.title))
                for (index, work) in prepared.works.enumerated() {
                    let scan = work.scan
                    let workIdentity = LibraryPathResolver.join(root: final.path, relative: scan.folderRelativePath)
                    let workRoot = LibraryPathResolver.workDirectory(root: final.path, workRelativePath: scan.folderRelativePath, grouping: grouping)
                    let workID = try repository.upsertWork(WorkRecord(title: scan.title, rjCode: scan.rjCode,
                        circleName: library == .collection ? scan.circleName : nil,
                        seiyuuName: library == .collection ? scan.seiyuuName : nil,
                        coverPath: scan.coverRelativePath, folderPath: workIdentity,
                        folderRelativePath: LibraryRepository.storageKey(relativePath: scan.folderRelativePath, absolutePath: workIdentity),
                        sourceID: sourceID, scriptPath: scan.scriptRelativePath,
                        libraryKind: library, creatorID: library == .personal ? creatorID : nil))
                    let tracks = work.tracks.map { item -> TrackRecord in
                        var copy = item
                        copy.id = 0; copy.workID = workID
                        copy.filePath = LibraryPathResolver.join(root: workRoot, relative: copy.relativePath ?? copy.fileName)
                        return copy
                    }
                    try repository.replaceTracks(workID: workID, tracks: tracks)
                    if importIndependentCopy, let imported = try repository.work(id: workID) {
                        // Use the same metadata overrides as manual renaming, so rescans
                        // preserve the name (including personal-library single-track titles).
                        var number = 1
                        var copyTitle = InterfaceLocalization.text("\(imported.title) · 副本 \(number)")
                        while reservedTitles.contains(copyTitle) {
                            number += 1
                            copyTitle = InterfaceLocalization.text("\(imported.title) · 副本 \(number)")
                        }
                        reservedTitles.insert(copyTitle)
                        if library == .personal {
                            try repository.savePersonalWorkMetadata(workID: workID, title: copyTitle, creatorID: creatorID)
                        } else {
                            try repository.updateWorkMetadata(workID: workID, title: copyTitle,
                                circleName: imported.circleName ?? "", seiyuuNames: imported.seiyuuNames)
                        }
                    }
                    try repository.replaceScannedAttachments(workID: workID, files: attachmentGroups[scan.folderRelativePath] ?? [])
                    let persisted = try repository.tracks(workID: workID)
                    let byRelativePath = Dictionary(uniqueKeysWithValues: persisted.map { ($0.relativePath ?? $0.fileName, $0.id) })
                    let ids = Dictionary(uniqueKeysWithValues: work.tracks.compactMap { old -> (Int64, Int64)? in
                        byRelativePath[old.relativePath ?? old.fileName].map { (old.id, $0) }
                    })
                    for sidecar in work.sidecars {
                        guard let trackID = ids[sidecar.temporaryTrackID] else { throw LibraryEditingError.staleTrackOrder }
                        _ = try subtitleRepository.createTrack(trackID: trackID, kind: .sidecar,
                            language: sidecar.language, label: sidecar.label, cues: sidecar.cues,
                            note: "导入 ZIP 时自动配对", activate: true)
                        importedIDs.insert(trackID); subtitleCount += 1
                    }
                    let durations = Dictionary(uniqueKeysWithValues: persisted.compactMap { t in t.durationMS.map { (t.id, $0) } })
                    for document in work.pdfs.documents {
                        let assignments = document.assignments.map { row -> ScriptImportAssignment in
                            var copy = row; copy.trackID = row.trackID.flatMap { ids[$0] }; return copy
                        }
                        _ = try subtitleRepository.importScriptSections(assignments, fileName: document.relativePath,
                            automatically: true, durationsMS: durations)
                        importedIDs.formUnion(assignments.compactMap(\.trackID))
                    }
                    audioCount += persisted.count
                    unmatched += work.unmatchedSubtitles
                    pendingPDFs += work.pdfs.forReview.count
                    setImportPhase(.saving(current: index + 1, total: prepared.works.count))
                }
                let key = "importedZIPCopies.\(library.rawValue).\(archive.archiveSHA256)"
                let old = try repository.setting(key) ?? ""
                try repository.setSetting(key, old.isEmpty ? String(sourceID) : old + "," + String(sourceID))
                if try repository.setting("importedZIP.\(library.rawValue).\(archive.archiveSHA256)") == nil {
                    try repository.setSetting("importedZIP.\(library.rawValue).\(archive.archiveSHA256)", String(sourceID))
                }
            }
            // retain is an in-memory ownership transfer after a successful commit.
            archive.retain()
            setCurrentLibrary(library)
            reload()
            importedSubtitleTracks.send(importedIDs)
            setImportSummary(pendingPDFs > 0 ? InterfaceLocalization.text("\(pendingPDFs) 份 PDF 可在作品菜单手动配对") : InterfaceLocalization.text("ZIP 已保存到 App，原压缩包不受影响"))
            setImportPhase(.done(works: prepared.works.count, tracks: audioCount, subtitles: subtitleCount,
                                 unmatchedSubtitles: unmatched, pendingPDFs: pendingPDFs))
        } catch {
            try? archive.dispose()
            if error is CancellationError { clearPhase() }
            else { reportError(InterfaceLocalization.text("ZIP 导入失败：\(error.localizedDescription)")) }
            throw error
        }
    }
}

private struct PreparedArchiveLibrary: Sendable {
    struct Sidecar: Sendable {
        var temporaryTrackID: Int64
        var label: String
        var language: String?
        var cues: [SubtitleCue]
    }
    struct Work: Sendable {
        var scan: ScannedWork
        var tracks: [TrackRecord]
        var sidecars: [Sidecar]
        var unmatchedSubtitles: Int
        var pdfs: AutomaticPDFScripts.Result
    }
    var files: [ScannedFile]
    var works: [Work]

    static func scan(root: URL, originalName: String, grouping: ScanOptions.Grouping) throws -> ([ScannedFile], [ScannedWork]) {
        let files = try FolderImporter.enumerate(url: root, rootPath: root.path)
        var works = LibraryScanner.plan(files: files, sourceRoot: root.path,
            options: ScanOptions(includeVideos: true, separateAudioFormats: true, grouping: grouping))
        for index in works.indices where works[index].folderRelativePath.isEmpty {
            let classification = FolderClassifier.classify(name: (originalName as NSString).deletingPathExtension)
            works[index].title = classification.cleanedTitle.isEmpty ? (originalName as NSString).deletingPathExtension : classification.cleanedTitle
            works[index].rjCode = classification.rjCode
            works[index].circleName = classification.circle.first
            works[index].seiyuuName = classification.seiyuu.isEmpty ? nil : classification.seiyuu.joined(separator: "、")
        }
        return (files, works)
    }

    static func read(root: URL, originalName: String, grouping: ScanOptions.Grouping) throws -> PreparedArchiveLibrary {
        let (files, scans) = try scan(root: root, originalName: originalName, grouping: grouping)
        var result: [Work] = []
        for scan in scans {
            try Task.checkCancellation()
            var tracks: [TrackRecord] = []
            for (index, audio) in scan.tracks.filter({ !$0.isVideo }).enumerated() {
                try Task.checkCancellation()
                let file: AVAudioFile
                do { file = try AVAudioFile(forReading: URL(fileURLWithPath: audio.filePath)) }
                catch { throw WorkAssetImportError.unreadableAudio(audio.fileName) }
                let rate = file.processingFormat.sampleRate
                guard file.length > 0, rate.isFinite, rate > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024) else {
                    throw WorkAssetImportError.unreadableAudio(audio.fileName)
                }
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { throw WorkAssetImportError.unreadableAudio(audio.fileName) }
                tracks.append(TrackRecord(id: -Int64(index + 1), workID: 0, fileName: audio.fileName,
                    filePath: audio.filePath, relativePath: audio.relativePath, fileType: audio.fileType,
                    title: audio.title, durationMS: Int(Double(file.length) * 1000 / rate),
                    fileSize: audio.size, fileMtime: audio.modified, category: audio.category))
            }
            let matches = SubtitleSidecarFinder.importMatches(audioPaths: scan.tracks.flatMap { $0.variants.map(\.filePath) },
                subtitlePaths: scan.subtitlePaths, selectedAudioPaths: Set(tracks.map(\.filePath)))
            var sidecars: [Sidecar] = [], matched = Set<String>()
            for track in tracks {
                try Task.checkCancellation()
                guard let selected = matches[track.filePath] else { continue }
                let pair = SubtitleSidecarFinder.importPair(for: selected, subtitlePaths: scan.subtitlePaths)
                let match = pair.primary
                let url = URL(fileURLWithPath: match.path)
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024,
                      let text = SubtitleTextDecoder.decode(data: try Data(contentsOf: url)) else { continue }
                var cues = SubtitleParser.parse(text, formatHint: match.format).cues
                guard !cues.isEmpty else { continue }
                if let secondary = pair.secondary {
                    let secondaryURL = URL(fileURLWithPath: secondary.path)
                    if let size = try? secondaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       size <= 32 * 1024 * 1024,
                       let data = try? Data(contentsOf: secondaryURL),
                       let text = SubtitleTextDecoder.decode(data: data) {
                        let translation = SubtitleParser.parse(text, formatHint: secondary.format).cues
                        if !translation.isEmpty {
                            cues = SubtitleTranslationMerger.merge(primary: cues, secondary: translation)
                            matched.insert(secondary.path)
                        }
                    }
                }
                sidecars.append(Sidecar(temporaryTrackID: track.id, label: url.lastPathComponent, language: match.languageHint, cues: cues))
                matched.insert(match.path)
            }
            let pdfs = AutomaticPDFScripts.read(paths: scan.scriptCandidates, sourceRoot: root.path,
                workRoot: LibraryPathResolver.workDirectory(root: root.path, workRelativePath: scan.folderRelativePath, grouping: grouping), tracks: tracks)
            result.append(Work(scan: scan, tracks: tracks, sidecars: sidecars,
                unmatchedSubtitles: Set(scan.subtitlePaths).subtracting(matched).count, pdfs: pdfs))
        }
        return PreparedArchiveLibrary(files: files, works: result)
    }
}

extension LibraryStore {
    func makeZIPPreview(_ archive: PreparedZIPImport, grouping: ScanOptions.Grouping) async -> ImportPreview {
        let root = archive.stagingURL, name = archive.originalFileName
        do {
            let (_, works) = try await Task.detached(priority: .userInitiated) {
                try PreparedArchiveLibrary.scan(root: root, originalName: name, grouping: grouping)
            }.value
            var preview = ImportPreview(workCount: works.count, trackCount: works.flatMap(\.tracks).filter { !$0.isVideo }.count,
                videoCount: works.flatMap(\.tracks).filter(\.isVideo).count, titles: works.prefix(8).map(\.title),
                errorMessage: works.isEmpty ? InterfaceLocalization.text("没有找到可导入的音频或视频，请调整作品划分方式。") : nil)
            preview.describeFiles(in: works)
            return preview
        } catch { return ImportPreview(errorMessage: error.localizedDescription) }
    }
}
