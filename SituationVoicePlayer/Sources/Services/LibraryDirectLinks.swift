import Foundation

extension LibraryStore {
    func directLinks(for work: WorkRecord) -> [DirectLinkMetadata] {
        (try? repository?.directLinks(workID: work.id)) ?? []
    }

    func importSoundgasm(_ page: SoundgasmPage, library: MediaLibraryKind, creatorID: Int64?,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard !phase.isBusy, let repository else { throw DirectLinkError.message(InterfaceLocalization.text("请等待当前导入完成。")) }
        let link = try DirectLink(page.metadata.sourceURL, site: .soundgasm)
        guard try repository.workForDirectLink(link, library: library) == nil else {
            throw DirectLinkError.message(InterfaceLocalization.text("这个 Soundgasm 链接已在所选媒体库中，已有作品保持原样。"))
        }
        let local = try await DirectLinkDownloader.fetch(page.audioURL, limit: 2 * 1024 * 1024 * 1024, extension: "m4a",
                                                         allowed: { DirectLink.isSoundgasmAudio($0) }, progress: progress)
        defer { try? FileManager.default.removeItem(at: local) }
        try Task.checkCancellation()
        try await importAudioWorks([local], library: library, creatorID: creatorID, directLink: page.metadata)
    }

    /// Full text attachment, subtitle source and attribution are committed together.
    func importScriptbin(_ document: ScriptbinDocument, into work: WorkRecord,
                         files: [(name: String, rows: [ScriptImportAssignment])], activate: Bool) throws {
        guard let repository, let subtitleRepository else { throw LibraryEditingError.unavailable }
        let link = try DirectLink(document.metadata.sourceURL, site: .scriptbin)
        guard try !repository.directLinks(workID: work.id).contains(where: { $0.sourceURL == link.url.absoluteString }) else {
            throw DirectLinkError.message(InterfaceLocalization.text("这个 Scriptbin 链接已保存到本作品，已有台本和编辑版本保持原样。"))
        }
        let trackIDs = Set(try repository.tracks(workID: work.id).filter { !$0.isVideo }.map(\.id))
        let selected = files.flatMap(\.rows).compactMap(\.trackID)
        guard !selected.isEmpty, Set(selected).isSubset(of: trackIDs) else { throw ScriptImportFailure.noSelection }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("scriptbin-" + UUID().uuidString + ".txt")
        try Data(document.text.utf8).write(to: temp, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temp) }
        let copied = try WorkAssetImporter.copyAttachment(from: temp, workID: work.id)
        // Keep the imported title in the visible attachment, independently of its UUID storage path.
        let attachment = WorkAttachmentRecord(workID: work.id,
            attachment: WorkAttachment(relativePath: "Scriptbin · " + String(document.metadata.title.prefix(140)).replacingOccurrences(of: "/", with: "／") + ".txt",
                                       kind: .text, byteCount: Int64(document.text.utf8.count)),
            assetRelativePath: copied.assetRelativePath)
        do {
            try repository.db.transaction {
                try repository.appendOwnedMedia(workID: work.id, tracks: [], attachments: [attachment])
                _ = try subtitleRepository.importScriptFiles(files, activate: activate)
                try repository.saveDirectLink(document.metadata, workID: work.id)
            }
        } catch {
            if let path = attachment.assetRelativePath { WorkAssetImporter.remove(path) }
            throw error
        }
        reload()
        importedSubtitleTracks.send(Set(selected))
    }
}
