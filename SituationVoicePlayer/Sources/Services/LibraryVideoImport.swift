import Foundation
import AVFoundation

private struct LibraryVideoImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 每个视频单独成为一个作品：原文件只复制到 App，作品通过 work_attachment 的 video 记录保存，不新建 track。
extension LibraryStore {
    func importVideoWorks(_ urls: [URL], library: MediaLibraryKind, creatorID: Int64?) async throws {
        guard !phase.isBusy, !urls.isEmpty else { throw LibraryVideoImportError(message: InterfaceLocalization.text("请选择视频，并等待当前导入完成。")) }
        guard let repository else { throw LibraryEditingError.unavailable }
        for url in urls {
            guard WorkAttachmentFinder.kind(forExtension: url.pathExtension) == .video else {
                throw LibraryVideoImportError(message: InterfaceLocalization.text("「\(url.lastPathComponent)」不是可导入的视频文件，当前选择的内容没有导入。"))
            }
        }
        setImportPhase(.scanning(found: urls.count))
        var copied: [WorkAttachmentRecord] = []
        do {
            // detached 中先复制原文件，再用 PreparedWorkVideo.prepare 验证可播放（含 AVI remux），
            // 但保存的是原文件副本，remux 结果只用于验证。
            let operation = Task.detached(priority: .userInitiated) {
                var result: [WorkAttachmentRecord] = []
                func locate(_ path: String?) -> URL? {
                    path.flatMap(WorkAssetImporter.path).map { URL(fileURLWithPath: $0) }
                }
                do {
                    for url in urls {
                        try Task.checkCancellation()
                        let record = try WorkAssetImporter.copyAttachment(from: url, workID: 0)
                        result.append(record)
                        try Task.checkCancellation()
                        guard let copy = locate(record.assetRelativePath) else {
                            throw LibraryVideoImportError(message: InterfaceLocalization.text("「\(url.lastPathComponent)」复制失败，请重新选择。"))
                        }
                        // 返回值的 url 可能是 AVI remux 的临时文件，随预览释放；保存的仍是原副本。
                        withExtendedLifetime(try await PreparedWorkVideo.prepare(copy)) {}
                        try Task.checkCancellation()
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
                let sourceID = try repository.saveSource(LibrarySource(name: "单独导入的视频", type: .local, grouping: .childrenAsWorks))
                for (index, original) in copied.enumerated() {
                    let key = UUID().uuidString
                    let title = (original.attachment.relativePath as NSString).deletingPathExtension
                    let workID = try repository.upsertWork(WorkRecord(
                        title: title,
                        // 与单独导入的音频使用同一前缀，兼容现有 owned-only-source 判断；视频本身仍按附件 kind 区分。
                        folderPath: "owned-audio/" + key, folderRelativePath: key,
                        sourceID: sourceID, libraryKind: library,
                        creatorID: library == .personal ? creatorID : nil))
                    let attachment = WorkAttachmentRecord(workID: workID, attachment: original.attachment,
                        assetRelativePath: original.assetRelativePath, categoryKey: original.categoryKey,
                        sortOrder: original.sortOrder)
                    try repository.appendOwnedMedia(workID: workID, tracks: [], attachments: [attachment])
                    setImportPhase(.saving(current: index + 1, total: copied.count))
                }
            }
            setCurrentLibrary(library)
            reload()
            setImportSummary(InterfaceLocalization.text("每个视频已保存为一个独立作品，原视频文件保持原样"))
            setImportPhase(.done(works: copied.count, tracks: 0, subtitles: 0, unmatchedSubtitles: 0, pendingPDFs: 0))
        } catch {
            copied.compactMap(\.assetRelativePath).forEach(WorkAssetImporter.remove)
            if error is CancellationError { clearPhase() }
            else { reportError(InterfaceLocalization.text("视频导入失败：\(error.localizedDescription)")) }
            throw error
        }
    }
}
