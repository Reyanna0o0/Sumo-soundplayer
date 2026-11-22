import Foundation

/// Owns only the newly copied audio until an explicit commit. The original file
/// and every earlier App-owned copy are outside this object's cleanup scope.
@MainActor
final class PendingAudioRelink: Identifiable {
    let id: UUID
    let workID: Int64
    let trackID: Int64
    let previousFileName: String
    let previousDurationMS: Int?
    let selectedFileName: String
    let durationMS: Int
    let byteCount: Int64
    fileprivate let expected: OwnedAudioRelinkSnapshot
    fileprivate let copied: TrackRecord
    fileprivate let repository: LibraryRepository
    private enum State { case pending, committed, discarded }
    private var state = State.pending

    fileprivate init(expected: OwnedAudioRelinkSnapshot, copied: TrackRecord, repository: LibraryRepository) {
        id = UUID()
        self.expected = expected
        self.copied = copied
        self.repository = repository
        workID = expected.work.id
        trackID = expected.track.id
        previousFileName = expected.track.fileName
        previousDurationMS = expected.track.durationMS
        selectedFileName = copied.fileName
        durationMS = copied.durationMS ?? 0
        byteCount = copied.fileSize ?? 0
    }

    fileprivate var isPending: Bool { state == .pending }
    fileprivate func retainCommittedCopy() { state = .committed }

    fileprivate func discard() {
        guard state == .pending else { return }
        state = .discarded
        if let asset = copied.assetRelativePath { WorkAssetImporter.remove(asset) }
    }

    deinit {
        if state == .pending, let asset = copied.assetRelativePath { WorkAssetImporter.remove(asset) }
    }
}

extension LibraryStore {
    func prepareAudioRelink(for work: WorkRecord, trackID: Int64, selectedURL: URL) async throws -> PendingAudioRelink {
        guard !phase.isBusy else { throw WorkRelinkError.message(InterfaceLocalization.text("请等待当前导入或文件处理完成，再重新选择音频。")) }
        guard let repository else { throw LibraryEditingError.unavailable }
        let expected = try repository.ownedAudioRelinkSnapshot(workID: work.id, trackID: trackID)
        try Task.checkCancellation()
        setImportPhase(.scanning(found: 1))
        var copied: TrackRecord?
        do {
            let operation = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let result = try WorkAssetImporter.copyAudio(from: selectedURL, workID: work.id)
                do {
                    try Task.checkCancellation()
                    return result
                } catch {
                    if let asset = result.assetRelativePath { WorkAssetImporter.remove(asset) }
                    throw error
                }
            }
            copied = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            guard let copied else { throw OwnedAudioRelinkingError.invalidAudio }
            try validateAudioRelinkCopy(copied)
            let pending = PendingAudioRelink(expected: expected, copied: copied, repository: repository)
            clearPhase()
            return pending
        } catch {
            if let asset = copied?.assetRelativePath { WorkAssetImporter.remove(asset) }
            if error is CancellationError { clearPhase() }
            else { reportError(InterfaceLocalization.text("音频未替换：\(error.localizedDescription)")) }
            throw error
        }
    }

    /// Failure consumes the pending copy. The UI can then choose another file;
    /// retrying a committed/cancelled object can never delete the current source.
    func commitAudioRelink(_ pending: PendingAudioRelink) throws {
        var ownsPhase = false
        do {
            guard pending.isPending else { throw OwnedAudioRelinkingError.alreadyFinished }
            guard !phase.isBusy else { throw WorkRelinkError.message(InterfaceLocalization.text("请等待当前导入或文件处理完成，再重新选择音频。")) }
            guard let repository, repository === pending.repository else { throw OwnedAudioRelinkingError.staleSelection }
            setImportPhase(.saving(current: 0, total: 1))
            ownsPhase = true
            try validateAudioRelinkCopy(pending.copied)
            let updated = try repository.replaceOwnedAudio(expected: pending.expected, with: pending.copied, operationID: pending.id)
            // No fallible operation may remove the file after the DB has committed.
            pending.retainCommittedCopy()
            let work = (try? repository.work(id: pending.workID)) ?? pending.expected.work
            let path = updated.assetRelativePath.flatMap(WorkAssetImporter.path) ?? pending.copied.filePath
            let fallback = PlaybackQueueItem(workID: work.id, trackID: updated.id, workTitle: work.title,
                trackTitle: updated.displayTitle, subtitle: creator(id: work.creatorID)?.name,
                filePath: path, fileType: updated.fileType, durationMS: updated.durationMS, category: updated.category)
            clearPhase()
            finishAudioSourceReplacement(fallback)
        } catch {
            pending.discard()
            if ownsPhase { reportError(InterfaceLocalization.text("音频未替换：\(error.localizedDescription)")) }
            throw error
        }
    }

    func cancelAudioRelink(_ pending: PendingAudioRelink) { pending.discard() }

    private func validateAudioRelinkCopy(_ copied: TrackRecord) throws {
        guard let asset = copied.assetRelativePath,
              let path = WorkAssetImporter.path(for: asset),
              URL(fileURLWithPath: path).standardizedFileURL.path == URL(fileURLWithPath: copied.filePath).standardizedFileURL.path else {
            throw OwnedAudioRelinkingError.invalidAudio
        }
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == copied.fileSize,
              values.contentModificationDate == copied.fileMtime,
              copied.durationMS.map({ $0 > 0 }) == true, copied.fileSize.map({ $0 > 0 }) == true else {
            throw OwnedAudioRelinkingError.invalidAudio
        }
    }
}
